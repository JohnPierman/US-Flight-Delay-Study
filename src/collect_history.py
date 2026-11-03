"""Resumable, budget-aware BTS ingestion for 2023–2025. No model data are fabricated."""
from __future__ import annotations
import calendar, csv, hashlib, json, logging, os, shutil, time, zipfile
from datetime import datetime, timezone
from pathlib import Path
import polars as pl
from timezonefinder import TimezoneFinder
from pipeline import ROOT, RAW, BTS, download, metadata

START_YEAR=2023
END_YEAR=2025
DATA=ROOT/'data'
ZIPDIR=RAW/'bts_monthly'
PARTS=DATA/'intermediate'/'bts_flights'
REPORTS=ROOT/'reports'
LIMIT=10*1024**3
MIN_FREE=2*1024**3
FIELDS=['Year','Month','DayofMonth','DayOfWeek','FlightDate','Reporting_Airline','DOT_ID_Reporting_Airline','IATA_CODE_Reporting_Airline','Tail_Number','Flight_Number_Reporting_Airline','OriginAirportID','Origin','OriginCityName','OriginState','DestAirportID','Dest','DestCityName','DestState','CRSDepTime','DepTime','DepDelay','CRSArrTime','ArrTime','ArrDelay','CRSElapsedTime','ActualElapsedTime','AirTime','Distance','TaxiOut','TaxiIn','WheelsOff','WheelsOn','Cancelled','CancellationCode','Diverted','CarrierDelay','WeatherDelay','NASDelay','SecurityDelay','LateAircraftDelay']
NUMERIC=['DepDelay','ArrDelay','CRSElapsedTime','ActualElapsedTime','AirTime','Distance','TaxiOut','TaxiIn','Cancelled','Diverted','CarrierDelay','WeatherDelay','NASDelay','SecurityDelay','LateAircraftDelay']

def dir_size(path):
    return sum(p.stat().st_size for p in path.rglob('*') if p.is_file())

def budget(extra=0):
    used=dir_size(DATA); free=shutil.disk_usage(DATA).free
    if used+extra>LIMIT or free-extra<MIN_FREE:
        raise RuntimeError(f'storage stop: data={used}, projected extra={extra}, cap={LIMIT}, free={free}, reserve={MIN_FREE}')

def airport_zones():
    # Use only unique US IATA/ICAO pairs; ambiguity remains unmapped rather than guessed.
    path=RAW/'airports.csv'; download('https://davidmegginson.github.io/ourairports-data/airports.csv',path)
    groups={}
    with path.open(newline='',encoding='utf8') as f:
        for r in csv.DictReader(f):
            if r['iso_country'] != 'US' or not r['iata_code'] or r['type']=='closed': continue
            groups.setdefault(r['iata_code'],[]).append(r)
    tf=TimezoneFinder(); rows=[]
    for code, matches in groups.items():
        # Prefer an exact ICAO-to-IATA match; multiple remaining candidates are uncertain.
        exact=[r for r in matches if r['ident'] in ('K'+code, 'P'+code)]
        candidates=exact if exact else matches
        if len(candidates)!=1: continue
        r=candidates[0]
        try:
            lat,lon=float(r['latitude_deg']),float(r['longitude_deg'])
            zone=tf.timezone_at(lat=lat,lng=lon)
        except (ValueError,TypeError): continue
        if zone: rows.append({'code':code,'icao':r['ident'],'airport_name':r['name'],'latitude':lat,'longitude':lon,'timezone':zone})
    p=DATA/'intermediate'/'airport_metadata.parquet';p.parent.mkdir(parents=True,exist_ok=True)
    frame=pl.DataFrame(rows);frame.write_parquet(p,compression='zstd');return frame

def clock_matches(utc_col, clock, zone):
    local=pl.col(utc_col).dt.convert_time_zone(zone)
    hh=pl.col(clock).cast(pl.Int32,strict=False)//100
    mm=pl.col(clock).cast(pl.Int32,strict=False)%100
    return (hh<=24)&(mm<60)&((hh!=24)|(mm==0))&(local.dt.hour()==hh%24)&(local.dt.minute()==mm)

