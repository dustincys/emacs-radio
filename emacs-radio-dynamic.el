;;; emacs-radio-dynamic.el --- CNR / CGTN Radio URL support -*- lexical-binding: t; -*-
;; Optional adapter: do not edit the upstream emacs-radio.el or scanner.
(require 'cl-lib)

(defgroup emacs-radio-dynamic nil
  "Resolve expiring URLs before scanning or playing in emacs-radio."
  :group 'multimedia)

(defcustom emacs-radio-dynamic-python "python3"
  "Python executable used for URL resolving wrappers."
  :type 'string
  :group 'emacs-radio-dynamic)

(defvar emacs-radio-dynamic--directory
  (file-name-directory (or load-file-name buffer-file-name))
  "Folder containing dynamic URL helper programs.")

(defun emacs-radio-dynamic--file (name)
  "Return absolute helper path NAME."
  (expand-file-name name emacs-radio-dynamic--directory))

(defun emacs-radio-dynamic--signed-candidate-p (value)
  "Whether VALUE is a CNR or CRI/CGTN HLS radio URL."
  (and (stringp value)
       (string-match-p
        "\\`https?://\\(ngcdn[0-9]+\\.cnr\\.cn\\|sk\\.cri\\.cn\\)/.*\\.m3u8\\([?#].*\\)?\\'"
        value)))

(defun emacs-radio-dynamic--python-p (program)
  "Return whether PROGRAM is a Python executable."
  (and (stringp program)
       (string-match-p "\\`python\\([0-9.]*\\)?\\'"
                       (file-name-nondirectory program))))

(defun emacs-radio-dynamic--command (command)
  "Rewrite COMMAND for signed playback/scanning, leaving others untouched."
  (if (not (and (consp command) (stringp (car command))))
      command
    (let* ((program (car command))
           (args (cdr command))
           (exe (file-name-nondirectory program))
           (stream-pos (cl-position-if #'emacs-radio-dynamic--signed-candidate-p args))
           (scan-pos
            (and (emacs-radio-dynamic--python-p program)
                 (cl-position-if
                  (lambda (part)
                    (and (stringp part)
                         (string= (file-name-nondirectory part)
                                  "emacs-radio-probe.py")))
                  args))))
      (cond
       ;; Only intercept a signed CNR stream; other mpv uses are unchanged.
       ((and (string= exe "mpv") stream-pos)
        (let* ((url (nth stream-pos args))
               (other (cl-remove-if
                       (lambda (arg) (equal arg url)) args))
               ;; Remove an optional end-of-options marker from original
               ;; arguments: the wrapper supplies its own -- marker.
               (other (if (equal (car (last other)) "--")
                          (butlast other) other)))
          (append
           (list emacs-radio-dynamic-python
                 (emacs-radio-dynamic--file "emacs-radio-play.py")
                 "--url" url "--mpv" program "--")
           other)))
       ((and scan-pos (file-readable-p (emacs-radio-dynamic--file "emacs-radio-scan.py")))
        (append
         (list program (emacs-radio-dynamic--file "emacs-radio-scan.py")
               "--original" (nth scan-pos args) "--")
         (cl-loop for arg in args for i from 0
                  unless (= i scan-pos) collect arg)))
       (t command)))))

(defun emacs-radio-dynamic--make-process (original &rest properties)
  "Advise ORIGINAL make-process with modified command in PROPERTIES."
  (let ((command (plist-get properties :command)))
    (when command
      (setq properties (plist-put properties :command
                                 (emacs-radio-dynamic--command command))))
    (apply original properties)))

(defun emacs-radio-dynamic--start-process
    (original name buffer program &rest args)
  "Advise ORIGINAL start-process, retaining NAME and BUFFER."
  (let ((command (emacs-radio-dynamic--command (cons program args))))
    (apply original name buffer (car command) (cdr command))))

;;;###autoload
(defun emacs-radio-dynamic-enable ()
  "Enable transparent fresh-URL resolution for emacs-radio.
Intercepts only CNR/CRI/CGTN mpv URLs and emacs-radio-probe.py invocations."
  (interactive)
  (dolist (file '("emacs-radio-play.py" "emacs-radio-scan.py"
                  "emacs_radio_resolver.py"))
    (unless (file-readable-p (emacs-radio-dynamic--file file))
      (user-error "Missing emacs-radio helper: %s" file)))
  (unless (executable-find emacs-radio-dynamic-python)
    (user-error "Python not found: %s" emacs-radio-dynamic-python))
  (unless (advice-member-p #'emacs-radio-dynamic--make-process 'make-process)
    (advice-add 'make-process :around #'emacs-radio-dynamic--make-process))
  (unless (advice-member-p #'emacs-radio-dynamic--start-process 'start-process)
    (advice-add 'start-process :around #'emacs-radio-dynamic--start-process))
  (message "emacs-radio dynamic URL adapter enabled"))

;;;###autoload
(defun emacs-radio-dynamic-disable ()
  "Disable dynamic stream URL process adapters."
  (interactive)
  (advice-remove 'make-process #'emacs-radio-dynamic--make-process)
  (advice-remove 'start-process #'emacs-radio-dynamic--start-process))

(provide 'emacs-radio-dynamic)
;;; emacs-radio-dynamic.el ends here
