#!/usr/bin/env python3
"""并发检测网络广播：基于实际解码的 PCM 音频判断可播放性。"""
import argparse
import csv
import os
import shutil
import subprocess
import tempfile
import time
import wave
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

COLUMNS = ('分类', '电台', 'URL')
RATE = 8000
CHANNELS = 1
BYTES_PER_SAMPLE = 2


def atomic_write(destination, writer):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix='.radio-', dir=destination.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as file:
            writer(file)
        os.replace(tmp, destination)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def atomic_backup(source, destination):
    def writer(output):
        with source.open('r', encoding='utf-8', newline='') as original:
            shutil.copyfileobj(original, output)
    atomic_write(destination, writer)


def read_and_deduplicate(source, parser):
    with source.open('r', encoding='utf-8-sig', newline='') as file:
        reader = csv.DictReader(file, delimiter='\t')
        if not reader.fieldnames or not set(COLUMNS).issubset(reader.fieldnames):
            parser.error('TSV must contain columns: 分类, 电台, URL')
        input_rows = list(reader)
    if not input_rows:
        parser.error('TSV has no station entries')
    seen, unique = set(), []
    for row in input_rows:
        url = (row.get('URL') or '').strip()
        if not url or url in seen:
            continue
        seen.add(url)
        unique.append({key: (row.get(key) or '').strip() for key in COLUMNS})
    print(f'Input: {len(input_rows)} rows; unique URLs: {len(unique)}; '
          f'duplicates/empty URLs skipped: {len(input_rows) - len(unique)}', flush=True)
    return unique


def classify_error(info, timed_out):
    lower = info.lower()
    if '403' in lower or '401' in lower or 'server returned 403' in lower:
        return 'DENIED'
    if '404' in lower:
        return 'NOT_FOUND'
    if any(word in lower for word in ('resolve', 'dns', 'name or service not known')):
        return 'DNS_ERROR'
    return 'TIMEOUT' if timed_out else 'FAILED'


def probe_once(url, timeout, sample_seconds, min_seconds):
    # Only decode the first audio stream, ignore video output completely.
    # The short PCM output is bounded (8kHz * mono * 16bit * sample_seconds).
    command = [
        'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'warning',
        '-rw_timeout', str(int(timeout * 1_000_000)),
        '-analyzeduration', '3000000', '-probesize', '5000000',
        '-i', url,
        '-map', '0:a:0', '-vn', '-sn', '-dn',
        '-t', str(sample_seconds),
        '-ac', str(CHANNELS), '-ar', str(RATE),
        '-f', 's16le', '-acodec', 'pcm_s16le', 'pipe:1',
    ]
    timed_out = False
    try:
        completed = subprocess.run(command, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, timeout=timeout,
                                   check=False)
        pcm = completed.stdout or b''
        diagnostics = completed.stderr or b''
        code = completed.returncode
    except subprocess.TimeoutExpired as exc:
        timed_out = True
        pcm = exc.stdout or b''
        diagnostics = exc.stderr or b''
        code = None
    except OSError as exc:
        return {'状态': 'FAILED', '音频秒数': '0.00',
                '返回码': '', '信息': str(exc)[:300]}

    audio_seconds = len(pcm) / (RATE * CHANNELS * BYTES_PER_SAMPLE)
    info = diagnostics.decode('utf-8', errors='replace').replace('\r', ' ').replace('\n', ' ')[:300]
    if audio_seconds >= min_seconds:
        # Valid PCM received, even if broken HLS timestamps later produce errors.
        status = 'PLAYABLE'
    else:
        status = classify_error(info, timed_out)
    return {'状态': status, '音频秒数': f'{audio_seconds:.2f}',
            '返回码': '' if code is None else str(code), '信息': info}


