# Preliminary smoke quality report

```json
{
  "scope": "bounded January 2024 smoke, both endpoints in five selected airports",
  "master_rows": 6585,
  "completed_rows": 6333,
  "predictive_rows": 6333,
  "explanatory_rows": 6333,
  "weather_rows": 5351,
  "origin_cutoff_weather_pct": 99.98,
  "destination_cutoff_weather_pct": 99.98,
  "tentative_previous_pct": 37.42,
  "timestamp_status": [
    {
      "timestamp_status": "ok",
      "len": 6585
    }
  ],
  "duplicate_looking_groups": 0,
  "negative_delay_rows": 3124,
  "maximum_departure_delay_minutes": 2809.0,
  "airlines": [
    "AA",
    "DL",
    "F9",
    "MQ",
    "NK",
    "OO",
    "UA",
    "WN",
    "YX"
  ],
  "airports": [
    "ATL",
    "DEN",
    "DFW",
    "DSM",
    "ORD"
  ],
  "delay_validated_actual_timestamps_pct": 100.0
}
```

This is a filtered pilot, not full coverage. Previous connections are tentative. All joins retain the source row count.

## Missingness in master

feature,nulls,missing_pct
TotalAddGTime,6495,98.63325740318908
LongestAddGTime,6495,98.63325740318908
predictive_destination_wind_gust_kt,5369,81.53378891419894
predictive_origin_wind_gust_kt,5367,81.50341685649204
departure_origin_wind_gust_kt,5365,81.47304479878512
arrival_destination_weather_codes,5362,81.42748671222476
arrival_destination_wind_gust_kt,5358,81.36674259681094
departure_destination_wind_gust_kt,5348,81.21488230827639
departure_destination_weather_codes,5334,81.00227790432803
departure_origin_weather_codes,5313,80.68337129840548
predictive_origin_weather_codes,5292,80.36446469248293
predictive_destination_weather_codes,5272,80.06074411541383
CarrierDelay,4804,72.95368261199697
WeatherDelay,4804,72.95368261199697
NASDelay,4804,72.95368261199697
SecurityDelay,4804,72.95368261199697
LateAircraftDelay,4804,72.95368261199697
previous_flight_id,4121,62.581624905087324
previous_flight_arrival_delay_minutes,4121,62.581624905087324
actual_turnaround_minutes,4121,62.581624905087324
departure_destination_cloud_ceiling_ft,2726,41.39711465451784
predictive_destination_cloud_ceiling_ft,2715,41.23006833712984
predictive_origin_cloud_ceiling_ft,2691,40.865603644646924
departure_origin_cloud_ceiling_ft,2689,40.83523158694002
arrival_destination_cloud_ceiling_ft,2641,40.10630220197419
predictive_destination_precipitation_mm,666,10.11389521640091
predictive_origin_precipitation_mm,662,10.053151100987092
departure_destination_precipitation_mm,638,9.688686408504177
departure_origin_precipitation_mm,628,9.536826119969628
arrival_destination_precipitation_mm,628,9.536826119969628
actual_arrival_utc,264,4.009111617312073
ArrDelay,263,3.9939255884586182
ArrDelayMinutes,263,3.9939255884586182
ArrDel15,263,3.9939255884586182
ArrivalDelayGroups,263,3.9939255884586182
ActualElapsedTime,263,3.9939255884586182
AirTime,263,3.9939255884586182
TaxiIn,252,3.826879271070615
TaxiOut,249,3.781321184510251
DepDelay,244,3.7053910402429766
DepDelayMinutes,244,3.7053910402429766
DepDel15,244,3.7053910402429766
DepartureDelayGroups,244,3.7053910402429766
actual_departure_utc,244,3.7053910402429766
departure_delay_minutes,244,3.7053910402429766
departure_origin_temperature_c,5,0.07593014426727411
departure_origin_dewpoint_c,5,0.07593014426727411
departure_origin_relative_humidity_pct,5,0.07593014426727411
arrival_destination_temperature_c,5,0.07593014426727411
arrival_destination_dewpoint_c,5,0.07593014426727411
arrival_destination_relative_humidity_pct,5,0.07593014426727411
predictive_origin_wind_speed_kt,3,0.04555808656036447
departure_origin_wind_speed_kt,3,0.04555808656036447
predictive_origin_temperature_c,2,0.030372057706909643
predictive_origin_dewpoint_c,2,0.030372057706909643
predictive_origin_relative_humidity_pct,2,0.030372057706909643
predictive_destination_temperature_c,2,0.030372057706909643
predictive_destination_dewpoint_c,2,0.030372057706909643
predictive_destination_relative_humidity_pct,2,0.030372057706909643
predictive_destination_wind_speed_kt,2,0.030372057706909643
departure_origin_station,2,0.030372057706909643
departure_origin_timestamp_utc,2,0.030372057706909643
departure_origin_visibility_m,2,0.030372057706909643
departure_origin_altimeter_hpa,2,0.030372057706909643
departure_origin_weather_age_minutes,2,0.030372057706909643
departure_destination_temperature_c,2,0.030372057706909643
departure_destination_dewpoint_c,2,0.030372057706909643
departure_destination_relative_humidity_pct,2,0.030372057706909643
arrival_destination_wind_speed_kt,2,0.030372057706909643
predictive_origin_station,1,0.015186028853454821
predictive_origin_timestamp_utc,1,0.015186028853454821
predictive_origin_visibility_m,1,0.015186028853454821
predictive_origin_altimeter_hpa,1,0.015186028853454821
predictive_origin_weather_age_minutes,1,0.015186028853454821
predictive_destination_station,1,0.015186028853454821
predictive_destination_timestamp_utc,1,0.015186028853454821
predictive_destination_visibility_m,1,0.015186028853454821
predictive_destination_altimeter_hpa,1,0.015186028853454821
predictive_destination_weather_age_minutes,1,0.015186028853454821
departure_destination_wind_speed_kt,1,0.015186028853454821
Year,0,0.0
Quarter,0,0.0
Month,0,0.0
DayofMonth,0,0.0
DayOfWeek,0,0.0
FlightDate,0,0.0
Reporting_Airline,0,0.0
DOT_ID_Reporting_Airline,0,0.0
IATA_CODE_Reporting_Airline,0,0.0
Tail_Number,0,0.0
Flight_Number_Reporting_Airline,0,0.0
OriginAirportID,0,0.0
OriginAirportSeqID,0,0.0
OriginCityMarketID,0,0.0
Origin,0,0.0
OriginCityName,0,0.0
OriginState,0,0.0
OriginStateFips,0,0.0
OriginStateName,0,0.0
OriginWac,0,0.0
DestAirportID,0,0.0
DestAirportSeqID,0,0.0
DestCityMarketID,0,0.0
Dest,0,0.0
DestCityName,0,0.0
DestState,0,0.0
DestStateFips,0,0.0
DestStateName,0,0.0
DestWac,0,0.0
CRSDepTime,0,0.0
DepTime,0,0.0
DepTimeBlk,0,0.0
WheelsOff,0,0.0
WheelsOn,0,0.0
CRSArrTime,0,0.0
ArrTime,0,0.0
ArrTimeBlk,0,0.0
Cancelled,0,0.0
CancellationCode,0,0.0
CRSElapsedTime,0,0.0
Flights,0,0.0
Distance,0,0.0
DistanceGroup,0,0.0
FirstDepTime,0,0.0
flight_id,0,0.0
scheduled_departure_utc,0,0.0
scheduled_arrival_utc,0,0.0
timestamp_status,0,0.0
prediction_cutoff_utc,0,0.0
origin_timezone,0,0.0
destination_timezone,0,0.0
departure_destination_station,0,0.0
departure_destination_timestamp_utc,0,0.0
departure_destination_visibility_m,0,0.0
departure_destination_altimeter_hpa,0,0.0
departure_destination_weather_age_minutes,0,0.0
arrival_destination_station,0,0.0
arrival_destination_timestamp_utc,0,0.0
arrival_destination_visibility_m,0,0.0
arrival_destination_altimeter_hpa,0,0.0
arrival_destination_weather_age_minutes,0,0.0
previous_connection_status,0,0.0
