# Emacs Radio v0.4.0 — 真实声音微型 SVG 曲线

适配 Emacs 27.1+ / Helm 3+ / mpv（支持 `astats` 音频滤镜）及图形版 Emacs 的 SVG 支持。

## 原理

```
电台 URL -> mpv (唯一播放进程) -> 音频播放设备
                        │
                   astats=metadata=1:reset=1
                        │
              af-metadata/radio-meter
                        │
                JSON IPC Unix socket
                        │
             最近 12 次真实 RMS dBFS
                        │
              SVG 连续音量包络曲线
                        │
                Mode-line: 📻 ▶ 台名 [小曲线]
```

这是**真实 RMS 音量包络曲线**，反映主播与音乐的响度起伏；不是逐采样 PCM 电压波形，不能据此还原声谱。没有额外开第二条广播流，也不会包含其他应用的声音。mpv 的音频缓冲会造成曲线与扬声器实际发声有轻微延迟或提前。

## 安装

1. 依赖：`sudo apt install mpv ffmpeg python3`，Emacs 中安装 Helm。
2. 本 ZIP 中 `emacs-radio.el`、`emacs-radio-waveform.el`、`emacs-radio-probe.py` **必须在同一安装目录**。电台清单可以放在其他地方。
3. 在配置中：

```elisp
(add-to-list 'load-path "~/github/emacs-radio/")
(require 'emacs-radio)
(setq emacs-radio-sources-file "~/github/emacs-radio/radio_sources.tsv"
      emacs-radio-cache-directory "~/.emacs.d/emacs-radio-cache/")
(emacs-radio-mode 1)
```

升级前退出 Emacs 或移除旧的 `.elc`/`.eln` 缓存，确保 `.el` 的新版本确实被加载。不要只替换一个 `.el` 文件：新主文件依赖新增模块。

## Spacemacs Private Layer

`spacemacs-layer/my-radio/packages.el` 已把 `emacs-radio-waveform.el` 添加进 GitHub recipe 的 `:files`。如果已经有 `my-radio` layer：

1. 先将本 ZIP 内的新源码文件提交到你的 `dustincys/emacs-radio` GitHub 仓库。
2. 再替换 `~/.emacs.d/private/my-radio/packages.el`，让 Quelpa 安装时下载新增的波形模块。或者把整个 `spacemacs-layer/my-radio/` 复制到私有 layer 路径。
3. 更新/重新安装 GitHub package 后重启 Emacs。

注意：如果本地包管理器只安装了旧版 3 文件的 recipe，将会提示 `Cannot open load file: emacs-radio-waveform`。

## 使用

- `M-x emacs-radio-scan`：按 URL 去重并检测可播放流（扫描需要 FFmpeg）。
- `M-x emacs-radio`：Helm 搜索电台，列表按使用频率降序，同频率稳定排序，列表支持上下循环。
- `M-x emacs-radio-toggle-pause`：暂停/恢复。或者点击 Mode-line 的收音机状态/曲线。
- `M-x emacs-radio-stop`：停止 mpv、定时器、IPC，且从 Mode-line 完全隐藏。
- `M-x emacs-radio-waveform-status`：显示当前 RMS、距最近更新时间、IPC 状态以及失败原因。**判断是否真的采样成功，请优先看这个命令。**

播放中显示绿色的小曲线，暂停显示水平线；停播隐藏。正在连接时可能暂时只显示平线。

## 配置

```elisp
(setq emacs-radio-waveform-enabled t
      emacs-radio-waveform-interval 0.15  ; 约 6.7 次/秒
      emacs-radio-waveform-width 42       ; 像素
      emacs-radio-waveform-height 16
      emacs-radio-waveform-color "#65DFA3"
      emacs-radio-waveform-samples 12)
```

如果你想关闭波形而继续使用电台播放器，将 `emacs-radio-waveform-enabled` 设置为 `nil` 并重新选台。

图形 Emacs 必须有 SVG 图像支持，检查：

```elisp
(image-type-available-p 'svg)  ; 应为 t
```

在纯终端 Emacs 中仍能播放和切换电台，但**不会绘制 SVG 图标**。如果视频流缺少可用的 `astats` 元数据，图标保持基线，`M-x emacs-radio-waveform-status` 显示对应错误。

## 常见问题

1. **曲线不动**：先看 `M-x emacs-radio-waveform-status` 是否显示 `IPC connected`、RMS 是否为数字；再检查 `*emacs-radio-mpv*` 缓冲区中的滤镜/音频错误。
2. **`Invalid function: helm-build-sync-source`**：新版主文件顶层已经提前 require `helm-source`，但必须清理旧的 `.elc` 并重新安装包。
3. **GitHub 的 TSV 写回可能丢失**：本包使用的是此前更新的 Python 脚本，默认会将可播放台写回 `radio_sources.tsv` 并生成 `.bak`。若不希望在 GitHub package 安装目录修改 TSV，请将 TSV 放入用户目录，或以 `--no-write-back` 手动运行脚本。
4. **验证**：本地未装 Emacs/mpv，因此当前交付已完成结构、Python 语法与文本级检查，未在实际 Spacemacs + mpv 环境做端到端音频测试。

## 测试

在安装了 Emacs 的环境（包含 Helm）可执行：

```sh
emacs -Q --batch -L . -l tests/emacs-radio-waveform-tests.el -f ert-run-tests-batch-and-exit
```

本项目的测试聚焦 RMS 解析、SVG 路径生成、数据窗口更新；真实 mpv 音频与桌面显示仍需本机手动检查。
