;;; emacs-radio-waveform-tests.el --- Tests for Emacs Radio waveform -*- lexical-binding: t; -*-
(require 'ert)
(require 'emacs-radio-waveform)

(ert-deftest emacs-radio-waveform/db-valid ()
  "MPV 的 RMS_level 字符串应能正常转换为 dBFS。"
  (should (= -22.5 (emacs-radio-waveform--db-from-reply
                    '((lavfi.astats.Overall.RMS_level . "-22.5")))))
  (should (= -60.0 (emacs-radio-waveform--db-from-reply
                    '((lavfi.astats.Overall.RMS_level . "-inf")))))
  (should-not (emacs-radio-waveform--db-from-reply nil))
  (should-not (emacs-radio-waveform--db-from-reply
               '((something-else . "-7")))))

(ert-deftest emacs-radio-waveform/path-is-continuous ()
  "小曲线至少包含 M/Q/L 三种合法片段。"
  (let ((path (emacs-radio-waveform--path '(-60.0 -30.0 -12.0 -40.0))))
    (should (string-prefix-p "M " path))
    (should (string-match-p " Q " path))
    (should (string-match-p " L " path))))

(ert-deftest emacs-radio-waveform/push-level-keeps-window ()
  "推入新 RMS 后只保留固定数量的样本。"
  (let ((emacs-radio-waveform-samples 4)
        (emacs-radio-waveform--levels '(-60.0 -60.0 -60.0 -60.0)))
    (cl-letf (((symbol-function 'emacs-radio-waveform--render) #'ignore)
              ((symbol-function 'emacs-radio--refresh-mode-line) #'ignore))
      (emacs-radio-waveform--push-db -10.0)
      (should (equal emacs-radio-waveform--levels
                     '(-60.0 -60.0 -60.0 -10.0))))))

(provide 'emacs-radio-waveform-tests)
;;; emacs-radio-waveform-tests.el ends here