def compute(f, airports):
    # UTC scheduled departure, separately by origin timezone; DST folds and gaps are null.
    zones=airports.select(pl.col('code').alias('Origin'),pl.col('timezone').alias('origin_timezone'))
    zones2=airports.select(pl.col('code').alias('Dest'),pl.col('timezone').alias('destination_timezone'))
    f=f.join(zones,on='Origin',how='left',validate='m:1').join(zones2,on='Dest',how='left',validate='m:1')
    output=[]
    for key, g in f.partition_by('origin_timezone',as_dict=True,maintain_order=False).items():
        zone=key[0]
        if zone is None:
            output.append(g.with_columns(pl.lit(None,dtype=pl.Datetime('us','UTC')).alias('scheduled_departure_utc')));continue
        hh=pl.col('CRSDepTime').cast(pl.Int32,strict=False)//100
        mm=pl.col('CRSDepTime').cast(pl.Int32,strict=False)%100
        valid=(hh<=24)&(mm<60)&((hh!=24)|(mm==0))
        naive=pl.col('FlightDate').str.to_date(strict=False).cast(pl.Datetime('us'))+pl.duration(hours=hh,minutes=mm)
        dep=naive.dt.replace_time_zone(zone,ambiguous='null',non_existent='null').dt.convert_time_zone('UTC')
        output.append(g.with_columns(pl.when(valid).then(dep).otherwise(None).alias('scheduled_departure_utc')))
    f=pl.concat(output,how='vertical')
    f=f.with_columns((pl.col('scheduled_departure_utc')+pl.duration(minutes=pl.col('CRSElapsedTime'))).alias('_sa'),(pl.col('scheduled_departure_utc')+pl.duration(minutes=pl.col('DepDelay'))).alias('_ad'))
    output=[]
    for key,g in f.partition_by('destination_timezone',as_dict=True,maintain_order=False).items():
        zone=key[0]
        if zone is None:
            output.append(g.with_columns(pl.lit(None,dtype=pl.Datetime('us','UTC')).alias('scheduled_arrival_utc')));continue
        ok=(pl.col('CRSElapsedTime')>0)&(pl.col('CRSElapsedTime')<=1440)&clock_matches('_sa','CRSArrTime',zone)
        output.append(g.with_columns(pl.when(ok).then(pl.col('_sa')).otherwise(None).alias('scheduled_arrival_utc')))
    f=pl.concat(output,how='vertical')
    output=[]
    for key,g in f.partition_by('origin_timezone',as_dict=True,maintain_order=False).items():
        zone=key[0]
        if zone is None:
            output.append(g.with_columns(pl.lit(None,dtype=pl.Datetime('us','UTC')).alias('actual_departure_utc')));continue
        output.append(g.with_columns(pl.when(clock_matches('_ad','DepTime',zone)).then(pl.col('_ad')).otherwise(None).alias('actual_departure_utc')))
    f=pl.concat(output,how='vertical').with_columns((pl.col('scheduled_arrival_utc')+pl.duration(minutes=pl.col('ArrDelay'))).alias('_aa'))
    output=[]
    for key,g in f.partition_by('destination_timezone',as_dict=True,maintain_order=False).items():
        zone=key[0]
        if zone is None:
            output.append(g.with_columns(pl.lit(None,dtype=pl.Datetime('us','UTC')).alias('actual_arrival_utc')));continue
        elapsed=(pl.col('_aa')-pl.col('actual_departure_utc')).dt.total_minutes()
        ok=clock_matches('_aa','ArrTime',zone)&((elapsed-pl.col('ActualElapsedTime')).abs()<1)
        output.append(g.with_columns(pl.when(ok).then(pl.col('_aa')).otherwise(None).alias('actual_arrival_utc')))
    return pl.concat(output,how='vertical').drop('_sa','_ad','_aa').with_columns(pl.when(pl.col('DepTime').is_not_null()).then(pl.col('DepDelay')).otherwise(None).alias('departure_delay_minutes'))

