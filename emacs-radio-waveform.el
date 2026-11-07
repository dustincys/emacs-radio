;;; emacs-radio-waveform.el --- Real audio-level curve for Emacs Radio -*- lexical-binding: t; -*-

;; Version: 0.4.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: multimedia
;; URL: https://github.com/dustincys/emacs-radio

;;; Commentary:
;; 用 mpv 同一播放进程的 FFmpeg astats 滤镜读取真实音频 RMS（dBFS）。
;; 单独建立一条轻量、持续存在的 JSON IPC 连接，按固定间隔请求：
;;     ["get_property", "af-metadata/radio-meter"]
;; 最近一组真实 RMS 值 -> 曲线路径 -> 42×16 SVG -> Emacs Mode-line。
;; 注意：RMS 是“音量包络”，不是 PCM 逐采样正负振幅波形。
;; 不建立第二条电台网络连接，也不监视其他应用的声音。

;;; Code:
(require 'cl-lib)
(require 'json)
(require 'svg)

(defgroup emacs-radio-waveform nil
  "Emacs Radio 中的微型真实音量曲线。"
  :group 'emacs-radio
  :prefix "emacs-radio-waveform-")

(defcustom emacs-radio-waveform-enabled t
  "非 nil 时尝试从 mpv 获取真实 RMS，绘制 SVG 动态图标。"
  :type 'boolean)

(defcustom emacs-radio-waveform-interval 0.15
  "两次采样请求的最小间隔（秒），建议 0.1～0.3。"
  :type 'number)

(defcustom emacs-radio-waveform-width 42
  "微型音量曲线的宽度（像素）。"
  :type 'integer)

(defcustom emacs-radio-waveform-height 16
  "微型音量曲线的高度（像素）。"
  :type 'integer)

(defcustom emacs-radio-waveform-color "#65DFA3"
  "SVG 曲线的颜色。"
  :type 'string)

(defcustom emacs-radio-waveform-samples 12
  "曲线上保留多少个最近的音量测量值。"
  :type 'integer)

(defvar emacs-radio-waveform--timer nil "负责定时请求音量数据的计时器。")
(defvar emacs-radio-waveform--ipc nil "专用于音量测量的 mpv IPC 进程。")
(defvar emacs-radio-waveform--pending "" "尚未收到换行结尾的 JSON 响应片段。")
(defvar emacs-radio-waveform--awaiting nil "正在等待的请求编号，没有则为 nil。")
(defvar emacs-radio-waveform--sent-at nil "上一次请求的发送时间。")
(defvar emacs-radio-waveform--counter 0 "用于匹配 IPC 请求和响应的编号。")
(defvar emacs-radio-waveform--generation nil "曲线所属播放器代数，防止旧回调串台。")
(defvar emacs-radio-waveform--levels nil "最近的真实 RMS dBFS 测量值。")
(defvar emacs-radio-waveform--image nil "缓存的 SVG image，避免 Mode-line 重绘时重复生成。")
(defvar emacs-radio-waveform--last-db nil "最近一次读取到的真实 RMS dBFS 值。")
(defvar emacs-radio-waveform--last-error nil "最后一次 mpv 采样失败的原因。")
(defvar emacs-radio-waveform--last-update nil "最近一次成功读取音量的时间。")

;; 上游 emacs-radio.el 管理的状态；由播放器控制文件设置。
(defvar emacs-radio--state)
(defvar emacs-radio--player)
(defvar emacs-radio--ipc-socket)
(defvar emacs-radio--generation)
(declare-function emacs-radio--refresh-mode-line "emacs-radio")

(defun emacs-radio-waveform--count ()
  "将用户设置的样本数限制在 >=2，避免除零和空曲线。"
  (max 2 emacs-radio-waveform-samples))

(defun emacs-radio-waveform--flat ()
  "创建初始化曲线（-60 dBFS），用于静音、连接中和重置状态。"
  (make-list (emacs-radio-waveform--count) -60.0))

(defun emacs-radio-waveform--db-from-reply (data)
  "从 mpv 的 DATA 元数据中提取有效的 Overall RMS_level。
返回浮点 dBFS；当测得 -inf（静音）时用 -60.0 表示。
如果没有这个字段，则返回 nil，绝不捏造声音数据。"
  (let* ((raw (and (listp data)
                   (alist-get 'lavfi.astats.Overall.RMS_level data)))
         (value (cond ((numberp raw) raw)
                      ((and (stringp raw)
                            (string-match-p
                             "\\`[-+]?[0-9]+\\(\\.[0-9]+\\)?\\([eE][-+]?[0-9]+\\)?\\'"
                             raw))
                       (string-to-number raw))
                      ((and (stringp raw)
                            (string-match-p "\\`-\\(?:inf\\|Inf\\|Infinity\\)\\'" raw))
                       -60.0)
                      (t nil))))
    (when (and (numberp value) (= value value))
      (float (max -90.0 (min 0.0 value))))))

(defun emacs-radio-waveform--point-y (db)
  "将 RMS 音量 DB（约 -60～0 dBFS）映射到 SVG 的 Y 坐标。
这里使用音量包络：越响曲线越靠上，而非假装 PCM 在正负间振荡。"
  (let* ((height (max 8 emacs-radio-waveform-height))
         (volume (max 0.0 (min 1.0 (/ (+ db 60.0) 54.0)))))
    (- (float (- height 2)) (* volume (- height 4)))))

(defun emacs-radio-waveform--path (levels)
  "将 LEVELS 的音量历史变成一条连续、平滑的 SVG 二次贝塞尔曲线。
取相邻样本中点作为贝塞尔终点，绘制真实音量包络的平滑趋势。"
  (let* ((values (or levels (emacs-radio-waveform--flat)))
         (n (length values))
         (width (float (max 20 emacs-radio-waveform-width)))
         (step (/ width (float (max 1 (1- n)))))
         (points (cl-loop for db in values for i from 0
                          collect (cons (* i step)
                                        (emacs-radio-waveform--point-y db))))
         (first (car points))
         (tail (cdr points))
         (prev first)
         (path (format "M %.2f %.2f" (car first) (cdr first))))
    (dolist (next tail)
      (setq path
            (concat path
                    (format " Q %.2f %.2f %.2f %.2f"
                            (car prev) (cdr prev)
                            (/ (+ (car prev) (car next)) 2.0)
                            (/ (+ (cdr prev) (cdr next)) 2.0))))
      (setq prev next))
    (concat path (format " L %.2f %.2f" (car prev) (cdr prev)))))

(defun emacs-radio-waveform--render (&optional paused)
  "渲染并缓存微型 SVG 图标，PAUSED 非 nil 时画水平线。
这里生成的是 SVG 的一条 path（曲线），不是 Unicode 柱状图。"
  (when (and (display-graphic-p) (image-type-available-p 'svg))
    (let* ((width (max 20 emacs-radio-waveform-width))
           (height (max 8 emacs-radio-waveform-height))
           (svg (svg-create width height))
           (path (if paused
                     (format "M 0 %.2f L %d %.2f"
                             (/ height 2.0) width (/ height 2.0))
                   (emacs-radio-waveform--path emacs-radio-waveform--levels))))
      ;; svg-node 使用标准 SVG path 属性；圆角保证 42px 下细线清楚。
      (svg-node svg 'path
                :d path :stroke emacs-radio-waveform-color
                :stroke-width 1.5 :stroke-linejoin "round"
                :stroke-linecap "round" :fill "none")
      (setq emacs-radio-waveform--image (svg-image svg :ascent 'center)))))

(defun emacs-radio-waveform--push-db (db)
  "将 mpv 刚测到的 DB 加入历史，并更新图标和整个 Mode-line。"
  (let* ((count (emacs-radio-waveform--count))
         (levels (or emacs-radio-waveform--levels
                     (emacs-radio-waveform--flat))))
    (setq emacs-radio-waveform--levels
          (append (last levels (1- count)) (list db))
          emacs-radio-waveform--last-db db
          emacs-radio-waveform--last-update (float-time)))
  (emacs-radio-waveform--render)
  (emacs-radio--refresh-mode-line))

(defun emacs-radio-waveform--close-ipc ()
  "关闭专用音量 IPC 连接，并清空未完成的采样请求。
关闭前先清空变量，避免连接退出 sentinel 误操作新的连接。"
  (let ((old emacs-radio-waveform--ipc))
    (setq emacs-radio-waveform--ipc nil
          emacs-radio-waveform--pending ""
          emacs-radio-waveform--awaiting nil
          emacs-radio-waveform--sent-at nil)
    (when (process-live-p old)
      (delete-process old))))

(defun emacs-radio-waveform--accept-line (line generation)
  "处理专用 IPC 收到的一条完整 JSON LINE，只接受当前 GENERATION。
request_id 防止把迟到的旧响应或者无关事件当作音量。"
  (when (= generation emacs-radio--generation)
    (condition-case err
        (let* ((reply (json-parse-string line :object-type 'alist))
               (id (alist-get 'request_id reply))
               (status (alist-get 'error reply)))
          (when (and (numberp id)
                     (eql id emacs-radio-waveform--awaiting))
            (setq emacs-radio-waveform--awaiting nil
                  emacs-radio-waveform--sent-at nil)
            (if (equal status "success")
                (let ((db (emacs-radio-waveform--db-from-reply
                           (alist-get 'data reply))))
                  (if db
                      (progn
                        (setq emacs-radio-waveform--last-error nil)
                        (when (eq emacs-radio--state 'playing)
                          (emacs-radio-waveform--push-db db)))
                    (setq emacs-radio-waveform--last-error
                          "RMS metadata not ready or missing")))
              (setq emacs-radio-waveform--last-error
                    (format "mpv get_property: %s" status)))))
      (error (setq emacs-radio-waveform--last-error
                   (format "Bad IPC reply: %s" (error-message-string err)))))))

(defun emacs-radio-waveform--on-data (proc chunk generation)
  "为当前 IPC PROC 缓冲不完整 CHUNK 并解析换行分隔的 JSON。
防止单次读到半行或多行时解析错误；废弃旧代数的数据。"
  (when (and (= generation emacs-radio--generation)
             (eq proc emacs-radio-waveform--ipc))
    (setq emacs-radio-waveform--pending
          (concat emacs-radio-waveform--pending chunk))
    (while (string-match "\n" emacs-radio-waveform--pending)
      (let ((line (substring emacs-radio-waveform--pending
                             0 (match-beginning 0))))
        (setq emacs-radio-waveform--pending
              (substring emacs-radio-waveform--pending (match-end 0)))
        (emacs-radio-waveform--accept-line line generation)))
    ;; 若 mpv 传来异常长的无换行数据，丢弃它而不是让 Emacs 内存增长。
    (when (> (length emacs-radio-waveform--pending) 65536)
      (setq emacs-radio-waveform--pending ""))))

(defun emacs-radio-waveform--connect (generation)
  "在 mpv Unix socket 已存在时为 GENERATION 建立专用监测连接。
创建失败不抛给用户；定时器稍后会重试，网络电台播放不受影响。"
  (when (and (not (process-live-p emacs-radio-waveform--ipc))
             (stringp emacs-radio--ipc-socket)
             (file-exists-p emacs-radio--ipc-socket))
    (condition-case err
        (setq emacs-radio-waveform--ipc
              (make-network-process
               :name "emacs-radio-waveform-ipc"
               :family 'local :service emacs-radio--ipc-socket
               :coding 'utf-8-unix :noquery t
               :filter (lambda (proc chunk)
                         (emacs-radio-waveform--on-data proc chunk generation))
               :sentinel (lambda (proc _event)
                           (when (eq proc emacs-radio-waveform--ipc)
                             (setq emacs-radio-waveform--ipc nil
                                   emacs-radio-waveform--awaiting nil
                                   emacs-radio-waveform--sent-at nil)))))
      (file-error (setq emacs-radio-waveform--last-error
                        (error-message-string err))))))

(defun emacs-radio-waveform--tick (generation)
  "定时从 mpv 的 astats 读取一次 RMS；每次最多只允许一个未完成请求。
连接丢失时自动重试；长时间未响应时重连；暂停时不发采样请求。"
  (when (and (= generation emacs-radio--generation)
             emacs-radio-waveform-enabled
             (eq emacs-radio--state 'playing)
             (process-live-p emacs-radio--player))
    (unless (process-live-p emacs-radio-waveform--ipc)
      (emacs-radio-waveform--connect generation))
    (when (process-live-p emacs-radio-waveform--ipc)
      (if emacs-radio-waveform--awaiting
          (when (and emacs-radio-waveform--sent-at
                     (> (- (float-time) emacs-radio-waveform--sent-at) 1.5))
            (emacs-radio-waveform--close-ipc))
        (cl-incf emacs-radio-waveform--counter)
        (let ((id emacs-radio-waveform--counter))
          (condition-case err
              (progn
                (process-send-string
                 emacs-radio-waveform--ipc
                 (concat (json-serialize
                          `((command . ["get_property" "af-metadata/radio-meter"])
                            (request_id . ,id)))
                         "\n"))
                (setq emacs-radio-waveform--awaiting id
                      emacs-radio-waveform--sent-at (float-time)))
            (file-error
             (setq emacs-radio-waveform--last-error
                   (error-message-string err))
             (emacs-radio-waveform--close-ipc))))))))

(defun emacs-radio-waveform-stop ()
  "停止计时器、释放专用 IPC，并清除旧台波形（不影响 mpv 播放）。"
  (when (timerp emacs-radio-waveform--timer)
    (cancel-timer emacs-radio-waveform--timer))
  (setq emacs-radio-waveform--timer nil)
  (emacs-radio-waveform--close-ipc)
  (setq emacs-radio-waveform--levels nil
        emacs-radio-waveform--image nil
        emacs-radio-waveform--last-db nil
        emacs-radio-waveform--last-update nil
        emacs-radio-waveform--last-error nil
        emacs-radio-waveform--generation nil))

(defun emacs-radio-waveform-start (generation)
  "为当前 mpv 播放代数 GENERATION 启动真实音量曲线。
如果没有 SVG 支持或被用户禁用，不启动定时器；播放本身保持正常。"
  (emacs-radio-waveform-stop)
  (when (and emacs-radio-waveform-enabled
             (display-graphic-p) (image-type-available-p 'svg))
    (setq emacs-radio-waveform--generation generation
          emacs-radio-waveform--levels (emacs-radio-waveform--flat))
    (emacs-radio-waveform--render)
    (setq emacs-radio-waveform--timer
          (run-with-timer
           0 (max 0.08 emacs-radio-waveform-interval)
           (lambda () (emacs-radio-waveform--tick generation))))))

(defun emacs-radio-waveform-pause ()
  "停止采样并把当前曲线重绘成水平线；定时器继续存活以待恢复。"
  (setq emacs-radio-waveform--awaiting nil)
  (when emacs-radio-waveform--generation
    (emacs-radio-waveform--render t))
  (emacs-radio--refresh-mode-line))

(defun emacs-radio-waveform-resume ()
  "恢复音量曲线；之后定时器会继续从 mpv 请求真实音量。"
  (when emacs-radio-waveform--generation
    (setq emacs-radio-waveform--levels (emacs-radio-waveform--flat))
    (emacs-radio-waveform--render)
    (emacs-radio--refresh-mode-line)))

(defun emacs-radio-waveform-icon ()
  "返回供 Mode-line 拼接的微型 SVG 字符串；不支持 SVG 时返回空串。
实际图像缓存在 `emacs-radio-waveform--image' 中，此函数不重复绘图。"
  (if (and emacs-radio-waveform-enabled emacs-radio-waveform--image)
      (propertize " " 'display emacs-radio-waveform--image)
    ""))

;;;###autoload
(defun emacs-radio-waveform-status ()
  "显示音量采样诊断信息，帮助确认曲线确实来自真实音频数据。"
  (interactive)
  (message "Radio waveform: %s | RMS=%s dBFS | last=%.1fs ago | error=%s"
           (if (process-live-p emacs-radio-waveform--ipc) "IPC connected" "IPC disconnected")
           (if emacs-radio-waveform--last-db
               (format "%.1f" emacs-radio-waveform--last-db)
             "N/A")
           (if emacs-radio-waveform--last-update
               (- (float-time) emacs-radio-waveform--last-update)
             -1.0)
           (or emacs-radio-waveform--last-error "none")))

(provide 'emacs-radio-waveform)
;;; emacs-radio-waveform.el ends here
