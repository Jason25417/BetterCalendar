#!/usr/bin/env python3
"""Match local upload receipts with another device's observations; never infer clock sync."""
import argparse
import json
import math
import statistics
from pathlib import Path


def summarize(reports):
    uploads = {}
    for report in reports:
        if report.get('formatVersion') != 1:
            raise ValueError('Unsupported report format')
        for row in report['receipts']:
            if row['direction'] == 'uploaded':
                uploads[key(row)] = row
    matched, unmatched = [], 0
    seen = set()
    for report in reports:
        for row in report['receipts']:
            if row['direction'] != 'received' or row['action'].startswith('tick'):
                continue
            identity = (report['localDevice'], key(row))
            if identity in seen:
                continue
            seen.add(identity)
            upload = uploads.get(key(row))
            if upload is None or row['sourceDevice'] == report['localDevice']:
                unmatched += 1
                continue
            # Dates use the archive encoder's Unix milliseconds; never substitute file mtime.
            matched.append({
                'sourceDevice': row['sourceDevice'], 'receivingDevice': report['localDevice'],
                'sequence': row['sequence'], 'action': row['action'], 'trigger': row['trigger'],
                'apparentActionToDisplaySeconds': (row['observedAt'] - upload['sourceAt']) / 1000,
                'uploadRequestSeconds': upload['requestSeconds'],
                'readRequestSeconds': row['requestSeconds'],
            })
    ages = sorted(x['apparentActionToDisplaySeconds'] for x in matched)
    return {
        'matchedActions': matched, 'unmatchedObservations': unmatched,
        'sampleCount': len(ages),
        'apparentMedianSeconds': statistics.median(ages) if ages else None,
        'apparentP95Seconds': ages[max(0, math.ceil(len(ages) * .95) - 1)] if ages else None,
        'clockWarning': 'Cross-device ages include clock skew; negative values are preserved. Startup/catch-up observations may refer to old actions. These are observations, not guaranteed delivery bounds.',
    }


def key(row):
    return row['sourceDevice'], row['sequence'], row['action'], row['sourceAt']


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('reports', nargs='+', type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize([json.loads(p.read_text()) for p in args.reports]), ensure_ascii=False, indent=2))
