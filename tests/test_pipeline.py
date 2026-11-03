from datetime import datetime, timezone, timedelta

UTC=timezone.utc

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

def test_production_timestamps_reject_dst_gap_and_handle_midnight():
    import polars as pl
    from collect_history import compute
    rows=[{'FlightDate':'2024-01-01','Origin':'AAA','Dest':'AAA','CRSDepTime':'2330','CRSArrTime':'0130','CRSElapsedTime':120.,'DepTime':'0030','DepDelay':60.,'ArrTime':'0230','ArrDelay':60.,'ActualElapsedTime':120.},
          {'FlightDate':'2024-03-10','Origin':'AAA','Dest':'AAA','CRSDepTime':'0230','CRSArrTime':'0330','CRSElapsedTime':60.,'DepTime':'0230','DepDelay':0.,'ArrTime':'0330','ArrDelay':0.,'ActualElapsedTime':60.}]
    airports=pl.DataFrame({'code':['AAA'],'timezone':['America/New_York']})
    result=compute(pl.DataFrame(rows),airports)
    good=result.filter(pl.col('FlightDate')=='2024-01-01').row(0,named=True)
    assert good['actual_departure_utc']-good['scheduled_departure_utc']==timedelta(minutes=60)
    assert good['actual_arrival_utc']-good['actual_departure_utc']==timedelta(minutes=120)
    assert result.filter(pl.col('FlightDate')=='2024-03-10')['scheduled_departure_utc'].item() is None


def test_main_stops_and_records_failed_stage(tmp_path,monkeypatch):
    import json
    import sys
    import main as entry
    from types import SimpleNamespace
    called=[]
    def fake_run(command,**kwargs):
        called.append(command[-1])
        return SimpleNamespace(returncode=7 if command[-1].endswith('collect_weather_history.py') else 0)
    monkeypatch.setattr(entry.subprocess,'run',fake_run)
    monkeypatch.setattr(sys,'argv',['main.py','--smoke','--workspace',str(tmp_path)])
    assert entry.main()==7
    assert len(called)==2
    status=json.loads((tmp_path/'reports/pipeline_status.json').read_text())
    assert status['state']=='failed' and status['exit_code']==7 and status['smoke']
