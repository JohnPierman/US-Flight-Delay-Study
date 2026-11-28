# Serialize the fitted ranger trees and exact leaf counts for browser inference.
# Run after analysis/study_cv.R. The optional fourth argument writes QA fixtures locally.
library(data.table)
invisible(loadNamespace("Matrix"))
source("analysis/study_inputs.R")
source("analysis/delay_forest.R")

args = commandArgs(trailingOnly = TRUE)
if (!length(args) %in% c(3L, 4L)) {
  stop("Usage: Rscript analysis/export_forest_controls.R PREPARED_DIR CV_RESULTS_DIR SITE_DIR [QA_DIR]")
}
dir.create(args[3L], recursive = TRUE, showWarnings = FALSE)
if (length(args) == 4L) dir.create(args[4L], recursive = TRUE, showWarnings = FALSE)
manifest = fread(file.path(args[2L], "cv_flight_assignments.csv"))
profiles = fread(file.path(args[2L], "cv_density_profiles.csv"))
counts = manifest[, .N, by = question]
stopifnot(uniqueN(counts$N) == 1L, counts$N[1L] %% 36L == 0L)

# Recover the exact original training rows by ID. Keep one column projection per month.
columns = c("flight_id", "flight_day", "Origin", "Dest", "Reporting_Airline", "Distance",
            "minute_of_day", "departure_delay_minutes", "origin_lat", "origin_lon",
            "dest_lat", "dest_lon", "traffic_daily", "traffic_weekly", "temperature_c",
            "wind_speed_kt", "visibility_m", "prior_delay", "turn_minutes", "prior_known_at_cutoff")
manifest[, month := substr(flight_id, 1L, 7L)]
rows = rbindlist(lapply(unique(manifest$month), function(month_value) {
  path = file.path(args[1L], paste0("flights-", month_value, ".parquet"))
  flights = setDT(arrow::read_parquet(path, col_select = tidyselect::all_of(columns)))
  flights[manifest[month == month_value, .(flight_id, question)], on = "flight_id"]
}))
stopifnot(nrow(rows) == nrow(manifest), all(is.finite(rows$departure_delay_minutes)))

model_controls = function(model, forest, data, initial, preprocessing) {
  vars = forest$independent.variable.names
  stopifnot(identical(model$predictors, vars))
  controls = list()
  position = function(feature) match(feature, vars) - 1L

  add_range = function(feature, label, group, unit, scale, step, missing = NULL, center = NULL) {
    if (!feature %in% vars) return(invisible(NULL))
    value = initial[[feature]] * scale
    limits = unname(quantile(data[[feature]] * scale, c(0.01, 0.99)))
    low = min(floor(limits[1L] / step) * step, value)
    high = max(ceiling(limits[2L] / step) * step, value)
    grid = seq(ceiling(low / step) * step, floor(high / step) * step, by = step)
    grid = sort(unique(c(round(grid, 8), value)))
    control = list(id = feature, type = "range", label = label, group = group, index = position(feature),
                   unit = unit, scale = scale, values = as.list(grid), initial = match(value, grid) - 1L,
                   baseline = sprintf("%.17g", initial[[feature]]))
    if (!is.null(missing) && missing %in% vars) {
      multiplier = if (feature == "visibility_km") 0.001 else if (feature == "temperature_10") 0.1 else 1
      control$missing = list(index = position(missing), initial = initial[[missing]] == 1L,
                             center = sprintf("%.17g", preprocessing$centers[[center]] * multiplier))
    }
    controls[[length(controls) + 1L]] <<- control
  }

  add_category = function(feature, label, group, labels = NULL) {
    if (!feature %in% vars) return(invisible(NULL))
    levels = forest$covariate.levels[[feature]]
    order = order(levels)
    if (feature == "weekday") stopifnot(setequal(levels, names(labels)))
    choices = lapply(order, function(i) {
      name = levels[i]
      list(label = if (!is.null(labels)) unname(labels[[name]]) else
             if (name == "OTHER") "Other (pooled)" else name, value = i)
    })
    controls[[length(controls) + 1L]] <<-
      list(id = feature, type = "category", label = label, group = group, index = position(feature),
           choices = choices, initial = match(as.character(initial[[feature]]), levels))
  }

  add_range("hour", "Scheduled departure", "Flight schedule", "clock", 60, 15)
  add_category("weekday", "Day of week", "Flight schedule",
               setNames(c("Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"), 0:6))
  if (all(c("month_sin", "month_cos") %in% vars)) {
    controls[[length(controls) + 1L]] = list(
      id = "month", type = "month", label = "Month", group = "Flight schedule",
      indexes = unname(position(c("month_sin", "month_cos"))),
      choices = lapply(1:12, function(month) {
        list(label = month.name[month], value = month,
             pair = sprintf("%.17g", c(sin(2 * pi * month / 12), cos(2 * pi * month / 12))))
      }),
      initial = as.integer(as.character(initial$calendar_month)))
  }
  add_category("Reporting_Airline_group", "Reporting airline", "Flight schedule")
  add_range("distance_1000", "Scheduled distance", "Flight schedule", "mi", 1000, 25)
  add_category("Origin_group", "Departure airport", "Airport and traffic")
  add_category("Dest_group", "Arrival airport", "Airport and traffic")
  add_range("origin_lat", "Departure latitude", "Airport and traffic", "deg", 1, 0.5)
  add_range("origin_lon", "Departure longitude", "Airport and traffic", "deg", 1, 0.5)
  add_range("dest_lat", "Arrival latitude", "Airport and traffic", "deg", 1, 0.5)
  add_range("dest_lon", "Arrival longitude", "Airport and traffic", "deg", 1, 0.5)
  add_range("traffic_day_100", "Previous day departures", "Airport and traffic", "flights", 100, 10)
  add_range("traffic_week_100", "Prior week departures per day", "Airport and traffic", "flights", 100, 10)
  add_range("temperature_10", "Departure temperature", "Departure weather", "degC", 10, 1,
            "temperature_c_missing", "temperature_c")
  add_range("wind_speed_kt", "Wind speed", "Departure weather", "kt", 1, 1,
            "wind_speed_kt_missing", "wind_speed_kt")
  add_range("visibility_km", "Visibility", "Departure weather", "km", 1, 0.25,
            "visibility_m_missing", "visibility_m")
  add_range("turn_hours", "Scheduled turnaround", "Inbound aircraft", "min", 60, 5)
  add_range("prior_delay_30", "Previous arrival delay", "Inbound aircraft", "min", 30, 5)
  covered = unlist(lapply(controls, function(control) c(control[["index"]], control[["indexes"]], control[["missing"]][["index"]])))
  stopifnot(identical(sort(covered), seq_along(vars) - 1L))
  controls
}

