# Emacs Radio

Standalone Emacs package for Internet radio: TSV source → asynchronous FFmpeg probing → playable cache → Helm station search → mpv streaming → mode-line playback status.

## Dependencies

- Emacs 27.1+ with `helm` installed (`M-x package-install RET helm RET`, or Spacemacs `helm` layer)
- Python 3 (standard library only)
- `ffmpeg` and `mpv`: `sudo apt install ffmpeg mpv`

## Install

Keep `emacs-radio.el` and `emacs-radio-probe.py` in the same directory; `radio_sources.tsv` may be elsewhere.

```elisp
(add-to-list 'load-path "~/github/emacs-radio/")
(require 'emacs-radio)
(setq emacs-radio-sources-file "~/github/emacs-radio/radio_sources.tsv")
(setq emacs-radio-cache-directory "~/.emacs.d/emacs-radio-cache/")
(emacs-radio-mode 1)

;; Optional shortcuts (Spacemacs leader bindings can be configured instead)
(global-set-key (kbd "C-c r r") #'emacs-radio)
(global-set-key (kbd "C-c r s") #'emacs-radio-scan)
(global-set-key (kbd "C-c r SPC") #'emacs-radio-toggle-pause)
(global-set-key (kbd "C-c r q") #'emacs-radio-stop)
```

First run `M-x emacs-radio-scan`. The scan runs **asynchronously**; use `M-x emacs-radio-scan-log` to view progress. On success the cache directory contains:

- `radio_results.csv`: all tested stations and statuses/error reasons
- `radio_playable.tsv`: **only FFmpeg-decodable stations**
- `radio_playable.m3u`: corresponding player playlist

Subsequently run `M-x emacs-radio` (or `C-c r r`) to Helm-search the verified list. Cache is loaded upon initialization; re-run scan only when needed. Stream URLs frequently change; regional CDN restrictions may cause failure.

The global mode line shows `[Radio … Station]` while connecting, `[Radio ▶ Station]` while the mpv process is running, and `[Radio ⏸ Station]` when paused. **Left-click the radio indicator** to pause/resume (mouse-1). **After `emacs-radio-stop`, the indicator disappears entirely** until a station starts again. `▶` means mpv is running, not independent proof audio output is audible. Inspect buffer ` *emacs-radio-mpv*` for errors.

`C-c r SPC` toggles pause through mpv's Unix-domain JSON IPC socket. `emacs-radio-stop` terminates the player. This IPC approach is intended for Unix/Linux, such as Debian.

## Notes

- Source file should contain tab-separated columns `分类`, `电台`, `URL` in that order.
- The scan does not modify the original source TSV.
- To change timeout/parallelism, customize `emacs-radio-probe-timeout` and `emacs-radio-probe-workers`.
- The Python scan is based on the supplied `check_radios.py` and checks whether FFmpeg can actually decode 2 seconds of audio, not just receive HTTP 200.
- The mode-line indicator is added to `global-mode-string`, so it can be displayed in every buffer using standard mode-line settings. Themes with custom mode-line layouts may need to include `global-mode-string`.

## Upgrade (v0.2.0)

Replace the old `emacs-radio.el` with the new version, then restart Emacs or run `M-x load-file` on it. If an existing minor mode is already enabled, `M-x emacs-radio-mode` twice toggles it off/on. Mouse interaction uses text properties (`local-map`, `mouse-face` and `help-echo`) on the mode-line string. The indicator is absent when no station is active. Comments are included in each Elisp function explaining implementation choices.

## Upgrade (v0.3.0): usage ranking and deduplication

- Helm candidates now show `[play count]` and are sorted by **descending number of times selected**. Ties keep the order in `radio_playable.tsv`. For example, `[ 12] 山东 山东交通广播` comes before `[  2] 中央 中国之声`.
- One successful launch of an `mpv` process increments the count by one. Pause/resume and opening Helm without choosing a station do **not** increment it. Counts are keyed by **URL**, so if the station display name changes the count is retained. A launched mpv process does not prove audible audio output.
- Counts persist in `~/.emacs.d/emacs-radio-cache/radio_usage.tsv` by default, or `emacs-radio-usage-file` if customized. Scanning will not overwrite this file. Existing v0.2.0 caches continue to load; prior usage counts cannot be reconstructed, so all stations start at zero.
- Before FFmpeg probing, the Python scanner removes duplicate URLs (after stripping surrounding whitespace), keeping the **first** name/category for each URL. A station with multiple distinct backup URLs is still represented by multiple rows. Empty URLs are ignored. `radio_results.csv`, `radio_playable.tsv`, and `radio_playable.m3u` all contain one row per unique URL. An older duplicate-filled playable cache is also deduplicated in memory by Emacs when loaded.
- After replacing the package, restart Emacs, or evaluate `(emacs-radio-mode -1)` then reload `emacs-radio.el` and evaluate `(emacs-radio-mode 1)`. Run `M-x emacs-radio-scan` to regenerate a clean cache.
