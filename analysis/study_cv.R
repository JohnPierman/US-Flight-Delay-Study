# STAT4P87 five-fold cross-validation with calendar weeks as the sampling units.
library(data.table)
setDTthreads(2)
source("analysis/study_inputs.R")
source("analysis/delay_forest.R")
source("analysis/forest_figures.R")
source("analysis/cv_figures.R")

args = commandArgs(trailingOnly = TRUE)
if (!length(args) %in% c(2L, 3L)) {
  stop("Usage: Rscript analysis/study_cv.R PREPARED_DIR OUTPUT_DIR [ROWS_PER_MONTH_PER_COHORT]")
}
rows_per_month = if (length(args) == 3L) suppressWarnings(as.integer(args[3])) else 1800L
if (is.na(rows_per_month) || rows_per_month < 1L) stop("Specify a positive monthly sample size.")
output = args[2]
dir.create(output, recursive = TRUE, showWarnings = FALSE)
weeks = fread(file.path(args[1], "weekly_summary.csv"), select = c("week_start", "flights"))
weeks[, week_start := as.IDate(week_start)]
first_day = as.IDate("2023-01-01")
last_day = as.IDate("2025-12-31")
# Use each week's midpoint to assign a calendar stratum, including partial endpoint weeks.
weeks[, anchor := pmin(pmax(week_start + 3L, first_day), last_day)]
weeks[, c("season_year", "quarter") := .(format(anchor, "%Y"), (as.integer(format(anchor, "%m")) - 1L) %/% 3L + 1L)]
stopifnot(!anyDuplicated(weeks$week_start), uniqueN(weeks$season_year) == 3L)
setorder(weeks, week_start)
set.seed(487)
weeks[, fold := sample(rep(sample.int(5L), length.out = .N)), by = .(season_year, quarter)]
stopifnot(all(weeks[, uniqueN(fold), by = .(season_year, quarter)]$V1 == 5L))
fwrite(weeks, file.path(output, "cv_week_assignments.csv"))

cohorts = read_study_cohorts(args[1], last_year = 2025L, rows_per_month = rows_per_month)
cohorts = lapply(cohorts, function(data) {
  data = data[flight_day >= first_day & flight_day <= last_day]
  data[, week_start := flight_day - (as.integer(flight_day) + 3L) %% 7L]
  data[, fold := weeks$fold[match(week_start, weeks$week_start)]]
  stopifnot(!anyNA(data$fold), !anyDuplicated(data$flight_id),
            uniqueN(data$fold) == 5L, uniqueN(format(data$flight_day, "%Y-%m")) == 36L)
  data
})
sample_manifest = rbindlist(lapply(names(cohorts), function(question_value) {
  cohorts[[question_value]][, .(question = question_value, flight_id, flight_day, week_start, fold)]
}))
fwrite(sample_manifest, file.path(output, "cv_flight_assignments.csv"))

# Match the specifications highlighted in the chronological study. The other
# airport/traffic combinations are scored as full models for sensitivity.
primary = data.table(question = c("heat", "rotation", "cutoff"),
                     airport = c("coordinates", "factors", "coordinates"),
                     bucket = c("weekly", "daily", "weekly"), leaf = c(50L, 25L, 25L))
