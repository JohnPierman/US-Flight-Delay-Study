# STAT4P87 flight delay study update

November 27, 2026

## What we built

We prepared 36 months of U.S. domestic flight records, from January 2023 through December 2025. The resulting dataset contains **20,420,136 eligible flights**. About 15.0 million have matched departure-airport temperature, and 8.4 million have a linked inbound arrival by the cutoff. Our outcome is the signed difference, in minutes, between actual and scheduled departure. Negative values represent early departures. The R preparation joins departure-airport weather, adds local minute of day and daily and weekly airport traffic, and reconstructs tentative inbound connections for the same aircraft. For those connections, we record whether the inbound aircraft had landed by the one-hour prediction cutoff.

We built a quantile regression forest in R using the regression forest from the STAT4P87 ensemble lecture. It estimates a distribution of delay minutes for each flight. We use it to calculate probabilities of 15-, 30-, and 60-minute delays and prediction intervals. The density plots smooth the estimated minute probabilities so we can compare scenarios with one input changed and the rest held fixed.

## How we validated it

We replaced the chronological holdouts with **five-fold cross-validation** covering all three years. We shuffled 158 whole Monday-start weeks within each year and quarter to distribute seasonal patterns across the folds. Flights in the same week stay together because they can share weather and operational disruptions. Each sampled flight is scored once, by a model trained on the other four folds. The preparation covers all eligible records. For this model run, we used a reproducible sample of up to 1,800 flights per month per cohort, which gave 64,800 evaluated flights per cohort across all 36 months. Competing models use the same flights within each cohort.

This design measures how well models generalize to unseen weeks in the historical period. A later, untouched period would be needed to measure future-year forecasting performance. The retrospective and cutoff-only rotation cohorts also describe different groups of flights.

## What the results show

| Cohort | Linear CRPS | Forest CRPS | Forest 90% interval coverage |
|---|---:|---:|---:|
| Departure-airport heat | 16.42 | 14.94 | 92.0% |
| Retrospective inbound delay | 11.45 | 8.77 | 93.6% |
| Inbound landed by cutoff | 8.03 | 7.43 | 92.2% |

Lower continuous ranked probability score (CRPS) is better. Although the forest improved the overall heat model, adding departure-airport temperature slightly worsened CRPS in all five folds. The current analysis gives little evidence that temperature adds predictive value after accounting for the other inputs.

Prior arrival delay was strongly informative retrospectively. Including it reduced the modeled 5 p.m. versus 10 a.m. mean-delay gap by 65–70% across the folds. In the cutoff-only cohort, prior delay improved CRPS slightly in every fold, and its association with the intraday gap was much smaller. The gap widened by 3% in one fold and narrowed by up to 20% in the others. The cutoff result is the more relevant one for a prediction made an hour before departure.

The daily and weekly traffic controls performed nearly identically within each airport encoding. Airport factors scored slightly better for retrospective rotation. Airport encoding made little difference in the heat and cutoff-only cohorts.

## What the team can use

The [README](../README.md#three-year-cross-validation) links the plot gallery, including fold balance, linear versus forest scores, airport and traffic sensitivity, predictor contribution, calibration, interval coverage, and the density overlays. The [run instructions](model_readiness.md#reproduce-the-data-and-analysis) walk through downloading or reusing the BTS and weather data, preparing the three-year partitions, and running the R models. The run writes fold assignments, score tables, plot data, and the refit forests locally. These outputs make it possible to reproduce both the comparison and the predicted delay probabilities.
