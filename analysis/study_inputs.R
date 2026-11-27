# Shared inputs for the STAT4P87 linear and forest comparisons.
study_features = function(flights) {
  flights = copy(as.data.table(flights))
  flights[, flight_day := as.IDate(flight_day)]
  flights[, calendar_month := format(flight_day, "%m")]
  flights[, month_sin := sin(2 * pi * as.integer(calendar_month) / 12)]
  flights[, month_cos := cos(2 * pi * as.integer(calendar_month) / 12)]
  flights[, weekday := as.integer(flight_day + 3L) %% 7L]
  flights[, distance_1000 := Distance / 1000]
  flights[, c("origin_lon", "dest_lon") := lapply(.SD, function(x) (x + 240) %% 360 - 240),
          .SDcols = c("origin_lon", "dest_lon")]
  flights
}

read_study_cohorts = function(prepared_dir, last_year = 2024L, rows_per_month = 4500L) {
  months = format(seq(as.Date("2023-01-01"), as.Date(paste0(last_year, "-12-01")), by = "month"), "%Y-%m")
  paths = file.path(prepared_dir, paste0("flights-", months, ".parquet"))
  if (!all(file.exists(paths))) stop("Run prepare_study.R before fitting.")
  set.seed(487)
  sample_rows = function(data) data[sample.int(nrow(data), min(nrow(data), rows_per_month))]
  columns = c("flight_id", "flight_day", "Origin", "Dest", "Reporting_Airline", "Distance",
              "minute_of_day", "departure_delay_minutes", "origin_lat", "origin_lon",
              "dest_lat", "dest_lon", "traffic_daily", "traffic_weekly", "temperature_c",
              "wind_speed_kt", "visibility_m", "prior_delay", "turn_minutes", "prior_known_at_cutoff")
  samples = lapply(paths, function(path) {
    flights = setDT(arrow::read_parquet(path, col_select = tidyselect::all_of(columns)))
    setorder(flights, flight_id)
    flights = flights[complete.cases(traffic_daily, traffic_weekly, origin_lat, origin_lon,
                                    Distance, Reporting_Airline)]
    rotation = flights[complete.cases(dest_lat, dest_lon)]
    list(heat = sample_rows(flights[is.finite(temperature_c)]),
         rotation = sample_rows(rotation[is.finite(prior_delay)]),
         cutoff = sample_rows(rotation[prior_known_at_cutoff == TRUE]))
  })
  questions = c("heat", "rotation", "cutoff")
  setNames(lapply(questions, function(question) {
    study_features(rbindlist(lapply(samples, "[[", question)))
  }), questions)
}

learn_study_preprocessing = function(train, question) {
  categories = c("Origin", "Reporting_Airline", if (question != "heat") "Dest")
  levels = lapply(setNames(categories, categories), function(column) {
    counts = table(train[[column]])
    keep = names(counts)[counts >= 75]
    if (length(keep) == length(counts) && length(keep) > 1) {
      keep = setdiff(keep, names(which.min(counts)))
    }
    unique(c(keep, "OTHER"))
  })
  weather = c("temperature_c", "wind_speed_kt", "visibility_m")
  centers = vapply(setNames(weather, weather), function(column) {
    center = median(train[[column]][is.finite(train[[column]])])
    if (is.finite(center)) center else 0
  }, numeric(1))
  list(levels = levels, centers = centers, question = question)
}

apply_study_preprocessing = function(data, preprocessing) {
  data = copy(data)
  if (preprocessing$question == "heat" && !all(is.finite(data$temperature_c))) {
    stop("The heat cohort requires measured departure-airport temperature.")
  }
  for (column in names(preprocessing$levels)) {
    levels = preprocessing$levels[[column]]
    value = data[[column]]
    value[!value %in% levels] = "OTHER"
    set(data, j = paste0(column, "_group"), value = factor(value, levels = levels))
  }
  for (column in names(preprocessing$centers)) {
    value = data[[column]]
    missing = !is.finite(value)
    value[missing] = preprocessing$centers[[column]]
    set(data, j = paste0(column, "_missing"), value = as.integer(missing))
    set(data, j = column, value = value)
  }
  data[, hour := minute_of_day / 60]
  data[, temperature_10 := temperature_c / 10]
  data[, prior_delay_30 := prior_delay / 30]
  data[, turn_hours := turn_minutes / 60]
  data[, traffic_day_100 := traffic_daily / 100]
  data[, traffic_week_100 := traffic_weekly / 100]
  data[, visibility_km := visibility_m / 1000]
  data[, c("calendar_month", "weekday") := lapply(.SD, factor), .SDcols = c("calendar_month", "weekday")]
  data
}

prepare_sets = function(train, calibration, validation, question) {
  preprocessing = learn_study_preprocessing(train, question)
  lapply(list(train, calibration, validation), apply_study_preprocessing, preprocessing = preprocessing)
}

study_formula = function(train, question, airports, bucket, include_exposure) {
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
  reformulate(terms, response = "departure_delay_minutes")
}

folds = data.table(fold = c("Jan-Jun 2024", "Jul-Dec 2024"),
                   calibration_from = as.IDate(c("2023-11-01", "2024-05-01")),
                   validation_from = as.IDate(c("2024-01-01", "2024-07-01")),
                   validation_until = as.IDate(c("2024-07-01", "2025-01-01")))
variants = CJ(airports = c("factors", "coordinates"), bucket = c("daily", "weekly"))

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
