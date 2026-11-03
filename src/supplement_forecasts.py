"""Build conservative forecast-enriched, validated-label training partitions."""
from __future__ import annotations
import argparse, gzip, hashlib, io, json, logging, os
from pathlib import Path
from datetime import datetime,timezone,timedelta
import polars as pl
import requests
from collect_history import DATA, REPORTS, budget

URL='https://mesonet.agron.iastate.edu/cgi-bin/request/taf.py'
RAW=DATA/'raw'/'taf'; PROCESSED=DATA/'intermediate'/'taf'; BASE=DATA/'processed'/'history'
OUT=BASE/'flights_model_ready'; METRICS=BASE/'model_quality'
SESSION=requests.Session()
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry
SESSION.mount('https://',HTTPAdapter(max_retries=Retry(total=4,backoff_factor=2,status_forcelist=[429,500,502,503,504])))


def fetch(station,year):
    """Cache the unchanged response body losslessly in gzip, and validate the archive schema."""
    path=RAW/f'{station}_{year}.csv.gz'; meta=path.with_suffix('.json')
    if path.exists() and meta.exists(): return path
    budget(80*1024**2)
    params={'station':station,'sts':f'{year-1}-12-30T00:00Z','ets':f'{year+1}-01-02T00:00Z','tz':'UTC','fmt':'csv'}
    resp=SESSION.get(URL,params=params,timeout=(30,240));resp.raise_for_status()
    body=resp.content
    first=body.splitlines()[0] if body else b''
    required=(b'station',b'valid',b'fx_valid',b'product_id',b'ftype')
    if not all(x in first.split(b',') for x in required): raise ValueError(f'Unexpected TAF response for {station} {year}: {body[:120]!r}')
    path.parent.mkdir(parents=True,exist_ok=True);tmp=path.with_suffix('.tmp')
    with gzip.open(tmp,'wb',compresslevel=6) as f:f.write(body)
    tmp.replace(path)
    info={'url':URL,'params':params,'sha256_uncompressed':hashlib.sha256(body).hexdigest(),'retrieved_utc':datetime.now(timezone.utc).isoformat(),'bytes':len(body)}
    meta.write_text(json.dumps(info,indent=2));return path


def prepare(path,station,year):
    out=PROCESSED/f'year={year}'/f'{station}.parquet'
    if out.exists():return out
    with gzip.open(path,'rb') as f: raw=pl.read_csv(io.BytesIO(f.read()),infer_schema=False,null_values=['','M'])
    if raw.height == 0: raise ValueError(f'No archived TAF rows for {station} {year}')
    needed=['station','valid','fx_valid','fx_valid_end','product_id','ftype','raw','sknt','drct','gust','visibility','presentwx','skyc','skyl','is_amendment']
    if not set(needed).issubset(raw.columns):raise ValueError('TAF schema missing required fields')
    raw=raw.select(needed).with_columns([pl.col(c).str.to_datetime('%Y-%m-%d %H:%M',time_zone='UTC',strict=False) for c in ('valid','fx_valid','fx_valid_end')])
    raw=raw.with_columns([pl.col(c).cast(pl.Float64,strict=False) for c in ('sknt','drct','gust','visibility')])
    if raw.filter(pl.col('station')!='K'+station).height:raise ValueError('Unexpected TAF station')
    out.parent.mkdir(parents=True,exist_ok=True);tmp=out.with_suffix('.tmp');raw.write_parquet(tmp,compression='zstd');tmp.replace(out)
    return out


