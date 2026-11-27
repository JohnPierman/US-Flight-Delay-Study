# Quantile regression forest using the empirical delay distribution in each leaf.
# Tree partitions use the numeric response. Every fitting row contributes one
# observation to the leaf it reaches in each tree, as in Meinshausen (2006).
forest_nodes = function(forest, data) {
  loadNamespace("ranger")
  stats::predict(forest, data = data, type = "terminalNodes", num.threads = 4)$predictions
}

fit_delay_forest = function(formula, train, leaf_size, seed, trees = 128L) {
  response = all.vars(formula)[1L]
  predictors = all.vars(formula)[-1L]
  x = as.data.frame(train[, ..predictors])
  y = train[[response]]
  forest = ranger::ranger(x = x, y = y, num.trees = trees,
                          min.node.size = 2L * leaf_size, min.bucket = leaf_size,
                          respect.unordered.factors = "order", seed = seed,
                          oob.error = FALSE, num.threads = 4)
  nodes = forest_nodes(forest, x)
  # Give each tree's terminal nodes a disjoint range of column indices.
  widths = apply(nodes, 2L, max) + 1L
  offsets = c(0L, head(cumsum(widths), -1L)) + 1L
  support = sort(unique(y))
  counts = Matrix::sparseMatrix(i = rep(match(y, support), times = trees),
                                j = as.vector(sweep(nodes, 2L, offsets, "+")),
                                x = 1, dims = c(length(support), sum(widths)))
  totals = Matrix::colSums(counts)
  leaf_mass = counts %*% Matrix::Diagonal(x = 1 / pmax(totals, 1))
  list(forest = forest, response = response, predictors = predictors, support = support, leaf_mass = leaf_mass,
       offsets = offsets, n_trees = trees, leaf_size = leaf_size)
}

forest_mass = function(model, data) {
  columns = model$predictors
  x = as.data.frame(data[, ..columns])
  if (!all(complete.cases(x))) stop("Some forest predictors are missing for these flights.")
  nodes = forest_nodes(model$forest, x)
  weights = Matrix::sparseMatrix(i = as.vector(sweep(nodes, 2L, model$offsets, "+")),
                                 j = rep(seq_len(nrow(x)), times = model$n_trees),
                                 x = 1 / model$n_trees,
                                 dims = c(ncol(model$leaf_mass), nrow(x)))
  mass = model$leaf_mass %*% weights
  stopifnot(all(abs(Matrix::colSums(mass) - 1) < 1e-9))
  mass
}

# Return a sparse PMF with delay values as rows and new flights as columns.
# Inputs use the schema written by analysis/prepare_study.R.
predict_delay_distribution = function(artifact, newdata) {
  newdata = study_features(newdata)
  question = artifact$preprocessing$question
  if (question == "cutoff" &&
      (!"prior_known_at_cutoff" %in% names(newdata) || !all(newdata$prior_known_at_cutoff %in% TRUE))) {
    stop("The cutoff forest requires a linked inbound flight that arrived by cutoff.")
  }
  prepared = apply_study_preprocessing(newdata, artifact$preprocessing)
  list(minutes = artifact$model$support, probability = forest_mass(artifact$model, prepared))
}

summarize_forest_mass = function(mass, support, actual = rep(NA_real_, ncol(mass))) {
  stopifnot(length(actual) == ncol(mass))
  stats = vapply(seq_len(ncol(mass)), function(row) {
    indices = seq.int(mass@p[row] + 1L, mass@p[row + 1L])
    values = support[mass@i[indices] + 1L]
    weights = mass@x[indices]
    cumulative = cumsum(weights)
    quantile = function(p) values[which(cumulative >= p - 1e-12)[1L]]
    mean_delay = sum(values * weights)
    # E|Y-y| - 0.5 E|Y-Y'|, with the second term computed from the sorted PMF.
    crps = sum(weights * abs(values - actual[row])) -
      sum(weights * values * (2 * cumulative - weights - 1))
    c(mean = mean_delay, q05 = quantile(0.05), median = quantile(0.50), q95 = quantile(0.95),
      p15 = sum(weights[values >= 15]), p30 = sum(weights[values >= 30]),
      p60 = sum(weights[values >= 60]), crps = crps)
  }, numeric(8))
  setDT(as.data.frame(t(stats)))
}

score_delay_forest = function(model, data, batch_size = 768L) {
  batches = split(seq_len(nrow(data)), (seq_len(nrow(data)) - 1L) %/% batch_size)
  rbindlist(lapply(batches, function(ids) {
    batch = data[ids]
    summarize_forest_mass(forest_mass(model, batch), model$support, batch[[model$response]])
  }))
}

forest_metrics = function(prediction, actual) {
  error = prediction$mean - actual
  data.table(n = length(actual), MAE = mean(abs(error)), RMSE = sqrt(mean(error^2)),
             CRPS = mean(prediction$crps),
             coverage90 = mean(actual >= prediction$q05 & actual <= prediction$q95),
             interval90_width = mean(prediction$q95 - prediction$q05),
             brier30 = mean((prediction$p30 - (actual >= 30))^2))
}

standardized_profiles = function(data) {
  # Both time bands must be represented in the profile's departure airport and month.
  support = data[, .(morning = sum(hour >= 9 & hour < 11),
                     afternoon = sum(hour >= 16 & hour < 18)), by = .(Origin, calendar_month)]
  matched = data[support[morning >= 10 & afternoon >= 10], on = .(Origin, calendar_month),
                 nomatch = NULL][(hour >= 9 & hour < 11) | (hour >= 16 & hour < 18)]
  if (!nrow(matched)) stop("No common support for the intraday contrast.")
  setorder(matched, flight_id)
  matched = matched[unique(round(seq(1, .N, length.out = min(.N, 1200L))))]
  rbindlist(lapply(c(10, 17), function(hour_value) copy(matched)[, hour := hour_value]))
}

reliability_counts = function(prediction, actual) {
  # Fixed 0.1-wide bins for the probability of at least a 30-minute delay.
  bin = pmin(9L, floor(prediction$p30 * 10))
  data.table(bin, forecast = prediction$p30, outcome = actual >= 30)[,
    .(n = .N, predicted = mean(forecast), observed = mean(outcome)), by = bin]
}
