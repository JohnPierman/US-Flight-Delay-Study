# STAT4P87 nonlinear distribution study. Run from the repository root.
library(data.table)
setDTthreads(2)
source("analysis/study_inputs.R")
source("analysis/delay_forest.R")
source("analysis/forest_figures.R")

args = commandArgs(trailingOnly = TRUE)
if (length(args) != 3L) {
  stop("Usage: Rscript analysis/forest_study.R PREPARED_DIR LINEAR_RESULTS_DIR OUTPUT_DIR")
}
output = args[3]
dir.create(output, recursive = TRUE, showWarnings = FALSE)
linear = fread(file.path(args[2], "fold_scores.csv"))
cohorts = read_study_cohorts(args[1])
candidate_sizes = c(25L, 80L)

tune_leaf_size = function(train, calibration, question, seed) {
  # Use a fixed evenly spaced subsample of the chronologically sorted calibration observations.
  search = calibration[order(flight_day, flight_id)]
  search = search[unique(round(seq(1, .N, length.out = min(.N, 2500L))))]
  formula = study_formula(train, question, "coordinates", "daily", TRUE)
  rbindlist(lapply(candidate_sizes, function(size) {
    model = fit_delay_forest(formula, train, size, seed, trees = 64L)
    prediction = score_delay_forest(model, search)
    data.table(leaf_size = size, calibration_n = nrow(search), CRPS = mean(prediction$crps))
  }))
}

results = list()
tuning = list()
contrasts = list()
reliability = list()
selected = list()
for (question_value in names(cohorts)) {
  data = cohorts[[question_value]]
  for (f in seq_len(nrow(folds))) {
    fold_name = folds$fold[f]
    fit_rows = data[flight_day < folds$calibration_from[f]]
    calibration = data[flight_day >= folds$calibration_from[f] & flight_day < folds$validation_from[f]]
    validation = data[flight_day >= folds$validation_from[f] & flight_day < folds$validation_until[f]]
    sets = prepare_sets(fit_rows, calibration, validation, question_value)
    train = sets[[1]]
    cal = sets[[2]]
    valid = sets[[3]]
    seed = 487L + f
    message("Fitting ", question_value, " / ", fold_name)
    tuning_scores = tune_leaf_size(train, cal, question_value, seed)
    leaf = tuning_scores[which.min(CRPS), leaf_size]
    tuning[[length(tuning) + 1L]] = tuning_scores[, .(question = question_value, fold = fold_name,
                                                       leaf_size, calibration_n, CRPS)]
    inputs = rbindlist(list(cal, valid))
    time_profiles = if (question_value != "heat") standardized_profiles(valid) else NULL
    rows_per_validation = seq.int(nrow(cal) + 1L, nrow(inputs))
    for (v in seq_len(nrow(variants))) {
      airport_value = variants$airports[v]
      bucket_value = variants$bucket[v]
      key = list(question = question_value, fold = fold_name, airport = airport_value, bucket = bucket_value)
      for (full_value in c(FALSE, TRUE)) {
        formula = study_formula(train, question_value, airport_value, bucket_value, full_value)
        model = fit_delay_forest(formula, train, leaf, seed)
        prediction = score_delay_forest(model, inputs)
        cal_crps = mean(prediction[seq_len(nrow(cal)), crps])
        forecast = prediction[rows_per_validation]
        actual = valid$departure_delay_minutes
        row_key = as.data.table(c(key, list(full = full_value)))
        results[[length(results) + 1L]] = cbind(row_key, leaf_size = leaf, n_fit = nrow(train),
                                                n_calibration = nrow(cal), calibration_CRPS = cal_crps,
                                                forest_metrics(forecast, actual))
        if (full_value) {
          counts = reliability_counts(forecast, actual)
          reliability[[length(reliability) + 1L]] = cbind(row_key[rep(1L, nrow(counts))], counts)
        }
        if (!is.null(time_profiles)) {
          time_prediction = score_delay_forest(model, time_profiles)
          time_prediction[, hour := time_profiles$hour]
          means = time_prediction[, .(n = .N, mean_delay = mean(mean), p30 = mean(p30)), by = hour]
          contrasts[[length(contrasts) + 1L]] = cbind(row_key[rep(1L, nrow(means))], means)
        }
        rm(model)
      }
    }
    message(question_value, " / ", fold_name, " complete (minimum leaf size ", leaf, ")")
  }
}
scores = rbindlist(results)
tuning = rbindlist(tuning)
reliability = rbindlist(reliability)
time_scores = rbindlist(contrasts)
fwrite(tuning, file.path(output, "forest_tuning.csv"))
fwrite(scores, file.path(output, "forest_fold_scores.csv"))

