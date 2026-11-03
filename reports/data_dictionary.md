# Preliminary data dictionary

BTS fields retain their original names and units as defined in the official BTS field documentation. Derived weather fields use the prefixes predictive_origin, predictive_destination, departure_origin, departure_destination and arrival_destination. Predictive weather is at or before the cutoff; departure and arrival weather is retrospective. Temperatures are degrees C, humidity percent, wind knots, visibility metres, altimeter hPa, precipitation mm and ceiling feet. Trace precipitation is not converted to zero. UTC timestamps are timezone aware. All previous-flight fields are tentative retrospective reconstruction.

| Field | Type | Missing % (master) | Availability / construction |
|---|---|---:|---|
| Year | String | 0.00 | outcome or retrospective; excluded from prediction |
| Quarter | String | 0.00 | outcome or retrospective; excluded from prediction |
| Month | String | 0.00 | outcome or retrospective; excluded from prediction |
| DayofMonth | String | 0.00 | outcome or retrospective; excluded from prediction |
| DayOfWeek | String | 0.00 | outcome or retrospective; excluded from prediction |
| FlightDate | String | 0.00 | conditional schedule or cutoff observation |
| Reporting_Airline | String | 0.00 | conditional schedule or cutoff observation |
| DOT_ID_Reporting_Airline | String | 0.00 | outcome or retrospective; excluded from prediction |
| IATA_CODE_Reporting_Airline | String | 0.00 | outcome or retrospective; excluded from prediction |
| Tail_Number | String | 0.00 | outcome or retrospective; excluded from prediction |
| Flight_Number_Reporting_Airline | String | 0.00 | conditional schedule or cutoff observation |
| OriginAirportID | String | 0.00 | outcome or retrospective; excluded from prediction |
| OriginAirportSeqID | String | 0.00 | outcome or retrospective; excluded from prediction |
| OriginCityMarketID | String | 0.00 | outcome or retrospective; excluded from prediction |
| Origin | String | 0.00 | conditional schedule or cutoff observation |
| OriginCityName | String | 0.00 | outcome or retrospective; excluded from prediction |
| OriginState | String | 0.00 | outcome or retrospective; excluded from prediction |
| OriginStateFips | String | 0.00 | outcome or retrospective; excluded from prediction |
| OriginStateName | String | 0.00 | outcome or retrospective; excluded from prediction |
| OriginWac | String | 0.00 | outcome or retrospective; excluded from prediction |
| DestAirportID | String | 0.00 | outcome or retrospective; excluded from prediction |
| DestAirportSeqID | String | 0.00 | outcome or retrospective; excluded from prediction |
| DestCityMarketID | String | 0.00 | outcome or retrospective; excluded from prediction |
| Dest | String | 0.00 | conditional schedule or cutoff observation |
| DestCityName | String | 0.00 | outcome or retrospective; excluded from prediction |
| DestState | String | 0.00 | outcome or retrospective; excluded from prediction |
| DestStateFips | String | 0.00 | outcome or retrospective; excluded from prediction |
| DestStateName | String | 0.00 | outcome or retrospective; excluded from prediction |
| DestWac | String | 0.00 | outcome or retrospective; excluded from prediction |
| CRSDepTime | String | 0.00 | conditional schedule or cutoff observation |
| DepTime | String | 0.00 | outcome or retrospective; excluded from prediction |
| DepDelay | String | 3.71 | outcome or retrospective; excluded from prediction |
| DepDelayMinutes | String | 3.71 | outcome or retrospective; excluded from prediction |
| DepDel15 | String | 3.71 | outcome or retrospective; excluded from prediction |
| DepartureDelayGroups | String | 3.71 | outcome or retrospective; excluded from prediction |
| DepTimeBlk | String | 0.00 | outcome or retrospective; excluded from prediction |
| TaxiOut | String | 3.78 | outcome or retrospective; excluded from prediction |
| WheelsOff | String | 0.00 | outcome or retrospective; excluded from prediction |
| WheelsOn | String | 0.00 | outcome or retrospective; excluded from prediction |
| TaxiIn | String | 3.83 | outcome or retrospective; excluded from prediction |
| CRSArrTime | String | 0.00 | conditional schedule or cutoff observation |
| ArrTime | String | 0.00 | outcome or retrospective; excluded from prediction |
| ArrDelay | String | 3.99 | outcome or retrospective; excluded from prediction |
| ArrDelayMinutes | String | 3.99 | outcome or retrospective; excluded from prediction |
| ArrDel15 | String | 3.99 | outcome or retrospective; excluded from prediction |
| ArrivalDelayGroups | String | 3.99 | outcome or retrospective; excluded from prediction |
| ArrTimeBlk | String | 0.00 | outcome or retrospective; excluded from prediction |
| Cancelled | String | 0.00 | outcome or retrospective; excluded from prediction |
| CancellationCode | String | 0.00 | outcome or retrospective; excluded from prediction |
| CRSElapsedTime | String | 0.00 | conditional schedule or cutoff observation |
| ActualElapsedTime | String | 3.99 | outcome or retrospective; excluded from prediction |
| AirTime | String | 3.99 | outcome or retrospective; excluded from prediction |
| Flights | String | 0.00 | outcome or retrospective; excluded from prediction |
| Distance | String | 0.00 | conditional schedule or cutoff observation |
| DistanceGroup | String | 0.00 | outcome or retrospective; excluded from prediction |
| CarrierDelay | String | 72.95 | outcome or retrospective; excluded from prediction |
| WeatherDelay | String | 72.95 | outcome or retrospective; excluded from prediction |
| NASDelay | String | 72.95 | outcome or retrospective; excluded from prediction |
| SecurityDelay | String | 72.95 | outcome or retrospective; excluded from prediction |
| LateAircraftDelay | String | 72.95 | outcome or retrospective; excluded from prediction |
| FirstDepTime | String | 0.00 | outcome or retrospective; excluded from prediction |
| TotalAddGTime | String | 98.63 | outcome or retrospective; excluded from prediction |
| LongestAddGTime | String | 98.63 | outcome or retrospective; excluded from prediction |
| flight_id | String | 0.00 | conditional schedule or cutoff observation |
| scheduled_departure_utc | Datetime(time_unit='us', time_zone='UTC') | 0.00 | conditional schedule or cutoff observation |
| scheduled_arrival_utc | Datetime(time_unit='us', time_zone='UTC') | 0.00 | conditional schedule or cutoff observation |
| actual_departure_utc | Datetime(time_unit='us', time_zone='UTC') | 3.71 | outcome or retrospective; excluded from prediction |
| actual_arrival_utc | Datetime(time_unit='us', time_zone='UTC') | 4.01 | outcome or retrospective; excluded from prediction |
| timestamp_status | String | 0.00 | outcome or retrospective; excluded from prediction |
| prediction_cutoff_utc | Datetime(time_unit='us', time_zone='UTC') | 0.00 | conditional schedule or cutoff observation |
| departure_delay_minutes | Float64 | 3.71 | conditional schedule or cutoff observation |
| origin_timezone | String | 0.00 | outcome or retrospective; excluded from prediction |
| destination_timezone | String | 0.00 | outcome or retrospective; excluded from prediction |
| predictive_origin_station | String | 0.02 | conditional schedule or cutoff observation |
| predictive_origin_timestamp_utc | Datetime(time_unit='us', time_zone='UTC') | 0.02 | conditional schedule or cutoff observation |
| predictive_origin_temperature_c | Float64 | 0.03 | conditional schedule or cutoff observation |
| predictive_origin_dewpoint_c | Float64 | 0.03 | conditional schedule or cutoff observation |
| predictive_origin_relative_humidity_pct | Float64 | 0.03 | conditional schedule or cutoff observation |
| predictive_origin_wind_speed_kt | Float64 | 0.05 | conditional schedule or cutoff observation |
| predictive_origin_wind_gust_kt | Float64 | 81.50 | conditional schedule or cutoff observation |
| predictive_origin_visibility_m | Float64 | 0.02 | conditional schedule or cutoff observation |
| predictive_origin_altimeter_hpa | Float64 | 0.02 | conditional schedule or cutoff observation |
| predictive_origin_precipitation_mm | Float64 | 10.05 | conditional schedule or cutoff observation |
| predictive_origin_cloud_ceiling_ft | Float64 | 40.87 | conditional schedule or cutoff observation |
| predictive_origin_weather_codes | String | 80.36 | conditional schedule or cutoff observation |
| predictive_origin_weather_age_minutes | Float64 | 0.02 | conditional schedule or cutoff observation |
| predictive_destination_station | String | 0.02 | conditional schedule or cutoff observation |
| predictive_destination_timestamp_utc | Datetime(time_unit='us', time_zone='UTC') | 0.02 | conditional schedule or cutoff observation |
| predictive_destination_temperature_c | Float64 | 0.03 | conditional schedule or cutoff observation |
| predictive_destination_dewpoint_c | Float64 | 0.03 | conditional schedule or cutoff observation |
| predictive_destination_relative_humidity_pct | Float64 | 0.03 | conditional schedule or cutoff observation |
| predictive_destination_wind_speed_kt | Float64 | 0.03 | conditional schedule or cutoff observation |
| predictive_destination_wind_gust_kt | Float64 | 81.53 | conditional schedule or cutoff observation |
| predictive_destination_visibility_m | Float64 | 0.02 | conditional schedule or cutoff observation |
| predictive_destination_altimeter_hpa | Float64 | 0.02 | conditional schedule or cutoff observation |
| predictive_destination_precipitation_mm | Float64 | 10.11 | conditional schedule or cutoff observation |
| predictive_destination_cloud_ceiling_ft | Float64 | 41.23 | conditional schedule or cutoff observation |
| predictive_destination_weather_codes | String | 80.06 | conditional schedule or cutoff observation |
| predictive_destination_weather_age_minutes | Float64 | 0.02 | conditional schedule or cutoff observation |
| departure_origin_station | String | 0.03 | outcome or retrospective; excluded from prediction |
| departure_origin_timestamp_utc | Datetime(time_unit='us', time_zone='UTC') | 0.03 | outcome or retrospective; excluded from prediction |
| departure_origin_temperature_c | Float64 | 0.08 | outcome or retrospective; excluded from prediction |
| departure_origin_dewpoint_c | Float64 | 0.08 | outcome or retrospective; excluded from prediction |
| departure_origin_relative_humidity_pct | Float64 | 0.08 | outcome or retrospective; excluded from prediction |
| departure_origin_wind_speed_kt | Float64 | 0.05 | outcome or retrospective; excluded from prediction |
| departure_origin_wind_gust_kt | Float64 | 81.47 | outcome or retrospective; excluded from prediction |
| departure_origin_visibility_m | Float64 | 0.03 | outcome or retrospective; excluded from prediction |
| departure_origin_altimeter_hpa | Float64 | 0.03 | outcome or retrospective; excluded from prediction |
| departure_origin_precipitation_mm | Float64 | 9.54 | outcome or retrospective; excluded from prediction |
| departure_origin_cloud_ceiling_ft | Float64 | 40.84 | outcome or retrospective; excluded from prediction |
| departure_origin_weather_codes | String | 80.68 | outcome or retrospective; excluded from prediction |
| departure_origin_weather_age_minutes | Float64 | 0.03 | outcome or retrospective; excluded from prediction |
| departure_destination_station | String | 0.00 | outcome or retrospective; excluded from prediction |
| departure_destination_timestamp_utc | Datetime(time_unit='us', time_zone='UTC') | 0.00 | outcome or retrospective; excluded from prediction |
| departure_destination_temperature_c | Float64 | 0.03 | outcome or retrospective; excluded from prediction |
| departure_destination_dewpoint_c | Float64 | 0.03 | outcome or retrospective; excluded from prediction |
| departure_destination_relative_humidity_pct | Float64 | 0.03 | outcome or retrospective; excluded from prediction |
| departure_destination_wind_speed_kt | Float64 | 0.02 | outcome or retrospective; excluded from prediction |
| departure_destination_wind_gust_kt | Float64 | 81.21 | outcome or retrospective; excluded from prediction |
| departure_destination_visibility_m | Float64 | 0.00 | outcome or retrospective; excluded from prediction |
| departure_destination_altimeter_hpa | Float64 | 0.00 | outcome or retrospective; excluded from prediction |
| departure_destination_precipitation_mm | Float64 | 9.69 | outcome or retrospective; excluded from prediction |
| departure_destination_cloud_ceiling_ft | Float64 | 41.40 | outcome or retrospective; excluded from prediction |
| departure_destination_weather_codes | String | 81.00 | outcome or retrospective; excluded from prediction |
| departure_destination_weather_age_minutes | Float64 | 0.00 | outcome or retrospective; excluded from prediction |
| arrival_destination_station | String | 0.00 | outcome or retrospective; excluded from prediction |
| arrival_destination_timestamp_utc | Datetime(time_unit='us', time_zone='UTC') | 0.00 | outcome or retrospective; excluded from prediction |
| arrival_destination_temperature_c | Float64 | 0.08 | outcome or retrospective; excluded from prediction |
| arrival_destination_dewpoint_c | Float64 | 0.08 | outcome or retrospective; excluded from prediction |
| arrival_destination_relative_humidity_pct | Float64 | 0.08 | outcome or retrospective; excluded from prediction |
| arrival_destination_wind_speed_kt | Float64 | 0.03 | outcome or retrospective; excluded from prediction |
| arrival_destination_wind_gust_kt | Float64 | 81.37 | outcome or retrospective; excluded from prediction |
| arrival_destination_visibility_m | Float64 | 0.00 | outcome or retrospective; excluded from prediction |
| arrival_destination_altimeter_hpa | Float64 | 0.00 | outcome or retrospective; excluded from prediction |
| arrival_destination_precipitation_mm | Float64 | 9.54 | outcome or retrospective; excluded from prediction |
| arrival_destination_cloud_ceiling_ft | Float64 | 40.11 | outcome or retrospective; excluded from prediction |
| arrival_destination_weather_codes | String | 81.43 | outcome or retrospective; excluded from prediction |
| arrival_destination_weather_age_minutes | Float64 | 0.00 | outcome or retrospective; excluded from prediction |
| previous_flight_id | String | 62.58 | outcome or retrospective; excluded from prediction |
| previous_flight_arrival_delay_minutes | Float64 | 62.58 | outcome or retrospective; excluded from prediction |
| actual_turnaround_minutes | Float64 | 62.58 | outcome or retrospective; excluded from prediction |
| previous_connection_status | String | 0.00 | outcome or retrospective; excluded from prediction |
