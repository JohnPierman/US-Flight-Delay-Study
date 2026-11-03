"""Audit each model partition against source labels and enforce cutoff rules."""
import json
from pathlib import Path
import polars as pl
from collect_history import DATA,REPORTS

base=DATA/'processed/history'; paths=sorted((base/'flights_model_ready').glob('year=*/month=*/part.parquet'))
if len(paths)!=36:raise SystemExit(f'Expected 36 partitions, got {len(paths)}')
summary={'partitions':len(paths),'rows':0,'train_rows':0,'test_rows':0,'negative_delays':0,'forecast_matches':0,'origin_weather_matches':0,'destination_weather_matches':0,'issues':[], 'null_counts':{}}
for path in paths:
    y=int(path.parent.parent.name.split('=')[1]);m=int(path.parent.name.split('=')[1])
    f=pl.read_parquet(path); n=f.height
    if f['flight_id'].n_unique()!=n: raise RuntimeError(f'duplicate IDs: {path}')
    forbidden={'DepTime','ArrTime','DepDelay','ArrDelay','actual_departure_utc','actual_arrival_utc','Tail_Number','Cancelled','previous_flight_id','actual_turnaround_minutes'}
    if forbidden & set(f.columns):raise RuntimeError('outcome or retrospective predictor found')
    assert f['departure_delay_minutes'].null_count()==0
    source=pl.read_parquet(DATA/'intermediate/bts_flights'/f'year={y}'/f'month={m:02d}'/'flights.parquet',columns=['flight_id','DepDelay','Cancelled'])
    check=f.select('flight_id','departure_delay_minutes').join(source,on='flight_id',how='left',validate='1:1')
    assert check.height==n and check['DepDelay'].null_count()==0
    assert check.filter((pl.col('departure_delay_minutes')!=pl.col('DepDelay'))|(pl.col('Cancelled')!=0)).height==0
    for prefix in ('predictive_origin','predictive_destination'):
        assert f.filter(pl.col(prefix+'_timestamp_utc')>pl.col('prediction_cutoff_utc')).height==0
    assert f.filter(pl.col('destination_forecast_issued_utc')>pl.col('prediction_cutoff_utc')).height==0
    assert f.filter((pl.col('destination_forecast_valid_from_utc')>pl.col('scheduled_arrival_utc'))|(pl.col('destination_forecast_valid_until_utc')<=pl.col('scheduled_arrival_utc'))).height==0
    assert f.filter(pl.col('destination_forecast_station').is_not_null() & (pl.col('destination_forecast_station')!=pl.concat_str([pl.lit('K'),pl.col('Dest')]))).height==0
    expected='test_2025' if y==2025 else 'train_2023_2024'
    assert f.filter(pl.col('temporal_split')!=expected).height==0
    assert f.filter(~pl.col('FlightDate').str.starts_with(str(y)+'-'+f'{m:02d}')).height==0
    summary['rows']+=n
    summary['train_rows']+=f.filter(pl.col('temporal_split')=='train_2023_2024').height
    summary['test_rows']+=f.filter(pl.col('temporal_split')=='test_2025').height
    summary['negative_delays']+=f.filter(pl.col('departure_delay_minutes')<0).height
    for field,col in [('forecast_matches','destination_forecast_issued_utc'),('origin_weather_matches','predictive_origin_timestamp_utc'),('destination_weather_matches','predictive_destination_timestamp_utc')]:summary[field]+=f[col].is_not_null().sum()
    for col,num in f.null_count().to_dicts()[0].items():summary['null_counts'][col]=summary['null_counts'].get(col,0)+num
    print(f'{y}-{m:02d}: {n:,} rows validated',flush=True)
summary['null_percentages']={k:round(v/summary['rows']*100,3) for k,v in summary['null_counts'].items()}
(REPORTS/'model_validation.json').write_text(json.dumps(summary,indent=2))
print(json.dumps({k:v for k,v in summary.items() if k not in ('null_counts','null_percentages')},indent=2))
