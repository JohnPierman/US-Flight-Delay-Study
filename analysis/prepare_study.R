# STAT4P87 flight-level preparation. Run from the repository root.
# Arguments: cached data directory, weather directory, output directory.
library(arrow)
library(data.table)
setDTthreads(2)

args = commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
  stop("Usage: Rscript analysis/prepare_study.R DATA_DIR WEATHER_DIR OUTPUT_DIR")
}
data_dir = args[1]
weather_dir = args[2]
output_dir = args[3]
dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)

read_part = function(path, columns = NULL) {
  if (is.null(columns)) return(setDT(read_parquet(path)))
  setDT(read_parquet(path, col_select = tidyselect::all_of(columns)))
}

monday = function(day) {
  day - (as.integer(day) + 3L) %% 7L
}

month_ids = format(seq(as.Date("2023-01-01"), as.Date("2024-12-01"), by = "month"), "%Y-%m")
paths = file.path(data_dir, "intermediate", "bts_flights",
                  paste0("year=", substr(month_ids, 1, 4)),
                  paste0("month=", substr(month_ids, 6, 7)), "flights.parquet")
if (!all(file.exists(paths))) stop("Missing development partitions: ", paste(month_ids[!file.exists(paths)], collapse = ", "))

airports = read_part(file.path(data_dir, "intermediate", "airport_metadata.parquet"))
stopifnot(!anyDuplicated(airports$code))

weather_paths = unlist(lapply(2022:2024, function(year) {
  list.files(file.path(weather_dir, paste0("year=", year)), "[.]parquet$", full.names = TRUE)
}))
if (!length(weather_paths)) stop("No cached station observations found.")
weather = rbindlist(lapply(weather_paths, read_part,
                         columns = c("station", "timestamp_utc", "temperature_c", "wind_speed_kt", "visibility_m")))
weather[, weather_seconds := as.numeric(timestamp_utc)]
weather = unique(weather[, timestamp_utc := NULL])
# A timestamp with different reported values is ambiguous.
weather = weather[!duplicated(weather, by = c("station", "weather_seconds")) &
                  !duplicated(weather, by = c("station", "weather_seconds"), fromLast = TRUE)]
setkey(weather, station, weather_seconds)
fwrite(data.table(station_file = weather_paths), file.path(output_dir, "weather_inputs.csv"))

study_days = as.IDate(seq(as.Date("2023-01-01"), as.Date("2024-12-31"), by = "day"))
iso_days = format(study_days, "%Y-%m-%d")
parse_days = function(x) study_days[match(x, iso_days)]

message("Counting scheduled departures by origin and local day")
daily = rbindlist(lapply(paths, function(path) {
  schedule = read_part(path, c("FlightDate", "Origin", "CRSDepTime"))
  schedule[, clock := as.integer(CRSDepTime)]
  schedule = schedule[!is.na(clock) & clock >= 0 & clock %% 100L < 60L &
                        (clock < 2400L | clock == 2400L) & !is.na(Origin)]
  schedule[, .(departures = .N), by = .(Origin, day = parse_days(FlightDate) + as.integer(clock == 2400L))]
}))[, .(departures = sum(departures)), by = .(Origin, day)]
weekly = daily[, .(departures = sum(departures)), by = .(Origin, week = monday(day))]
stopifnot(!anyDuplicated(daily, by = c("Origin", "day")), !anyDuplicated(weekly, by = c("Origin", "week")))

rotation_columns = c("flight_id", "FlightDate", "Tail_Number", "Origin", "Dest",
                     "scheduled_departure_utc", "scheduled_arrival_utc", "actual_arrival_utc",
                     "ArrDelay", "Cancelled", "Diverted")
flight_columns = c(rotation_columns, "CRSDepTime", "Reporting_Airline", "Distance",
                   "departure_delay_minutes", "actual_departure_utc")

