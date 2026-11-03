# Requires arrow. Partitioned Parquet directories may contain only completed months.
library(arrow)
base <- 'data/processed/history'
master <- open_dataset(file.path(base, 'flights_master'), format='parquet', partitioning='hive')
predictive <- open_dataset(file.path(base, 'flights_predictive'), format='parquet', partitioning='hive')
explanatory <- open_dataset(file.path(base, 'flights_explanatory'), format='parquet', partitioning='hive')
print(master$schema)
