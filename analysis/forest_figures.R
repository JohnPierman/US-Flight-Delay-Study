# Diagnostic plots for the estimated delay distribution and its validation.
forest_colors = c("#245786", "#168477", "#B74D21")

plot_forest_density = function(artifact, data, output) {
  question = artifact$preprocessing$question
  heat = question == "heat"
  data = apply_study_preprocessing(data, artifact$preprocessing)
  data[, hour_band := minute_of_day %/% 120L]
  data[, cell_n := .N, by = .(Origin, calendar_month, hour_band)]
  if (heat) data[, hot_n := sum(temperature_c >= 30), by = .(Origin, calendar_month, hour_band)]
  candidates = if (heat && any(data$hot_n >= 20)) data[hot_n >= 20] else data
  setorder(candidates, -cell_n, flight_id)
  cell = candidates[1L]
  matching = data[Origin == cell$Origin & calendar_month == cell$calendar_month & hour_band == cell$hour_band]
  exposure = if (heat) "temperature_c" else "prior_delay"
  center = median(matching[[exposure]])
  profile = matching[which.min(abs(matching[[exposure]] - center))]
  if (!heat) matching = matching[abs(turn_minutes - profile$turn_minutes) <= 30]
  if (question == "cutoff") {
    # A longer arrival delay must still put the inbound arrival before cutoff
    # at the fixed profile's scheduled turn time.
    matching = matching[prior_delay <= profile$turn_minutes - 60]
  }
  levels = unique(as.numeric(quantile(matching[[exposure]], c(0.1, 0.5, 0.9), type = 1)))
  if (length(levels) < 2L) stop("Insufficient within-airport support for ", question, " density scenarios.")
  scenarios = profile[rep(1L, length(levels))]
  if (heat) scenarios[, temperature_10 := levels / 10] else scenarios[, prior_delay_30 := levels / 30]
  model = artifact$model
  mass = forest_mass(model, scenarios)
  stats = summarize_forest_mass(mass, model$support)
  curves = lapply(seq_along(levels), function(i) {
    density(model$support, weights = as.numeric(mass[, i]), bw = 2.5, from = -35, to = 180, n = 1024)
  })
  colors = forest_colors[seq_along(levels)]
  labels = paste(format(round(levels, 1), trim = TRUE),
                 if (heat) "\u00b0C at departure" else "min inbound delay")
  title = switch(question, heat = "Departure-airport heat",
                 rotation = "Inbound delay | retrospective",
                 cutoff = "Inbound delay | inbound arrived by cutoff")
  path = file.path(output, paste0("forest_", question, "_density.png"))
  png(path, width = 1400, height = 700, res = 145)
  on.exit(dev.off())
  layout(matrix(1:2, nrow = 1), widths = c(1.6, 1))
  par(mar = c(4.5, 4.2, 4.3, 0.6), las = 1, bty = "l")
  plot(curves[[1L]]$x, curves[[1L]]$y, type = "n",
       ylim = c(0, 1.15 * max(vapply(curves, function(curve) max(curve$y), numeric(1)))),
       main = title, xlab = "Departure delay (minutes)", ylab = "Density")
  abline(v = 0, lty = 3, col = "grey55")
  for (i in seq_along(levels)) lines(curves[[i]], col = colors[i], lwd = 2.4, lty = i)
  legend("topright", labels, col = colors, lwd = 2.4, lty = seq_along(levels), bty = "n", cex = 0.82)
  mtext(sprintf("%s  |  %s  |  %02d:%02d local",
                profile$Origin, as.character(profile$flight_day),
                profile$minute_of_day %/% 60, profile$minute_of_day %% 60),
        line = 0.35, col = "#4F5F6D", cex = 0.82)

  par(mar = c(4.5, 4.2, 4.3, 0.8), las = 1, bty = "l")
  chances = 100 * t(as.matrix(stats[, .(p15, p30, p60)]))
  matplot(c(15, 30, 60), chances, type = "b", lty = seq_along(levels), pch = 15:17,
          col = colors, lwd = 2, xaxt = "n", ylim = c(0, max(chances) * 1.1),
          main = "Chance of a long delay", xlab = "At least this many minutes",
          ylab = "Probability (%)")
  axis(1, at = c(15, 30, 60))
  mtext("Probabilities from the unsmoothed distribution", line = 0.35, col = "#4F5F6D", cex = 0.72)

  data.table(question, airport = artifact$airport, bucket = artifact$bucket,
             flight_id = profile$flight_id, origin = profile$Origin, destination = profile$Dest,
             flight_day = profile$flight_day, minute_of_day = profile$minute_of_day,
             local_comparison_n = nrow(matching), turn_minutes = profile$turn_minutes,
             exposure = levels, stats[, setdiff(names(stats), "crps"), with = FALSE])
}

plot_forest_validation = function(selected, attenuation, reliability, output) {
  selected_keys = selected[, .(question, airport, bucket)]
  calibration = merge(reliability, selected_keys, by = names(selected_keys))
  contrasts = merge(attenuation, selected_keys, by = names(selected_keys))
  labels = c(heat = "Departure heat", rotation = "Retrospective inbound", cutoff = "Inbound by cutoff")
  png(file.path(output, "forest_calibration.png"), width = 1400, height = 605, res = 135)
  par(mfrow = c(1, 3), mar = c(4.6, 4.2, 4, 0.8), las = 1, bty = "l")
  for (question_value in names(labels)) {
    points = calibration[question == question_value & n >= 30]
    plot(c(0, 1), c(0, 1), type = "n", xlim = c(0, 1), ylim = c(0, 1),
         main = labels[[question_value]], xlab = "Mean predicted probability",
         ylab = "Observed fraction delayed 30+ min")
    abline(0, 1, col = "grey60", lty = 2)
    for (f in seq_len(nrow(folds))) {
      line = points[fold == folds$fold[f]][order(bin)]
      lines(line$predicted, line$observed, type = "b", pch = 15L + f, col = forest_colors[f], lwd = 2)
    }
    if (question_value == "heat") {
      legend("topleft", folds$fold, col = forest_colors, pch = 16:17, lwd = 2, bty = "n", cex = 0.75)
    }
  }
  dev.off()

  png(file.path(output, "forest_intraday.png"), width = 1170, height = 630, res = 135)
  par(mfrow = c(1, 2), mar = c(5.2, 4.6, 4, 1), las = 1, bty = "l")
  limits = range(0, 1.25 * contrasts$mean_contrast_FALSE, 1.25 * contrasts$mean_contrast_TRUE)
  for (question_value in c("rotation", "cutoff")) {
    values = contrasts[question == question_value]
    values = values[match(folds$fold, fold)]
    heights = rbind(values$mean_contrast_FALSE, values$mean_contrast_TRUE)
    barplot(heights, beside = TRUE, col = forest_colors[1:2], border = NA,
            names.arg = c("Jan-Jun", "Jul-Dec"), ylim = limits,
            ylab = "5 pm minus 10 am fitted mean delay (min)", main = labels[[question_value]],
            sub = "Same flights and covariates at both times")
    abline(h = 0, col = "grey60")
    legend("topright", c("Without inbound delay", "With inbound delay"),
           fill = forest_colors[1:2], border = NA, bty = "n", cex = 0.75)
  }
  dev.off()
}
