# Export conditional distributions from the fitted forests for GitHub Pages.
# Run from the project root after analysis/study_cv.R.
library(data.table)
source("analysis/study_inputs.R")
source("analysis/delay_forest.R")

args = commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
  stop("Usage: Rscript analysis/export_dashboard.R PREPARED_DIR CV_RESULTS_DIR DESTINATION_JSON")
}
prepared_dir = args[1]
results_dir = args[2]
manifest = fread(file.path(results_dir, "cv_flight_assignments.csv"))
profiles = fread(file.path(results_dir, "cv_density_profiles.csv"))
delay_grid = seq(-30, 180)
bandwidth = 2.5
threshold = function(x, p) unname(quantile(x, p, type = 1))

read_flight_month = function(month) {
  setDT(arrow::read_parquet(file.path(prepared_dir, paste0("flights-", month, ".parquet"))))
}

summarize_scenarios = function(artifact, scenarios) {
  predicted = predict_delay_distribution(artifact, scenarios)
  mass = predicted$probability
  summary = summarize_forest_mass(mass, predicted$minutes)
  kernel = outer(delay_grid, predicted$minutes, function(z, y) {
    dnorm(z, mean = y, sd = bandwidth)
  })
  pdf = as.matrix(kernel %*% mass)
  lapply(seq_len(nrow(scenarios)), function(i) {
    list(density = unname(round(pdf[, i], 6)), median = summary$median[i],
         q05 = summary$q05[i], q95 = summary$q95[i], p15 = round(summary$p15[i], 6),
         p30 = round(summary$p30[i], 6), p60 = round(summary$p60[i], 6))
  })
}

make_view = function(question_value) {
  artifact = readRDS(file.path(results_dir, "models", paste0(question_value, ".rds")))
  profile = profiles[question == question_value][1L]
  source_month = substr(profile$flight_id, 1L, 7L)
  flight = read_flight_month(source_month)[flight_id == profile$flight_id]
  stopifnot(nrow(flight) == 1L)
  month = format(as.IDate(flight$flight_day), "%m")
  local_ids = manifest[question == question_value & format(as.IDate(flight_day), "%m") == month,
                       flight_id]
  source_months = unique(substr(local_ids, 1L, 7L))
  local = rbindlist(lapply(source_months, function(source) {
    read_flight_month(source)[flight_id %in% local_ids & Origin == flight$Origin]
  }))
  if (question_value != "heat") local = local[abs(turn_minutes - flight$turn_minutes) <= 30]
  distance = function(x, y) abs((x - y + 720) %% 1440 - 720)
  metadata = list(origin = flight$Origin, destination = flight$Dest, date = as.character(flight$flight_day),
                  minute = flight$minute_of_day, turn = flight$turn_minutes,
                  airport_encoding = artifact$airport, traffic_bucket = artifact$bucket)
  if (question_value == "heat") {
    nearby = local[distance(minute_of_day, flight$minute_of_day) <= 60 & is.finite(temperature_c)]
    stopifnot(nrow(nearby) >= 20L)
    range = threshold(nearby$temperature_c, c(0.05, 0.95))
    values = seq(ceiling(range[1L]), floor(range[2L]))
    stopifnot(length(values) >= 3L)
    scenarios = flight[rep(1L, length(values))]
    scenarios[, temperature_c := values]
    return(list(profile = metadata, support = nrow(nearby), initial = which.min(abs(values - flight$temperature_c)) - 1L,
                values = as.list(values), curves = summarize_scenarios(artifact, scenarios)))
  }
  by_time = lapply(seq(5 * 60, 23 * 60, by = 30), function(minute) {
    nearby = local[distance(minute_of_day, minute) <= 60 & is.finite(prior_delay)]
    if (question_value == "cutoff") nearby = nearby[prior_delay <= flight$turn_minutes - 60]
    if (nrow(nearby) < 12L) return(NULL)
    range = threshold(nearby$prior_delay, c(0.10, 0.90))
    if (diff(range) < 5) return(NULL)
    # A five-minute grid anchored to round clock minutes, with both bounds retained.
    values = sort(unique(c(range, seq(5 * ceiling(range[1L] / 5), 5 * floor(range[2L] / 5), by = 5))))
    scenarios = flight[rep(1L, length(values))]
    scenarios[, c("minute_of_day", "prior_delay") := .(minute, values)]
    list(minute = minute, support = nrow(nearby), values = as.list(values),
         curves = summarize_scenarios(artifact, scenarios))
  })
  by_time = Filter(Negate(is.null), by_time)
  stopifnot(length(by_time) >= 4L)
  choice = which.min(abs(vapply(by_time, function(x) x$minute, numeric(1)) - flight$minute_of_day))
  prior = unlist(by_time[[choice]]$values)
  list(profile = metadata, times = by_time, initial_time = choice - 1L,
       initial_prior = which.min(abs(prior - flight$prior_delay)) - 1L)
}

data = list(delay = list(from = min(delay_grid), to = max(delay_grid), step = 1),
            bandwidth = bandwidth, heat = make_view("heat"),
            rotation = make_view("rotation"), cutoff = make_view("cutoff"))
dir.create(dirname(args[3]), recursive = TRUE, showWarnings = FALSE)
jsonlite::write_json(data, args[3], auto_unbox = TRUE, digits = 7)
