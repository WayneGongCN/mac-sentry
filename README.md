# Mac 哨兵

[官网](https://mac-sentry.waynegong.com) · [下载最新版本](https://github.com/WayneGongCN/mac-sentry/releases/latest) · [GitHub 源码](https://github.com/WayneGongCN/mac-sentry) · [反馈问题](https://github.com/WayneGongCN/mac-sentry/issues)

基于 [Lakr233/Sentry](https://github.com/Lakr233/Sentry) 1.3.13 的个人定制版，使用 SwiftUI、AVFoundation 和 Vision。当前发布包为 1.2.0。保留原项目 MIT 许可及署名。

## 使用

从 [GitHub Releases](https://github.com/WayneGongCN/mac-sentry/releases/latest) 下载 `MacSentry-v1.2.0-macos-arm64.zip` 并解压，可使用同页的 `SHA256SUMS.txt` 校验安装包。当前发布包采用 ad-hoc 本地签名，尚未经过 Apple 公证；首次打开可能需要在“系统设置 → 隐私与安全性”中确认。

将 `MacSentry.app` 放进“应用程序”目录后打开，在设置窗口点击“授权摄像头”，开启“锁屏后自动守卫”。应用驻留菜单栏，关闭设置窗口后仍然工作。同一用户重复打开不同路径的定制版时，会唤起现有实例，避免重复守卫。原版 Sentry 与本应用拥有不同的 Bundle ID，验证定制版时请退出原版，避免两套锁屏界面同时显示。

在「画面、声音与通知」中点击「在系统设置启用锁屏壁纸…」，然后在 macOS「墙纸」中为所需显示器选择「Mac 哨兵锁屏壁纸」。应用会保存每块显示器启用前的系统壁纸。若系统要求允许读取当前壁纸文件，请按提示选择该文件。回到系统「墙纸」选择其他壁纸即可关闭。

锁屏后，守卫图和告警图按比例裁切铺满所选屏幕，原生 macOS 登录控件位于壁纸上方。图片未配置或失效时，显示该屏启用前保存的原壁纸静态副本。真实告警期间，实时摄像头固定在右上角，完整保留视频比例。摄像头不可用时隐藏画中画。解锁后恢复显示原壁纸副本。

在“画面、声音与通知”中分别选择守卫图片、告警图片和告警声音。图片支持 PNG、JPEG、HEIC、GIF、APNG，动图按素材帧间隔循环播放。声音支持 MP3、M4A、WAV。导入后使用应用容器 `Application Support/MacSentry/Media` 中的副本，移动原文件不影响使用。恢复默认后，未引用的旧副本在下次启动时清理。

守卫和告警预览使用当前选择的素材和锁屏布局。告警预览使用摄像头显示右上角画中画，关闭时释放摄像头。预览不录像或播放告警音。

告警音量独立设置（0–100%，默认 10%），“试听 2 秒”使用当前选择的声音与音量。试听可随时停止，关闭设置也会立即停止；试听不会开启声音告警。声音开关默认关闭，开启后仅在告警期间循环播放，告警解除、解锁、暂停或退出时停止；守卫状态始终静音。应用不修改系统音量，实际响度仍受系统音量与输出设备影响。

## 录像与电源

- 「检测人脸」下的「机主豁免（试验）」可录入、更换或移除一张 JPEG、PNG 或 HEIC 机主照片。应用只在本机保存图像特征，匹配的人脸可跳过触发，同框的其他人仍可触发完整画面录像。侧脸或弱光下机主仍可能触发。
- 每秒最多三次在完整摄像头画面上进行本地人脸检测。人脸框须完整位于画面内，宽高分别至少占画面宽高的 10%，置信度至少为 0.65。连续三次检测到合格人脸后触发，多脸中任意一张合格即可。
- 人脸事件录像目标为 720p、15fps、无声 H.264 MOV，最后一次合格人脸消失后续录 10 秒，再次出现会延长同一事件。
- 使用 AVAssetWriter 独立写入原始视频帧，摄像头停止与文件编码收尾互不阻塞。长事件每 60 秒切换文件；文件完成写入前始终受清理保护。文件写入器实际接收视频帧之后才显示“正在录像”。
- 本应用容器的 `Documents/VideoClip` 保存录像，点击“打开录像目录”访问。超过 24 小时或总量 5GB 时清理最早的已完成片段。
- 磁盘不足、摄像头未授权或采集中断时显示故障。自定义图片不影响摄像头采集、检测和录像；录像只保存摄像头原始画面。
- 接电且守卫期间使用应用级电源断言保持亮屏。电池供电遵循系统电源设置；合盖、主动睡眠和低电量睡眠仍可能中断采集。屏幕熄灭或睡眠前收尾并释放摄像头，唤醒后仍锁定则恢复。
- 设置变更在下一次锁屏生效；“锁屏后自动守卫”开关立即生效。声音、Bark 与设备触发默认关闭，按需在设置中开启。

## 本地构建

要求 Apple Silicon Mac、Xcode 16.3 或更高版本、macOS 13 或更高版本。实际验收环境以本机 macOS 为准。

```sh
./scripts/build-local.sh Release
swift test
./scripts/package-release.sh
```

构建脚本使用 ad-hoc 本地签名，启用 App Sandbox，允许摄像头、网络客户端、读取用户选择的文件及访问应用专用壁纸目录，Bundle ID 为 `com.waynegong.MacSentry`。未使用上游作者的发布签名校验。该包用于本机运行，不包含 Developer ID 公证；重新签名后可能需要重新授权摄像头。

锁屏壁纸使用 macOS WallpaperExtensionKit，按真机验收过的系统构建号启用。目前支持 macOS 27.2（26B123）。其他构建继续使用系统锁屏和守卫检测。扩展通过应用专用目录读取壁纸素材，通过本机回环接收每次锁屏单独加密的实时画面。画中画帧只在内存中传递。

开发辅助入口：`MacSentry --verify-overlay` 在桌面做三轮多屏被动窗口展示与退出自检，覆盖守卫及告警状态，以零音量检查声音循环与解除后停止；输出每屏位置、尺寸、窗口编号及清理结果，不更改用户设置或发送通知。`MacSentry --verify-recording` 在授权后做 15 秒强制录像与短周期分段检查，不要求镜头里有人。其余入口：`MacSentry --export-previews` 在容器 `Documents/Previews` 导出守卫与告警的横屏、竖屏静态界面；`MacSentry --verify-capture` 在摄像头授权后进行 15 秒真实采集检查并输出本地 JSON 摘要（`faceConfirmed` 为人脸确认结果）；检测到合格人脸时会保存本地事件录像。检查模式将分段周期缩短为 3 秒，正常应用仍为 60 秒。均应在普通应用进程退出后运行。

真锁屏验收需确认单屏与多屏的登录控件始终可见、密码及 Touch ID 可用、告警画中画保持在右上角，并检查显示器热插拔、睡眠唤醒与反复解锁后的窗口清理。人脸验收覆盖画面中央和四边。机主、符合条件的侧脸或照片也可能触发。

### 机主照片比对试验

使用一张只有机主的 JPEG、PNG 或 HEIC 照片，以及同一台摄像头录制的短片。样本目录下建立 `calibration` 和 `holdout`，分别放入两次独立采集的 MOV 或 MP4 短片，每段 3–15 秒。两组各需要以下样本。

- `owner-01.mov` 等至少 5 段机主单独出现的短片，包含正脸、侧脸和弱光。
- `other-A-01.mov` 等至少 3 位其他人单独出现的短片，每人用不同字母。
- `mixed-01.mov` 等至少 1 段两人同时在场的短片，机主在画面左半，另一人在右半。

```sh
mkdir -p .build-local
xcrun swiftc -O -target arm64-apple-macosx13.0 \
  Sentry/Logic/FaceFilter.swift Sentry/Logic/FacePresence.swift \
  Sentry/Logic/FacePrints.swift \
  scripts/verify-owner-face.swift -o .build-local/verify-owner-face
.build-local/verify-owner-face "/机主照片路径.jpg" "/样本目录"
```

工具只读本地输入，输出两组的汇总计数和候选阈值。两组均须排除至少 80% 的机主单人触发片段，且跳过的其他人脸数为 0，才会返回 `passed: true`。

## 官网

官网：[mac-sentry.waynegong.com](https://mac-sentry.waynegong.com)。源码位于 `website/`，使用原生 HTML、CSS 与 JavaScript，无需安装依赖或构建。应用界面预览不包含真实摄像头图像。

```sh
python3 -m http.server 4317 --directory website
```

当前 Vercel 项目已连接本 GitHub 仓库，推送 `main` 自动部署官网。项目根目录为 `website`，Framework Preset 使用 Other，关闭安装与构建命令，输出目录为 `.`。

生产首页的 canonical、分享卡片、站点名称和 `sitemap.xml` 都使用 `https://mac-sentry.waynegong.com/`。更换域名时，同步更新 `website/index.html`、`website/robots.txt` 和 `website/sitemap.xml`。

Google Search Console 和 Bing Webmaster Tools 都使用官网的 URL 前缀，由首页的 `google-site-verification` 和 `msvalidate.01` 标签分别验证所有权，共用 `/sitemap.xml`。更换域名时为新站重新验证并提交站点地图。

生产官网使用 GA4 统计页面访问和下载按钮点击（`download_click`），标签位于 `website/app.js`，只在生产域名启用。更换域名或 GA4 数据流时，同步更新域名和测量 ID。

手动部署时，在仓库根目录运行 `vercel link` 关联上述项目，再运行 `vercel --prod`。根目录的 `.vercelignore` 仅上传官网文件。部署自己的副本时，同样将 Vercel 项目根目录设置为 `website`。`.vercel` 登录与项目关联信息不提交到仓库。
