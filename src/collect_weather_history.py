"""Collect annual IEM histories for high-traffic stations, retaining source CSVs."""
import csv, json, logging, os
from datetime import datetime,timezone
import polars as pl
from collect_history import DATA, RAW, REPORTS, budget
from common import IEM, download, haversine, asfloat

WEATHER=DATA/'intermediate'/'weather'

def main():
    logging.basicConfig(level=logging.INFO,format='%(asctime)s %(levelname)s %(message)s',handlers=[logging.StreamHandler(),logging.FileHandler(REPORTS/'weather_collection.log')])
    source=DATA/'intermediate/bts_flights/year=2024/month=01/flights.parquet'
    flights=pl.scan_parquet(source)
    traffic=pl.concat([flights.select(pl.col('Origin').alias('code')),flights.select(pl.col('Dest').alias('code'))]).group_by('code').len().sort('len',descending=True).collect()
    airports=pl.read_parquet(DATA/'intermediate/airport_metadata.parquet')
    candidates=traffic.join(airports,on='code',how='inner').sort('len',descending=True).filter(pl.col('icao')==pl.concat_str([pl.lit('K'),pl.col('code')])).head(2 if os.environ.get('FLIGHT_STUDY_SMOKE')=='1' else 40)
    manifest=[]
    failures=[]
    for station in candidates.to_dicts():
        code=station['code']
        for year in ([2024] if os.environ.get('FLIGHT_STUDY_SMOKE')=='1' else [2024,2025,2023]):
            path=RAW/'iem_annual'/f'{code}_{year}.csv';target=WEATHER/f'year={year}'/f'{code}.parquet';target.parent.mkdir(parents=True,exist_ok=True)
            if target.exists(): continue
            budget(100*1024**2)
            params={'station':code,'data':'all','year1':year,'month1':1,'day1':1,'year2':year+1,'month2':1,'day2':1,'tz':'Etc/UTC','format':'onlycomma','latlon':'yes','missing':'M','trace':'T','report_type':[3,4]}
            try:
                download(IEM,path,params)
                rows=[]
                with path.open(newline='',encoding='utf8') as f:
                    reader=csv.DictReader(f)
                    if not reader.fieldnames or not {'station','valid','lat','lon','tmpf','metar'}.issubset(reader.fieldnames): raise ValueError('Unexpected IEM response; retained source for inspection')
                    for r in reader:
                        try:
                            t=datetime.strptime(r['valid'],'%Y-%m-%d %H:%M').replace(tzinfo=timezone.utc)
                            lat,lon=float(r['lat']),float(r['lon']);dist=haversine(station['latitude'],station['longitude'],lat,lon)
                        except (ValueError,KeyError): continue
                        if dist>5: raise ValueError(f'station {code} distance {dist:.2f} km exceeds 5 km')
                        val=lambda k:asfloat(r.get(k))
                        c=[val('skyl'+str(i)) for i in range(1,5) if r.get('skyc'+str(i)) in ('BKN','OVC','VV') and val('skyl'+str(i)) is not None]
                        rows.append({'station':code,'timestamp_utc':t,'latitude':lat,'longitude':lon,'distance_km':dist,'temperature_c':(val('tmpf')-32)*5/9 if val('tmpf') is not None else None,'dewpoint_c':(val('dwpf')-32)*5/9 if val('dwpf') is not None else None,'relative_humidity_pct':val('relh'),'wind_speed_kt':val('sknt'),'wind_direction_deg':val('drct'),'wind_gust_kt':val('gust'),'visibility_m':val('vsby')*1609.344 if val('vsby') is not None else None,'altimeter_hpa':val('alti')*33.8638866667 if val('alti') is not None else None,'precipitation_mm':val('p01i')*25.4 if val('p01i') is not None else None,'precipitation_trace':r.get('p01i')=='T','cloud_ceiling_ft':min(c) if c else None,'weather_codes':r.get('wxcodes') if r.get('wxcodes') not in ('M','') else None,'metar':r.get('metar')})
                if not rows: raise ValueError('IEM returned no usable observations')
                tmp=target.with_suffix('.tmp');pl.DataFrame(rows,infer_schema_length=None).sort('timestamp_utc').write_parquet(tmp,compression='zstd');tmp.replace(target)
                manifest.append({'station':code,'year':year,'rows':len(rows),'source':IEM,'params':params})
                logging.info('%s %s observations=%s',code,year,len(rows))
            except RuntimeError:
                raise
            except Exception as e:
                failures.append(f'{code} {year}: {e}')
                logging.exception('IEM failed %s %s: %s',code,year,e)
    (REPORTS/'weather_collection_manifest_last_run.json').write_text(json.dumps({'collected':manifest,'failures':failures},indent=2))
    if failures: raise RuntimeError(f'{len(failures)} weather downloads failed; retry the main command')
if __name__=='__main__':main()
