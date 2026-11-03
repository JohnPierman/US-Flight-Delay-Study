library(arrow)
library(dplyr)
# This uses lazy reads; do not collect all rows unless RAM is sufficient.
flights <- open_dataset('data/processed/history/flights_model_ready', format='parquet', partitioning='hive')
print(flights$schema)
print(flights |> group_by(temporal_split) |> summarise(n=n(), mean_delay=mean(departure_delay_minutes, na.rm=TRUE)) |> collect())
