#!/usr/bin/env python3
"""Summary of a Budget Wallet log (Plan > Diagnostics > Save logs, or dist/logs/app-emulator.log).

    python3 -I tools/log-summary.py <logfile> [more logfiles...]

Prints counts per level and logger, every WARNING/SEVERE record, a perf table per timed operation (bw.perf),
frame windows (bw.frames), memory (bw.mem) and startup phases (app.start). Python standard library only.

Line format (wallet_core formatLogRecord):
    2026-10-16T19:01:02.123+02:00 DEBUG bw.import import.done {"rows":312,"dupes":4,"ms":41}
followed by optional "  error: ..." and two-space indented stack lines.
"""
import json
import math
import re
import sys
from collections import Counter, OrderedDict, defaultdict

LINE = re.compile(r'^(\d{4}-\d\d-\d\dT[\d:.]+[+-]\d\d:\d\d) (\S+) (\S+) (\S+)(?: (\{.*\}))?$')
LEVEL_ORDER = ['FINEST', 'FINER', 'DEBUG', 'FINE', 'CONFIG', 'INFO', 'WARNING', 'SEVERE', 'SHOUT']


class Record:
    __slots__ = ('time', 'level', 'logger', 'event', 'fields', 'extra')

    def __init__(self, time, level, logger, event, fields):
        self.time, self.level, self.logger, self.event, self.fields = time, level, logger, event, fields
        self.extra = []

    def line(self):
        f = ' ' + json.dumps(self.fields, ensure_ascii=False, separators=(',', ':')) if self.fields else ''
        return f'{self.time} {self.level} {self.logger} {self.event}{f}'


def parse(paths):
    records, unparsed = [], 0
    for path in paths:
        with open(path, encoding='utf-8', errors='replace') as fh:
            for raw in fh:
                raw = raw.rstrip('\n')
                if raw.startswith('  ') and records:
                    records[-1].extra.append(raw[2:])
                    continue
                m = LINE.match(raw)
                if not m:
                    if raw.strip():
                        unparsed += 1
                    continue
                fields = {}
                if m.group(5):
                    try:
                        fields = json.loads(m.group(5), object_pairs_hook=OrderedDict)
                    except ValueError:
                        fields = {}
                records.append(Record(m.group(1), m.group(2), m.group(3), m.group(4), fields))
    return records, unparsed


def rank(sorted_xs, p):
    """Nearest-rank percentile of an ascending list."""
    if not sorted_xs:
        return None
    k = max(1, math.ceil(p / 100 * len(sorted_xs)))
    return sorted_xs[min(k, len(sorted_xs)) - 1]


def num(x):
    return x if isinstance(x, (int, float)) and not isinstance(x, bool) else None


def fmt(x):
    if x is None:
        return '-'
    if isinstance(x, float):
        return str(int(x)) if x.is_integer() else f'{x:.1f}'
    return str(x)


def section(title):
    print(f'\n== {title} ==')


def table(rows, header):
    widths = [max(len(str(r[i])) for r in [header] + rows) for i in range(len(header))]
    for r in [header] + rows:
        print('  ' + '  '.join(str(c).ljust(widths[i]) if i == 0 else str(c).rjust(widths[i]) for i, c in enumerate(r)))