prepare_month = function(flights, neighbors) {
  eligible = flights[Cancelled == 0 & is.finite(departure_delay_minutes) &
                       !is.na(scheduled_departure_utc) & !is.na(actual_departure_utc),
                     .(flight_id, FlightDate, Origin, Dest, Reporting_Airline, Distance,
                       clock = as.integer(CRSDepTime), departure_delay_minutes,
                       departure_seconds = as.numeric(scheduled_departure_utc))]
  eligible[, minute_of_day := (clock %/% 100L * 60L + clock %% 100L) %% 1440L]
  eligible[, flight_day := parse_days(FlightDate) + as.integer(clock == 2400L)]
  eligible[, week_start := monday(flight_day)]
  eligible[, cutoff_seconds := departure_seconds - 3600]
  eligible[, cutoff_day := flight_day]
  eligible[, c("origin_lat", "origin_lon", "origin_tz") :=
             airports[match(Origin, code), .(latitude, longitude, timezone)]]
  eligible[, c("dest_lat", "dest_lon") := airports[match(Dest, code), .(latitude, longitude)]]
  eligible[, cutoff_day := as.IDate(as.POSIXct(cutoff_seconds, origin = "1970-01-01", tz = "UTC"),
                                   tz = origin_tz[1]), by = origin_tz]

  eligible[, daily_lookup := cutoff_day - 1L]
  eligible[, weekly_lookup := monday(cutoff_day) - 7L]
  eligible[, traffic_daily := daily[eligible, on = .(Origin, day = daily_lookup), x.departures]]
  eligible[, traffic_weekly := weekly[eligible, on = .(Origin, week = weekly_lookup), x.departures] / 7]
  eligible[is.na(traffic_daily) & daily_lookup >= as.IDate("2023-01-01"), traffic_daily := 0]
  eligible[is.na(traffic_weekly) & weekly_lookup >= as.IDate("2023-01-01"), traffic_weekly := 0]
  eligible[daily_lookup < as.IDate("2023-01-01"), traffic_daily := NA_real_]
  eligible[weekly_lookup < as.IDate("2023-01-01"), traffic_weekly := NA_real_]

  rotations = rbindlist(c(list(flights[, ..rotation_columns]), neighbors))
  rotations = rotations[!is.na(Tail_Number) & nzchar(Tail_Number) & !is.na(scheduled_departure_utc)]
  setorder(rotations, Tail_Number, scheduled_departure_utc, flight_id)
  rotations[, tied := duplicated(rotations, by = c("Tail_Number", "scheduled_departure_utc")) |
                      duplicated(rotations, by = c("Tail_Number", "scheduled_departure_utc"), fromLast = TRUE)]
  prior_fields = c("Dest", "scheduled_arrival_utc", "actual_arrival_utc", "ArrDelay",
                   "Cancelled", "Diverted", "tied")
  rotations[, paste0("prior_", prior_fields) := shift(.SD), by = Tail_Number, .SDcols = prior_fields]
  links = rotations[!tied & !prior_tied & Origin == prior_Dest & prior_Cancelled == 0 & prior_Diverted == 0 &
                      is.finite(prior_ArrDelay) & !is.na(prior_actual_arrival_utc),
                    .(flight_id, prior_delay = prior_ArrDelay, prior_sched = as.numeric(prior_scheduled_arrival_utc),
                      prior_actual = as.numeric(prior_actual_arrival_utc),
                      turn_minutes = (as.numeric(scheduled_departure_utc) - as.numeric(prior_scheduled_arrival_utc)) / 60)]
  eligible[links, on = "flight_id", c("prior_delay", "prior_sched", "prior_actual", "turn_minutes") :=
             .(i.prior_delay, i.prior_sched, i.prior_actual, i.turn_minutes)]
  # Identify a same-day rotation using scheduled local time. The target's actual delay
  # plays no role in link eligibility. At the file boundary the candidate may be incomplete.
  eligible[, prior_day := as.IDate(as.POSIXct(prior_sched, origin = "1970-01-01", tz = "UTC"),
                                  tz = origin_tz[1]), by = origin_tz]
  eligible[is.na(prior_day) | prior_day != flight_day | turn_minutes < 0 | turn_minutes > 720 |
             flight_day <= as.IDate("2023-01-01") | flight_day >= as.IDate("2024-12-31"),
           c("prior_delay", "prior_actual", "turn_minutes") := .(NA_real_, NA_real_, NA_real_)]
  eligible[, prior_known_at_cutoff := !is.na(prior_actual) & prior_actual <= cutoff_seconds]

  matched = weather[eligible, on = .(station = Origin, weather_seconds = cutoff_seconds),
                    roll = 3600, .(weather_age_minutes = (i.cutoff_seconds - x.weather_seconds) / 60,
                                   temperature_c, wind_speed_kt, visibility_m)]
  stopifnot(nrow(matched) == nrow(eligible), all(is.na(matched$weather_age_minutes) |
              (matched$weather_age_minutes >= 0 & matched$weather_age_minutes <= 60)),
            !anyDuplicated(eligible$flight_id))
  eligible[, names(matched) := matched]
  eligible[, c("clock", "departure_seconds", "origin_tz", "cutoff_day", "cutoff_seconds",
               "daily_lookup", "weekly_lookup", "prior_sched", "prior_day", "prior_actual") := NULL]
  eligible
}