def month(year,mon,airports):
    name=f'{year}-{mon:02d}'; dest=PARTS/f'year={year}'/f'month={mon:02d}'/'flights.parquet'; meta=dest.with_suffix('.json')
    if dest.exists() and meta.exists():
        logging.info('%s already complete',name);return
    ZIPDIR.mkdir(parents=True,exist_ok=True);dest.parent.mkdir(parents=True,exist_ok=True)
    zip_path=ZIPDIR/f'bts_{year}_{mon:02d}.zip';url=BTS.format(year=year,month=mon)
    budget(550*1024**2)
    download(url,zip_path)
    with zipfile.ZipFile(zip_path) as z:
        if z.testzip(): raise RuntimeError('Corrupt zip: '+name)
        names=[n for n in z.namelist() if n.lower().endswith('.csv')]
        if len(names)!=1: raise RuntimeError('Unexpected ZIP contents: '+name)
        tmp=dest.parent/'source.csv.tmp'
        budget(z.getinfo(names[0]).file_size+200*1024**2)
        with z.open(names[0]) as src,tmp.open('wb') as out: shutil.copyfileobj(src,out)
    try:
        frame=pl.scan_csv(tmp,infer_schema=False,truncate_ragged_lines=True,row_index_name='_source_row').select(['_source_row']+FIELDS).collect()
        frame=frame.with_columns([pl.col(c).cast(pl.Float64,strict=False) for c in NUMERIC]).with_columns((pl.lit(name+'-')+pl.col('_source_row').cast(pl.String).str.pad_start(8,'0')).alias('flight_id'))
        frame=compute(frame,airports)
        if frame['flight_id'].n_unique()!=frame.height: raise RuntimeError('Nonunique flight identifiers')
        assert frame.filter(pl.col('departure_delay_minutes').is_not_null() & pl.col('DepTime').is_null()).height==0
        temp=dest.with_suffix('.parquet.tmp');frame.write_parquet(temp,compression='zstd',statistics=True);temp.replace(dest)
        digest=hashlib.file_digest(zip_path.open('rb'),'sha256').hexdigest()
        report={'year':year,'month':mon,'rows':frame.height,'source_url':url,'source_sha256':digest,'retrieved_utc':datetime.fromtimestamp(zip_path.stat().st_mtime,timezone.utc).isoformat(),'scheduled_departure_utc_nonnull':frame['scheduled_departure_utc'].is_not_null().sum(),'scheduled_arrival_utc_nonnull':frame['scheduled_arrival_utc'].is_not_null().sum(),'actual_departure_utc_nonnull':frame['actual_departure_utc'].is_not_null().sum(),'depdelay_nonnull':frame['departure_delay_minutes'].is_not_null().sum(),'negative_delays':frame.filter(pl.col('departure_delay_minutes')<0).height}
        mtmp=meta.with_suffix('.json.tmp');mtmp.write_text(json.dumps(report,indent=2));mtmp.replace(meta)
        logging.info('%s rows=%s dep_utc=%.2f%% size=%s',name,frame.height,100*report['scheduled_departure_utc_nonnull']/max(1,frame.height),dest.stat().st_size)
    finally:
        tmp.unlink(missing_ok=True)

def main():
    DATA.mkdir(exist_ok=True);REPORTS.mkdir(exist_ok=True)
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s',handlers=[logging.StreamHandler(),logging.FileHandler(REPORTS/'collection.log')])
    airports=airport_zones();logging.info('Mapped %d unambiguous US airport codes',airports.height)
    # Complete requested 2024–2025 first, then extend backward to 2023.
    for year in [2024,2025,2023]:
        for mon in range(1,13):
            try: month(year,mon,airports)
            except Exception:
                logging.exception('Failed month %s-%02d; stopping for safe restart',year,mon);raise
    logging.info('BTS collection complete')
if __name__=='__main__': main()