write_model = function(question_value) {
  artifact = readRDS(file.path(args[2L], "models", paste0(question_value, ".rds")))
  model = artifact$model
  forest = model$forest$forest
  raw = copy(rows[question == question_value])
  setorder(raw, flight_id)
  profile = profiles[question == question_value][1L]
  data = apply_study_preprocessing(study_features(raw), artifact$preprocessing)
  initial = data[flight_id == profile$flight_id]
  stopifnot(nrow(initial) == 1L, nrow(data) == counts[question == question_value, N],
            all(forest$is.ordered), length(forest$child.nodeIDs) == model$n_trees)
  controls = model_controls(model, forest, data, initial, artifact$preprocessing)
  node_count = ncol(model$leaf_mass)
  widths = lengths(forest$split.varIDs)
  roots = model$offsets - 1L
  stopifnot(sum(widths) == node_count, all(roots == c(0, head(cumsum(widths), -1L))))
  left = as.integer(unlist(lapply(forest$child.nodeIDs, "[[", 1L)))
  right = as.integer(unlist(lapply(forest$child.nodeIDs, "[[", 2L)))
  terminal = left == 0L
  stopifnot(all(right[terminal] == 0L), all(right[!terminal] == left[!terminal] + 1L))
  splits = as.numeric(unlist(forest$split.values))
  splits[terminal] = 0
  feature = as.raw(unlist(forest$split.varIDs))
  mass = model$leaf_mass
  sizes = tabulate(as.vector(sweep(forest_nodes(model$forest, data[, model$predictors, with = FALSE]),
                                 2L, model$offsets, "+")), nbins = node_count)
  n_occupied = diff(mass@p)
  recovered = mass@x * rep(sizes, n_occupied)
  sample_counts = as.integer(round(recovered))
  stopifnot(max(abs(recovered - sample_counts)) < 1e-9, all(sample_counts > 0),
            max(sample_counts) < 65536, max(mass@i) < 65536)
  # Verify recovered frequency sums for all leaves before writing the packed arrays.
  prefix = c(0, cumsum(sample_counts))
  stopifnot(all(prefix[mass@p[-1L] + 1L] - prefix[head(mass@p, -1L) + 1L] == sizes))
  filename = paste0("forest-", question_value, ".bin.gz")
  con = gzfile(file.path(args[3L], filename), open = "wb", compression = 9L)
  on.exit(close(con))
  # Layout uses little-endian arrays. Missing values never enter a tree split.
  writeBin(splits, con, size = 8L, endian = "little")
  writeBin(left, con, size = 4L, endian = "little")
  writeBin(mass@p, con, size = 4L, endian = "little")
  writeBin(mass@i, con, size = 2L, endian = "little")
  writeBin(sample_counts, con, size = 2L, endian = "little")
  writeBin(feature, con)

  if (length(args) == 4L) {
    set.seed(77)
    check = rbindlist(list(initial, data[sample.int(nrow(data), 30L)]))
    probabilities = as.matrix(forest_mass(model, check))
    inputs = lapply(model$predictors, function(feature_name) {
      levels = forest$covariate.levels[[feature_name]]
      value = if (length(levels)) match(as.character(check[[feature_name]]), levels) else check[[feature_name]]
      sprintf("%.17g", value)
    })
    jsonlite::write_json(list(inputs = unname(asplit(do.call(cbind, inputs), 1L)),
                             expected = unname(asplit(t(probabilities), 1L))),
                         file.path(args[4L], paste0(question_value, ".json")),
                         digits = NA, auto_unbox = TRUE)
  }
  message(question_value, ": ", length(controls), " controls covering ", length(model$predictors), " predictors")
  list(file = filename, nodes = node_count, entries = length(mass@x), roots = roots,
       support = model$support, controls = controls, features = model$predictors)
}

keys = c("heat", "rotation", "cutoff")
jsonlite::write_json(setNames(lapply(keys, write_model), keys),
                     file.path(args[3L], "forest-controls.json"), digits = NA, auto_unbox = TRUE)