previous = NULL
current = read_part(paths[1], flight_columns)
coverage = vector("list", length(paths))
bucket_counts = vector("list", length(paths))
for (i in seq_along(paths)) {
  following = if (i < length(paths)) read_part(paths[i + 1L], flight_columns) else NULL
  start = as.IDate(paste0(month_ids[i], "-01"))
  next_start = as.IDate(seq(as.Date(start), by = "month", length.out = 2)[2])
  neighbors = list()
  if (!is.null(previous)) neighbors = c(neighbors, list(previous))
  if (!is.null(following)) {
    neighbors = c(neighbors, list(following[parse_days(FlightDate) < next_start + 2L, ..rotation_columns]))
  }
  prepared = prepare_month(current, neighbors)
  coverage[[i]] = prepared[, .(month = month_ids[i], eligible = .N,
                               temperature = sum(is.finite(temperature_c)),
                               linked = sum(is.finite(prior_delay)),
                               linked_at_cutoff = sum(prior_known_at_cutoff),
                               missing_coordinates = sum(!complete.cases(origin_lat, origin_lon, dest_lat, dest_lon)),
                               missing_buckets = sum(!complete.cases(traffic_daily, traffic_weekly)))]
  bucket_counts[[i]] = prepared[, .(flights = .N, total_delay = sum(departure_delay_minutes),
                                    temperature = sum(is.finite(temperature_c)), linked = sum(is.finite(prior_delay))),
                                by = .(flight_day, week_start)]
  target = file.path(output_dir, paste0("flights-", month_ids[i], ".parquet"))
  temporary = paste0(target, ".tmp")
  write_parquet(prepared, temporary, compression = "zstd")
  if (file.exists(target) && .Platform$OS.type == "windows") file.remove(target)
  if (!file.rename(temporary, target)) stop("Could not publish ", target)
  previous = current[parse_days(FlightDate) >= next_start - 2L, ..rotation_columns]
  current = following
  message(sprintf("%s: %s eligible flights", month_ids[i], nrow(prepared)))
}
fwrite(rbindlist(coverage), file.path(output_dir, "coverage.csv"))

buckets = rbindlist(bucket_counts)
daily_summary = buckets[, .(flights = sum(flights), mean_delay = sum(total_delay) / sum(flights),
                            temperature = sum(temperature), linked = sum(linked)), by = flight_day]
weekly_summary = buckets[, .(flights = sum(flights), mean_delay = sum(total_delay) / sum(flights),
                             temperature = sum(temperature), linked = sum(linked)), by = week_start]
setorder(daily_summary, flight_day)
setorder(weekly_summary, week_start)
stopifnot(sum(daily_summary$flights) == sum(weekly_summary$flights))
fwrite(daily_summary, file.path(output_dir, "daily_summary.csv"))
fwrite(weekly_summary, file.path(output_dir, "weekly_summary.csv"))
