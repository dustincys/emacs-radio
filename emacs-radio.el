;;; emacs-radio.el --- Helm radio browser and mpv player -*- lexical-binding: t; -*-

;; Author: ChatGPT
;; Version: 0.4.0
;; Package-Requires: ((emacs "27.1") (helm "3.0"))
;; Keywords: multimedia, convenience
;; URL: https://github.com/dustincys/emacs-radio

;;; Commentary:
;; Read radio_sources.tsv, asynchronously probe streams using FFmpeg,
;; store verified playable stations, select with Helm, play using mpv,
;; and show a clickable station/status indicator in the global mode line.
;; See README.md for setup.

;;; Code:

;; ============================================================================
;; 中文阅读指南：Emacs Radio v0.4.0
;; ============================================================================
;; 本文件实现的是“电台管理界面”，并不直接解码音频：
;;
;;  原始 radio_sources.tsv（分类 / 电台 / URL）
;;         │
;;         └─ M-x emacs-radio-scan
;;              │ make-process：后台执行 emacs-radio-probe.py
;;              │ Python 使用 FFmpeg 检验流是否能解码，并按 URL 去重
;;              ▼
;;  缓存目录 radio_playable.tsv / radio_results.csv / radio_playable.m3u
;;         │
;;         └─ emacs-radio-load：仅载入“已通过检测”的 TSV
;;              │
;;              └─ M-x emacs-radio：按播放次数倒序显示 Helm 候选项
;;                    │
;;                    └─ emacs-radio-play：启动后台 mpv
;;                          │
;;                          ├─ mode-line 显示电台名和播放状态
;;                          ├─ 鼠标点击 → 暂停/恢复（经 mpv JSON IPC）
;;                          └─ emacs-radio-stop → 停止并隐藏显示
;;
;; 重要数据结构：
;;   STATION = (CATEGORY NAME URL)，例如 ("山东" "山东交通广播" "https://...")。
;;   emacs-radio--stations 是 STATION 列表，仅包含缓存中可播放的项目。
;;   emacs-radio--usage-counts 是 URL → 次数的 hash-table。
;;   emacs-radio--state 取 stopped / connecting / playing / paused。
;;   emacs-radio--generation 用于防止旧进程的异步回调影响新电台。
;;
;; Emacs Lisp 速读：
;;   defcustom：可由用户 customize 的设置；defvar：运行时变量；
;;   defun：函数定义；interactive：可通过 M-x 调用；
;;   let/let*：局部变量；setq：变量赋值；when/unless：条件执行；
;;   lambda：匿名回调；sentinel：进程退出等事件回调；
;;   buffer：Emacs 文本缓冲区（可用作后台进程日志）。
;;
;; v0.4.0 增加 mpv astats 实时 RMS -> SVG 曲线；详见 emacs-radio-waveform.el。
;; ============================================================================

