"""Bounded, real-data January 2024 pilot. See README for incomplete scope."""
from __future__ import annotations
import bisect
import csv
import hashlib
import json
import math
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo
import requests
import polars as pl
import yaml
from timezonefinder import TimezoneFinder
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

ROOT = Path(__file__).resolve().parents[1]
RAW = ROOT / 'data/raw'
OUT = ROOT / 'data/processed'
REPORTS = ROOT / 'reports'
UTC = timezone.utc
AIRPORTS_URL = 'https://davidmegginson.github.io/ourairports-data/airports.csv'
BTS = 'https://transtats.bts.gov/PREZIP/On_Time_Reporting_Carrier_On_Time_Performance_1987_present_{year}_{month}.zip'
IEM = 'https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py'
SESSION = requests.Session()
SESSION.mount('https://', HTTPAdapter(max_retries=Retry(total=4, backoff_factor=1, status_forcelist=[429, 500, 502, 503, 504])))

def download(url, path, params=None):
    if path.exists() and path.stat().st_size:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + '.part')
    with SESSION.get(url, params=params, timeout=(30, 180), stream=True) as response:
        response.raise_for_status()
        with tmp.open('wb') as dest:
            for chunk in response.iter_content(1024 * 1024):
                dest.write(chunk)
    tmp.replace(path)

