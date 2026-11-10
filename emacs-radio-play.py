#!/usr/bin/env python3
"""Resolve a station on every play, then replace this process with mpv.

Example:
  python3 emacs-radio-play.py --url 'https://ngcdn001.cnr.cn/live/zgzs/index.m3u8' \
      --name '中国之声' --mpv mpv -- --no-video --no-terminal

The PID stays the same across os.execvp(), preserving Emacs process sentinel,
mode-line, waveform collection and the mpv Unix IPC socket.
"""
import argparse
import os
import sys

from emacs_radio_resolver import ResolveError, resolve_url


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    if "--" not in argv:
        raise SystemExit("Expected '--' before mpv arguments")
    index = argv.index("--")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True)
    parser.add_argument("--name", default="")
    parser.add_argument("--mpv", default="mpv")
    parser.add_argument("--resolve-timeout", type=float, default=8)
    args = parser.parse_args(argv[:index])
    options = argv[index + 1:]
    if args.resolve_timeout <= 0:
        parser.error("--resolve-timeout must be positive")
    try:
        resolved = resolve_url(args.url, args.name, timeout=args.resolve_timeout)
    except ResolveError as exc:
        # Do not leak signed tokens in error messages or logs.
        raise SystemExit(f"emacs-radio: URL resolution failed: {exc}") from exc
    command = [args.mpv, *options, "--", resolved]
    try:
        os.execvp(args.mpv, command)
    except OSError as exc:
        raise SystemExit(f"emacs-radio: unable to start mpv: {exc}") from exc


if __name__ == "__main__":
    main()
