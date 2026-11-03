# Modeling dataset field guide

The final dataset is `data/processed/history/flights_model_ready/`. All UTC columns are timezone-aware. Null means unavailable or excluded by timing/quality rules, not zero. Field-level missingness for the reference run appears in `reports/model_validation.json`.

| Field | Meaning and units |
|---|---|
| `flight_id` | Source month and source row index; stable for an unchanged BTS monthly file. |
| `FlightDate` | BTS local scheduled departure date, YYYY-MM-DD. |
| `Reporting_Airline`, `Flight_Number_Reporting_Airline` | BTS reporting-carrier code and flight number. |
| `Origin`, `Dest` | BTS origin and destination airport codes. |
| `CRSDepTime`, `CRSArrTime` | Scheduled local departure and arrival clock times, HHMM; `2400` means midnight. |
| `CRSElapsedTime` | Scheduled elapsed time in minutes. |
| `Distance` | Scheduled route distance in miles. |
| `scheduled_departure_utc`, `scheduled_arrival_utc` | Reconstructed scheduled UTC timestamps. |
| `prediction_cutoff_utc` | Scheduled departure minus 60 minutes. |
| `departure_delay_minutes` | **Outcome**, original BTS DepDelay in minutes; positive is late, negative is early. Never use as an input predictor. |
| `label_quality` | `clock_consistent` for retained rows; local actual departure clock agrees with the delay-derived time. This is not independent measurement verification. |
| `temporal_split` | `train_2023_2024` or `test_2025`; not a weather or operational predictor. |

## Observed weather at the prediction cutoff

Fields with prefixes `predictive_origin_` and `predictive_destination_` use the same suffixes below. Each is the latest observation at the relevant airport at or before the cutoff, at most 60 minutes old. Weather comes from IEM ASOS/AWOS/METAR; only selected stations are collected. Historical publication latency is unverified.

| Suffix | Meaning and units |
|---|---|
| `station`, `timestamp_utc` | IEM station identifier and observation time. |
| `temperature_c`, `dewpoint_c` | Air temperature and dew point in degrees Celsius. |
| `relative_humidity_pct` | Relative humidity, percent. |
| `wind_speed_kt`, `wind_gust_kt`, `wind_direction_deg` | Wind speed and gust in knots; direction in degrees. |
| `visibility_m` | Visibility in metres. |
| `altimeter_hpa` | Altimeter setting in hectopascals. |
| `precipitation_mm`, `precipitation_trace` | Reported hourly precipitation in millimetres; trace flag is separate and trace is not converted to zero. |
| `cloud_ceiling_ft` | Lowest broken, overcast or vertical-visibility layer, in feet. |
| `weather_codes` | IEM present-weather codes. |
| `weather_age_minutes` | Cutoff minus observation time, in minutes. |

## Forecast at scheduled arrival

Fields with prefix `destination_forecast_` come from IEM's archived TAFs issued no later than the cutoff. Only prevailing explicit FM intervals bounded by a subsequent forecast change are retained. TEMPO and probability groups are not included; no match means missing, not clear conditions.

| Suffix | Meaning and units |
|---|---|
| `station` | Four-character ICAO forecast station. |
| `issued_utc` | Forecast issue time. |
| `valid_from_utc`, `valid_until_utc` | Selected forecast interval: start inclusive, end exclusive. |
| `product_id`, `raw_segment` | IEM product identifier and selected raw TAF segment. |
| `sknt`, `gust`, `drct` | Forecast wind speed and gust in knots and direction in degrees. |
| `visibility` | Forecast visibility in miles; IEM encodes greater than six miles as 6.01. |
| `presentwx`, `skyc`, `skyl` | Parsed present-weather, sky-coverage and sky-layer values as text; sky levels are feet. |

Partition columns `year` and `month` may also appear when an Arrow reader opens the dataset as a Hive-partitioned directory. Schedule fields come from final BTS data; the historical availability of each schedule at cutoff is assumed, not established.
