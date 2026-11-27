# STAT4P87 linear regression, validation, and residual density diagnostics.
library(arrow)
library(data.table)
setDTthreads(2)

args = commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) stop("Usage: Rscript analysis/linear_study.R PREPARED_DIR OUTPUT_DIR")
dir.create(args[2], recursive = TRUE, showWarnings = FALSE)
months = format(seq(as.Date("2023-01-01"), as.Date("2024-12-01"), by = "month"), "%Y-%m")
paths = file.path(args[1], paste0("flights-", months, ".parquet"))
if (!all(file.exists(paths))) stop("Run prepare_study.R before fitting.")
set.seed(487)
sample_rows = function(data, n) {
  data[sample.int(nrow(data), min(nrow(data), n))]
}
samples = lapply(paths, function(path) {
  flights = setDT(read_parquet(path))
  setorder(flights, flight_id)
  flights = flights[complete.cases(traffic_daily, traffic_weekly, origin_lat, origin_lon,
                                  Distance, Reporting_Airline)]
  flights[, flight_day := as.IDate(flight_day)]
  flights[, calendar_month := format(flight_day, "%m")]
  flights[, month_sin := sin(2 * pi * as.integer(calendar_month) / 12)]
  flights[, month_cos := cos(2 * pi * as.integer(calendar_month) / 12)]
  flights[, weekday := as.integer(flight_day + 3L) %% 7L]
  flights[, distance_1000 := Distance / 1000]
  flights[, c("origin_lon", "dest_lon") := lapply(.SD, function(x) (x + 240) %% 360 - 240),
          .SDcols = c("origin_lon", "dest_lon")]
  rotation = flights[complete.cases(dest_lat, dest_lon)]
  list(heat = sample_rows(flights[is.finite(temperature_c)], 4500),
       rotation = sample_rows(rotation[is.finite(prior_delay)], 4500),
       cutoff = sample_rows(rotation[prior_known_at_cutoff == TRUE], 4500))
})
cohorts = lapply(c("heat", "rotation", "cutoff"), function(question) {
  rbindlist(lapply(samples, "[[", question))
})
names(cohorts) = c("heat", "rotation", "cutoff")
rm(samples)

# Learn rare-level pooling and weather medians from each fitting period only.
prepare_sets = function(train, calibration, validation, question) {
  sets = lapply(list(train, calibration, validation), copy)
  for (column in c("Origin", "Reporting_Airline", if (question != "heat") "Dest")) {
    counts = table(train[[column]])
    keep = names(counts)[counts >= 75]
    if (length(keep) == length(counts) && length(keep) > 1) {
      keep = setdiff(keep, names(which.min(counts)))
    }
    for (data in sets) {
      value = data[[column]]
      value[!value %in% keep] = "OTHER"
      set(data, j = paste0(column, "_group"), value = factor(value, levels = unique(c(keep, "OTHER"))))
    }
  }
  for (column in c("temperature_c", "wind_speed_kt", "visibility_m")) {
    center = median(train[[column]][is.finite(train[[column]])])
    if (!is.finite(center)) center = 0
    for (data in sets) {
      value = data[[column]]
      missing = !is.finite(value)
      value[missing] = center
      set(data, j = paste0(column, "_missing"), value = as.integer(missing))
      set(data, j = column, value = value)
    }
  }
  for (data in sets) {
    data[, hour := minute_of_day / 60]
    data[, temperature_10 := temperature_c / 10]
    data[, prior_delay_30 := prior_delay / 30]
    data[, turn_hours := turn_minutes / 60]
    data[, traffic_day_100 := traffic_daily / 100]
    data[, traffic_week_100 := traffic_weekly / 100]
    data[, visibility_km := visibility_m / 1000]
    data[, c("calendar_month", "weekday") := lapply(.SD, factor), .SDcols = c("calendar_month", "weekday")]
  }
  if (question == "heat") stopifnot(all(sets[[1]]$temperature_c_missing == 0))
  sets
}

