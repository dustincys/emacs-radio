;;; emacs-radio-scan-upgrade.el --- Improved audio-only probing -*- lexical-binding: t; -*-
;; Load AFTER emacs-radio.el.  This overrides only `emacs-radio-scan'.
(require 'emacs-radio)

(defgroup emacs-radio-scan-upgrade nil
  "Reliable audio-only radio scanning."
  :group 'emacs-radio)

(defcustom emacs-radio-scan-engine "auto"
  "Probe engine: auto tries mpv first, then FFmpeg."
  :type '(choice (const "auto") (const "mpv") (const "ffmpeg"))
  :group 'emacs-radio-scan-upgrade)

(defcustom emacs-radio-scan-retries 1
  "Extra attempts for each engine."
  :type 'natnum :group 'emacs-radio-scan-upgrade)

(defcustom emacs-radio-scan-sample-seconds 2.0
  "Amount of audio decoded during testing."
  :type 'number :group 'emacs-radio-scan-upgrade)

(defcustom emacs-radio-scan-min-seconds 0.5
  "Minimum PCM audio duration needed for a positive result."
  :type 'number :group 'emacs-radio-scan-upgrade)

;;;###autoload
(defun emacs-radio-scan ()
  "Asynchronously scan stations using audio-only mpv/FFmpeg probes.
Keep source TSV intact and preserve cache if the scan finds no playable streams."
  (interactive)
  (when (process-live-p emacs-radio--scan-process)
    (user-error "A radio scan is already running"))
  (unless (file-readable-p emacs-radio-sources-file)
    (user-error "Cannot read radio sources: %s" emacs-radio-sources-file))
  (unless (executable-find emacs-radio-python-program)
    (user-error "Python not found: %s" emacs-radio-python-program))
  (when (member emacs-radio-scan-engine '("auto" "mpv"))
    (unless (executable-find "mpv")
      (user-error "mpv not found")))
  (when (member emacs-radio-scan-engine '("auto" "ffmpeg"))
    (unless (executable-find "ffmpeg")
      (user-error "FFmpeg not found")))
  (let ((script (emacs-radio--probe-script)))
    (unless (and script (file-readable-p script))
      (user-error "Cannot read scanner: %s" script))
    (make-directory emacs-radio-cache-directory t)
    (with-current-buffer (get-buffer-create emacs-radio--scan-buffer)
      (erase-buffer))
    (setq emacs-radio--scan-process
          (make-process
           :name "emacs-radio-scan"
           :buffer (get-buffer-create emacs-radio--scan-buffer)
           :command (list emacs-radio-python-program script
                          "--input" (expand-file-name emacs-radio-sources-file)
                          "--output-dir" (expand-file-name emacs-radio-cache-directory)
                          "--timeout" (number-to-string emacs-radio-probe-timeout)
                          "--workers" (number-to-string emacs-radio-probe-workers)
                          "--engine" emacs-radio-scan-engine
                          "--retries" (number-to-string emacs-radio-scan-retries)
                          "--sample-seconds" (number-to-string emacs-radio-scan-sample-seconds)
                          "--min-seconds" (number-to-string emacs-radio-scan-min-seconds)
                          "--no-write-back")
           :noquery t
           :sentinel (lambda (proc _event)
                       (when (and (eq proc emacs-radio--scan-process)
                                  (memq (process-status proc) '(exit signal)))
                         (if (and (eq (process-status proc) 'exit)
                                  (zerop (process-exit-status proc)))
                             (progn
                               (emacs-radio-load)
                               (message "Radio scan completed: %d in cache (details: M-x emacs-radio-scan-log)"
                                        (length emacs-radio--stations)))
                           (message "Radio scan failed: M-x emacs-radio-scan-log"))))))
    (message "Radio scan started asynchronously; M-x emacs-radio-scan-log")))

(provide 'emacs-radio-scan-upgrade)
;;; emacs-radio-scan-upgrade.el ends here
