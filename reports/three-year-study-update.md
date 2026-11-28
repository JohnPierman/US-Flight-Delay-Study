# STAT4P87 flight-delay explorer handoff

## Data preparation

The study joins 2023–2025 Bureau of Transportation Statistics domestic flight records with airport metadata and Iowa Environmental Mesonet weather observations. The preparation produced 36 monthly Parquet partitions with 20,420,136 eligible non-cancelled flights. The response is signed departure delay in minutes, computed as actual departure minus scheduled departure. Early departures have negative values.

The R preparation converts scheduled departures to local minute of day, adds the origin airport's previous completed day and week of scheduled traffic, and joins origin weather available by the one-hour prediction cutoff. It links a qualifying prior arrival on the same aircraft, calculates the scheduled turn, and flags whether that aircraft had landed by the cutoff. The study uses a seeded sample of 1,800 records per month per cohort. For validation, Monday-start weeks stay together and are distributed across five folds within each year and quarter. Category pooling and weather imputation are learned from the training rows in each fold.

## Model specification

The explorer uses the three **quantile regression forests** refitted on sampled flights from all three years after cross-validation. Each forest uses 64 regression trees via the R package `ranger`. For a given scenario, each tree contributes the empirical distribution of signed delays in the leaf reached by that scenario. The forecast averages those distributions across trees.

| Model | Inputs that distinguish the cohort | Minimum leaf size |
|---|---|---:|
| Departure heat | Origin temperature, origin latitude and longitude, weekly origin traffic | 50 |
| Retrospective inbound | Prior arrival delay, scheduled turn, origin and destination airport factors, daily origin traffic | 25 |
| Inbound arrived by cutoff | Prior arrival delay and scheduled turn for qualifying arrivals, both airports' coordinates, weekly origin traffic | 25 |

All three include local scheduled departure time, scheduled route distance, reporting airline, weekday, seasonal terms, and origin wind and visibility. The inbound models also include origin temperature. The primary output is probability mass over observed delay minutes. The interface derives the median, central 90% prediction interval, and probability of a delay of at least 30 minutes from that mass.

## Site construction

`analysis/export_dashboard.R` loads the saved forests and evaluates fixed flight profiles on a grid. The heat view varies origin temperature. The inbound view varies scheduled local departure time and prior arrival delay, with a selector for the two inbound cohorts. Slider settings are drawn from locally supported ranges. The cutoff view also checks that the hypothetical prior arrival could have occurred by the cutoff with the fixed scheduled turn.

The exporter applies Gaussian kernel smoothing with a 2.5-minute bandwidth to draw each density curve and writes the curves, profile metadata, and probability summaries to JSON. GitHub Pages serves the `docs/` folder as static HTML, CSS, and JavaScript. The browser selects the corresponding forest prediction when a slider moves and can pin any scenario as a reference. See the [reproduction instructions](model_readiness.md#interactive-explorer) for the export command.