def probe_mpv(url, timeout, sample_seconds, min_seconds):
    """mpv fallback: disable video and capture actual decoded WAV audio."""
    if shutil.which('mpv') is None:
        return {'状态': 'FAILED', '音频秒数': '0.00', '返回码': '',
                '信息': 'mpv not installed (needed for fallback)', '检测器': 'mpv'}
    with tempfile.TemporaryDirectory(prefix='radio-mpv-') as tmpdir:
        output = Path(tmpdir) / 'probe.wav'
        cmd = [
            'mpv', '--no-config', '--no-terminal', '--no-video', '--vid=no',
            '--msg-level=all=error', '--cache=yes',
            '--audio-samplerate=8000', '--audio-channels=mono',
            '--audio-format=s16', '--ao=pcm', f'--ao-pcm-file={output}',
            f'--length={sample_seconds}', url,
        ]
        timed_out = False
        try:
            cp = subprocess.run(cmd, capture_output=True, timeout=timeout,
                                check=False)
            diagnostics = cp.stderr or b''
            code = cp.returncode
        except subprocess.TimeoutExpired as exc:
            timed_out = True
            diagnostics = exc.stderr or b''
            code = None
        except OSError as exc:
            return {'状态': 'FAILED', '音频秒数': '0.00', '返回码': '',
                    '信息': str(exc)[:300], '检测器': 'mpv'}

        seconds = 0.0
        if output.is_file():
            try:
                with wave.open(str(output), 'rb') as wav:
                    seconds = min(wav.getnframes(), max(0, output.stat().st_size - 44) // max(1, wav.getnchannels() * wav.getsampwidth())) / wav.getframerate()
            except (wave.Error, EOFError, OSError, ZeroDivisionError):
                # Incomplete WAV header after timeout: use the output size as a
                # conservative estimate, since we requested 8kHz mono s16.
                seconds = max(0, output.stat().st_size - 44) / 16000
        info = diagnostics.decode('utf-8', 'replace').replace('\r', ' ').replace('\n', ' ')[:300]
        status = 'PLAYABLE' if seconds >= min_seconds else classify_error(info, timed_out)
        return {'状态': status, '音频秒数': f'{seconds:.2f}',
                '返回码': '' if code is None else str(code),
                '信息': info, '检测器': 'mpv'}


def check_stream(row, args):
    last = None
    engines = (['mpv'] if args.engine == 'mpv'
               else ['ffmpeg'] if args.engine == 'ffmpeg'
               else ['mpv', 'ffmpeg'])
    attempts = 0
    for engine in engines:
        for attempt in range(1, args.retries + 2):
            attempts += 1
            if engine == 'mpv':
                last = probe_mpv(row['URL'], args.timeout, args.sample_seconds,
                                 args.min_seconds)
            else:
                last = probe_once(row['URL'], args.timeout, args.sample_seconds,
                                  args.min_seconds)
                last['检测器'] = 'ffmpeg'
            if last['状态'] == 'PLAYABLE':
                return {**row, **last, '尝试次数': str(attempts)}
            if attempt <= args.retries:
                time.sleep(min(attempt, 2))
    return {**row, **last, '尝试次数': str(attempts)}


def write_stations(file, rows):
    writer = csv.DictWriter(file, fieldnames=COLUMNS, delimiter='\t',
                            extrasaction='ignore')
    writer.writeheader()
    writer.writerows(rows)


def write_results(file, rows):
    writer = csv.DictWriter(file,
                            fieldnames=[*COLUMNS, '状态', '音频秒数', '返回码', '尝试次数', '检测器', '信息'],
                            extrasaction='ignore')
    writer.writeheader()
    writer.writerows(rows)


def write_m3u(file, rows):
    file.write('#EXTM3U\n')
    for row in rows:
        category = row['分类'].replace('"', '').replace('\r', ' ').replace('\n', ' ')
        name = row['电台'].replace('\r', ' ').replace('\n', ' ')
        url = row['URL'].replace('\r', '').replace('\n', '')
        file.write(f'#EXTINF:-1 group-title="{category}",{name}\n{url}\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, help='原始电台 TSV')
    parser.add_argument('--output-dir', required=True, help='缓存目录')
    parser.add_argument('--timeout', type=float, default=30, help='单次尝试的总超时秒数 (默认30)')
    parser.add_argument('--workers', type=int, default=8, help='并行检测数量')
    parser.add_argument('--engine', choices=['auto', 'ffmpeg', 'mpv'], default='auto',
                        help='auto: mpv first, then FFmpeg; mpv: only mpv')
    parser.add_argument('--retries', type=int, default=2, help='失败重试次数')
    parser.add_argument('--sample-seconds', type=float, default=2.0,
                        help='最多解码多少秒音频（默认2）')
    parser.add_argument('--min-seconds', type=float, default=0.5,
                        help='判为可播放所需的最短有效音频秒数')
    parser.add_argument('--no-write-back', action='store_true', help='不覆盖源文件')
    parser.add_argument('--allow-empty', action='store_true', help='允许空结果覆盖源文件（不推荐）')
    args = parser.parse_args()
    if args.engine in ('auto', 'mpv') and shutil.which('mpv') is None:
        parser.error('mpv not found')
    if args.engine in ('auto', 'ffmpeg') and shutil.which('ffmpeg') is None:
        parser.error('ffmpeg not found')
    if (args.workers < 1 or args.timeout <= 0 or args.retries < 0 or
        args.min_seconds <= 0 or args.sample_seconds < args.min_seconds):
        parser.error('Invalid workers/timeout/retries/sample-seconds/min-seconds')
    source = Path(args.input).expanduser().resolve()
    outdir = Path(args.output_dir).expanduser().resolve()
    if not source.is_file():
        parser.error(f'Source TSV not found: {source}')
    rows = read_and_deduplicate(source, parser)
    results = [None] * len(rows)
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(check_stream, row, args): index
                   for index, row in enumerate(rows)}
        for future in as_completed(futures):
            index = futures[future]
            result = future.result()
            results[index] = result
            print(f"{result['状态']:<10} {result['音频秒数']:>5}s "
                  f"try={result['尝试次数']} via={result['检测器']} {result['分类']} {result['电台']}", flush=True)
    playable = [row for row in results if row['状态'] == 'PLAYABLE']
    atomic_write(outdir / 'radio_results.csv', lambda f: write_results(f, results))
    # Preserve the last known-good playlist on a completely failed scan.
    # A failed network check must not erase the Helm station selection.
    if playable:
        atomic_write(outdir / 'radio_playable.tsv', lambda f: write_stations(f, playable))
        atomic_write(outdir / 'radio_playable.m3u', lambda f: write_m3u(f, playable))
    else:
        print('WARNING: zero playable stations; retaining previous cache', flush=True)
    print(f'Playable: {len(playable)}/{len(results)} unique streams', flush=True)
    print(f'Cache directory: {outdir}', flush=True)
    if not playable:
        return
    if args.no_write_back:
        print('Source TSV unchanged (--no-write-back).', flush=True)
    elif not playable and not args.allow_empty:
        print('WARNING: No PLAYABLE streams; source TSV NOT modified.', flush=True)
    else:
        backup = source.with_name(source.name + '.bak')
        atomic_backup(source, backup)
        atomic_write(source, lambda f: write_stations(f, playable))
        print(f'Backup: {backup}', flush=True)
        print(f'Updated source TSV: {source}', flush=True)

if __name__ == '__main__':
    main()
