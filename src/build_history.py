"""Build partitioned history from completed monthly BTS and annual station files."""
from __future__ import annotations
import json, logging
import polars as pl
from collect_history import DATA, REPORTS, budget

SRC=DATA/'intermediate'/'bts_flights'
WEATHER=DATA/'intermediate'/'weather'
OUT=DATA/'processed'/'history'
WEATHER_FIELDS=['temperature_c','dewpoint_c','relative_humidity_pct','wind_speed_kt','wind_direction_deg','wind_gust_kt','visibility_m','altimeter_hpa','precipitation_mm','precipitation_trace','cloud_ceiling_ft','weather_codes']

def rotations(current, previous=None):
    cols=['flight_id','Tail_Number','Origin','Dest','Reporting_Airline','scheduled_departure_utc','scheduled_arrival_utc','actual_departure_utc','actual_arrival_utc','DepDelay','ArrDelay','ActualElapsedTime']
    combined=pl.concat([previous.select(cols),current.select(cols)]) if previous is not None else current.select(cols)
    valid=combined.filter(pl.col('Tail_Number').is_not_null()&pl.col('scheduled_departure_utc').is_not_null()).sort(['Tail_Number','scheduled_departure_utc','flight_id'])
    shifts=[pl.col(c).shift(1).over('Tail_Number').alias('_prev_'+c) for c in cols if c!='Tail_Number']
    valid=valid.with_columns(shifts)
    gap=(pl.col('actual_departure_utc')-pl.col('_prev_actual_arrival_utc')).dt.total_minutes()
    ok=(pl.col('_prev_Dest')==pl.col('Origin'))&(pl.col('_prev_scheduled_departure_utc')<pl.col('scheduled_departure_utc'))&(gap>=0)&(gap<=1440)
    fields={'previous_flight_id':'flight_id','previous_flight_origin':'Origin','previous_flight_destination':'Dest','previous_flight_airline':'Reporting_Airline','previous_flight_scheduled_departure_utc':'scheduled_departure_utc','previous_flight_actual_arrival_utc':'actual_arrival_utc','previous_flight_departure_delay_minutes':'DepDelay','previous_flight_arrival_delay_minutes':'ArrDelay','previous_flight_flight_duration_minutes':'ActualElapsedTime'}
    valid=valid.select('flight_id',*[pl.when(ok).then(pl.col('_prev_'+src)).otherwise(None).alias(dst) for dst,src in fields.items()],pl.when(ok).then(gap).otherwise(None).alias('actual_turnaround_minutes'),pl.when(ok).then(pl.lit('tentative')).otherwise(pl.lit('unknown')).alias('previous_connection_status'))
    return current.select('flight_id').join(valid,on='flight_id',how='left',validate='1:1').with_columns(pl.col('previous_connection_status').fill_null('unknown'))

def weather_join(frame,weather,airport,timecol,prefix):
    cols=['station','timestamp_utc']+WEATHER_FIELDS
    rename={x:prefix+'_'+x for x in cols}
    if weather is None or weather.height==0:
        schema={'station':pl.String,'timestamp_utc':pl.Datetime('us','UTC'),'precipitation_trace':pl.Boolean,'weather_codes':pl.String}
        return frame.with_columns([pl.lit(None,dtype=schema.get(x,pl.Float64)).alias(prefix+'_'+x) for x in cols])
    left=frame.select('flight_id',airport,timecol).filter(pl.col(timecol).is_not_null()).sort(timecol)
    right=weather.select(cols).sort('timestamp_utc')
    joined=left.join_asof(right,left_on=timecol,right_on='timestamp_utc',by_left=airport,by_right='station',strategy='backward',tolerance='60m',check_sortedness=False)
    # Polars drops the right by-key; an observation exists exactly when timestamp is non-null.
    joined=joined.with_columns(pl.when(pl.col('timestamp_utc').is_not_null()).then(pl.col(airport)).otherwise(None).alias('station')).select(['flight_id']+cols).rename(rename)
    return frame.join(joined,on='flight_id',how='left',validate='1:1')

def build(src, prev, weather):
    current=pl.read_parquet(src);n=current.height
    previous=pl.read_parquet(prev) if prev and prev.exists() else None
    rot=rotations(current,previous)
    frame=current.join(rot,on='flight_id',how='left',validate='1:1').with_columns((pl.col('scheduled_departure_utc')-pl.duration(minutes=60)).alias('prediction_cutoff_utc'))
    for prefix,airport,col in [('predictive_origin','Origin','prediction_cutoff_utc'),('predictive_destination','Dest','prediction_cutoff_utc'),('departure_origin','Origin','scheduled_departure_utc'),('departure_destination','Dest','scheduled_departure_utc'),('arrival_destination','Dest','scheduled_arrival_utc')]:
        frame=weather_join(frame,weather,airport,col,prefix)
        frame=frame.with_columns(((pl.col(col)-pl.col(prefix+'_timestamp_utc')).dt.total_seconds()/60).alias(prefix+'_weather_age_minutes'))
    assert frame.height==n and frame['flight_id'].n_unique()==n
    for prefix in ('predictive_origin','predictive_destination'):
        assert frame.filter(pl.col(prefix+'_timestamp_utc')>pl.col('prediction_cutoff_utc')).height==0
    return frame

def main():
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s',handlers=[logging.StreamHandler(),logging.FileHandler(REPORTS/'build_history.log')])
    paths=sorted(SRC.glob('year=*/month=*/flights.parquet'))
    reports=[]
    for src in paths:
        year=int(src.parent.parent.name.split('=')[1]);mon=int(src.parent.name.split('=')[1]); y2,m2=(year-1,12) if mon==1 else (year,mon-1)
        prev=SRC/f'year={y2}'/f'month={m2:02d}'/'flights.parquet'
        target=OUT/'flights_master'/f'year={year}'/f'month={mon:02d}'/'part.parquet'
        metric=OUT/'metrics'/f'{year}-{mon:02}.json'
        if metric.exists() and target.exists():continue
        budget(250*1024**2)
        weather_paths=[p for y in (year-1,year,year+1) for p in sorted((WEATHER/f'year={y}').glob('*.parquet'))]
        weather=pl.concat([pl.read_parquet(p) for p in weather_paths],how='vertical_relaxed') if weather_paths else None
        frame=build(src,prev,weather)
        completed=frame.filter((pl.col('Cancelled')==0)&pl.col('departure_delay_minutes').is_not_null())
        target.parent.mkdir(parents=True,exist_ok=True)
        tmp=target.with_suffix('.tmp');frame.write_parquet(tmp,compression='zstd');tmp.replace(target)
        metric.parent.mkdir(parents=True,exist_ok=True)
        r={'month':f'{year}-{mon:02}','master_rows':frame.height,'completed_rows':completed.height,'prediction_origin_weather':frame['predictive_origin_timestamp_utc'].is_not_null().sum(),'prediction_destination_weather':frame['predictive_destination_timestamp_utc'].is_not_null().sum(),'previous_tentative':frame['previous_flight_id'].is_not_null().sum()}
        metric.write_text(json.dumps(r,indent=2));reports.append(r);logging.info('%s',r)
    allmetrics=[json.loads(p.read_text()) for p in sorted((OUT/'metrics').glob('*.json'))]
    (REPORTS/'history_quality.json').write_text(json.dumps({'partitions':allmetrics,'note':'Tentative rotations; schedule snapshots and weather publication latency unverified.'},indent=2))
if __name__=='__main__':main()
