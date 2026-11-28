# Forecast-enriched departure-delay data

The output is partitioned Parquet under `data/processed/history/flights_model_ready`, with one row per eligible non-cancelled flight. `departure_delay_minutes` is the official BTS DepDelay: positive = late, negative = early. The 2023–24 rows are labelled `train_2023_2024`, and 2025 `test_2025`. Those labels describe the original chronological workflow. The current three-year cross-validation uses the same years under a separate week-based fold assignment. Chronological separation is based on BTS FlightDate (local scheduled departure date).

Only rows with a nonmissing BTS delay and a clock-consistent reconstructed UTC departure are included. Scheduled departure and elapsed time are resolved using airport-coordinate time zones. Actual UTC departure is computed as scheduled UTC plus BTS DepDelay, then checked against BTS's actual departure local clock. This check is not independent verification of the day or the magnitude of a delay differing by an exact whole number of days. Ambiguous/nonexistent scheduled local times, unknown time zones and clock mismatches are excluded; departures that occurred despite a recorded cancellation are also excluded. The complete master retains these records. Exclusions can affect representativeness and must be reported.

Prediction cutoff is 60 minutes before scheduled departure. Target-flight actual time, actual delay components, cancellation, actual arrival, tail number, retrospectively reconstructed rotations, and realized previous-flight outcomes are absent from the input columns. Flight existence and schedule are taken from the final BTS data; no historical schedule snapshot proves their availability or original values at cutoff. Observation timestamps are assumed to approximate publication times. Thus this is a candidate historical predictive dataset, not a strictly proven live-deployment backtest. The 2025 test split remains subject to these assumptions.

Historical IEM TAFs are joined by destination station. The newest unambiguous TAF product issued no later than cutoff and no more than 24 hours before it is selected first. A match is retained only for an explicit prevailing FM segment whose start is at or before scheduled arrival and whose end is bounded by the next forecast or becoming segment within that same product. The initial and final unbounded forecast periods, ambiguous products, and unknown intervals remain missing. TEMPO and PROB alternatives are not incorporated; values describe prevailing conditions, not all risks. Forecast fields include issuing station, product ID, issue time, segment bounds, raw text, wind speed/direction/gust, visibility, present-weather and sky text. IEM represents visibility exceeding six miles as 6.01 miles, not an exact measurement. Forecasts contain no temperature prediction in this source. The issue timestamp is not independently verified delivery time. Airport station mappings are limited to the earlier explicitly checked IEM/airport mappings. The model inputs still include observed cutoff weather, separate from forecast-at-arrival fields.

The weather and forecast data have substantial missingness. Do not encode missing observations as calm, dry or zero. Build preprocessing and imputation from the training period only, with missingness indicators if appropriate. Avoid making causal claims from a predictive model. The extended output does not yet include a comprehensive feature dictionary, historical schedule-availability evidence, full airport metadata validation, or an independently executed R loading test. See `model_quality.json` for per-month counts and source failures and `forecast_supplement.log` for acquisition progress.

To resume the complete workflow: `.venv/bin/python src/main.py`. The source data response is retained losslessly in gzip and hashed in adjacent JSON. Existing completed months are skipped. The 10 GiB data-directory budget and 2 GiB free-space reserve remain in force. R loading example: `analysis/load_model_ready.R`.

## Completed run and audit

The 36 master partitions contain 20,928,579 scheduled records. The candidate modeling subset contains 20,420,136 eligible non-cancelled rows; 508,443 master records are excluded. Training (2023–2024) contains 13,597,650 rows and test (2025) contains 6,822,486; 11,847,593 labels are negative.

- Bounded destination forecast: 7,589,318 rows (37.17%).
- Origin cutoff observation: 14,976,746 rows (73.34%).
- Destination cutoff observation: 14,777,099 rows (72.37%).

There were 0 reported TAF acquisition failures. Audit verified unique IDs per monthly partition, equality with the original BTS DepDelay, non-cancelled outcomes, split dates, observation cutoffs, forecast issue/validity times and destination station consistency. Run `.venv/bin/python src/main.py` to repeat the complete workflow and audit; detailed field null rates are in `model_validation.json`. This audit checks the stored data and does not independently verify BTS source measurements or prove historical data delivery.