def issue_segments(raw):
    # A forecast product is chosen first based solely on its issuance time. Products
    # with identical issue times and different ids are excluded as ambiguous.
    products=raw.select('station','valid','product_id').drop_nulls().unique()
    products=(products.group_by('station','valid').agg(pl.when(pl.col('product_id').n_unique()==1).then(pl.col('product_id').first()).otherwise(None).alias('product_id')).sort('valid'))
    # Use only explicit prevailing FM entries (IEM type Forecast), whose end is
    # bounded by the next explicit FM entry in the *same* product. Last FM,
    # initial prevailing period, BECMG, TEMPO, PROB and unknowns are excluded.
    seg=raw.filter(pl.col('ftype').is_in(['Forecast','Becoming','BECMG'])).sort(['product_id','fx_valid'])
    seg=seg.with_columns(pl.col('fx_valid').shift(-1).over('product_id').alias('interval_end'))
    seg=seg.filter((pl.col('ftype')=='Forecast')&pl.col('raw').str.starts_with('FM')&pl.col('fx_valid').is_not_null()&pl.col('interval_end').is_not_null()&(pl.col('interval_end')>pl.col('fx_valid')))
    seg=seg.unique(subset=['product_id','fx_valid'],keep='none').sort('fx_valid')
    return products,seg


def enrich(frame,raw):
    products,segments=issue_segments(raw)
    n=frame.height
    a=frame.filter(pl.col('prediction_cutoff_utc').is_not_null()&pl.col('scheduled_arrival_utc').is_not_null()).select('flight_id','Dest','prediction_cutoff_utc','scheduled_arrival_utc').with_columns(pl.concat_str([pl.lit('K'),pl.col('Dest')]).alias('station')).sort('prediction_cutoff_utc')
    a=a.join_asof(products,left_on='prediction_cutoff_utc',right_on='valid',by='station',strategy='backward',tolerance='24h',check_sortedness=False)
    a=a.filter(pl.col('product_id').is_not_null()).sort('scheduled_arrival_utc')
    cols=['product_id','fx_valid','interval_end','sknt','drct','gust','visibility','presentwx','skyc','skyl','raw']
    a=a.join_asof(segments.select(cols),left_on='scheduled_arrival_utc',right_on='fx_valid',by='product_id',strategy='backward',check_sortedness=False)
    a=a.filter(pl.col('fx_valid').is_not_null()&(pl.col('scheduled_arrival_utc')<pl.col('interval_end')))
    a=a.select('flight_id',pl.col('station').alias('destination_forecast_station'),pl.col('valid').alias('destination_forecast_issued_utc'),pl.col('fx_valid').alias('destination_forecast_valid_from_utc'),pl.col('interval_end').alias('destination_forecast_valid_until_utc'),pl.col('product_id').alias('destination_forecast_product_id'),pl.col('raw').alias('destination_forecast_raw_segment'),*[pl.col(c).alias('destination_forecast_'+c) for c in ('sknt','drct','gust','visibility','presentwx','skyc','skyl')])
    out=frame.join(a,on='flight_id',how='left',validate='1:1')
    assert out.height==n
    assert out.filter(pl.col('destination_forecast_issued_utc')>pl.col('prediction_cutoff_utc')).height==0
    assert out.filter((pl.col('destination_forecast_valid_from_utc')>pl.col('scheduled_arrival_utc'))|(pl.col('destination_forecast_valid_until_utc')<=pl.col('scheduled_arrival_utc'))).height==0
    return out


