# Diagnostic figures for grouped five-fold validation.
cv_png = function(output, name, draw, width = 1420, height = 585) {
  png(file.path(output, paste0("cv_", name, ".png")), width = width, height = height, res = 135)
  on.exit(dev.off())
  force(draw)
}

plot_cv_diagnostics = function(matched, reliability, contrasts, ablation, pooled, weeks, output) {
  titles = c(heat = "Departure heat", rotation = "Retrospective inbound", cutoff = "Inbound by cutoff")
  questions = names(titles)
  cv_png(output, "scores", {
    par(mfrow = c(1, 3), mar = c(4.3, 4.3, 3, 1), las = 1, bty = "l")
    for (question_value in questions) {
      data = matched[question == question_value][order(fold)]
      matplot(data$fold, as.matrix(data[, .(CRPS_linear, CRPS_forest)]), type = "b",
              col = forest_colors[1:2], lty = 1:2, pch = c(16, 17), lwd = 2,
              main = titles[[question_value]], xlab = "Validation fold", ylab = "CRPS (lower is better)")
      legend("topright", c("Linear", "Forest"), col = forest_colors[1:2], pch = c(16, 17),
             lty = 1:2, lwd = 2, bty = "n", cex = 0.8)
    }
  })
  cv_png(output, "interval_coverage", {
    par(mfrow = c(1, 3), mar = c(4.3, 4.6, 3, 1), las = 1, bty = "l")
    limits = range(90, 100 * matched$coverage_linear, 100 * matched$coverage_forest) + c(-0.5, 0.5)
    for (question_value in questions) {
      data = matched[question == question_value][order(fold)]
      matplot(data$fold, 100 * as.matrix(data[, .(coverage_linear, coverage_forest)]), type = "b",
              col = forest_colors[1:2], lty = 1:2, pch = c(16, 17), lwd = 2, ylim = limits,
              main = titles[[question_value]], xlab = "Validation fold", ylab = "90% interval coverage (%)")
      abline(h = 90, col = "grey55", lty = 3)
      legend("bottomright", c("Linear", "Forest"), col = forest_colors[1:2],
             pch = c(16, 17), lty = 1:2, lwd = 2, bty = "n", cex = 0.8)
    }
  })

  cv_png(output, "exposure", {
    par(mfrow = c(1, 3), mar = c(4.3, 4.7, 3, 1), las = 1, bty = "l")
    for (question_value in questions) {
      data = ablation[question == question_value][order(fold)]
      barplot(data$CRPS_improvement, names.arg = data$fold, col = forest_colors[2],
              border = NA, ylim = range(0, 1.15 * data$CRPS_improvement),
              main = titles[[question_value]], xlab = "Validation fold",
              ylab = "CRPS gain from adding exposure")
      abline(h = 0, col = "grey45")
    }
  })
  cv_png(output, "intraday", {
    par(mfrow = c(1, 2), mar = c(4.3, 4.6, 3, 1), las = 1, bty = "l")
    limits = range(0, 1.3 * contrasts$mean_gap_FALSE, 1.3 * contrasts$mean_gap_TRUE)
    for (question_value in c("rotation", "cutoff")) {
      data = contrasts[question == question_value][order(fold)]
      barplot(rbind(data$mean_gap_FALSE, data$mean_gap_TRUE), beside = TRUE,
              names.arg = data$fold, col = forest_colors[1:2], border = NA, ylim = limits,
              main = titles[[question_value]], xlab = "Validation fold",
              ylab = "5 p.m. minus 10 a.m. fitted delay (min)")
      abline(h = 0, col = "grey50")
      legend("topright", c("Without inbound delay", "With inbound delay"),
             fill = forest_colors[1:2], border = NA, bty = "n", cex = 0.78)
    }
  }, width = 1120)
  cv_png(output, "calibration", {
    par(mfrow = c(1, 3), mar = c(4.5, 4.5, 3, 1), las = 1, bty = "l")
    bins = reliability[, .(n = sum(n), x = weighted.mean(predicted, n),
                             y = weighted.mean(observed, n)), by = .(question, bin)]
    for (question_value in questions) {
      data = bins[question == question_value & n >= 30][order(bin)]
      plot(c(0, 1), c(0, 1), type = "n", xlab = "Predicted probability",
           ylab = "Observed fraction delayed 30+ min", main = titles[[question_value]])
      abline(0, 1, col = "grey65", lty = 2)
      lines(data$x, data$y, type = "b", col = forest_colors[1], pch = 16, lwd = 2)
    }
  })
  cv_png(output, "configurations", {
    par(mfrow = c(1, 3), mar = c(4.3, 7.8, 3.5, 1), oma = c(1.4, 0, 0, 0), las = 1, bty = "l")
    for (question_value in questions) {
      data = pooled[question == question_value & full == TRUE][order(CRPS)]
      index = rev(seq_len(nrow(data)))
      labels = paste(ifelse(data$airport == "coordinates", "Coordinates", "Factors"),
                     data$bucket, sep = " / ")
      limits = extendrange(data$CRPS, f = 0.1)
      plot(data$CRPS, index, type = "n", xlim = limits, ylim = c(0.6, nrow(data) + 0.4), yaxt = "n",
           main = titles[[question_value]], xlab = "Pooled forest CRPS", ylab = "")
      axis(2, at = index, labels = labels, tick = FALSE, cex.axis = 0.75)
      segments(limits[1], index, data$CRPS, index, col = "grey83", lty = 3)
      points(data$CRPS, index, pch = 16, col = ifelse(data$headline, forest_colors[2], forest_colors[1]))
    }
    mtext("Teal marks the prespecified configuration used for baseline and exposure comparisons.",
          side = 1, outer = TRUE, line = 0.1, cex = 0.76, col = "#4F5F6D")
  }, width = 1500, height = 620)

  cv_png(output, "fold_balance", {
    par(mar = c(4.4, 4.8, 3, 1), las = 1, bty = "l")
    allocation = weeks[, .(flights = sum(flights)), by = .(season_year, quarter, fold)]
    allocation[, share := 100 * flights / sum(flights), by = .(season_year, quarter)]
    strata = dcast(allocation, season_year + quarter ~ fold, value.var = "share")
    labels = paste0(strata$season_year, " Q", strata$quarter)
    shares = as.matrix(strata[, as.character(1:5), with = FALSE])
    image(seq_len(nrow(shares)), 1:5, shares, xlab = "Season of week midpoint", ylab = "Validation fold",
          xaxt = "n", yaxt = "n", col = hcl.colors(15, "Teal"), main = "Share of eligible flights by season")
    axis(1, at = seq_along(labels), labels = labels, cex.axis = 0.75)
    axis(2, at = 1:5)
    text(rep(seq_along(labels), times = 5), rep(1:5, each = nrow(shares)),
         paste0(round(as.vector(shares)), "%"), cex = 0.8,
         col = ifelse(as.vector(shares) < min(shares) + 0.35 * diff(range(shares)), "white", "#142D36"))
  }, width = 1200, height = 470)
}
