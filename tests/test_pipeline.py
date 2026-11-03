from datetime import datetime, timezone, timedelta
from pipeline import local_candidates, timestamps, weather_at

UTC=timezone.utc

def row(**kwargs):
    base={'FlightDate':'2024-01-01','CRSDepTime':'2330','CRSArrTime':'0130','CRSElapsedTime':'120','DepTime':'0030','DepDelay':'60','ArrTime':'0230','ArrDelay':'60','ActualElapsedTime':'120'}
    return base | kwargs

def test_midnight_and_delay():
    sd,sa,ad,aa,status=timestamps(row(),'America/Chicago','America/Chicago')
    assert (sa-sd).total_seconds()==7200
    assert (ad-sd).total_seconds()==3600 and (aa-sa).total_seconds()==3600
    assert status=='ok'

def test_nonexistent_and_ambiguous_dst():
    assert local_candidates('2024-03-10','0230','America/New_York') == []
    assert len(local_candidates('2024-11-03','0130','America/New_York')) == 2

def test_ambiguous_time_not_invented():
    data=row(FlightDate='2024-11-03',CRSDepTime='0130',CRSArrTime='0330',CRSElapsedTime='120')
    # Both folds are considered; only the second is consistent with two elapsed hours.
    assert timestamps(data,'America/New_York','America/New_York')[0] == datetime(2024,11,3,6,30,tzinfo=UTC)

def test_delay_longer_than_day():
    sd,sa,ad,aa,_=timestamps(row(DepTime='0030',DepDelay='1500',ArrTime='0230',ArrDelay='1500'),'America/Chicago','America/Chicago')
    assert (ad-sd)==timedelta(minutes=1500)

def test_bad_actual_clock_is_missing():
    assert timestamps(row(DepTime='0040'),'America/Chicago','America/Chicago')[2] is None

def test_weather_never_looks_ahead():
    t=datetime(2024,1,1,tzinfo=UTC)
    records=[{'timestamp_utc':t},{'timestamp_utc':t+timedelta(minutes=30)}]
    assert weather_at(records,[x['timestamp_utc'] for x in records],t+timedelta(minutes=20),60)==records[0]
    assert weather_at(records,[x['timestamp_utc'] for x in records],t-timedelta(minutes=1),60) is None

def test_pilot_outputs_if_present():
    from pathlib import Path
    import polars as pl
    path=Path(__file__).resolve().parents[1]/'data/processed'
    if not (path/'flights_master.parquet').exists():
        import pytest
        pytest.skip('run the real-data smoke first')
    master=pl.read_parquet(path/'flights_master.parquet')
    pred=pl.read_parquet(path/'flights_predictive.parquet')
    expl=pl.read_parquet(path/'flights_explanatory.parquet')
    assert master['flight_id'].n_unique()==master.height
    assert pred['flight_id'].n_unique()==pred.height
    assert set(pred['flight_id'])==set(expl['flight_id'])
    assert pred.select(['flight_id','departure_delay_minutes']).sort('flight_id').equals(expl.select(['flight_id','departure_delay_minutes']).sort('flight_id'))
    assert not {'DepTime','ArrTime','DepDelay','ArrDelay','Tail_Number','actual_turnaround_minutes','previous_flight_id'} & set(pred.columns)
    for prefix in ('predictive_origin','predictive_destination'):
        assert pred.filter(pl.col(prefix+'_timestamp_utc')>pl.col('prediction_cutoff_utc')).height==0

def test_history_weather_join_never_multiplies_or_looks_ahead():
    import polars as pl
    from build_history import weather_join
    t=datetime(2024,1,1,tzinfo=UTC)
    f=pl.DataFrame({'flight_id':['a','b'],'Origin':['ORD','ORD'],'cutoff':[t,t+timedelta(minutes=30)]})
    w=pl.DataFrame({'station':['ORD','ORD'],'timestamp_utc':[t,t+timedelta(minutes=15)],'temperature_c':[1.,2.], 'dewpoint_c':[0.,1.], 'relative_humidity_pct':[50.,50.], 'wind_speed_kt':[3.,4.], 'wind_direction_deg':[90.,90.], 'wind_gust_kt':[None,None], 'visibility_m':[1000.,1000.], 'altimeter_hpa':[1000.,1000.], 'precipitation_mm':[None,None], 'precipitation_trace':[False,False], 'cloud_ceiling_ft':[None,None], 'weather_codes':[None,None]})
    out=weather_join(f,w,'Origin','cutoff','wx').sort('flight_id')
    assert out.height == 2
    assert out['wx_temperature_c'].to_list()==[1.,2.]
    assert out.filter(pl.col('wx_timestamp_utc') > pl.col('cutoff')).height == 0

