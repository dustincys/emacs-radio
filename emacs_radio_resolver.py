#!/usr/bin/env python3
"""Resolve expiring CNR / CRI (CGTN Radio) HLS addresses for emacs-radio.

Public providers:
* CNR's ``POST https://apppc.cnr.cn/national`` gives signed CDN URLs for
  both ngcdn*.cnr.cn and sk.cri.cn, including 905/nhzs/am846.
* CGTN Radio's publicly published live-program catalog is a backup for CRI.
  It sometimes publishes *unsigned* HLS URLs (these are valid published URLs,
  not locally generated or guessed signatures).

The same ``resolve_url`` and ``stable_url`` functions are used by the scanner
and the mpv launcher.  Uses Python's standard library only.
"""
from __future__ import annotations

import json
import re
import threading
import time
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit
from urllib.request import Request, urlopen

CNR_API = "https://apppc.cnr.cn/national"
CGTN_API = ("https://radio.cgtn.com/downapiRES/radio/v1/live/detail/"
            "groupType1_id22.json")
_CNR_CDN = re.compile(r"ngcdn[0-9]+\.cnr\.cn\Z", re.IGNORECASE)
_CRI_HOST = "sk.cri.cn"
_SIGNATURE_FIELDS = frozenset(("key", "time"))
_CACHE_TTL_SECONDS = 40.0
_MAX_JSON_BYTES = 2 * 1024 * 1024
_LOCK = threading.Lock()
_CNR_CACHE = None
_CNR_CACHE_UNTIL = 0.0
_CGTN_CACHE = None
_CGTN_CACHE_UNTIL = 0.0
# Preserve cache attributes used by v0.5.0's callers/tests.
_CACHE = None
_CACHE_UNTIL = 0.0


class ResolveError(RuntimeError):
    """An eligible stream cannot currently be resolved via official sources."""


def is_cnr_stream(url: str) -> bool:
    """Whether URL is a CNR-CDN or CRI HLS stream eligible for resolution.

    Regional satellitepull.cnr.cn feeds and other radio hosts pass unchanged.
    """
    if not isinstance(url, str):
        return False
    parts = urlsplit(url.strip())
    hostname = (parts.hostname or "").lower()
    return (parts.scheme.lower() in ("http", "https")
            and (bool(_CNR_CDN.fullmatch(hostname)) or hostname == _CRI_HOST)
            and parts.path.lower().endswith(".m3u8"))


def stable_url(url: str) -> str:
    """Remove only expiring signature fields from supported radio URLs."""
    url = url.strip()
    if not is_cnr_stream(url):
        return url
    parts = urlsplit(url)
    kept = [(key, value) for key, value in
            parse_qsl(parts.query, keep_blank_values=True)
            if key.lower() not in _SIGNATURE_FIELDS]
    return urlunsplit((parts.scheme, parts.netloc, parts.path,
                       urlencode(kept), parts.fragment))


def redact_signed_urls(message: str) -> str:
    """Remove signed HLS parameters from diagnostics before printing/logging."""
    return re.sub(r"(https?://[^\s\"'<>?]+\.m3u8)\?[^\s\"'<>]*",
                  r"\1?[signed]", str(message))


def _is_signed_url(url: str) -> bool:
    if not is_cnr_stream(url) or urlsplit(url).scheme.lower() != "https":
        return False
    params = dict(parse_qsl(urlsplit(url).query, keep_blank_values=True))
    return bool(params.get("key") and params.get("time"))


def _read_json(request: Request, timeout: float) -> object:
    try:
        with urlopen(request, timeout=timeout) as response:
            raw = response.read(_MAX_JSON_BYTES + 1)
        if len(raw) > _MAX_JSON_BYTES:
            raise ResolveError("Official radio catalog exceeds safety limit")
        return json.loads(raw.decode("utf-8-sig"))
    except ResolveError:
        raise
    except (OSError, ValueError, UnicodeError) as exc:
        raise ResolveError("Official radio catalog request failed: "
                           + redact_signed_urls(str(exc))) from exc


def _station_entries(payload):
    data = payload.get("data") or {}
    if not isinstance(data, dict):
        raise ResolveError("CNR response has invalid data structure")
    categories = data.get("categories") or []
    if not isinstance(categories, list):
        raise ResolveError("CNR response has no categories list")
    for category in categories:
        if isinstance(category, dict):
            for station in (category.get("detail") or []):
                if isinstance(station, dict):
                    yield station


def _download_cnr_catalog(timeout: float):
    request = Request(CNR_API, data=b"{}", method="POST", headers={
        "Content-Type": "application/json; charset=utf-8",
        "Accept": "application/json",
        "User-Agent": "Mozilla/5.0 (compatible; emacs-radio/0.6)",
    })
    payload = _read_json(request, timeout)
    if (not isinstance(payload, dict)
            or str(payload.get("code")) != "200"):
        raise ResolveError("CNR API returned non-success response")
    by_path, by_name = {}, {}
    for station in _station_entries(payload):
        name = str(station.get("name") or "").strip()
        candidates = station.get("other_info11") or []
        if isinstance(candidates, dict):
            candidates = [candidates]
        if not isinstance(candidates, list):
            continue
        # Observed CNR API lists higher-quality stream at index 2.
        preferred = candidates[2:] + candidates[:2] if len(candidates) > 2 else candidates
        preferred_urls = []
        for item in preferred:
            candidate = item.get("url") if isinstance(item, dict) else None
            if not isinstance(candidate, str) or not _is_signed_url(candidate):
                continue
            preferred_urls.append(candidate)
            by_path.setdefault(urlsplit(candidate).path.lower(), candidate)
        if name and preferred_urls:
            by_name.setdefault(name, preferred_urls[0])
    if not by_path:
        raise ResolveError("CNR API has no signed HLS addresses")
    return by_path, by_name