fit_baseline = function(train, question, airports, bucket, include_exposure) {
  terms = c("hour", "distance_1000", "Reporting_Airline_group", "month_sin", "month_cos", "weekday",
            "wind_speed_kt", "wind_speed_kt_missing", "visibility_km", "visibility_m_missing")
  terms = c(terms, if (bucket == "daily") "traffic_day_100" else "traffic_week_100")
  terms = c(terms, if (airports == "factors") "Origin_group" else c("origin_lat", "origin_lon"))
  if (question != "heat") {
    terms = c(terms, if (airports == "factors") "Dest_group" else c("dest_lat", "dest_lon"),
              "temperature_10", "temperature_c_missing", "turn_hours")
  }
  if (include_exposure) terms = c(terms, if (question == "heat") "temperature_10" else "prior_delay_30")
  terms = terms[vapply(train[, ..terms], uniqueN, integer(1)) > 1L]
  lm(reformulate(terms, response = "departure_delay_minutes"), data = train)
}

# CRPS of the empirical predictive CDF. Prefix sums avoid a matrix of pairwise distances.
distribution_scores = function(actual, prediction, residual) {
  residual = sort(residual)
  n = length(residual)
  error = actual - prediction
  k = findInterval(error, residual)
  prefix = c(0, cumsum(residual))
  distance = ((2 * k - n) * error + prefix[n + 1L] - 2 * prefix[k + 1L]) / n
  pairwise_half = sum((2 * seq_len(n) - n - 1) * residual) / n^2
  interval = unname(quantile(residual, c(0.05, 0.95)))
  c(n = length(error), MAE = mean(abs(error)), RMSE = sqrt(mean(error^2)),
    CRPS = mean(distance - pairwise_half),
    coverage90 = mean(error >= interval[1] & error <= interval[2]))
}

folds = data.table(fold = c("Jan-Jun 2024", "Jul-Dec 2024"),
                   calibration_from = as.IDate(c("2023-11-01", "2024-05-01")),
                   validation_from = as.IDate(c("2024-01-01", "2024-07-01")),
                   validation_until = as.IDate(c("2024-07-01", "2025-01-01")))
variants = CJ(airports = c("factors", "coordinates"), bucket = c("daily", "weekly"))
rows = list()
for (question in names(cohorts)) {
  data = cohorts[[question]]
  for (f in seq_len(nrow(folds))) {
    train = data[flight_day < folds$calibration_from[f]]
    calibration = data[flight_day >= folds$calibration_from[f] & flight_day < folds$validation_from[f]]
    validation = data[flight_day >= folds$validation_from[f] & flight_day < folds$validation_until[f]]
    stopifnot(nrow(train) > 0, nrow(calibration) > 0, nrow(validation) > 0)
    sets = prepare_sets(train, calibration, validation, question)
    for (v in seq_len(nrow(variants))) {
      airport = variants$airports[v]
      bucket = variants$bucket[v]
      for (full in c(FALSE, TRUE)) {
        model = fit_baseline(sets[[1]], question, airport, bucket, full)
        residual = calibration$departure_delay_minutes - predict(model, sets[[2]])
        prediction = predict(model, sets[[3]])
        exposure = if (question == "heat") "temperature_10" else "prior_delay_30"
        scores = distribution_scores(validation$departure_delay_minutes, prediction, residual)
        rows[[length(rows) + 1L]] = data.table(question, fold = folds$fold[f], airport, bucket, full,
                                              n_fit = nrow(train), n_calibration = nrow(calibration),
                                              as.data.frame(as.list(scores)), hour_slope = unname(coef(model)["hour"]),
                                              exposure_slope = unname(coef(model)[exposure]))
      }
    }
    message(question, " / ", folds$fold[f], " complete")
  }
}
scores = rbindlist(rows)
fwrite(scores, file.path(args[2], "fold_scores.csv"))
summary = scores[, .(n = sum(n), MAE = weighted.mean(MAE, n), RMSE = sqrt(weighted.mean(RMSE^2, n)),
                     CRPS = weighted.mean(CRPS, n), coverage90 = weighted.mean(coverage90, n)), by = .(question, airport, bucket, full)]
setorder(summary, question, full, CRPS)
fwrite(summary, file.path(args[2], "validation_scores.csv"))

comparison = dcast(scores, question + fold + airport + bucket ~ full,
                   value.var = c("CRPS", "hour_slope"))
comparison[, crps_improvement := CRPS_FALSE - CRPS_TRUE]
comparison[, slope_attenuation := fifelse(hour_slope_FALSE > 0, 1 - hour_slope_TRUE / hour_slope_FALSE, NA_real_)]
fwrite(comparison, file.path(args[2], "exposure_comparisons.csv"))

