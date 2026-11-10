#!/usr/bin/env python3
"""Run an existing emacs-radio-probe.py with dynamic URL resolution.

Intercepts external ffmpeg/mpv probes and normalizes CSV/TSV records in-process,
without rewriting or assuming any source-code anchors in the original scanner.
"""
from __future__ import annotations
import argparse
import csv
import os
import runpy
import subprocess
import sys
from pathlib import Path

from emacs_radio_resolver import ResolveError, is_cnr_stream, resolve_url, stable_url

_REAL_POPEN = subprocess.Popen
_REAL_CSV_NEXT = csv.DictReader.__next__
_REAL_CSV_WRITE = csv.DictWriter.writerow


def _rewrite_command(command):
    if not isinstance(command, (list, tuple)):
        return command
    new = list(command)
    for index, value in enumerate(new):
        if isinstance(value, str) and is_cnr_stream(value):
            try:
                new[index] = resolve_url(stable_url(value))
            except ResolveError as exc:
                raise OSError(f"emacs-radio stream resolver: {exc}") from exc
    return tuple(new) if isinstance(command, tuple) else new


def _popen(args, *pargs, **kwargs):
    return _REAL_POPEN(_rewrite_command(args), *pargs, **kwargs)


def _csv_next(self):
    row = _REAL_CSV_NEXT(self)
    if isinstance(row, dict) and isinstance(row.get('URL'), str):
        row['URL'] = stable_url(row['URL'])
    return row


def _csv_write(self, rowdict):
    if isinstance(rowdict, dict) and isinstance(rowdict.get('URL'), str):
        rowdict = dict(rowdict, URL=stable_url(rowdict['URL']))
    return _REAL_CSV_WRITE(self, rowdict)


def main(argv=None):
    args = list(sys.argv[1:] if argv is None else argv)
    if '--' not in args:
        raise SystemExit('Expected -- between --original and scanner arguments')
    sep = args.index('--')
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--original', required=True)
    parsed = p.parse_args(args[:sep])
    path = Path(parsed.original).expanduser().resolve()
    if not path.is_file():
        raise SystemExit(f'Scanner does not exist: {path}')
    if path.name == Path(__file__).name:
        raise SystemExit('Refusing to invoke scanner wrapper recursively')
    subprocess.Popen = _popen
    csv.DictReader.__next__ = _csv_next
    csv.DictWriter.writerow = _csv_write
    sys.argv = [str(path), *args[sep + 1:]]
    # Keep original scanner import semantics and normal __main__ entrypoint.
    sys.path.insert(0, str(path.parent))
    runpy.run_path(str(path), run_name='__main__')


if __name__ == '__main__':
    main()
