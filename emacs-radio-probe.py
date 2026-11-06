#!/usr/bin/env python3
"""Probe radio streams using FFmpeg and atomically write cache files.

Compatible with radio_sources.tsv columns: 分类, 电台, URL.
"""
import argparse
import csv
import os
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path


def atomic_write(destination, writer):
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.radio-', dir=destination.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as f:
            writer(f)
        os.replace(tmp, destination)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--input', required=True)
    parser.add_argument('--output-dir', required=True)
    parser.add_argument('--timeout', type=int, default=18)
    parser.add_argument('--workers', type=int, default=8)
    args = parser.parse_args()

    if shutil.which('ffmpeg') is None:
        parser.error('ffmpeg not found: install ffmpeg first')
    if args.workers < 1 or args.timeout < 1:
        parser.error('--workers and --timeout must be positive')

    with open(args.input, encoding='utf-8-sig', newline='') as source:
        rows = list(csv.DictReader(source, delimiter='\t'))
    for key in ('分类', '电台', 'URL'):
        if not rows or key not in rows[0]:
            parser.error('TSV must have columns: 分类, 电台, URL and at least one entry')

    # Deduplicate on stripped stream URL before scheduling FFmpeg. The first
    # matching row wins, so category/name stay predictable in exported files.
    # Distinct URLs for the same station remain as independent backup sources.
    original_count = len(rows)
    seen_urls = set()
    unique_rows = []
    for row in rows:
        url = row['URL'].strip()
        if not url or url in seen_urls:
            continue
        seen_urls.add(url)
        row['URL'] = url
        unique_rows.append(row)
    rows = unique_rows
    print(f'Input: {original_count} rows; unique URLs: {len(rows)}; '
          f'duplicates/empty URLs skipped: {original_count - len(rows)}', flush=True)

    def check(row):
        command = [
            'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
            '-rw_timeout', str(args.timeout * 1000000),
            '-i', row['URL'], '-map', '0:a:0', '-t', '2', '-f', 'null', '-'
        ]
        try:
            result = subprocess.run(
                command, capture_output=True, text=True,
                timeout=args.timeout + 2, check=False
            )
            info = result.stderr.strip().replace('\r', ' ').replace('\n', ' ')[:200]
            if result.returncode == 0:
                status = 'PLAYABLE'
            elif '403' in info or '401' in info:
                status = 'DENIED'
            elif '404' in info:
                status = 'NOT_FOUND'
            elif 'resolve' in info.lower() or 'dns' in info.lower():
                status = 'DNS_ERROR'
            else:
                status = 'FAILED'
        except subprocess.TimeoutExpired:
            status, info = 'TIMEOUT', 'probe timed out'
        except OSError as exc:
            status, info = 'FAILED', str(exc)
        return {**row, '状态': status, '信息': info.replace('\t', ' ')}

    results = [None] * len(rows)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(check, row): i for i, row in enumerate(rows)}
        for future in as_completed(futures):
            index = futures[future]
            results[index] = future.result()
            r = results[index]
            print(f"{r['状态']:<10} {r['分类']:<8} {r['电台']}", flush=True)

    outdir = Path(args.output_dir).expanduser().resolve()
    playable = [r for r in results if r['状态'] == 'PLAYABLE']

    def write_results(f):
        writer = csv.DictWriter(f, fieldnames=['分类', '电台', 'URL', '状态', '信息'])
        writer.writeheader()
        writer.writerows(results)

    def write_tsv(f):
        writer = csv.DictWriter(f, fieldnames=['分类', '电台', 'URL'], delimiter='\t', extrasaction='ignore')
        writer.writeheader()
        writer.writerows(playable)

    def write_m3u(f):
        f.write('#EXTM3U\n')
        for row in playable:
            category = row['分类'].replace('"', '').replace('\n', ' ')
            name = row['电台'].replace('\n', ' ')
            f.write(f'#EXTINF:-1 group-title="{category}",{name}\n{row["URL"]}\n')

    atomic_write(outdir / 'radio_results.csv', write_results)
    atomic_write(outdir / 'radio_playable.tsv', write_tsv)
    atomic_write(outdir / 'radio_playable.m3u', write_m3u)
    print(f'Playable: {len(playable)}/{len(results)} unique streams', flush=True)
    print(f'Cache directory: {outdir}', flush=True)


if __name__ == '__main__':
    main()