def build(year,month,raw,pilot=False):
    path=BASE/'flights_master'/f'year={year}'/f'month={month:02d}'/'part.parquet'
    f=pl.read_parquet(path)
    n=f.height
    # The official label is authoritative; UTC reconstruction uses that label and
    # checks the observed HHMM clock, not an independent label derivation.
    f=f.with_columns(pl.when(pl.col('departure_delay_minutes').is_null()).then(pl.lit('no_departure_delay')).when(pl.col('scheduled_departure_utc').is_null()).then(pl.lit('scheduled_timestamp_unresolved')).when(pl.col('actual_departure_utc').is_null()).then(pl.lit('actual_clock_inconsistent_or_missing')).otherwise(pl.lit('clock_consistent')).alias('label_quality'))
    counts=f.group_by('label_quality').len().to_dicts()
    valid=f.filter((pl.col('Cancelled')==0)&(pl.col('label_quality')=='clock_consistent'))
    pred_cols=['flight_id','FlightDate','Reporting_Airline','Flight_Number_Reporting_Airline','Origin','Dest','CRSDepTime','CRSArrTime','CRSElapsedTime','Distance','scheduled_departure_utc','scheduled_arrival_utc','prediction_cutoff_utc','departure_delay_minutes','label_quality']+[c for c in f.columns if c.startswith('predictive_')]
    valid=valid.select(pred_cols).with_columns(pl.when(pl.col('FlightDate')<'2025-01-01').then(pl.lit('train_2023_2024')).otherwise(pl.lit('test_2025')).alias('temporal_split'))
    out=enrich(valid,raw)
    assert out['flight_id'].n_unique()==out.height and out.height==valid.height
    result={'year':year,'month':month,'master_rows':n,'eligible_rows':out.height,'label_quality':counts,'forecast_matches':out['destination_forecast_issued_utc'].is_not_null().sum(),'early_departures':out.filter(pl.col('departure_delay_minutes')<0).height,'train_rows':out.filter(pl.col('temporal_split')=='train_2023_2024').height,'test_rows':out.filter(pl.col('temporal_split')=='test_2025').height}
    if pilot:
        out.head(1000).write_parquet(REPORTS/'model_pilot.parquet',compression='zstd')
        matched=out.filter(pl.col('destination_forecast_issued_utc').is_not_null()).head(5)
        matched.write_csv(REPORTS/'model_pilot_sample.csv')
        (REPORTS/'model_pilot_quality.json').write_text(json.dumps(result,indent=2))
    else:
        target=OUT/f'year={year}'/f'month={month:02d}'/'part.parquet';target.parent.mkdir(parents=True,exist_ok=True)
        budget(150*1024**2);tmp=target.with_suffix('.tmp');out.write_parquet(tmp,compression='zstd');tmp.replace(target)
        METRICS.mkdir(parents=True,exist_ok=True);(METRICS/f'{year}-{month:02d}.json').write_text(json.dumps(result,indent=2))
    return result


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--pilot',action='store_true');args=parser.parse_args()
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s',handlers=[logging.StreamHandler(),logging.FileHandler(REPORTS/'forecast_supplement.log')])
    if args.pilot:
        p=prepare(fetch('SLC',2024),'SLC',2024);raw=pl.read_parquet(p);logging.info('pilot %s',build(2024,1,raw,True));return
    # Weather observation station set supplies explicit, previously checked airport mappings.
    stations=sorted({p.stem for p in (DATA/'intermediate/weather/year=2024').glob('*.parquet')})
    failures=[]
    for year in (2023,2024,2025):
        paths=[]
        for station in stations:
            try:
                p=prepare(fetch(station,year),station,year);paths.append(p);logging.info('TAF acquired %s %s',station,year)
            except RuntimeError:raise
            except Exception as exc:
                failures.append({'year':year,'station':station,'error':str(exc)});logging.exception('TAF failure %s %s',station,year)
        if not paths:raise RuntimeError(f'No usable TAF files for {year}')
        raw=pl.concat([pl.read_parquet(p).with_columns([pl.col(c).cast(pl.Float64,strict=False) for c in ('sknt','drct','gust','visibility')]) for p in paths],how='vertical_relaxed')
        for month in range(1,13):
            target=OUT/f'year={year}'/f'month={month:02d}'/'part.parquet';metric=METRICS/f'{year}-{month:02d}.json'
            if target.exists() and metric.exists():continue
            logging.info('built %s',build(year,month,raw))
    allmetrics=[json.loads(p.read_text()) for p in sorted(METRICS.glob('*.json'))]
    (REPORTS/'model_quality.json').write_text(json.dumps({'months':allmetrics,'taf_failures':failures},indent=2))
if __name__=='__main__':main()
