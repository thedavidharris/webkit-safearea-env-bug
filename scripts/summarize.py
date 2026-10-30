#!/usr/bin/env python3
"""Summarize probe checkpoints, never infer first-paint correctness from them."""
import json
import sys
from pathlib import Path

EDGES = ('top', 'right', 'bottom', 'left')


def records(text):
    for line in text.splitlines():
        if 'PROBE ' not in line:
            continue
        try:
            record = json.loads(line.split('PROBE ', 1)[1])
        except json.JSONDecodeError:
            continue
        if isinstance(record, dict):
            yield record


def insets(value):
    if not isinstance(value, dict):
        return '—'
    return '/'.join('—' if value.get(e) is None else f'{value[e]:g}' for e in EDGES)


def matches(value, expected):
    return isinstance(value, dict) and all(
        isinstance(value.get(e), (int, float)) and abs(value[e] - expected[e]) <= 0.5 for e in EDGES)


def settle(events, key):
    """Milliseconds from the last native inset change until a page snapshot reports it."""
    changes = [e for e in events if e.get('event') == 'native-insets' and isinstance(e.get('insets'), dict)]
    if not changes:
        return '—'
    last = changes[-1]
    for e in events:
        if e.get('nativeMs', -1) >= last['nativeMs'] and matches(e.get(key), last['insets']):
            return f"{e['nativeMs'] - last['nativeMs']:.0f}"
    return 'NEVER'


def summarize(folder):
    lines = [
        '# Checkpoint results', '',
        'Insets are top/right/bottom/left. Times start when the destination coordinator is created; prewarming before that is excluded.',
        'Native-at-receipt is sampled after the JS checkpoint. Equality is diagnostic, not proof of first-paint correctness.',
        'Settle ms runs from the last native inset change to the first page snapshot (at native receipt) that matches it.', '',
        '| Log | Strategy | Initial native ms | Initial env | Initial injected | Initial effective | Native at receipt | Final env | Final effective | Final native at receipt | Env settle ms | Effective settle ms | Priming | Errors |',
        '|---|---|---:|---|---|---|---|---|---|---|---:|---:|---|---:|'
    ]
    logs = sorted(Path(folder).glob('run-*.log'))
    if not logs:
        raise ValueError('No run-*.log files found')
    for log in logs:
        events = list(records(log.read_text(errors='replace')))
        initial = [e for e in events if e.get('event') == 'initial']
        outcomes = [e['event'] for e in events if e.get('event') in {
            'prime-ready', 'prime-timeout', 'prime-failed', 'prime-process-terminated'}]
        outcome = outcomes[-1] if outcomes else ('NO OUTCOME' if any(e.get('strategy') in {'prime', 'preprime', 'preprime-inject'} for e in events) else 'n/a')
        errors = sum(e.get('event') in {'bridge-error', 'navigation-error', 'process-terminated', 'invalid-probe'} for e in events)
        final = next((e for e in reversed(events) if 'env' in e and 'nativeAtReceipt' in e), {})
        final_cells = (f"{insets(final.get('env'))} | {insets(final.get('effective'))} | {insets(final.get('nativeAtReceipt'))}"
                       f" | {settle(events, 'env')} | {settle(events, 'effective')}")
        if not initial:
            lines.append(f'| {log.name} | MISSING INITIAL PROBE | — | — | — | — | — | {final_cells} | {outcome} | {errors} |')
        for e in initial:
            lines.append(f"| {log.name} | {e.get('strategy', '?')} | {e['nativeMs']:.1f} | {insets(e.get('env'))} | {insets(e.get('native'))} | {insets(e.get('effective'))} | {insets(e.get('nativeAtReceipt'))} | {final_cells} | {outcome} | {errors} |")
    lines += ['', 'Inspect the full JSON logs for dom/load/frame/insets-change, navigation and reconciliation events.',
              'Screenshots at the end of a run do not show transient jumps. Review the videos separately.']
    return '\n'.join(lines)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('Usage: python3 scripts/summarize.py RESULTS_DIRECTORY')
    print(summarize(sys.argv[1]))
