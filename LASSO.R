# LASSO Logistic Regression Attempt (failed)

require(glmnet)
library(DBI)
library(duckdb)

con = dbConnect(duckdb())

path = "flights_model_ready"
dbExecute(con, "SELECT setseed(0)")
query = sprintf("

WITH targets AS MATERIALIZED (

    SELECT
        flight_id,
        FlightDate,
        Origin,
        scheduled_departure_utc,
        prediction_cutoff_utc,
        departure_delay_minutes,
        CRSElapsedTime,
        Distance,
        CRSDepTime,
        predictive_origin_temperature_c,
        predictive_origin_wind_speed_kt,
        predictive_origin_visibility_m,
        predictive_origin_precipitation_mm

    FROM read_parquet('%s/**/*.parquet',
                      hive_partitioning = true)

    WHERE CAST(year AS INTEGER) = 2023
      AND CAST(month AS INTEGER) BETWEEN 6 AND 8
      AND random() < 0.3
),

history AS (

    SELECT
        flight_id,
        Origin,

        TRY_CAST(scheduled_departure_utc AS TIMESTAMP)
        + INTERVAL '1 minute'
          * TRY_CAST(departure_delay_minutes AS DOUBLE)
        AS actual_departure,

        TRY_CAST(departure_delay_minutes AS DOUBLE) AS delay

    FROM read_parquet('%s/**/*.parquet',
                      hive_partitioning = true)

    WHERE CAST(year AS INTEGER) = 2023
      AND CAST(month AS INTEGER) BETWEEN 5 AND 8
),

historical_averages AS (

    SELECT
        f.flight_id,

        AVG(h.delay) AS origin_previous_3hr_avg_delay,

        COUNT(h.delay) AS origin_previous_3hr_flight_count

    FROM targets f

    LEFT JOIN history h

        ON h.Origin = f.Origin

        AND h.actual_departure >=
            TRY_CAST(f.prediction_cutoff_utc AS TIMESTAMP)
            - INTERVAL '3 hours'

        AND h.actual_departure <
            TRY_CAST(f.prediction_cutoff_utc AS TIMESTAMP)

        AND h.flight_id <> f.flight_id

    GROUP BY f.flight_id
)

SELECT
    f.*,
    a.origin_previous_3hr_avg_delay,
    a.origin_previous_3hr_flight_count

FROM targets f

LEFT JOIN historical_averages a
    ON f.flight_id = a.flight_id

", path, path)

summer_sample = dbGetQuery(con, query)



summary(summer_sample$departure_delay_minutes)
summary(summer_sample$origin_previous_3hr_avg_delay)
summary(summer_sample$origin_previous_3hr_flight_count)

mean(is.na(summer_sample$origin_previous_3hr_avg_delay))
mean(is.na(summer_sample$predictive_origin_temperature_c))

# categorize delays (>= 15 mins)
summer_sample$delayed = ifelse(
  summer_sample$departure_delay_minutes >= 15,
  1, 0
)



# distribution of delays
table(summer_sample$delayed)
prop.table(table(summer_sample$delayed))


# Attempt at LASSO logistic regression 

summer_sample$departure_hour =
  floor(as.numeric(summer_sample$CRSDepTime) / 100)


predictors = c(
  "origin_previous_3hr_avg_delay",
  "origin_previous_3hr_flight_count",
  "CRSElapsedTime",
  "Distance",
  "departure_hour",
  "predictive_origin_temperature_c",
  "predictive_origin_wind_speed_kt",
  "predictive_origin_visibility_m",
  "predictive_origin_precipitation_mm"
)

summer_sample$FlightDate = as.Date(summer_sample$FlightDate)

training_data = summer_sample[
  format(summer_sample$FlightDate, "%m") %in% c("06", "07"),
]

testing_data = summer_sample[
  format(summer_sample$FlightDate, "%m") == "08",
]

# remove data where any NAs are present (predictors or class)

training_data = training_data[
  complete.cases(training_data[, c("delayed", predictors)]),
]

testing_data = testing_data[
  complete.cases(testing_data[, c("delayed", predictors)]),
]

# convert to matrices

trainingX = as.matrix(training_data[, predictors])
trainingY = training_data$delayed

testingX = as.matrix(testing_data[, predictors])
testingY = testing_data$delayed



set.seed(0)

cv_fit = cv.glmnet(
  trainingX,
  trainingY,
  family = "binomial",
  alpha = 1
)

plot(cv_fit)


coef(cv_fit, s = "lambda.min")
coef(cv_fit, s = "lambda.1se")

probabilities = predict(
  cv_fit,
  newx = testingX,
  s = "lambda.min",
  type = "response"
)

yhat = ifelse(probabilities >= 0.5, 1, 0)

# model diagnostic
mean(yhat == testingY)

table(
  Actual = testingY,
  Predicted = yhat
)

sensitivity = sum(yhat == 1 & testingY == 1) /
  sum(testingY == 1)

specificity = sum(yhat == 0 & testingY == 0) /
  sum(testingY == 0)

sensitivity
specificity
