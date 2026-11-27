# STAT4P87 linear regression, validation, and residual density diagnostics.
library(arrow)
library(data.table)
setDTthreads(2)

args = commandArgs(trailingOnly = TRUE)
if (length(args) != 2L) stop("Usage: Rscript analysis/linear_study.R PREPARED_DIR OUTPUT_DIR")
dir.create(args[2], recursive = TRUE, showWarnings = FALSE)
source("analysis/study_inputs.R")
cohorts = read_study_cohorts(args[1])

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
        model = lm(study_formula(sets[[1]], question, airport, bucket, full), data = sets[[1]])
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
  model = lm(study_formula(sets[[1]], question, selected$airport, selected$bucket, TRUE), data = sets[[1]])
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