keys = c("question", "fold", "airport", "bucket", "full", "n", "n_fit", "n_calibration")
stopifnot(nrow(scores) == nrow(linear), nrow(merge(scores[, ..keys], linear[, ..keys], by = keys)) == nrow(scores))
matched = merge(scores, linear[, c(keys, "CRPS", "coverage90"), with = FALSE], by = keys,
                suffixes = c("_forest", "_linear"))
matched[, CRPS_improvement := CRPS_linear - CRPS_forest]
fwrite(matched, file.path(output, "forest_vs_linear.csv"))

summary = matched[, .(n = sum(n), calibration_CRPS = weighted.mean(calibration_CRPS, n_calibration),
                       CRPS_forest = weighted.mean(CRPS_forest, n),
                       CRPS_linear = weighted.mean(CRPS_linear, n),
                       coverage90 = weighted.mean(coverage90_forest, n),
                       brier30 = weighted.mean(brier30, n)),
                   by = .(question, airport, bucket, full)]
setorder(summary, question, calibration_CRPS)
fwrite(summary, file.path(output, "forest_validation_summary.csv"))
# Choose the displayed specification before either validation fold starts.
choices = scores[fold == folds$fold[1L] & full == TRUE][order(calibration_CRPS),
  .SD[1L], by = question][, .(question, airport, bucket)]
selected = summary[choices, on = .(question, airport, bucket), nomatch = NULL][full == TRUE]
fwrite(selected, file.path(output, "forest_selected.csv"))

ablation = dcast(scores, question + fold + airport + bucket ~ full, value.var = "CRPS")
ablation[, exposure_CRPS_improvement := get("FALSE") - get("TRUE")]
fwrite(ablation, file.path(output, "forest_exposure_comparison.csv"))

time_contrast = dcast(time_scores, question + fold + airport + bucket + full ~ hour,
                      value.var = c("mean_delay", "p30"))
time_contrast[, mean_contrast := get("mean_delay_17") - get("mean_delay_10")]
time_contrast[, p30_contrast := get("p30_17") - get("p30_10")]
attenuation = dcast(time_contrast, question + fold + airport + bucket ~ full,
                    value.var = c("mean_contrast", "p30_contrast"))
attenuation[, mean_attenuation := fifelse(mean_contrast_FALSE > 0,
                                            1 - mean_contrast_TRUE / mean_contrast_FALSE, NA_real_)]
fwrite(attenuation, file.path(output, "forest_intraday_contrasts.csv"))
fwrite(reliability, file.path(output, "forest_reliability.csv"))
plot_forest_validation(selected, attenuation, reliability, output)

dir.create(file.path(output, "models"), showWarnings = FALSE)
profile_results = vector("list", nrow(selected))
for (i in seq_len(nrow(selected))) {
  choice = selected[i]
  question_value = choice$question
  data = cohorts[[question_value]]
  train = data[flight_day < as.IDate("2024-11-01")]
  calibration = data[flight_day >= as.IDate("2024-11-01")]
  preprocessing = learn_study_preprocessing(train, question_value)
  train = apply_study_preprocessing(train, preprocessing)
  calibration = apply_study_preprocessing(calibration, preprocessing)
  leaf = tune_leaf_size(train, calibration, question_value, 487L)[which.min(CRPS), leaf_size]
  formula = study_formula(train, question_value, choice$airport, choice$bucket, TRUE)
  model = fit_delay_forest(formula, train, leaf, seed = 487L)
  artifact = list(model = model, preprocessing = preprocessing, airport = choice$airport, bucket = choice$bucket)
  saveRDS(artifact, file.path(output, "models", paste0(question_value, ".rds")))
  profiles = if (question_value == "heat") data[flight_day >= as.IDate("2024-06-01") &
                                                 flight_day < as.IDate("2024-09-01")] else calibration
  profile_results[[i]] = plot_forest_density(artifact, profiles, output)
}
fwrite(rbindlist(profile_results), file.path(output, "forest_density_profiles.csv"))