def local_candidates(day, hhmm, zone):
    """Return valid UTC instants; ambiguous and nonexistent local times are explicit."""
    try:
        n = int(float(hhmm)); h, m = divmod(n, 100)
        if m > 59 or h > 24 or (h == 24 and m): return []
        naive = datetime.fromisoformat(str(day)) + timedelta(days=h // 24, hours=h % 24, minutes=m)
        tz = ZoneInfo(zone)
        choices = {naive.replace(tzinfo=tz, fold=fold).astimezone(UTC) for fold in (0, 1)}
        return sorted(x for x in choices if x.astimezone(tz).replace(tzinfo=None) == naive)
    except (ValueError, TypeError, KeyError):
        return []

def matches_clock(utc, value, zone):
    try:
        n = int(float(value)); h, m = divmod(n, 100)
        return m < 60 and h <= 24 and not (h == 24 and m) and (utc.astimezone(ZoneInfo(zone)).hour, utc.astimezone(ZoneInfo(zone)).minute) == (h % 24, m)
    except (TypeError, ValueError): return False

def timestamps(row, oz, dz):
    # Elapsed time and destination clock jointly resolve DST folds, including overnight arrivals.
    possibilities = []
    for dep in local_candidates(row['FlightDate'], row['CRSDepTime'], oz):
        try:
            duration = float(row['CRSElapsedTime'])
            if not 0 < duration <= 24 * 60: continue
            arr = dep + timedelta(minutes=duration)
            if matches_clock(arr, row['CRSArrTime'], dz): possibilities.append((dep, arr))
        except (ValueError, TypeError): pass
    if len(possibilities) != 1: return (None, None, None, None, 'scheduled_ambiguous_or_inconsistent')
    dep, arr = possibilities[0]
    actual_dep = actual_arr = None
    try:
        candidate = dep + timedelta(minutes=float(row['DepDelay']))
        if matches_clock(candidate, row['DepTime'], oz): actual_dep = candidate
    except (ValueError, TypeError): pass
    try:
        candidate = arr + timedelta(minutes=float(row['ArrDelay']))
        if matches_clock(candidate, row['ArrTime'], dz) and actual_dep is not None and abs((candidate-actual_dep).total_seconds()/60-float(row['ActualElapsedTime'])) < 1:
            actual_arr = candidate
    except (ValueError, TypeError): pass
    return dep, arr, actual_dep, actual_arr, 'ok' if actual_dep or not row['DepDelay'] else 'actual_inconsistent'

def asfloat(x):
    try: return float(x)
    except (ValueError, TypeError): return None

def haversine(lat1, lon1, lat2, lon2):
    a = math.sin(math.radians(lat2-lat1)/2)**2 + math.cos(math.radians(lat1))*math.cos(math.radians(lat2))*math.sin(math.radians(lon2-lon1)/2)**2
    return 12742 * math.asin(math.sqrt(a))

def metadata(codes):
    download(AIRPORTS_URL, RAW/'airports.csv')
    tf = TimezoneFinder()
    found = {}
    with (RAW/'airports.csv').open(newline='', encoding='utf-8') as f:
        for r in csv.DictReader(f):
            code = r['iata_code']
            if code not in codes or not r['ident'].startswith('K') or r['ident'][1:] != code: continue
            lat, lon = float(r['latitude_deg']), float(r['longitude_deg'])
            found[code] = {'icao':r['ident'], 'latitude':lat, 'longitude':lon, 'timezone':tf.timezone_at(lng=lon, lat=lat), 'name':r['name']}
    if set(found) != set(codes) or any(not x['timezone'] for x in found.values()): raise RuntimeError('Incomplete airport metadata')
    return found

def load_weather(code, meta, year, month):
    import calendar
    end = datetime(year, month, 1) + timedelta(days=calendar.monthrange(year, month)[1])
    # Include prior day and one following day for timezone boundary coverage.
    start = datetime(year, month, 1)-timedelta(days=1); end += timedelta(days=2)
    params = {'station':code, 'data':'all', 'year1':start.year, 'month1':start.month, 'day1':start.day, 'year2':end.year, 'month2':end.month, 'day2':end.day, 'tz':'Etc/UTC', 'format':'onlycomma', 'latlon':'yes', 'missing':'M', 'trace':'T', 'report_type':[3,4]}
    path = RAW/f'iem_{code}_{year}_{month:02}.csv'
    download(IEM,path,params)
    records=[]
    with path.open(newline='', encoding='utf-8') as f:
        for r in csv.DictReader(f):
            try:
                lat,lon=float(r['lat']),float(r['lon']); dist=haversine(meta['latitude'],meta['longitude'],lat,lon)
                if dist > 5: raise RuntimeError(f'{code} station is {dist:.1f} km from airport; mapping rejected')
                t=datetime.strptime(r['valid'],'%Y-%m-%d %H:%M').replace(tzinfo=UTC)
            except (KeyError,ValueError): continue
            def val(k): return asfloat(r.get(k))
            ceiling=[val('skyl'+str(i)) for i in range(1,5) if r.get('skyc'+str(i)) in ('BKN','OVC','VV') and val('skyl'+str(i)) is not None]
            codes=r.get('wxcodes','')
            records.append({'station':code,'timestamp_utc':t,'station_latitude':lat,'station_longitude':lon,'distance_km':dist,'temperature_c':(val('tmpf')-32)*5/9 if val('tmpf') is not None else None,'dewpoint_c':(val('dwpf')-32)*5/9 if val('dwpf') is not None else None,'relative_humidity_pct':val('relh'),'wind_speed_kt':val('sknt'),'wind_direction_deg':val('drct'),'wind_gust_kt':val('gust'),'visibility_m':val('vsby')*1609.344 if val('vsby') is not None else None,'altimeter_hpa':val('alti')*33.8638866667 if val('alti') is not None else None,'precipitation_mm':val('p01i')*25.4 if val('p01i') is not None else None,'precipitation_trace':r.get('p01i')=='T','cloud_ceiling_ft':min(ceiling) if ceiling else None,'weather_codes':codes if codes not in ('M','') else None,'metar':r.get('metar')})
    records.sort(key=lambda r:r['timestamp_utc'])
    if not records: raise RuntimeError(f'No valid weather for {code}')
    return records

def weather_at(records, times, when, age):
    if when is None: return None
    i=bisect.bisect_right(times, when)-1
    if i < 0 or (when-times[i]).total_seconds()>age*60: return None
    return records[i]

def run():
    import zipfile
    config=yaml.safe_load((ROOT/'config/pipeline.yaml').read_text()); year=config['year']; month=config['month']; codes=set(config['airports'])
    if (year, month)!=(2024,1): raise RuntimeError('Only January 2024 bounded smoke execution is currently implemented')
    for p in (RAW,OUT,REPORTS): p.mkdir(parents=True,exist_ok=True)
    zip_path=RAW/f'bts_{year}_{month:02}.zip'; download(BTS.format(year=year,month=month),zip_path)
    with zipfile.ZipFile(zip_path) as z:
        if z.testzip() is not None: raise RuntimeError('Corrupt BTS ZIP')
        names=[n for n in z.namelist() if n.lower().endswith('.csv')]; assert len(names)==1
        csv_path=RAW/'bts_2024_01_extracted.csv'
        if not csv_path.exists():
            with z.open(names[0]) as source, csv_path.open('wb') as dest:
                import shutil; shutil.copyfileobj(source,dest)
    airports=metadata(codes)
    weather={c:load_weather(c,airports[c],year,month) for c in sorted(codes)}
    weather_times={c:[r['timestamp_utc'] for r in w] for c,w in weather.items()}
    all_weather=[r for w in weather.values() for r in w]
    pl.DataFrame(all_weather).write_parquet(OUT/'airport_weather.parquet')
    # Source line number, not a business key, preserves duplicate-looking records.
    flights=pl.scan_csv(csv_path, infer_schema=False, truncate_ragged_lines=True, row_index_name='_row').filter(pl.col('Origin').is_in(codes) & pl.col('Dest').is_in(codes)).collect().to_dicts()
    flights.sort(key=lambda r:r['_row'])
    output=[]
    for r in flights:
        o,d=r['Origin'],r['Dest']; sd,sa,ad,aa,reason=timestamps(r,airports[o]['timezone'],airports[d]['timezone'])
        result={k:v for k,v in r.items() if k != '_row' and k and not k.startswith('Div')}
        result.update({'flight_id':f'{year}{month:02}-{r["_row"]:08}', 'scheduled_departure_utc':sd,'scheduled_arrival_utc':sa,'actual_departure_utc':ad,'actual_arrival_utc':aa,'timestamp_status':reason,'prediction_cutoff_utc':sd-timedelta(minutes=config['prediction_minutes_before_departure']) if sd else None,'departure_delay_minutes':asfloat(r['DepDelay']) if r['DepTime'] else None,'origin_timezone':airports[o]['timezone'],'destination_timezone':airports[d]['timezone']})
        for prefix,airport,when in [('predictive_origin',o,result['prediction_cutoff_utc']),('predictive_destination',d,result['prediction_cutoff_utc']),('departure_origin',o,sd),('departure_destination',d,sd),('arrival_destination',d,sa)]:
            w=weather_at(weather[airport],weather_times[airport],when,config['weather_max_age_minutes'])
            for k in ('station','timestamp_utc','temperature_c','dewpoint_c','relative_humidity_pct','wind_speed_kt','wind_gust_kt','visibility_m','altimeter_hpa','precipitation_mm','cloud_ceiling_ft','weather_codes'):
                result[prefix+'_'+k]=w[k] if w else None
            result[prefix+'_weather_age_minutes']=(when-w['timestamp_utc']).total_seconds()/60 if w else None
        output.append(result)
    # A predecessor is only tentative: unreported movements and filtered airports are not observable.
    previous={}
    for r in sorted(output,key=lambda x:(x['Tail_Number'] or '',x['scheduled_departure_utc'] or datetime.max.replace(tzinfo=UTC))):
        tail=r['Tail_Number']; p=previous.get(tail) if tail else None
        valid=p and p['Dest']==r['Origin'] and p['actual_arrival_utc'] and r['actual_departure_utc'] and timedelta(0)<=r['actual_departure_utc']-p['actual_arrival_utc']<=timedelta(hours=24)
        r['previous_flight_id']=p['flight_id'] if valid else None
        r['previous_flight_arrival_delay_minutes']=asfloat(p['ArrDelay']) if valid else None
        r['actual_turnaround_minutes']=(r['actual_departure_utc']-p['actual_arrival_utc']).total_seconds()/60 if valid else None
        r['previous_connection_status']='tentative' if valid else 'unknown'
        if tail and r['scheduled_departure_utc']: previous[tail]=r
    frame=pl.DataFrame(output, infer_schema_length=None)
    frame.write_parquet(OUT/'flights_master.parquet')
    # Explicit allowlist avoids target outcomes and retrospective aircraft assignment leakage.
    allowed=['flight_id','FlightDate','Reporting_Airline','Flight_Number_Reporting_Airline','Origin','Dest','CRSDepTime','CRSArrTime','CRSElapsedTime','Distance','scheduled_departure_utc','scheduled_arrival_utc','prediction_cutoff_utc','departure_delay_minutes']
    allowed += [c for c in frame.columns if c.startswith('predictive_')]
    complete=frame.filter(pl.col('departure_delay_minutes').is_not_null() & (pl.col('Cancelled') == '0.00'))
    predictive=complete.select(allowed); predictive.write_parquet(OUT/'flights_predictive.parquet')
    complete.write_parquet(OUT/'flights_explanatory.parquet')
    frame.select(['flight_id','Tail_Number','previous_flight_id','previous_flight_arrival_delay_minutes','actual_turnaround_minutes','previous_connection_status']).write_parquet(OUT/'aircraft_rotations.parquet')
    # Minimal required regression variables; no optional weather complete-case requirement.
    complete.filter(pl.col('scheduled_departure_utc').is_not_null()).write_parquet(OUT/'flights_regression.parquet')
    assert frame['flight_id'].n_unique()==frame.height
    for prefix in ('predictive_origin','predictive_destination'):
        assert predictive.filter(pl.col(prefix+'_timestamp_utc')>pl.col('prediction_cutoff_utc')).height==0
    coverage=lambda f,c:round(100*f[c].is_not_null().sum()/max(1,f.height),2)
    summary={'scope':'bounded January 2024 smoke, both endpoints in five selected airports','master_rows':frame.height,'completed_rows':complete.height,'predictive_rows':predictive.height,'explanatory_rows':complete.height,'weather_rows':len(all_weather),'origin_cutoff_weather_pct':coverage(frame,'predictive_origin_timestamp_utc'),'destination_cutoff_weather_pct':coverage(frame,'predictive_destination_timestamp_utc'),'tentative_previous_pct':coverage(frame,'previous_flight_id'),'timestamp_status':frame.group_by('timestamp_status').len().to_dicts()}
    missing=frame.null_count().transpose(include_header=True,header_name='feature',column_names=['nulls']).with_columns((pl.col('nulls')*100/frame.height).alias('missing_pct')).sort('missing_pct',descending=True)
    duplicate_keys=frame.group_by(['FlightDate','Reporting_Airline','Flight_Number_Reporting_Airline','Origin','Dest','CRSDepTime']).len().filter(pl.col('len')>1)
    summary['duplicate_looking_groups']=duplicate_keys.height
    summary['negative_delay_rows']=frame.filter(pl.col('departure_delay_minutes')<0).height
    summary['maximum_departure_delay_minutes']=frame['departure_delay_minutes'].max()
    summary['airlines']=sorted(frame['Reporting_Airline'].drop_nulls().unique().to_list())
    summary['airports']=sorted(codes)
    summary['delay_validated_actual_timestamps_pct']=coverage(frame.filter(pl.col('departure_delay_minutes').is_not_null()),'actual_departure_utc')
    (REPORTS/'quality_report.md').write_text('# Preliminary smoke quality report\n\n```json\n'+json.dumps(summary,indent=2)+'\n```\n\nThis is a filtered pilot, not full coverage. Previous connections are tentative. All joins retain the source row count.\n\n## Missingness in master\n\n'+missing.write_csv())
    with (REPORTS/'data_dictionary.md').open('w') as f:
        f.write('# Preliminary data dictionary\n\nBTS fields retain their original names and units as defined in the official BTS field documentation. Derived weather fields use the prefixes predictive_origin, predictive_destination, departure_origin, departure_destination and arrival_destination. Predictive weather is at or before the cutoff; departure and arrival weather is retrospective. Temperatures are degrees C, humidity percent, wind knots, visibility metres, altimeter hPa, precipitation mm and ceiling feet. Trace precipitation is not converted to zero. UTC timestamps are timezone aware. All previous-flight fields are tentative retrospective reconstruction.\n\n| Field | Type | Missing % (master) | Availability / construction |\n|---|---|---:|---|\n')
        miss={r['feature']:r['missing_pct'] for r in missing.to_dicts()}
        for c,typ in frame.schema.items():
            availability='conditional schedule or cutoff observation' if c in allowed else 'outcome or retrospective; excluded from prediction'
            f.write(f'| {c} | {typ} | {miss[c]:.2f} | {availability} |\n')
    with (REPORTS/'feature_availability_matrix.csv').open('w',newline='') as f:
        writer=csv.writer(f); writer.writerow(['variable','source','transformation','available_at_cutoff','retrospective','historical_assumptions','leakage_risk','predictive_missing_pct','explanatory_missing_pct'])
        for c in frame.columns:
            ispred=c in allowed and c!='departure_delay_minutes'
            writer.writerow([c,'IEM' if 'temperature' in c or 'weather' in c or c.startswith(('predictive_','departure_origin','departure_destination','arrival_destination')) else 'BTS','See README','conditional' if ispred else 'no','yes','Published schedules assumed available at cutoff' if ispred else '', 'Schedule revisions and observation delivery times unverified' if ispred else 'Retrospective or outcome',round(100-coverage(predictive,c),2) if c in predictive.columns else '',round(100-coverage(complete,c),2)])
    paths=[zip_path,RAW/'airports.csv']+sorted(RAW.glob('iem_*.csv'))
    provenance={'retrieved_note':'Existing raw files are reused; timestamps are filesystem modification times in UTC.','files':[{'path':str(p.relative_to(ROOT)),'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'mtime_utc':datetime.fromtimestamp(p.stat().st_mtime,UTC).isoformat()} for p in paths], 'sources':[BTS.format(year=year,month=month),IEM,AIRPORTS_URL]}
    (REPORTS/'provenance.json').write_text(json.dumps(provenance,indent=2))
    print(json.dumps(summary,indent=2))
if __name__=='__main__': run()
