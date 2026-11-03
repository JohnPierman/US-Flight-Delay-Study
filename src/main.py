"""Single entry point for the flight-delay dataset pipeline."""
from __future__ import annotations
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
from datetime import datetime, timezone

CODE_ROOT = Path(__file__).resolve().parents[1]
STAGES = ('collect_history.py', 'collect_weather_history.py', 'build_history.py',
          'supplement_forecasts.py', 'validate_model_ready.py')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--workspace', type=Path, default=CODE_ROOT,
                        help='Directory for data and reports (default: repository root).')
    parser.add_argument('--smoke', action='store_true',
                        help='Run January 2024 and two weather stations in an isolated workspace.')
    args = parser.parse_args()
    workspace = args.workspace.resolve()
    if args.smoke and workspace == CODE_ROOT:
        parser.error('--smoke requires a separate --workspace to protect the full dataset')
    reports = workspace / 'reports'
    reports.mkdir(parents=True, exist_ok=True)
    status = reports / 'pipeline_status.json'
    env = os.environ.copy()
    env['FLIGHT_STUDY_ROOT'] = str(workspace)
    env['FLIGHT_STUDY_SMOKE'] = '1' if args.smoke else '0'

    def update(state, stage, code=None):
        status.write_text(json.dumps({'state': state, 'stage': stage, 'exit_code': code,
                         'smoke': args.smoke, 'updated_utc': datetime.now(timezone.utc).isoformat()}, indent=2))

    for stage in STAGES:
        update('running', stage)
        print(f'Running {stage}', flush=True)
        result = subprocess.run([sys.executable, str(CODE_ROOT / 'src' / stage)], cwd=CODE_ROOT, env=env)
        if result.returncode:
            update('failed', stage, result.returncode)
            return result.returncode
    update('complete', 'all', 0)
    print(f"Dataset: {workspace / 'data/processed/history/flights_model_ready'}", flush=True)
    print(f"Validation: {reports / 'model_validation.json'}", flush=True)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