## STAT4P87 analysis plan

This section documents the earlier chronological workflow. The current workflow is described under [three-year cross-validation](#three-year-cross-validation).

1. **Outcome.** Model the full distribution of signed departure delay in minutes for eligible non-cancelled flights. This measures schedule deviation at departure. A taxi-out, security, or passenger wait is a different outcome. The observed BTS values have minute resolution. A smoothed density is used to display the distribution, and an empirical predictive CDF is used for scoring.
2. **Heat.** Use the origin air temperature observed within an hour before the one-hour-ahead prediction cutoff. Compare models with and without temperature on the same flights with measured temperature. Control for origin weather (wind and visibility), local departure time, calendar, carrier, departure airport, route distance, and scheduled traffic. Interpret the coefficient per 10 °C and plot several locally observed temperatures for a fixed flight profile. Airport weather coverage and the association with season limit interpretation.
3. **Previous leg.** Link the immediately preceding scheduled leg of the same aircraft when its destination matches the next origin and its scheduled arrival is within 12 hours and on the same local day. Require a recorded, clock-consistent prior arrival and exclude prior cancellations, diversions, and ambiguous scheduled ties. Use signed arrival delay as the exposure and control for scheduled turnaround time. Compare models with and without prior delay on the same linked flights. Evaluate the change in predictive CRPS and the attenuation of the departure-hour slope, defined as `1 - adjusted slope / base slope` when the base slope is positive. Attenuation above 50% is a descriptive benchmark for “mostly,” and both folds should be checked. Timing, common disruptions, and aircraft assignment can affect these estimates. Repeat the comparison for the subset whose previous leg arrived by the one-hour cutoff. This subset uses historical tail assignments and overrepresents legs with enough time to arrive before the cutoff. The retrospective fit can use arrival outcomes that were unavailable at that cutoff.
4. **Airport encoding.** For heat, compare a departure-airport factor with latitude and longitude at the departure airport. Heat models use origin weather and require coordinates only at the origin. The rotation comparisons use both flight endpoints, represented by either airport factors or latitude and longitude. Rare factor levels are pooled using the fitting data. Longitude is recentered around the Americas to keep the Alaska and Pacific airport coordinates contiguous. Within each question, both encodings use the same flights.
5. **Daily versus weekly.** Keep the flight-level response. Assign each flight an origin-local scheduled day and a Monday-start week, and write both bucket summaries. The daily model uses the origin's scheduled departure count on the completed local day immediately before the cutoff day. The weekly model uses the mean daily scheduled departure count in the completed Monday–Sunday week immediately before the cutoff week. Both use all scheduled departures, including cancellations, and rely on historical final schedules. Rows without a complete lookback at the beginning of 2023 are excluded from the comparison. This compares time resolutions of the same traffic control.
6. **Time of day.** Use local scheduled minute of day (0–1439), scaled to hours for the linear fit. BTS `2400` rolls to minute 0 on the next local date. Scheduled local day and cutoff local day are computed separately using the airport's time zone.
7. **Validation.** Compare the 2 × 2 airport/traffic specifications on the same sampled rows. Use expanding chronological fitting windows, a separate two-month residual calibration window before each validation period, and two 2024 validation periods. Prepare all 2023–2024 eligible rows, then sample up to 4,500 flights per source month for each cohort with a fixed seed. Rank full models by CRPS (lower is better), and report MAE, RMSE and empirical 90% interval coverage. Keep 2025 for the final comparison after choosing the model.
8. **Density diagnostics.** The linear baseline models location with `lm()`. If its fitted mean is `m(x)` and the separate calibration residual density is `g(e)`, the displayed density is `g(y - m(x))`. Hold the other inputs fixed at a real flight profile. Choose the exposure values from nearby observed flights at the same origin, month, and time band, and for the rotation plot use similar scheduled turns. The baseline moves the curve horizontally because it uses a common residual distribution. Changes in spread or tail thickness require a model with a conditional residual distribution. The kernel smoothing lecture gives the basis for the plot. Discuss model choice after reviewing these baselines. The course's spline regression (Oct. 26 and 28) and additive smoothing spline (Nov. 9) code provide two potential starting points.

For each choice of airport encoding and traffic bucket, the baseline has a common linear predictor for schedule, airline, distance and observed weather controls. The heat model adds temperature per 10 °C. The rotation model also controls for temperature and scheduled turn time and adds prior arrival delay per 30 minutes. In each case the reduced model omits just the exposure being evaluated. Exposure coefficients describe changes in the fitted location of the delay distribution.

### Run the development analysis

Run from the repository root with R packages `arrow`, `data.table`, and `tidyselect` installed. The first argument is the data directory containing `intermediate/bts_flights` and `intermediate/airport_metadata.parquet`. The second is the directory containing the annual IEM station Parquet files, usually `data/intermediate/weather`. These inputs can come from an earlier data cache. The heat analysis uses the cached origin station observations directly.

```sh
Rscript analysis/prepare_study.R data data/intermediate/weather data/study
Rscript analysis/linear_study.R data/study data/study-results
```

The first command writes monthly feature partitions, monthly coverage, a weather input manifest, and daily and weekly summaries. The second writes fold scores, pooled validation scores, matched exposure comparisons, and the profile data and plots for the heat and prior-leg diagnostics.

### Development results

All 24 development partitions contain 13,597,650 eligible flights. Of these, 9,980,674 have a matched origin temperature, 10,239,124 have a qualifying tentative inbound rotation, and 5,674,361 have a qualifying inbound arrival by the cutoff. Daily and weekly totals reconcile. Each cohort's validation metrics use 54,000 sampled 2024 flights across two chronological folds. The 2025 flight outcomes remain reserved for final evaluation.

| Cohort | Lowest pooled validation CRPS | Airport factors with the same traffic bucket | Daily versus weekly gap with coordinates |
|---|---:|---:|---:|
| Heat | 16.561 (departure coordinates, daily) | 16.621 | 0.00060 |
| Retrospective rotation | 11.563 (coordinates, weekly) | 11.661 | 0.00022 |
| Inbound arrived by cutoff | 8.019 (coordinates, weekly) | 8.113 | 0.00048 |

- **Heat.** In the departure-coordinate/daily specification, a 10 °C increase corresponded to a fitted location shift of +0.12 minutes in the first fold and −0.74 minutes in the second. Adding temperature raised CRPS by 0.004 in the first fold and lowered it by 0.002 in the second. The fixed-airport DFW profiles from 34.4 to 38.9 °C shift the fitted delay by about 0.22 minutes.
- **Retrospective rotation.** In the coordinate/weekly specification, adding prior arrival delay lowered pooled CRPS from 14.615 to 11.563 and reduced the departure-hour slope by 61–64% across both folds. This meets the study's descriptive attenuation benchmark within the retrospective linked cohort.
- **Cutoff sensitivity.** For flights whose inbound leg had already arrived by the cutoff, the coordinate/weekly specification reduced the departure-hour slope by 2.5–3.0%. Pooled CRPS was 8.013 without prior arrival delay and 8.019 with it in this subset. The subset reflects different turn lengths and arrival timing. The two rotation results describe associations within their own populations.
- **Distribution diagnostics.** The nominal 90% intervals covered about 83–84% in the first validation fold and 92–93% in the second for the selected specifications. The linear baseline holds its residual shape fixed across profiles and seasons. The density plots zoom in on the main range of delays. The scores include all sampled validation rows.

## STAT4P87 quantile regression forest

This section describes the forest and its first chronological evaluation.

The forest uses the numeric signed delay in minutes as its response. Regression trees learn which flights to group together. Each leaf contributes a normalized distribution of the observed delays in that leaf, and the flight forecast averages those distributions over the trees. The resulting probability mass function preserves the resolution of the recorded delays. The displayed PDF is a Gaussian-kernel-smoothed version of that mass, with a shared 2.5-minute bandwidth. Threshold probabilities, interval coverage, and CRPS use the unsmoothed distribution.

The model follows the regression forest framework in STAT4P87 *Ensemble Methods*, slides 18–21, and uses the conditional distribution extension from [Meinshausen (2006)](https://jmlr.org/papers/v7/meinshausen06a.html). The R implementation uses [ranger](https://cran.r-project.org/package=ranger) for tree fitting and terminal-node assignments. The empirical distribution uses every fitting observation that reaches a leaf and gives every tree equal weight.

- **Comparison design.** The forest and linear baseline share flight samples, preprocessing, predictors, fitting windows, and 2024 validation folds. Within each cohort, compare both airport encodings and both traffic buckets, each with and without the exposure. The heat models use weather and geography at the departure airport. The rotation models retain both endpoints.
- **Tuning.** For each cohort and fold, compare minimum leaf sizes of 25 and 80 using earlier calibration observations and the coordinate/daily specification. The outer validation fits use 128 trees. Use the first calibration period to select the airport and traffic specification displayed for each cohort. All specification scores are retained. The saved diagnostic models refit through October 2024 and tune on November–December 2024. The 2025 outcomes remain reserved.
- **Interpretation.** The fixed-flight plots vary departure temperature or inbound arrival delay over locally observed values. The cutoff plot also requires that the hypothetical inbound arrival remain feasible by the model cutoff. The intraday comparison sets the same sampled profiles to 10 a.m. and 5 p.m. within airports and months with data in both time bands. It measures how the fitted mean-delay contrast changes when inbound delay is included. The difference describes a model association. The retrospective cohort and the subset that landed by cutoff each have their own comparisons.
- **Validation.** Lower CRPS is better. Score the forest against the linear model on the same rows for each specification. Also check 90% interval coverage and the reliability of the probability of a departure delay of 30 minutes or more.

### Run in R

Install `ranger` and `Matrix` alongside the packages used for the linear analysis. From the repository root, use the prepared monthly partitions and the linear fold results.

```sh
Rscript analysis/forest_study.R data/study data/study-results data/forest-results
```

The output includes the saved forests and their preprocessing, forest and linear comparison scores, exposure ablations, intraday contrasts, probability calibration, and fixed-flight density plots. To get a numeric probability from a saved model, pass rows with the schema produced by `analysis/prepare_study.R` to `predict_delay_distribution()`.

```r
library(data.table)
source("analysis/study_inputs.R")
source("analysis/delay_forest.R")

artifact = readRDS("data/forest-results/models/heat.rds")
forecast = predict_delay_distribution(artifact, flights)
p_at_least_30_min = Matrix::colSums(
  forecast$probability[forecast$minutes >= 30, , drop = FALSE]
)
```

### Forest development results

Across the displayed configurations, matched forest versus linear CRPS was 15.017 versus 16.561 for heat, 8.864 versus 11.656 for retrospective rotation, and 7.364 versus 8.019 for rotation by cutoff. Forest 90% interval coverage was 90.9%, 92.9%, and 91.1% respectively. The retrospective reliability plot shows underprediction of 30-minute delay risk in its higher-probability bins.

- In the heat comparison, departure-airport temperature reduced CRPS by 0.007 in January–June and raised it by 0.010 in July–December. The two folds give little evidence of incremental predictive value from temperature.
- In the retrospective rotation comparison, including prior arrival delay reduced CRPS from 13.368 to 8.864. It reduced the adjusted 5 p.m. versus 10 a.m. difference in fitted mean delay by 60–62%. For the cutoff-only cohort, prior delay reduced CRPS from 7.384 to 7.364 and reduced the intraday contrast by 9–12%.

## Three-year cross-validation

The current STAT4P87 evaluation uses **five-fold cross-validation across 2023–2025**. Each fold holds out whole Monday-start weeks. Within each calendar year and quarter, weeks are shuffled and spread across the five folds with a fixed seed. This is the grouped version of the course's shuffled fold assignment. Stratifying on the calendar balances seasons while keeping flights that share weather and operational disruptions together. Each sampled flight contributes one out-of-fold prediction per model specification. This evaluates performance on other weeks from the same historical period. A test of future-year performance would need a later, untouched period.

### Reproduce the data and analysis

Run these commands from the repository root. Activate a Python 3.11+ virtual environment before installing the project (for example, `python -m venv .venv`, then `source .venv/bin/activate` on macOS/Linux or `./.venv/Scripts/Activate.ps1` in PowerShell). The two collection steps reuse cached files and need network access for uncached data. They fetch BTS flight records, airport coordinates and IEM station observations. Archived destination forecasts are used by the older end-to-end pipeline. The current analysis uses departure-airport observations.

```sh
python -m pip install -e .
python src/collect_history.py
python src/collect_weather_history.py
```

In R, install the required packages once.

```r
install.packages(c("arrow", "data.table", "tidyselect", "ranger", "Matrix"))
```

Then prepare the full 36 monthly partitions and run the cross-validation.

```sh
Rscript analysis/prepare_study.R data data/intermediate/weather data/study-three-year 2025
Rscript analysis/study_cv.R data/study-three-year data/three-year-cv 1800
```

The prepare command processes all eligible source flights. For the forest comparison, the last argument sets the maximum sampled rows per month **per cohort**. The reported run uses 1,800, with all 36 months represented in each cohort. Higher values increase runtime and memory use. The three cohorts are departure-airport heat, retrospective aircraft rotation, and rotation with the prior arrival available by cutoff. The same sampled rows are used for competing specifications within each cohort. Different cohorts can contain the same flight.

The forest uses 64 trees with a fixed minimum leaf size of 50 for heat and 25 for the two rotation cohorts. Headline airport and traffic configurations come from the previous comparison and are fixed before assigning results. Other airport/traffic combinations are scored as full-model sensitivity checks. Exposure removal and the linear comparison use the headline specifications. The linear residual distribution is estimated on a separate week fold within each outer training set. Feature preprocessing and model fits use only each outer training set. The three saved forest models are then refit on all sampled years.

The output directory contains week and flight fold assignments, fold-level and pooled scores, calibration bins, intraday contrasts, density-profile probabilities, plots, and the refit R models. See the [team write-up](three-year-study-update.md) for the technical specification and the [README](../README.md#three-year-cross-validation) for the plot index.

## Interactive explorer

The browser uses the three forests refitted by `analysis/study_cv.R`. Regenerate the dashboard asset after refitting or changing the sample.

```r
install.packages("jsonlite")
```

```sh
Rscript analysis/export_dashboard.R data/study-three-year data/three-year-cv docs/delay-data.json
python -m http.server 8765 --directory docs
```

Open `http://localhost:8765` to preview. The export keeps fixed flight profiles, evaluates the forest at each supported slider setting, and writes the model summaries to a static asset. It uses a 2.5-minute Gaussian kernel for the displayed density and the original probability mass for threshold probabilities and prediction intervals. The inbound slider range depends on scheduled departure time and, in the cutoff cohort, the scheduled turn and one-hour prediction cutoff. GitHub Pages publishes the `docs/` directory from the `main` branch.

For the **All inputs** tab, export the same fitted tree splits, factor ordering, and leaf delay counts into the browser model assets. The optional QA directory stores local prediction fixtures for verifying the browser against R.

```sh
Rscript analysis/export_forest_controls.R data/study-three-year data/three-year-cv docs data/forest-browser-qa
node analysis/check_browser_forest.mjs docs data/forest-browser-qa
```

The All inputs tab evaluates the selected forest locally and allows arbitrary combinations within each control's range. Controls use the middle 98% of the fitting values plus the starting flight value. Month updates the two seasonal terms together. A weather observation marked missing uses its fitted imputation value and the corresponding missingness indicator. The cutoff model also checks that the edited inbound delay fits the one-hour cutoff given the scheduled turnaround.