plot_density = function(question, selected, data) {
  train = data[flight_day < as.IDate("2024-11-01")]
  calibration = data[flight_day >= as.IDate("2024-11-01")]
  profiles = if (question == "heat") data[flight_day >= as.IDate("2024-06-01") &
                                           flight_day < as.IDate("2024-09-01")] else calibration
  sets = prepare_sets(train, calibration, profiles, question)
  model = fit_baseline(sets[[1]], question, selected$airport, selected$bucket, TRUE)
  residual = calibration$departure_delay_minutes - predict(model, sets[[2]])

  reference = copy(sets[[3]])
  # Anchor to a real flight in a populated airport/month/time cell.
  reference[, hour_band := minute_of_day %/% 120L]
  reference[, cell_n := .N, by = .(Origin, calendar_month, hour_band)]
  if (question == "heat") {
    reference[, hot_n := sum(temperature_c >= 30), by = .(Origin, calendar_month, hour_band)]
  }
  candidates = if (question == "heat" && any(reference$hot_n >= 20)) reference[hot_n >= 20] else reference
  cell = candidates[which.max(cell_n)]
  nearby = reference[Origin == cell$Origin & calendar_month == cell$calendar_month & hour_band == cell$hour_band]
  exposure = if (question == "heat") "temperature_c" else "prior_delay"
  model_term = if (question == "heat") "temperature_10" else "prior_delay_30"
  units = if (question == "heat") "degrees C" else "min prior arrival delay"
  pivot = median(nearby[[exposure]])
  profile = nearby[which.min(abs(nearby[[exposure]] - pivot))]
  if (question != "heat") nearby = nearby[abs(turn_minutes - profile$turn_minutes) <= 30]
  levels = unique(round(as.numeric(quantile(nearby[[exposure]], c(0.1, 0.5, 0.9))), 1))
  if (length(levels) < 2L) stop("Diagnostic profile has insufficient exposure variation.")
  scenarios = profile[rep(1L, length(levels))]
  set(scenarios, j = model_term, value = levels / if (question == "heat") 10 else 30)
  prediction = as.numeric(predict(model, scenarios))
  x_limits = unname(quantile(residual, c(0.04, 0.985))) + c(min(prediction), max(prediction))
  if (question == "heat") x_limits[1] = min(-25, x_limits[1])
  # One shared kernel density makes the linear location-shift assumption explicit.
  estimate = density(residual, bw = "nrd0", from = x_limits[1] - max(prediction),
                     to = x_limits[2] - min(prediction), n = 1024)
  colors = c("#255884", "#088574", "#B44924")[seq_along(levels)]
  file = file.path(args[2], paste0(question, "_delay_density.png"))
  png(file, width = 1050, height = 650, res = 130)
  on.exit(dev.off())
  par(mar = c(5.2, 4.6, 4.5, 1))
  plot(estimate$x + prediction[1], estimate$y, type = "n", xlim = x_limits,
       xlab = "Departure delay (minutes)", ylab = "Density",
       main = if (question == "heat") "Departure delay at different temperatures"
              else "Departure delay at different prior arrival delays")
  abline(v = 0, col = "#8A8A8A", lty = 3)
  for (i in seq_along(levels)) lines(estimate$x + prediction[i], estimate$y, col = colors[i], lwd = 2)
  legend("topright", paste(levels, units), col = colors, lwd = 2, bty = "n")
  airport_label = if (question == "heat") paste("Departure airport", profile$Origin)
                  else paste(profile$Origin, "to", profile$Dest)
  mtext(sprintf("%s | %s | %02d:%02d local | %s, %s",
                airport_label, as.character(profile$flight_day),
                profile$minute_of_day %/% 60, profile$minute_of_day %% 60,
                selected$airport, selected$bucket), line = 0.5, cex = 0.78)
  data.table(question, airport = selected$airport, bucket = selected$bucket,
             flight_id = profile$flight_id, origin = profile$Origin, destination = profile$Dest,
             flight_day = profile$flight_day, minute_of_day = profile$minute_of_day,
             local_comparison_n = nrow(nearby), exposure = levels, prediction = prediction,
             q10 = prediction + unname(quantile(residual, 0.1)), q90 = prediction + unname(quantile(residual, 0.9)),
             x_min = x_limits[1], x_max = x_limits[2])
}
profiles = lapply(c("heat", "rotation"), function(question_value) {
  selected = summary[question == question_value & full][1]
  plot_density(question_value, selected, cohorts[[question_value]])
})
fwrite(rbindlist(profiles), file.path(args[2], "density_profiles.csv"))
