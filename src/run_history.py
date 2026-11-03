"""Run the resumable stages in order; logs and exit status remain on disk."""
import json, subprocess, sys
from datetime import datetime,timezone
from pathlib import Path
root=Path(__file__).resolve().parents[1]
status=root/'reports/history_run_status.json'
def update(state,stage,code=None):
    status.write_text(json.dumps({'state':state,'stage':stage,'exit_code':code,'updated_utc':datetime.now(timezone.utc).isoformat()},indent=2))
for stage in ('collect_history.py','collect_weather_history.py','build_history.py'):
    update('running',stage)
    result=subprocess.run([sys.executable,str(root/'src'/stage)],cwd=root)
    if result.returncode:
        update('failed',stage,result.returncode)
        sys.exit(result.returncode)
update('complete','all',0)