def _catalog_cnr(*, timeout: float, refresh: bool):
    global _CNR_CACHE, _CNR_CACHE_UNTIL, _CACHE, _CACHE_UNTIL
    with _LOCK:
        if (not refresh and _CNR_CACHE is not None
                and time.monotonic() < _CNR_CACHE_UNTIL):
            return _CNR_CACHE
        catalog = _download_cnr_catalog(timeout)
        _CNR_CACHE = catalog
        _CNR_CACHE_UNTIL = time.monotonic() + _CACHE_TTL_SECONDS
        _CACHE = catalog
        _CACHE_UNTIL = _CNR_CACHE_UNTIL
        return catalog


def _all_strings(node):
    """Yield string values in the CGTN catalog without assuming its schema."""
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for value in node.values():
            yield from _all_strings(value)
    elif isinstance(node, list):
        for value in node:
            yield from _all_strings(value)


_URL_PATTERN = re.compile(r"https?://[^\s\"'<>\\]+?\.m3u8(?:\?[^\s\"'<>\\]*)?",
                          re.IGNORECASE)


def _download_cgtn_catalog(timeout: float):
    # CGTN's public live catalog has been observed requested from its player.
    # Some entries use unsigned streams; these are returned unchanged rather
    # than fabricating a signature.
    request = Request(CGTN_API + "?timestamp=" + str(int(time.time() * 1000)),
                      headers={
                          "Accept": "application/json",
                          "User-Agent": "Mozilla/5.0 (compatible; emacs-radio/0.6)",
                      })
    payload = _read_json(request, timeout)
    if not isinstance(payload, (dict, list)):
        raise ResolveError("CGTN Radio catalog has an invalid JSON structure")
    candidates_by_path = {}
    for value in _all_strings(payload):
        for match in _URL_PATTERN.finditer(value):
            url = match.group(0).rstrip("),;]")
            if not is_cnr_stream(url) or urlsplit(url).hostname != _CRI_HOST:
                continue
            path = urlsplit(url).path.lower()
            candidates_by_path.setdefault(path, []).append(url)
    # Prefer signed links when CGTN does supply them, otherwise verified
    # URLs from its own catalog, and prefer HTTPS when equivalent.
    by_path = {}
    for path, urls in candidates_by_path.items():
        by_path[path] = sorted(
            urls, key=lambda url: (not _is_signed_url(url),
                                   urlsplit(url).scheme != "https"))[0]
    if not by_path:
        raise ResolveError("CGTN Radio catalog lists no CRI HLS addresses")
    return by_path


def _catalog_cgtn(*, timeout: float, refresh: bool):
    global _CGTN_CACHE, _CGTN_CACHE_UNTIL
    with _LOCK:
        if (not refresh and _CGTN_CACHE is not None
                and time.monotonic() < _CGTN_CACHE_UNTIL):
            return _CGTN_CACHE
        catalog = _download_cgtn_catalog(timeout)
        _CGTN_CACHE = catalog
        _CGTN_CACHE_UNTIL = time.monotonic() + _CACHE_TTL_SECONDS
        return catalog


def resolve_url(url: str, name: str = "", *, timeout: float = 8.0,
                refresh: bool = False) -> str:
    """Get a fresh HLS URL for CNR/CRI; pass all other stations unchanged.

    For CRI (sk.cri.cn), first request signed addresses from the public CNR
    API.  If that API is unavailable or the given station is missing, consult
    the official CGTN Radio live catalog.  Nothing falls back to an expired
    signed URL, nor do we invent key/time values.
    """
    if not is_cnr_stream(url):
        return url
    stable = stable_url(url)
    parts = urlsplit(stable)
    errors = []
    try:
        by_path, by_name = _catalog_cnr(timeout=timeout, refresh=refresh)
        match = by_path.get(parts.path.lower()) or by_name.get(name.strip())
        if match and urlsplit(match).path.lower() == parts.path.lower():
            return match
        # Preserve name fallback for legacy channel aliases only when there's
        # an explicit caller-supplied name: mirrors earlier resolver behavior.
        if match and name.strip() and not (parts.hostname == _CRI_HOST):
            return match
        errors.append("station not found in CNR catalog")
    except ResolveError as exc:
        errors.append(str(exc))

    if parts.hostname == _CRI_HOST:
        try:
            result = _catalog_cgtn(timeout=timeout, refresh=refresh).get(parts.path.lower())
            if result:
                return result
            errors.append("station not found in CGTN Radio catalog")
        except ResolveError as exc:
            errors.append(str(exc))
    label = name.strip() or parts.path
    raise ResolveError(f"Unable to resolve {label}: " + "; ".join(errors))


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url", help="Stable CNR/CRI HLS or ordinary stream URL")
    parser.add_argument("--name", default="", help="Optional station display name")
    parser.add_argument("--refresh", action="store_true", help="Bypass short-term cache")
    parser.add_argument("--timeout", type=float, default=8.0)
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")
    try:
        print(resolve_url(args.url, args.name,
                          refresh=args.refresh, timeout=args.timeout))
    except ResolveError as exc:
        parser.exit(2, f"emacs-radio: {redact_signed_urls(str(exc))}\n")
