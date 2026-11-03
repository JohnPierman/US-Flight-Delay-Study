"""Shared paths, download and geographic helpers."""
import math
import os
from pathlib import Path
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

ROOT = Path(os.environ.get("FLIGHT_STUDY_ROOT", Path(__file__).resolve().parents[1])).resolve()
RAW = ROOT / "data/raw"
BTS = "https://transtats.bts.gov/PREZIP/On_Time_Reporting_Carrier_On_Time_Performance_1987_present_{year}_{month}.zip"
IEM = "https://mesonet.agron.iastate.edu/cgi-bin/request/asos.py"
SESSION = requests.Session()
SESSION.mount("https://", HTTPAdapter(max_retries=Retry(total=4, backoff_factor=1, status_forcelist=[429,500,502,503,504])))

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

def asfloat(x):
    try: return float(x)
    except (ValueError, TypeError): return None

def haversine(lat1, lon1, lat2, lon2):
    a = math.sin(math.radians(lat2-lat1)/2)**2 + math.cos(math.radians(lat1))*math.cos(math.radians(lat2))*math.sin(math.radians(lon2-lon1)/2)**2
    return 12742 * math.asin(math.sqrt(a))
