#!/usr/bin/env python3
"""使用 FFmpeg 检测网络电台，生成缓存，并可将可播放电台写回原 TSV。"""

import argparse
import csv
import os
import shutil
import subprocess
import tempfile
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path

COLUMNS = ('分类', '电台', 'URL')


def atomic_write(destination, writer):
    """同目录创建临时文件，写入成功后使用 os.replace 原子替换。"""
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
    """安全创建源文件的备份，不直接在最终备份路径上写入。"""
    def writer(output):
        with open(source, 'r', encoding='utf-8', newline='') as original:
            shutil.copyfileobj(original, output)
    atomic_write(destination, writer)


def read_and_deduplicate(source, parser):
    """读取 TSV 并按清理首尾空格后的 URL 去重，保留第一次出现的记录。"""
    with source.open('r', encoding='utf-8-sig', newline='') as file:
        reader = csv.DictReader(file, delimiter='\t')
        if not reader.fieldnames or not set(COLUMNS).issubset(reader.fieldnames):
            parser.error('TSV must contain columns: 分类, 电台, URL')
        input_rows = list(reader)

    if not input_rows:
        parser.error('TSV has no station entries')

    seen = set()
    unique = []
    for row in input_rows:
        url = (row.get('URL') or '').strip()
        if not url or url in seen:
            continue
        seen.add(url)
        # 固定导出三列，避免原文件中其他列导致 DictWriter 报错。
        unique.append({key: (row.get(key) or '').strip() for key in COLUMNS})

    print(f'Input: {len(input_rows)} rows; unique URLs: {len(unique)}; '
          f'duplicates/empty URLs skipped: {len(input_rows) - len(unique)}',
          flush=True)
    return unique


def check_stream(row, timeout):
    """使用 FFmpeg 解码两秒音频，只有退出码为 0 才认定可播放。"""
    command = [
        'ffmpeg', '-nostdin', '-hide_banner', '-loglevel', 'error',
        '-rw_timeout', str(timeout * 1_000_000),
        '-i', row['URL'], '-map', '0:a:0', '-t', '2', '-f', 'null', '-'
    ]
    try:
        result = subprocess.run(
            command, capture_output=True, text=True,
            timeout=timeout + 2, check=False
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


def write_stations(file, rows):
    """按 Emacs Radio 使用的三列 TSV 格式输出电台列表。"""
    writer = csv.DictWriter(file, fieldnames=COLUMNS, delimiter='\t',
                            extrasaction='ignore')
    writer.writeheader()
    writer.writerows(rows)


def write_results(file, rows):
    """输出全部去重后的检测结果 CSV，便于查找失败原因。"""
    writer = csv.DictWriter(file, fieldnames=[*COLUMNS, '状态', '信息'],
                            extrasaction='ignore')
    writer.writeheader()
    writer.writerows(rows)


def write_m3u(file, rows):
    """为已通过检测的电台生成标准 M3U 播放列表。"""
    file.write('#EXTM3U\n')
    for row in rows:
        category = row['分类'].replace('"', '').replace('\r', ' ').replace('\n', ' ')
        name = row['电台'].replace('\r', ' ').replace('\n', ' ')
        file.write(f'#EXTINF:-1 group-title="{category}",{name}\n{row["URL"]}\n')


def main():
    """解析参数、并发检测、输出缓存，最后可选择备份并覆盖源 TSV。"""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', required=True, help='电台原始 TSV 路径')
    parser.add_argument('--output-dir', required=True, help='缓存目录')
    parser.add_argument('--timeout', type=int, default=18, help='每个电台超时秒数')
    parser.add_argument('--workers', type=int, default=8, help='并发检测数量')
    parser.add_argument('--no-write-back', action='store_true',
                        help='仅生成缓存，不覆盖原始 TSV')
    parser.add_argument('--allow-empty', action='store_true',
                        help='允许零个可播放结果时覆盖源 TSV（不推荐）')
    args = parser.parse_args()

    if shutil.which('ffmpeg') is None:
        parser.error('ffmpeg not found: install ffmpeg first')
    if args.workers < 1 or args.timeout < 1:
        parser.error('--workers and --timeout must be positive')

    source_path = Path(args.input).expanduser().resolve()
    outdir = Path(args.output_dir).expanduser().resolve()
    if not source_path.is_file():
        parser.error(f'Source TSV not found: {source_path}')

    rows = read_and_deduplicate(source_path, parser)
    results = [None] * len(rows)

    # future -> 原顺序索引：并发返回顺序可能改变，用索引还原 TSV 排列。
    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(check_stream, row, args.timeout): i
                   for i, row in enumerate(rows)}
        for future in as_completed(futures):
            index = futures[future]
            result = future.result()
            results[index] = result
            print(f"{result['状态']:<10} {result['分类']:<8} {result['电台']}",
                  flush=True)

    playable = [row for row in results if row['状态'] == 'PLAYABLE']

    # 始终保存报告和两个播放缓存，即使没有任何可播放流。
    atomic_write(outdir / 'radio_results.csv', lambda f: write_results(f, results))
    atomic_write(outdir / 'radio_playable.tsv', lambda f: write_stations(f, playable))
    atomic_write(outdir / 'radio_playable.m3u', lambda f: write_m3u(f, playable))
    print(f'Playable: {len(playable)}/{len(results)} unique streams', flush=True)
    print(f'Cache directory: {outdir}', flush=True)

    if args.no_write_back:
        print('Source TSV unchanged (--no-write-back).', flush=True)
    elif not playable and not args.allow_empty:
        print('WARNING: No PLAYABLE streams; source TSV NOT modified.', flush=True)
    else:
        backup = source_path.with_name(source_path.name + '.bak')
        # 先安全写出备份，备份失败则不允许覆盖原文件。
        atomic_backup(source_path, backup)
        atomic_write(source_path, lambda f: write_stations(f, playable))
        print(f'Backup: {backup}', flush=True)
        print(f'Updated source TSV: {source_path}', flush=True)


if __name__ == '__main__':
    main()