def main(argv):
    if len(argv) < 2 or argv[1] in ('-h', '--help'):
        print(__doc__.strip())
        return 2
    records, unparsed = parse(argv[1:])
    if not records:
        print('no log records found')
        return 1

    print(f'{len(records)} records, {records[0].time} .. {records[-1].time}' + (f', {unparsed} unparsed lines' if unparsed else ''))

    section('Levels')
    levels = Counter(r.level for r in records)
    print('  ' + '  '.join(f'{lv}={levels[lv]}' for lv in sorted(levels, key=lambda x: LEVEL_ORDER.index(x) if x in LEVEL_ORDER else 99)))

    section('Loggers')
    for name, n in sorted(Counter(r.logger for r in records).items(), key=lambda kv: (-kv[1], kv[0])):
        print(f'  {n:6d}  {name}')

    section('App')
    for r in records:
        if r.event == 'app.info':
            print('  ' + ', '.join(f'{k}={v}' for k, v in r.fields.items()))

    section('Startup (app.start, ms)')
    runs, cur = [], None
    for r in records:
        if r.event != 'app.start':
            continue
        phase = r.fields.get('phase', '?')
        if cur is None or phase == 'logs' or phase in cur:
            cur = OrderedDict()
            runs.append((r.time, cur))
        extra = {k: v for k, v in r.fields.items() if k not in ('phase', 'ms')}
        cur[phase] = fmt(r.fields.get('ms')) + (' (' + ', '.join(f'{k}={v}' for k, v in extra.items()) + ')' if extra else '')
    if not runs:
        print('  none')
    for t, phases in runs:
        print(f'  {t}: ' + ' | '.join(f'{p} {v}' for p, v in phases.items()))

    section('Warnings and errors')
    bad = [r for r in records if r.level in ('WARNING', 'SEVERE', 'SHOUT')]
    if not bad:
        print('  none')
    for r in bad:
        print('  ' + r.line())
        for x in r.extra[:4]:
            print('      ' + x)
        if len(r.extra) > 4:
            print(f'      ... {len(r.extra) - 4} more lines')

    section('Perf (bw.perf, ms)')
    perf = defaultdict(list)
    warns = Counter()
    for r in records:
        if r.logger == 'bw.perf' and num(r.fields.get('ms')) is not None:
            perf[r.event].append(r.fields['ms'])
            if r.level == 'WARNING':
                warns[r.event] += 1
    if not perf:
        print('  none')
    else:
        rows = []
        for name, xs in sorted(perf.items(), key=lambda kv: -sum(kv[1])):
            s = sorted(xs)
            rows.append([name, len(s), fmt(rank(s, 50)), fmt(rank(s, 90)), fmt(s[-1]), fmt(sum(s)), warns[name] or ''])
        table(rows, ['name', 'count', 'p50', 'p90', 'max', 'total', 'warn'])

    section('Frames (bw.frames)')
    windows = [r for r in records if r.event == 'frames.window']
    slow = [r for r in records if r.event == 'frames.slow']
    if not windows:
        print('  no frame windows')
    else:
        frames = sum(num(r.fields.get('frames')) or 0 for r in windows)
        janky = sum(num(r.fields.get('janky')) or 0 for r in windows)
        worst_b = max((num(r.fields.get('build_p99_ms')) or 0 for r in windows), default=0)
        worst_r = max((num(r.fields.get('raster_p99_ms')) or 0 for r in windows), default=0)
        max_b = max((num(r.fields.get('build_max_ms')) or 0 for r in windows), default=0)
        max_r = max((num(r.fields.get('raster_max_ms')) or 0 for r in windows), default=0)
        pct = 100.0 * janky / frames if frames else 0.0
        print(f'  {len(windows)} windows, {frames} frames, {janky} janky ({pct:.1f}%)')
        print(f'  worst p99: build {fmt(worst_b)} ms, raster {fmt(worst_r)} ms; max: build {fmt(max_b)} ms, raster {fmt(max_r)} ms')
        per_tab = defaultdict(lambda: [0, 0])
        for r in windows:
            t = per_tab[r.fields.get('tab', '?')]
            t[0] += num(r.fields.get('frames')) or 0
            t[1] += num(r.fields.get('janky')) or 0
        print('  by tab: ' + ', '.join(f'{tab} {f} frames/{j} janky' for tab, (f, j) in per_tab.items()))
    print(f'  slow frames (>100 ms): {len(slow)}')
    for r in slow[:10]:
        print('    ' + r.line())

    section('Memory (bw.mem, MB)')
    rss = [num(r.fields.get('rss_mb')) for r in records if r.event == 'mem']
    rss = [x for x in rss if x is not None]
    peak = [num(r.fields.get('max_rss_mb')) for r in records if r.event == 'mem']
    peak = [x for x in peak if x is not None]
    if rss:
        print(f'  rss min {fmt(min(rss))}, max {fmt(max(rss))}, last {fmt(rss[-1])} ({len(rss)} samples); peak max_rss {fmt(max(peak) if peak else None)}')
    else:
        print('  none')

    section('Lifecycle')
    states = [r.fields.get('state') for r in records if r.event == 'lifecycle']
    print('  ' + (' > '.join(str(s) for s in states[-20:]) if states else 'none'))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
