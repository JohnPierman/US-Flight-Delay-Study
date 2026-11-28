# STAT 4P87 U.S. flight delay study

The modeling dataset combines 2023–2025 BTS reporting-carrier domestic flights with airport metadata, historical observations and archived destination aviation forecasts. The signed BTS departure delay is the outcome. Weather is matched at or before a prediction cutoff 60 minutes before scheduled departure; destination forecasts must be issued by that cutoff and cover scheduled arrival. Eligible non-cancelled flights are stored as one partitioned Parquet dataset, with legacy labels for the original 2023–2024 training period and 2025 test period. Flight schedules and weather delivery times have historical-availability limitations described below.

## Regenerate the dataset

From a fresh clone, install Python 3.11 or later and run from the repository root:

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -e '.[test]'
.venv/bin/python src/main.py
```

This one command downloads and validates monthly BTS files, obtains airport metadata and IEM observations for the 40 highest-traffic eligible stations, constructs timestamps and weather matches, adds destination forecasts, and runs the final data audit. Work is checkpointed; if a stage fails, rerun the same command to resume. Status and logs are written under `reports/`. The run needs network access and can take substantial time. It enforces an approximate 10 GiB limit on the workspace `data/` directory and keeps 2 GiB of free disk as a reserve; temporary extraction is included in the checks. Raw data, intermediate data and Parquet files are not included in GitHub.

**Final dataset:** `data/processed/history/flights_model_ready/`. It is one Arrow-compatible dataset partitioned by year and month, not one Parquet file. Read the directory using R's `arrow::open_dataset()`; see `analysis/load_model_ready.R`. Intermediate source and master partitions remain on disk for validation and reproducibility, but they are not separate deliverables. Run `.venv/bin/pytest -q` for the automated tests.

For a smaller end-to-end check, use a separate workspace. This downloads January 2024 flights plus weather and forecasts for two airports and does not alter the full dataset:

```bash
.venv/bin/python src/main.py --smoke --workspace /tmp/flight-delay-smoke
```

Use `--workspace /path/to/workspace` without `--smoke` to place the full run elsewhere. Each workspace has its own `data/` and `reports/`. Cached downloads and completed partitions are reused; delete or archive a workspace only if you intend to rebuild it. The live data sources and airport metadata can be revised, so a fresh download may not reproduce earlier results byte for byte. BTS records are limited to reporting-carrier nonstop domestic flights, including eligible U.S. territories; they do not cover international flights or all carriers.

The STAT4P87 development analysis prepares heat and prior-leg features, compares airport encodings and traffic buckets, and fits R linear baselines.


## Three-year cross-validation

The current analysis uses five-fold cross-validation over **2023–2025**. Whole calendar weeks stay in the same fold, and assignments are balanced within each year and quarter. The prep pipeline processes all eligible flights. The model evaluation uses a reproducible monthly sample from all 36 months for each of the three study cohorts.

- [Interactive Flight Delay Explorer with All inputs controls](https://johnpierman.github.io/US-Flight-Delay-Study/)
- [One-page technical handoff](reports/three-year-study-update.md)
- [Data download, R dependencies, and run instructions](reports/model_readiness.md#reproduce-the-data-and-analysis)
- [Fold balance](reports/figures/three-year-cv/cv_fold_balance.png) and [linear versus forest scores by fold](reports/figures/three-year-cv/cv_scores.png)
- [Airport and traffic configurations](reports/figures/three-year-cv/cv_configurations.png) and [predictor contribution](reports/figures/three-year-cv/cv_exposure.png)
- [Intraday comparison](reports/figures/three-year-cv/cv_intraday.png), [30-minute delay calibration](reports/figures/three-year-cv/cv_calibration.png), and [prediction interval coverage](reports/figures/three-year-cv/cv_interval_coverage.png)
- [Departure heat density](reports/figures/three-year-cv/forest_heat_density.png), [retrospective inbound density](reports/figures/three-year-cv/forest_rotation_density.png), and [cutoff-only inbound density](reports/figures/three-year-cv/forest_cutoff_density.png)

The chronological baselines below are retained as historical comparisons. The grouped folds measure performance on unseen historical weeks within the three-year period.

## STAT4P87 baseline results

The R baselines model signed departure delay in minutes. The preparation covers 13,597,650 eligible flights in 2023–2024. Each comparison uses 54,000 sampled flights across two chronological 2024 validation folds. That chronological baseline used outcomes through 2024.

| Question | Best airport and traffic inputs | CRPS without the exposure | CRPS with the exposure |
|---|---|---:|---:|
| Departure-airport heat | Departure latitude/longitude, daily | 16.560 | 16.561 |
| Prior arrival delay, retrospective | Origin and destination latitude/longitude, weekly | 14.615 | 11.563 |
| Prior arrival delay, inbound landed by cutoff | Origin and destination latitude/longitude, weekly | 8.013 | 8.019 |

Lower continuous ranked probability score (CRPS) is better. Coordinates outperformed airport factors in all three pooled comparisons. With coordinates, changing the traffic bucket from daily to weekly moved CRPS by less than 0.001 in each comparison. Compare scores within each row because the cohorts differ.

**Departure-airport heat.** Temperature, wind, visibility, and airport identity or coordinates all refer to the departure airport. In the coordinate/daily model, a 10 °C increase corresponded to a fitted delay shift of +0.12 minutes in January–June and −0.74 minutes in July–December. The curves for the fixed DFW departure nearly overlap.

![Predicted departure-delay densities for a fixed DFW flight at 34.4, 36.1, and 38.9 degrees Celsius](reports/figures/heat_delay_density.png)

**Prior arrival delay.** The retrospective model reduced the estimated rise in delay over the day by 61–64% after adding the inbound aircraft's arrival delay. In the subset whose inbound aircraft had landed by the one-hour cutoff, the reduction was about 3%. The fixed-flight diagnostic below uses the retrospective model.

![Predicted departure-delay densities for a fixed DEN departure at three prior arrival delays](reports/figures/rotation_delay_density.png)

Each plot varies one input and holds the other flight inputs fixed. The baseline shifts a shared residual density horizontally. See the [analysis plan and run commands](reports/model_readiness.md#stat4p87-analysis-plan) for the model specification, validation details, and caveats.


## Nonlinear delay distributions

The quantile regression forest estimates a probability distribution over signed departure-delay minutes. The evaluation pairs each forest with the linear model using the same airport and traffic inputs and the same 54,000 validation flights per cohort. Lower CRPS is better. That chronological forest run also used outcomes through 2024.

| Cohort | Airport and traffic inputs | Linear CRPS | Forest CRPS | Forest 90% interval coverage |
|---|---|---:|---:|---:|
| Departure-airport heat | Departure coordinates, weekly | 16.56 | 15.02 | 90.9% |
| Prior arrival delay, retrospective | Airport factors, daily | 11.66 | 8.86 | 92.9% |
| Prior arrival delay, inbound landed by cutoff | Coordinates, weekly | 8.02 | 7.36 | 91.1% |

- **Heat.** Adding departure-airport temperature improved CRPS by 0.007 in the first fold and worsened it by 0.010 in the second. The forest's better overall predictions give little evidence of incremental predictive value from heat.
- **Inbound delay.** Adding prior arrival delay reduced the model's 5 p.m. versus 10 a.m. delay contrast by 60–62% in the retrospective cohort and by 9–12% in the cutoff-only cohort. These are model-based associations.
- **Diagnostics.** Each fixed-flight chart pairs a smoothed density with the estimated chances of reaching 15, 30, and 60 minutes of delay. See [departure heat](reports/figures/forest_heat_density.png), [retrospective inbound delay](reports/figures/forest_rotation_density.png), and [inbound delay by cutoff](reports/figures/forest_cutoff_density.png). The [intraday comparison](reports/figures/forest_intraday.png) and [probability calibration](reports/figures/forest_calibration.png) show the validation diagnostics. The retrospective model understates 30-minute delay risk in the higher-probability bins.

See the [forest methods and R run commands](reports/model_readiness.md#stat4p87-quantile-regression-forest).


## Data quality and limitations

The existing full run produced 20,928,579 scheduled-flight master records and 20,420,136 eligible modeling rows. Its final audit checks row identifiers, official BTS outcome values, weather and forecast cutoff times, destination station mapping, and the temporal split. The label consistency check reconstructs actual UTC using BTS's own delay and checks the local clock; it is not independent confirmation of the precise delay. Ambiguous local times and other unresolved records are excluded from the modeling dataset but retained in the master. Previous-flight links in the intermediate master are tentative and excluded from strict predictive features because historical aircraft-assignment availability is unknown.

Observed weather is available for a subset of airports, and conservative destination forecast intervals cover only some flights. BTS final schedules are assumed available at the cutoff, and observation or forecast issue times may precede actual publication. Consequently this is suitable for exploratory modeling, not a proven real-time backtest. See `reports/data_dictionary.md` for field definitions, `reports/model_readiness.md` for methodology, `reports/model_validation.json` for the last full-run audit, and `reports/polished_model_sample.csv` for example rows. Weather stations, airport metadata and live source revisions can affect regenerated coverage.

<!-- EXPLORATORY SUMMARY START -->
## Exploratory summary

The figures use **20,420,136 eligible non-cancelled flights** in the 2023–2025 modeling dataset, not all scheduled flights. Delay is the signed BTS departure delay: negative values are early. These are unadjusted descriptions, not estimates of causal effects. Cancellations are included only in the annual scheduled-flight table below.

| Statistic | Value |
|---|---:|
| Mean departure delay | 12.8 min |
| Median departure delay | -2.0 min |
| 90th percentile | 44.0 min |
| Departed early (< 0 min) | 58.0% |
| Departed at least 15 min late | 20.9% |

![Distribution of departure delays](reports/figures/delay_distribution.png)

The chart uses two-minute bins from −30 to under 120 minutes, with percentages calculated over all eligible flights. The unplotted tails contain 960 flights below −30 minutes (0.005%) and 609,906 flights at 120 minutes or more (2.99%). These flights remain included in the summary statistics and dataset.

![Mean departure delay by scheduled local hour](reports/figures/delay_by_hour.png)

Hours with fewer than 1,000 flights are omitted from the plot; the remaining overnight hours also have fewer flights than daytime hours.

![Monthly mean departure delay](reports/figures/delay_by_month.png)

| Year | Scheduled flights in master | Cancelled | Eligible flights | Mean delay (min) | Median delay (min) | ≥15 min late |
|---|---:|---:|---:|---:|---:|---:|
| 2023 | 6,847,899 | 87,943 (1.3%) | 6,690,114 | 12.2 | -2.0 | 20.5% |
| 2024 | 7,079,061 | 96,315 (1.4%) | 6,907,536 | 12.6 | -2.0 | 20.6% |
| 2025 | 7,001,619 | 102,876 (1.5%) | 6,822,486 | 13.5 | -2.0 | 21.7% |

**Five busiest origin airports in the eligible sample**

| Origin | Eligible departures | Mean delay (min) | ≥15 min late |
|---|---:|---:|---:|
| ATL | 982,089 | 12.2 | 21.3% |
| DEN | 905,356 | 15.1 | 25.2% |
| DFW | 895,723 | 18.0 | 26.6% |
| ORD | 853,354 | 15.4 | 22.6% |
| CLT | 599,982 | 16.0 | 24.1% |

The master covers BTS reporting-carrier flights, not every flight. The modeling subset excludes cancellations and records without a clock-consistent delay; exclusions may affect these summaries. Flight mix, routes, and weather differ across airports and hours. Regenerate these figures and tables with `.venv/bin/python src/create_summary.py` (requires the local Parquet data).
<!-- EXPLORATORY SUMMARY END -->