results = list()
comparisons = list()
contrasts = list()
reliability = list()
for (question_value in names(cohorts)) {
  data = cohorts[[question_value]]
  main = primary[question == question_value]
  for (fold_id in 1:5) {
    message("Fitting ", question_value, " / fold ", fold_id)
    fit = data[fold != fold_id]
    hold = data[fold == fold_id]
    stopifnot(!any(fit$week_start %in% hold$week_start))
    preprocess = learn_study_preprocessing(fit, question_value)
    train = apply_study_preprocessing(fit, preprocess)
    valid = apply_study_preprocessing(hold, preprocess)
    time_profiles = if (question_value == "heat") NULL else standardized_profiles(valid)

    # Keep the outer fold out of both linear fitting and residual calibration.
    # The inner linear fit generates out-of-week residuals, then the forecast
    # location model is refit on all four outer training folds.
    inner_fold = fold_id %% 5L + 1L
    inner = prepare_sets(fit[fold != inner_fold], fit[fold == inner_fold], hold, question_value)
    inner_formula = study_formula(inner[[1L]], question_value, main$airport, main$bucket, TRUE)
    inner_fit = lm(inner_formula, data = inner[[1L]])
    residual = inner[[2L]]$departure_delay_minutes - predict(inner_fit, inner[[2L]])
    linear = lm(study_formula(train, question_value, main$airport, main$bucket, TRUE), data = train)
    actual = hold$departure_delay_minutes
    linear_score = distribution_scores(actual, predict(linear, valid), residual)

    for (v in seq_len(nrow(variants))) {
      airport = variants$airports[v]
      bucket = variants$bucket[v]
      headline = airport == main$airport && bucket == main$bucket
      for (full in if (headline) c(FALSE, TRUE) else TRUE) {
        formula = study_formula(train, question_value, airport, bucket, full)
        model = fit_delay_forest(formula, train, main$leaf, seed = 487L + fold_id, trees = 64L)
        prediction = score_delay_forest(model, valid)
        metrics = forest_metrics(prediction, actual)
        key = data.table(question = question_value, fold = fold_id, airport, bucket, full, headline)
        results[[length(results) + 1L]] = cbind(key, n_fit = nrow(fit), metrics)
        if (headline && full) {
          comparisons[[length(comparisons) + 1L]] =
            cbind(key, n = nrow(hold), CRPS_forest = metrics$CRPS, CRPS_linear = linear_score[["CRPS"]],
                  coverage_forest = metrics$coverage90, coverage_linear = linear_score[["coverage90"]])
          bins = reliability_counts(prediction, actual)
          reliability[[length(reliability) + 1L]] = cbind(key[rep(1L, nrow(bins))], bins)
        }
        if (headline && !is.null(time_profiles)) {
          time = score_delay_forest(model, time_profiles)
          n_profiles = nrow(time) / 2
          contrasts[[length(contrasts) + 1L]] = cbind(key, n_profiles = n_profiles,
            mean_gap = mean(time$mean[(n_profiles + 1L):nrow(time)] - time$mean[seq_len(n_profiles)]),
            p30_gap = mean(time$p30[(n_profiles + 1L):nrow(time)] - time$p30[seq_len(n_profiles)]))
        }
      }
    }
    message("Completed ", question_value, " / fold ", fold_id)
  }
}

scores = rbindlist(results)
matched = rbindlist(comparisons)
reliability = rbindlist(reliability)
contrasts = dcast(rbindlist(contrasts), question + fold + airport + bucket ~ full, value.var = c("mean_gap", "p30_gap"))
contrasts[, attenuation := fifelse(mean_gap_FALSE > 0, 1 - mean_gap_TRUE / mean_gap_FALSE, NA_real_)]
ablation = dcast(scores[headline == TRUE], question + fold ~ full, value.var = "CRPS")
ablation[, CRPS_improvement := get("FALSE") - get("TRUE")]
pooled = scores[, .(n = sum(n), CRPS = weighted.mean(CRPS, n),
                    coverage90 = weighted.mean(coverage90, n),
                    width90 = weighted.mean(interval90_width, n), brier30 = weighted.mean(brier30, n)),
                by = .(question, airport, bucket, full, headline)]
comparison = matched[, .(n = sum(n), forest_CRPS = weighted.mean(CRPS_forest, n),
                          linear_CRPS = weighted.mean(CRPS_linear, n),
                          forest_coverage = weighted.mean(coverage_forest, n),
                          linear_coverage = weighted.mean(coverage_linear, n)), by = question]
stopifnot(nrow(scores) == 75L, nrow(matched) == 15L)
stopifnot(identical(as.integer(comparison$n), as.integer(lengths(lapply(cohorts[comparison$question], "[[", "flight_id")))))
tables = list(fold_scores = scores, pooled_scores = pooled, linear_comparison = matched,
              headline_summary = comparison, exposure_ablation = ablation,
              intraday_contrasts = contrasts, reliability = reliability)
for (name in names(tables)) fwrite(tables[[name]], file.path(output, paste0("cv_", name, ".csv")))
plot_cv_diagnostics(matched, reliability, contrasts, ablation, pooled, weeks, output)

# After evaluation, refit the specified configurations on all sampled years.
dir.create(file.path(output, "models"), showWarnings = FALSE)
profiles = lapply(seq_len(nrow(primary)), function(i) {
  main = primary[i]
  question_value = main$question
  data = cohorts[[question_value]]
  preprocessing = learn_study_preprocessing(data, question_value)
  train = apply_study_preprocessing(data, preprocessing)
  formula = study_formula(train, question_value, main$airport, main$bucket, TRUE)
  model = fit_delay_forest(formula, train, main$leaf, seed = 487L, trees = 64L)
  artifact = list(model = model, preprocessing = preprocessing, airport = main$airport, bucket = main$bucket)
  saveRDS(artifact, file.path(output, "models", paste0(question_value, ".rds")))
  example = if (question_value == "heat") data[calendar_month %in% c("06", "07", "08")] else data
  plot_forest_density(artifact, example, output)
})
fwrite(rbindlist(profiles), file.path(output, "cv_density_profiles.csv"))
