#!/usr/bin/env python3
"""Import Hevy workout CSV export into the Marginalia exercise log.

Usage:
    python3 scripts/import-hevy.py /path/to/workout_data.csv

Hevy exports one row per SET. This script aggregates to one row per
WORKOUT (date + title), capturing duration, set count, rep total,
exercise list, and total volume (weight × reps) in the notes field.

Idempotent-ish: doesn't check for duplicates, so re-running will
create duplicate entries. Clear old Hevy entries first if needed:
    curl -s http://localhost:3100/api/exercise | \
      python3 -c "..." | xargs -I{} curl -X DELETE .../{}
"""

import csv
import json
import sys
import urllib.request
from collections import defaultdict
from datetime import datetime

API = 'http://localhost:3100'

def main():
    if len(sys.argv) < 2:
        print(f'Usage: {sys.argv[0]} <hevy-csv-path>', file=sys.stderr)
        sys.exit(1)

    csv_path = sys.argv[1]

    # Aggregate per-set rows into per-workout sessions
    workouts = defaultdict(lambda: {
        'exercises': [], 'sets': 0, 'start': '', 'end': '',
        'title': '', 'total_reps': 0, 'total_volume': 0.0,
    })

    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            key = row['start_time']
            w = workouts[key]
            w['title'] = row['title']
            w['start'] = row['start_time']
            w['end'] = row['end_time']
            if row['exercise_title'] not in w['exercises']:
                w['exercises'].append(row['exercise_title'])
            w['sets'] += 1
            try:
                reps = int(row['reps']) if row['reps'] else 0
                w['total_reps'] += reps
                weight = float(row['weight_kg']) if row['weight_kg'] else 0
                w['total_volume'] += weight * reps
            except (ValueError, TypeError):
                pass

    def parse_date(s):
        return datetime.strptime(s.strip(), '%d %b %Y, %H:%M')

    created = 0
    failed = 0
    for key, w in sorted(workouts.items()):
        start = parse_date(w['start'])
        end = parse_date(w['end'])
        duration = max(1, int((end - start).total_seconds() / 60))
        date_str = start.strftime('%Y-%m-%d')
        exercises = ', '.join(w['exercises'])
        volume_str = f', {w["total_volume"]:.0f}kg volume' if w['total_volume'] > 0 else ''
        notes = f'{w["title"]}: {w["sets"]} sets, {w["total_reps"]} reps{volume_str}. Exercises: {exercises}'

        body = json.dumps({
            'activity': 'weights',
            'date': date_str,
            'duration': str(duration),
            'notes': notes,
            'source': 'hevy',
        }).encode()

        req = urllib.request.Request(
            f'{API}/api/exercise',
            data=body,
            headers={'Content-Type': 'application/json'},
            method='POST',
        )
        try:
            urllib.request.urlopen(req).read()
            print(f'  + {date_str}  {w["title"]:15s}  {duration:2d}min  {w["sets"]:2d} sets  {w["total_reps"]:3d} reps')
            created += 1
        except Exception as e:
            print(f'  ! {date_str}: {e}', file=sys.stderr)
            failed += 1

    print(f'\nImported {created} workouts, {failed} failed')


if __name__ == '__main__':
    main()