(require 'cl-lib)
(require 'subr-x)
(require 'json)

;; Helm 的 helm-build-sync-source 是宏，字节编译时必须提前加载。
(eval-when-compile (require 'helm-source))
(require 'helm)
(require 'helm-source)

;; 仅依赖 Emacs 自带 svg.el；waveform 模块不再启动额外 FFmpeg。
(require 'emacs-radio-waveform)

;; 用户自定义参数集中在这个 group 中，可以用 M-x customize-group RET emacs-radio。
;; defcustom 是“配置”，改这些值通常不需要编辑函数主体。
(defgroup emacs-radio nil
  "Internet radio browser/player with Helm and mpv."
  :group 'multimedia
  :prefix "emacs-radio-")

(defcustom emacs-radio-sources-file
  (expand-file-name "radio_sources.tsv" user-emacs-directory)
  "Source TSV with column names 分类, 电台, URL."
  :type 'file)

(defcustom emacs-radio-cache-directory
  (expand-file-name "emacs-radio/" user-emacs-directory)
  "Directory for radio_playable.tsv, radio_results.csv and radio_playable.m3u."
  :type 'directory)

(defcustom emacs-radio-python-program "python3"
  "Executable for probing radio streams."
  :type 'string)

(defcustom emacs-radio-mpv-program "mpv"
  "Executable used to play radio streams."
  :type 'string)

(defcustom emacs-radio-probe-timeout 18
  "Per-station FFmpeg connection/probe timeout in seconds."
  :type 'integer)

(defcustom emacs-radio-probe-workers 8
  "Maximum concurrent probe workers."
  :type 'integer)

(defcustom emacs-radio-probe-script nil
  "Optional explicit path of emacs-radio-probe.py.
If nil, find it alongside emacs-radio.el."
  :type '(choice (const :tag "Bundled script" nil) file))

(defcustom emacs-radio-show-mode-line t
  "Show the radio name and status in the global mode line."
  :type 'boolean)

;; 运行时共享状态：双连字符 -- 表示包的内部变量，不建议外部代码直接修改。
;; stations / usage-counts 是数据；player / socket / state 是播放控制状态。
(defvar emacs-radio--stations nil)
(defvar emacs-radio--usage-counts (make-hash-table :test 'equal)
  "Mapping of station URL to number of times the station was selected.")

(defcustom emacs-radio-usage-file nil
  "Optional TSV file for persisted station play counts.
When nil, use radio_usage.tsv inside `emacs-radio-cache-directory'."
  :type '(choice (const :tag "Cache directory default" nil) file))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--usage-path
;; 返回播放次数统计文件的实际路径。
;; 默认放在缓存目录内；若用户设置了 emacs-radio-usage-file 则优先使用。
;; 这样更新电台清单时，统计文件仍可独立保存。
;; --------------------------------------------------------------------------
(defun emacs-radio--usage-path ()
  "Return the path to the persistent station usage counter file.
The default follows the radio cache directory, so no extra setup is needed."
  ;; An explicit custom path allows users to preserve statistics separately.
  (or emacs-radio-usage-file (emacs-radio--cache-file "radio_usage.tsv")))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--load-usage
;; 从磁盘恢复“URL → 播放次数”哈希表。
;; 每行应有 URL 和 COUNT 两列；表头和格式错误的行会自动跳过。
;; 相同 URL 多次出现时取最大计数，避免意外重复造成统计下降。
;; 每次加载都重建哈希表，以磁盘内容作为统计数据源。
;; --------------------------------------------------------------------------
(defun emacs-radio--load-usage ()
  "Read saved station usage counts keyed by URL.
Malformed lines are ignored, and repeated URLs keep their largest count."
  ;; Rebuild the table on every load to avoid stale counts from old files.
  (setq emacs-radio--usage-counts (make-hash-table :test 'equal))
  (let ((file (emacs-radio--usage-path)))
    (when (file-readable-p file)
      (with-temp-buffer
        (insert-file-contents file)
        (goto-char (point-min))
        (while (not (eobp))
          (let* ((fields (split-string
                          (buffer-substring-no-properties
                           (line-beginning-position) (line-end-position))
                          "\t"))
                 (url (car fields))
                 (count (cadr fields)))
            (when (and (= (length fields) 2)
                       (not (string-empty-p url))
                       (string-match-p "\\`[0-9]+\\'" count))
              (puthash url (max (string-to-number count)
                                (gethash url emacs-radio--usage-counts 0))
                       emacs-radio--usage-counts)))
          (forward-line 1))))))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--save-usage
;; 把播放次数写成 TSV，并尽量避免写到一半损坏历史记录。
;; 先在目标目录创建临时文件，写入全部次数，再 rename 覆盖目标文件。
;; unwind-protect 保证中途报错时也会清理残余临时文件。
;; 保存的是 URL 和 COUNT，不依赖显示名称，所以改名后历史仍可继承。
;; --------------------------------------------------------------------------
(defun emacs-radio--save-usage ()
  "Persist the URL/count table to a TSV file using an atomic rename.
This avoids corrupting usage history if Emacs exits while writing."
  ;; Write only the authoritative URL/count data, independent of scan results.
  (let* ((target (emacs-radio--usage-path))
         (dir (file-name-directory target)))
    (make-directory dir t)
    (let ((tmp (make-temp-file (expand-file-name ".radio-usage-" dir))))
      (unwind-protect
          (progn
            (with-temp-file tmp
              (insert "URL\tCOUNT\n")
              (maphash
               (lambda (url count)
                 (insert (format "%s\t%d\n" url count)))
               emacs-radio--usage-counts))
            (rename-file tmp target t))
        (when (file-exists-p tmp) (delete-file tmp))))))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--play-count
;; 查询某个电台的历史播放次数。
;; 参数 station 是三元素列表，nth 2 取得 URL。
;; 若 URL 从未出现，gethash 的默认返回值为 0。
;; --------------------------------------------------------------------------
(defun emacs-radio--play-count (station)
  "Return persistent play count for STATION, identified by its URL."
  ;; URL keys preserve the count if the station display name changes.
  (gethash (nth 2 station) emacs-radio--usage-counts 0))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--record-play
;; 为指定电台增加一次播放计数，立即持久化到磁盘。
;; 这里只以“成功创建 mpv 子进程”为一次选择播放；并未证明声音已输出。
;; 暂停和恢复不会调用本函数，因此不会让计数增加。
;; 保存文件失败只报告消息，不中断已经发起的播放。
;; --------------------------------------------------------------------------
(defun emacs-radio--record-play (station)
  "Record one station selection and save updated play counts.
Called only after mpv has been successfully started."
  ;; A station switch counts as one selection; pause/resume do not count.
  (let ((url (nth 2 station)))
    (puthash url (1+ (gethash url emacs-radio--usage-counts 0))
             emacs-radio--usage-counts)
    (condition-case err
        (emacs-radio--save-usage)
      (file-error
       (message "Radio usage history could not be saved: %s"
                (error-message-string err))))))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--ranked-stations
;; 返回按照使用频率（次数从高到低）排列的新电台列表。
;; copy-sequence 防止排序过程修改原始缓存列表。
;; cl-stable-sort 是稳定排序：次数相同的电台保留缓存原顺序。
;; --------------------------------------------------------------------------
(defun emacs-radio--ranked-stations ()
  "Return stations sorted by play count, highest first.
Stations with equal counts retain their order in the cached source."
  ;; `cl-stable-sort' keeps the original order for never-played stations.
  (cl-stable-sort (copy-sequence emacs-radio--stations)
                  (lambda (a b)
                    (> (emacs-radio--play-count a)
                       (emacs-radio--play-count b)))))

;; 异步任务与播放器相关变量：
;; scan-process：Python 扫描子进程；scan-buffer：后台扫描日志；
;; player：mpv 子进程；ipc-socket：mpv JSON IPC 的 Unix socket 文件名；
;; station：正在收听的 (分类 名称 URL)；state：播放状态；
;; generation：逻辑版本号，用于忽略已经过期的异步回调。
(defvar emacs-radio--scan-process nil)
(defvar emacs-radio--scan-buffer " *emacs-radio-scan*")
(defvar emacs-radio--player nil)
(defvar emacs-radio--ipc-socket nil)
(defvar emacs-radio--station nil)
(defvar emacs-radio--state 'stopped)
(defvar emacs-radio--generation 0)

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--cache-file
;; 把相对文件名放到缓存目录下，得到完整文件路径。
;; 供播放次数统计、扫描结果载入等函数共同使用。
;; --------------------------------------------------------------------------
(defun emacs-radio--cache-file (name)
  "Return NAME under the cache directory."
  ;; All generated files share one customizable cache directory.
  (expand-file-name name emacs-radio-cache-directory))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--read-tsv
;; 读取简单的 TSV 文件，返回 ((分类 名称 URL) ...) 列表。
;; 逐行读取，以制表符拆为三列；跳过标题行和空 URL 行。
;; 这里不是通用 CSV/TSV 解析器：不支持字段内嵌 Tab 或换行。
;; push 构造列表时顺序反转，末尾 nreverse 恢复文件原顺序。
;; --------------------------------------------------------------------------
(defun emacs-radio--read-tsv (file)
  "Read FILE as TSV into (CATEGORY NAME URL) rows.
This is intended for simple TSV fields without embedded newlines/tabs."
  ;; Preserve CATEGORY, NAME and URL as a three-element list; skip header.
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (let (rows)
        (while (not (eobp))
          (let* ((line (string-trim-right
                        (buffer-substring-no-properties
                         (line-beginning-position) (line-end-position)) "\r"))
                 (fields (split-string line "\t" nil)))
            (when (and (= (length fields) 3)
                       (not (equal (car fields) "分类"))
                       (not (string-empty-p (nth 2 fields))))
              (push fields rows)))
          (forward-line 1))
        (nreverse rows)))))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio-load
;; 将扫描后缓存的可播放电台载入内存，并恢复播放次数。
;; 不会直接从未验证的原始清单中选台，避免把死链加入 Helm。
;; 即使旧缓存包含相同 URL 的多条记录，也只保留第一条。
;; 交互调用（M-x）时显示载入数量，后台调用则保持安静。
;; --------------------------------------------------------------------------
(defun emacs-radio-load ()
  "Load stations from cached, previously verified playable TSV."
  ;; Prefer the latest successful scan over unverified source entries.
  (interactive)
  (emacs-radio--load-usage)
  (setq emacs-radio--stations
        (emacs-radio--read-tsv (emacs-radio--cache-file "radio_playable.tsv")))
  ;; Older caches may contain duplicate URLs; remove duplicates in memory too.
  (let ((seen (make-hash-table :test 'equal)))
    (setq emacs-radio--stations
          (cl-remove-if
           (lambda (row)
             (let ((url (string-trim (nth 2 row))))
               (prog1 (gethash url seen)
                 (puthash url t seen))))
           emacs-radio--stations)))
  (when (called-interactively-p 'interactive)
    (message "Emacs Radio: loaded %d playable stations" (length emacs-radio--stations)))
  emacs-radio--stations)

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--probe-script
;; 确定 Python 检测器 emacs-radio-probe.py 的位置。
;; 用户显式配置路径时优先使用；否则寻找 emacs-radio.el 所在目录。
;; 扫描函数会在启动前检查脚本是否实际可读。
;; --------------------------------------------------------------------------
(defun emacs-radio--probe-script ()
  "Find installed bundled Python probe script."
  ;; Locate the helper next to the loaded package unless explicitly set.
  (or emacs-radio-probe-script
      (let* ((library (or (locate-library "emacs-radio") load-file-name))
             (dir (and library (file-name-directory library))))
        (and dir (expand-file-name "emacs-radio-probe.py" dir)))))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio-scan
;; 启动异步检测任务，而不是在 Emacs 主线程中逐台等待。
;; 先检查原始 TSV、Python、FFmpeg 和检测脚本；禁止并发重复扫描。
;; make-process 启动 Python；Python 内部并发调用 FFmpeg 检测音频。
;; 进程完成时 sentinel 检查退出码：0 表示脚本成功结束，随后重新载入缓存。
;; 注意：脚本成功完成 ≠ 所有电台都可播放；具体结果见 CSV 和日志。
;; --------------------------------------------------------------------------
(defun emacs-radio-scan ()
  "Asynchronously probe ALL sources and replace cached playable list.
Results live under `emacs-radio-cache-directory'.  Use
`emacs-radio-scan-log' to inspect progress."
  ;; Spawn Python asynchronously; the sentinel reloads a successful scan.
  (interactive)
  (when (process-live-p emacs-radio--scan-process)
    (user-error "A radio scan is already running"))
  (unless (file-readable-p emacs-radio-sources-file)
    (user-error "Cannot read source TSV: %s" emacs-radio-sources-file))
  (unless (executable-find emacs-radio-python-program)
    (user-error "Python not found: %s" emacs-radio-python-program))
  (unless (executable-find "ffmpeg")
    (user-error "FFmpeg not found; install ffmpeg"))
  (let ((script (emacs-radio--probe-script)))
    (unless (and script (file-readable-p script))
      (user-error "Cannot find emacs-radio-probe.py alongside emacs-radio.el"))
    (make-directory emacs-radio-cache-directory t)
    (with-current-buffer (get-buffer-create emacs-radio--scan-buffer)
      (erase-buffer))
    ;; 启动外部 Python 进程之后立即返回，Emacs 仍可编辑/移动光标。
    ;; 后续“检测完毕”的处理全部发生在 :sentinel 回调中。
    (setq emacs-radio--scan-process
          (make-process
           :name "emacs-radio-scan"
           :buffer (get-buffer-create emacs-radio--scan-buffer)
           :command (list emacs-radio-python-program script
                          "--input" (expand-file-name emacs-radio-sources-file)
                          "--output-dir" (expand-file-name emacs-radio-cache-directory)
                          "--timeout" (number-to-string emacs-radio-probe-timeout)
                          "--workers" (number-to-string emacs-radio-probe-workers))
           :noquery t
           :sentinel
           (lambda (proc _event)
             (when (and (eq proc emacs-radio--scan-process)
                        (memq (process-status proc) '(exit signal)))
               (if (and (eq (process-status proc) 'exit)
                        (= (process-exit-status proc) 0))
                   (progn
                     (emacs-radio-load)
                     (message "Radio scan completed: %d playable. Cache: %s"
                              (length emacs-radio--stations)
                              emacs-radio-cache-directory))
                 (message "Radio scan failed; see M-x emacs-radio-scan-log"))))))
    (message "Radio scan started in background; M-x emacs-radio-scan-log for progress")))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio-scan-log
;; 打开 Python 检测过程的输出缓冲区。
;; 用于观察扫描进度、诊断 FFmpeg 检测失败或脚本报错。
;; --------------------------------------------------------------------------
(defun emacs-radio-scan-log ()
  "Show the FFmpeg probe progress/error log."
  ;; Reuse the process output buffer for debugging failed probes.
  (interactive)
  (pop-to-buffer (get-buffer-create emacs-radio--scan-buffer)))

;; Mode-line 鼠标事件表。只有文字被加上 local-map 属性时才会生效。
;; 同时注册两种 mouse-1 事件形式以覆盖常见的 Emacs 版本差异。
(defvar emacs-radio--mode-line-mouse-map
  (let ((map (make-sparse-keymap)))
    ;; `global-mode-string' mode-line text dispatches clicks to this local map.
    ;; Support both event forms for compatibility with different Emacs builds.
    (define-key map [mode-line mouse-1] #'emacs-radio--mode-line-click)
    (define-key map [mouse-1] #'emacs-radio--mode-line-click)
    map)
  "Mouse keymap for the clickable radio mode-line indicator.")

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--mode-line-click
;; 响应用户对 mode-line 电台文字的鼠标左键点击。
;; interactive "e" 让 Emacs 传入鼠标事件；此处不需要读取具体坐标。
;; 只有 playing / paused 两种状态才切换，connecting 或 stopped 不执行。
;; --------------------------------------------------------------------------
(defun emacs-radio--mode-line-click (event)
  "Toggle pause/resume after clicking the radio indicator with EVENT."
  (interactive "e")
  ;; A click is meaningful only when there is an active/paused station.
  ;; Keep the callback narrowly scoped so it never starts a new station.
  (ignore event)
  (when (memq emacs-radio--state '(playing paused))
    (emacs-radio-toggle-pause)))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--mode-line-text
;; 动态生成显示在 mode-line 的电台状态字符串。
;; 在 stopped 或无当前电台时返回 nil，让显示完全消失。
;; 播放/暂停时用 propertize 绑定鼠标事件、悬浮提示和高亮外观。
;; 这里更新的是界面文本，并不负责控制 mpv。
;; --------------------------------------------------------------------------
(defun emacs-radio--mode-line-text ()
  "构造支持鼠标点击的 Mode-line 字符串，停止时不显示。"
  (when (and emacs-radio-show-mode-line
             emacs-radio--station
             (not (eq emacs-radio--state 'stopped)))
    (let* ((station-name (nth 1 emacs-radio--station))
           (state-text (pcase emacs-radio--state
                         ('playing  "▶")
                         ('paused   "⏸")
                         ('connecting "🔃")
                         (_ "")))
           ;; 这里的 SVG 不是柱状图，而是 42×16px 的连续音量曲线。
           ;; 真实 RMS 在专用 IPC filter 中计算并缓存图像；本函数只拼接。
           (wave (emacs-radio-waveform-icon))
           (text (concat (format "[📡 %s %s" state-text station-name)
                         (if (> (length wave) 0) (concat " " wave) "")
                         "]"))
           (clickable (memq emacs-radio--state '(playing paused))))
      ;; 在最终字符串上统一设置鼠标事件。SVG 所在的空格保留 display 属性，
      ;; 同时也继承 local-map，所以点击曲线本身亦可暂停/继续。
      (if clickable
          (propertize text
                      'local-map emacs-radio--mode-line-mouse-map
                      'mouse-face 'mode-line-highlight
                      'help-echo (if (eq emacs-radio--state 'paused)
                                     "mouse-1: Resume radio"
                                   "mouse-1: Pause radio"))
        (propertize text 'help-echo "Connecting to radio stream…")))))

;; 不是固定的文字，而是一个动态表达式：每次刷新时重新计算电台显示。
(defvar emacs-radio--mode-line-entry
  '(:eval (emacs-radio--mode-line-text)))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--refresh-mode-line
;; 请求 Emacs 刷新所有窗口的 mode-line。
;; 改变状态后调用，确保名称、图标和点击提示立即更新。
;; --------------------------------------------------------------------------
(defun emacs-radio--refresh-mode-line ()
  "Refresh mode line in all windows."
  ;; t refreshes every window because the entry is globally visible.
  (force-mode-line-update t))

;;;###autoload
;; --------------------------------------------------------------------------
;; 函数：emacs-radio-mode
;; 全局 minor mode 的入口：安装/移除 mode-line 显示组件。
;; 开启时仅向 global-mode-string 添加一次 (:eval ...) 表达式，并读取缓存。
;; 关闭时移除该组件；这只关闭状态显示功能，不等于停止 mpv。
;; (:eval ...) 会在刷新 mode-line 时动态执行 emacs-radio--mode-line-text。
;; --------------------------------------------------------------------------
(define-minor-mode emacs-radio-mode
  "Global minor mode showing the Internet radio state in mode-line."
  :global t
  :group 'emacs-radio
  ;; Install exactly one global entry; disabling the mode removes it.
  (if emacs-radio-mode
      (progn
        (unless (member emacs-radio--mode-line-entry global-mode-string)
          (setq global-mode-string
                (append global-mode-string (list emacs-radio--mode-line-entry))))
        (emacs-radio-load))
    (setq global-mode-string
          (delete emacs-radio--mode-line-entry global-mode-string))
    ;; 退出界面模式时也停止后台 RMS 采样，避免隐藏后浪费资源。
    (emacs-radio-waveform-stop))
  (emacs-radio--refresh-mode-line))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--delete-ipc-socket
;; 删除当前 mpv JSON IPC 使用的 Unix socket 文件。
;; 清理旧 socket 避免下一次播放误连过期实例。
;; ignore-errors 表示文件已经不存在时不阻断停止过程。
;; --------------------------------------------------------------------------
(defun emacs-radio--delete-ipc-socket ()
  "Remove mpv IPC socket, if present."
  ;; mpv uses a Unix socket for pause/resume JSON IPC commands.
  (when emacs-radio--ipc-socket
    (ignore-errors (delete-file emacs-radio--ipc-socket)))
  (setq emacs-radio--ipc-socket nil))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio-stop
;; 停止播放器、清理状态、隐藏 mode-line 电台信息。
;; 先把 generation 加一：此前的定时器或 mpv sentinel 即使稍后触发，
;; 也不会把新状态错误地覆盖掉。随后结束进程并清理 IPC socket。
;; 将 station 置 nil、state 置 stopped 是隐藏显示的关键。
;; --------------------------------------------------------------------------
(defun emacs-radio-stop ()
  "Stop current station and remove the indicator from the mode line."
  ;; Invalidate delayed callbacks before terminating the old mpv process.
  (interactive)
  (cl-incf emacs-radio--generation)
  ;; 先终止音频计量进程的 IPC 与 timer，再删除 mpv socket。
  (emacs-radio-waveform-stop)
  (let ((old-player emacs-radio--player))
    (setq emacs-radio--player nil)
    (when (process-live-p old-player)
      (delete-process old-player)))
  (emacs-radio--delete-ipc-socket)
  (setq emacs-radio--state 'stopped
        emacs-radio--station nil)
  (emacs-radio--refresh-mode-line)
  (when (called-interactively-p 'interactive)
    (message "Radio stopped")))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio-play
;; 接收 Helm 选中的三元素电台列表，启动 mpv 后台播放。
;; 检查 mpv 和参数格式、启用 minor mode、停止此前播放。
;; 通过 make-process 调用 mpv，并设置 Unix socket 供后续暂停/继续。
;; sentinel 负责 mpv 退出后的清理；generation 防止旧进程回调串台。
;; 1 秒定时器把仍存活的 connecting 状态标为 playing；这只是进程存活判断，
;; 并不保证声音已成功解码/输出。最后记录一次播放选择并刷新显示。
;; --------------------------------------------------------------------------
(defun emacs-radio-play (station)
  "Play STATION, represented by a (CATEGORY NAME URL) list."
  ;; Stop the previous station and start one mpv process with an IPC socket.
  (unless (executable-find emacs-radio-mpv-program)
    (user-error "mpv not found: %s" emacs-radio-mpv-program))
  (unless (and (listp station) (= (length station) 3))
    (user-error "Invalid radio station"))
  (unless emacs-radio-mode (emacs-radio-mode 1))
  (emacs-radio-stop)
  (let* ((generation emacs-radio--generation)
         (socket (make-temp-name (expand-file-name "emacs-radio-" temporary-file-directory)))
         (url (nth 2 station))
         (buffer (get-buffer-create " *emacs-radio-mpv*")))
    (setq emacs-radio--station station
          emacs-radio--state 'connecting
          emacs-radio--ipc-socket socket)
    (with-current-buffer buffer (erase-buffer))
    (condition-case err
        (setq emacs-radio--player
              (make-process
               :name "emacs-radio-mpv"
               :buffer buffer
               :command (append
                         (list emacs-radio-mpv-program
                               "--no-config" "--no-video" "--no-terminal"
                               "--msg-level=all=warn")
                         ;; 关闭可视化或纯终端 Emacs 不添加滤镜开销。
                         ;; 开启时只分析当前 mpv 已解码的音频，不会额外拉流。
                         ;; 通过标签 radio-meter 读取 RMS 元数据。
                         (when (and emacs-radio-waveform-enabled
                                    (display-graphic-p)
                                    (image-type-available-p 'svg))
                           (list "--af=@radio-meter:astats=metadata=1:reset=1"))
                         (list (concat "--input-ipc-server=" socket)
                               "--" url))
               :noquery t
               :sentinel
               (lambda (proc _event)
                 (when (and (= generation emacs-radio--generation)
                            (eq proc emacs-radio--player)
                            (memq (process-status proc) '(exit signal)))
                   (setq emacs-radio--player nil
                         emacs-radio--state 'stopped
                         emacs-radio--station nil)
                   (emacs-radio-waveform-stop)
                   (emacs-radio--delete-ipc-socket)
                   (emacs-radio--refresh-mode-line)
                   (message "Radio playback ended (%s). See buffer %s"
                            (process-exit-status proc) (buffer-name buffer))))))
      (error
       (emacs-radio-stop)
       (signal (car err) (cdr err))))
    ;; A live process indicates mpv was launched, not necessarily that audio
    ;; decoding succeeded. A failed stream normally causes mpv to exit.
    (run-at-time
     1 nil
     (lambda ()
       (when (and (= generation emacs-radio--generation)
                  (eq emacs-radio--state 'connecting)
                  (process-live-p emacs-radio--player))
         (setq emacs-radio--state 'playing)
         (emacs-radio--refresh-mode-line))))
    ;; 波形只在图形 Emacs + SVG 可用时启动；计时器等待 mpv socket 就绪。
    (emacs-radio-waveform-start generation)
    (emacs-radio--record-play station)
    (emacs-radio--refresh-mode-line)
    (message "Opening radio: %s" (nth 1 station))))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio--ipc-command
;; 向运行中的 mpv 发送一条 JSON IPC 指令。
;; 先确认进程和 socket 可用，再建立 Unix 本地网络连接。
;; process-send-string 发送 JSON 命令；filter 收到一行 JSON 回复时解析。
;; 只有 error 为 success 且 generation 仍匹配时才调用 on-success，
;; 借此避免“发送了命令但 mpv 实际没有执行”造成状态显示不一致。
;; 失败会报告响应内容，且不会错误改变暂停/播放状态。
;; --------------------------------------------------------------------------
(defun emacs-radio--ipc-command (command on-success)
  "Send mpv JSON IPC COMMAND and invoke ON-SUCCESS for success responses.
ON-SUCCESS is called only after mpv acknowledges the command."
  ;; Parse mpv JSON responses and update state only after acknowledgement.
  (unless (and (process-live-p emacs-radio--player)
               emacs-radio--ipc-socket
               (file-exists-p emacs-radio--ipc-socket))
    (user-error "mpv IPC is not ready; try again shortly"))
  (let* ((generation emacs-radio--generation)
         (pending "")
         (connection nil))
    (setq connection
          (make-network-process
           :name "emacs-radio-ipc" :family 'local :service emacs-radio--ipc-socket
           :coding 'utf-8-unix :noquery t
           :filter
           (lambda (proc chunk)
             (setq pending (concat pending chunk))
             (when (string-match "\n" pending)
               (let ((line (substring pending 0 (match-beginning 0))))
                 (condition-case nil
                     (let ((reply (json-parse-string line :object-type 'alist)))
                       (if (and (= generation emacs-radio--generation)
                                (equal (alist-get 'error reply) "success"))
                           (funcall on-success)
                         (message "mpv command failed: %s" line)))
                   (error (message "Invalid mpv reply: %s" line)))
                 (delete-process proc))))
           :sentinel (lambda (_proc _event) nil)))
    (process-send-string connection
                         (concat (json-serialize `((command . ,command))) "\n"))))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio-pause
;; 暂停当前电台：发送 mpv set_property pause true。
;; 直到 mpv 返回成功应答后才将界面状态改为 paused。
;; --------------------------------------------------------------------------
(defun emacs-radio-pause ()
  "Pause mpv radio playback."
  ;; Do not mark paused until mpv confirms setting its pause property.
  (interactive)
  (when (eq emacs-radio--state 'stopped)
    (user-error "No radio station is playing"))
  (emacs-radio--ipc-command
   ["set_property" "pause" t]
   (lambda ()
     (setq emacs-radio--state 'paused)
     (emacs-radio-waveform-pause)
     (emacs-radio--refresh-mode-line))))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio-resume
;; 继续播放：发送 mpv set_property pause false。
;; Emacs JSON 序列化中的 :false 表示 JSON 布尔值 false，
;; 避免把 Lisp 的 nil 误编码成不合预期的 JSON 值。
;; --------------------------------------------------------------------------
(defun emacs-radio-resume ()
  "Resume paused mpv radio playback."
  ;; Keep the indicator in sync with mpv after the resume IPC reply.
  (interactive)
  (when (eq emacs-radio--state 'stopped)
    (user-error "No radio station is playing"))
  (emacs-radio--ipc-command
   ["set_property" "pause" :false]
   (lambda ()
     (setq emacs-radio--state 'playing)
     (emacs-radio-waveform-resume)
     (emacs-radio--refresh-mode-line))))

;; --------------------------------------------------------------------------
;; 函数：emacs-radio-toggle-pause
;; 根据当前状态选择暂停或恢复。
;; 同一个函数供键盘命令和 mode-line 鼠标点击共用。
;; --------------------------------------------------------------------------
(defun emacs-radio-toggle-pause ()
  "Pause or resume the current radio."
  ;; Dispatch based on the current state for both keyboard and mouse.
  (interactive)
  (if (eq emacs-radio--state 'paused)
      (emacs-radio-resume)
    (emacs-radio-pause)))

;;;###autoload
;; --------------------------------------------------------------------------
;; 函数：emacs-radio
;; 用 Helm 交互选择电台。
;; 加载缓存，按历史计数从高到低排序，构造“次数 / 地区 / 名称”候选项。
;; Helm 候选项是 (显示文字 . STATION)；选择后 action 将 STATION 传给
;; emacs-radio-play。无缓存时提示用户先执行 emacs-radio-scan。
;; --------------------------------------------------------------------------
(defun emacs-radio ()
  "Use Helm to choose and play a previously verified radio station."
  ;; Helm candidate values are complete station rows for `emacs-radio-play`.
  (interactive)
  (require 'helm)
  (unless emacs-radio-mode (emacs-radio-mode 1))
  (unless emacs-radio--stations (emacs-radio-load))
  (unless emacs-radio--stations
    (user-error "No playable cache yet: run M-x emacs-radio-scan first"))
  ;; 只在本次电台 Helm 列表启用上下端循环，不影响其他 Helm 页面。
  (let ((helm-move-to-line-cycle-in-source t))
    (helm :sources
          (helm-build-sync-source "Playable radio stations"
            :candidates
            (mapcar
             (lambda (station)
               (cons (format "[%3d] %-10s  %s"
                             (emacs-radio--play-count station)
                             (nth 0 station) (nth 1 station)) station))
             (emacs-radio--ranked-stations))
            :action '(("Play station" . emacs-radio-play))
            :candidate-number-limit 500
            :multiline nil)
          :buffer "*helm radio*")))

;; require 'emacs-radio 依赖下面的 provide 声明识别功能已加载。
(provide 'emacs-radio)
;;; emacs-radio.el ends here