def test_history_rotation_checks_continuity_and_crosses_month():
    import polars as pl
    from build_history import rotations
    t=datetime(2024,1,31,22,tzinfo=UTC)
    def flight(fid,origin,dest,dep,arr):
        return {'flight_id':fid,'Tail_Number':'N1','Origin':origin,'Dest':dest,'Reporting_Airline':'AA','scheduled_departure_utc':dep,'scheduled_arrival_utc':arr,'actual_departure_utc':dep,'actual_arrival_utc':arr,'DepDelay':0.,'ArrDelay':0.,'ActualElapsedTime':60.}
    prev=pl.DataFrame([flight('previous','ORD','ATL',t,t+timedelta(hours=1))])
    curr=pl.DataFrame([flight('current','ATL','DEN',t+timedelta(hours=2),t+timedelta(hours=3))])
    assert rotations(curr,prev)['previous_flight_id'].to_list()==['previous']
    broken=curr.with_columns(pl.lit('DFW').alias('Origin'))
    assert rotations(broken,prev)['previous_flight_id'].to_list()==[None]

def test_taf_latest_issue_and_forecast_interval():
    import polars as pl
    from supplement_forecasts import enrich
    t=datetime(2024,1,1,tzinfo=UTC)
    rows=[]
    for issue,product,starts in [(t,'old',[t+timedelta(hours=1),t+timedelta(hours=8)]),(t+timedelta(hours=2),'new',[t+timedelta(hours=3),t+timedelta(hours=6)])]:
        for start in starts:
            rows.append({'station':'KORD','valid':issue,'product_id':product,'fx_valid':start,'ftype':'Forecast','raw':'FM test','sknt':'5','drct':'270','gust':None,'visibility':'6','presentwx':None,'skyc':None,'skyl':None})
    flights=pl.DataFrame({'flight_id':['a','b','c'],'Dest':['ORD']*3,'prediction_cutoff_utc':[t+timedelta(hours=1),t+timedelta(hours=3),t+timedelta(hours=3)],'scheduled_arrival_utc':[t+timedelta(hours=4),t+timedelta(hours=4),t+timedelta(hours=7)]})
    out=enrich(flights,pl.DataFrame(rows)).sort('flight_id')
    assert out.height==3
    assert out['destination_forecast_product_id'].to_list()==['old','new',None]
    assert out.filter(pl.col('destination_forecast_issued_utc')>pl.col('prediction_cutoff_utc')).height==0

def test_real_forecast_pilot_if_available():
    from pathlib import Path
    import polars as pl
    path=Path(__file__).resolve().parents[1]/'reports/model_pilot_sample.csv'
    if not path.exists():
        import pytest
        pytest.skip('forecast pilot has not run')
    p=pl.read_csv(path,try_parse_dates=True)
    assert p.height>0 and p['flight_id'].n_unique()==p.height
    assert p.filter(pl.col('destination_forecast_issued_utc')>pl.col('prediction_cutoff_utc')).height==0
    assert p.filter(pl.col('destination_forecast_valid_from_utc')>pl.col('scheduled_arrival_utc')).height==0
    assert p.filter(pl.col('destination_forecast_valid_until_utc')<=pl.col('scheduled_arrival_utc')).height==0
    assert not {'DepTime','ArrTime','DepDelay','ArrDelay','Tail_Number','actual_turnaround_minutes','previous_flight_id'} & set(p.columns)

def test_ambiguous_newer_taf_does_not_fall_back_to_old_forecast():
    import polars as pl
    from supplement_forecasts import enrich
    t=datetime(2024,1,1,tzinfo=UTC)
    rows=[]
    for issue,product in [(t,'old'),(t+timedelta(hours=2),'new-a'),(t+timedelta(hours=2),'new-b')]:
        for h in (3,8):
            rows.append({'station':'KORD','valid':issue,'product_id':product,'fx_valid':t+timedelta(hours=h),'ftype':'Forecast','raw':'FM test','sknt':'5','drct':'270','gust':None,'visibility':'6','presentwx':None,'skyc':None,'skyl':None})
    flights=pl.DataFrame({'flight_id':['a'],'Dest':['ORD'],'prediction_cutoff_utc':[t+timedelta(hours=3)],'scheduled_arrival_utc':[t+timedelta(hours=4)]})
    assert enrich(flights,pl.DataFrame(rows))['destination_forecast_product_id'].to_list()==[None]
