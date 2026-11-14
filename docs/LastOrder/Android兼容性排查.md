# Android 内嵌运行时兼容性排查（未发布）

2026-11-14 针对 LastOrder Android 的 biliTickerBuy 调用链进行源码、离线模拟与 API 36 模拟器检查。上游保持 v2.15.18 / `227ebf73f5af3eec0019984a7cbcb722977453e8`，不更新 vendor 快照、项目版本或公开安装包。Android 只负责登录、查询和任务配置，实际抢票仍交给远程 Sisters。

## 已确认问题与修复

| 问题 | 复现与影响 | 源码修复 |
| --- | --- | --- |
| 场次查询缺少 HTTPX/HTTP2 依赖 | `purchase_context → fetch_purchase_context → BiliRequest.get → _send_with_h2_recovery` 无条件导入 `httpx`，原 Android lock 没有该依赖。使用原锁定依赖、虚构 Cookie 与真实引擎离线调用，在任何 socket 连接前就失败。原 `ping` 只导入模块，因此能通过。 | 补齐与桌面相同版本的纯 Python HTTPX、HTTP2 与传递依赖；自检实际构造标准 HTTP/2 客户端和 CA 上下文，但不发网络请求。 |
| 声明支持未安装的压缩解码器 | 上游固定发送 `Accept-Encoding: gzip, deflate, br, zstd`，Android 不含 Brotli/Zstandard。仅补 HTTPX 后，服务端仍可按该声明返回无法解码的内容。 | Android 适配层将此请求头限制为 `gzip, deflate`；不引入原生压缩轮子，也不关闭 HTTPS 校验。 |
| 桌面进程生命周期被用于共享解释器 | 每次 Android 调用创建并删除临时目录，但 Python 缓存上游模块、全局数据库和请求实例；原实现不关闭这些资源，`GRADIO_TEMP_DIR` 也仍指向旧目录。 | 每次串行调用使用独立上游模块状态；退出时关闭 HTTPX、Requests 与数据库，清理导入失败的部分状态、恢复环境和模块，后续调用重新初始化。清理失败返回固定脱敏错误。 |
| 测试和包校验无法发现上述问题 | 原 Android 依赖环境测试将客户端引擎替换为假对象，原设备测试只有 `ping`、空配置校验、JNI 与存储；APK 校验没有检查 Python 模块、依赖与 CA 内容。 | 增加真实引擎的客户端业务链回归、原生二维码与配置测试、API 36 模拟器 CI，以及嵌套 Python 资产、关键依赖、CA 和 16 KB ELF/ZIP 对齐检查。 |
| 扫码窗口把可见但失去焦点视为后台 | `0.3.1` 扫码窗口只在生命周期为 `resumed` 时生成、检测和保存，等待自动生成时禁用「重新生成二维码」。Android 在应用可见但其他窗口持有输入焦点时报告 `inactive`，此时打开「添加账号」会一直停在「正在生成登录二维码…」，不调用运行时。 | 按可见性处理：`resumed`/`inactive` 照常进行，仅 `hidden`/`paused`/`detached` 暂停；用户点击视为窗口可见，按钮只在自动生成即将开始时禁用。详见下文。 |

## 扫码窗口在失去焦点时停在生成中

用户在 Pixel（Android 16）上安装官方 `0.3.1` arm64 APK 后，点击「添加账号」，窗口一直显示「正在生成登录二维码…」，没有二维码或错误提示，「重新生成二维码」为灰色。

排查结论：

- 运行时与安装包正常。下载官方 `LastOrder-0.3.1-android-arm64.apk`（SHA-256 与发布一致）安装到 API 36 arm64 模拟器，前台打开「添加账号」即生成二维码；本地 debug/release 构建、全新安装和模拟 `0.3.0 → 0.3.1` 覆盖升级（Chaquopy 按 `build.json` 哈希刷新资产）同样正常。`0.3.1` 的 PyPNG 编码修复有效。
- 问题在扫码窗口的生命周期判断。`0.3.1` 只在生命周期为 `null` 或 `resumed` 时自动生成，并在 `_needsQr` 为真时禁用「重新生成二维码」；打开窗口时若不是 `resumed`，`_generateQr` 不会执行，只能等到之后收到 `resumed`。按钮为灰色说明生成从未开始。`0.3.0` 的窗口由按钮直接调用 `qr_start`，没有这层判断。
- Flutter Android 嵌入层（`LifecycleChannel`）在 Activity 处于 resumed、但应用没有任何窗口持有输入焦点时报告 `inactive`，例如分屏另一侧、系统或第三方悬浮窗取得焦点。`hidden`/`paused` 时 Flutter 不渲染新帧，用户看不到窗口；用户能看到正在渲染的窗口且未生成，只能是 `inactive`。用户设备上导致焦点丢失的具体窗口未能确认。

修复：`_isVisible` 将 `null`、`resumed`、`inactive` 视为可见，生成、检测和保存只在 `hidden`/`paused`/`detached` 时暂停；从不可见恢复时立即检查一次，`resumed` 与 `inactive` 互相切换不打乱节奏。「重新生成二维码」「重试连接」「重试保存」、切换登录方式和提交 Cookie 均视为窗口可见；按钮只在自动生成即将开始时禁用，并在隐藏时显示「应用回到前台后将自动生成登录二维码。」。桌面窗口失去焦点但仍可见时同样继续检测。

验证（2026-11-14，API 36 arm64 模拟器，4 KB 页）：

| 检查 | 结果 |
| --- | --- |
| 官方 `0.3.1` arm64 APK，前台打开 | 生成二维码并进入自动检测 |
| 临时设备测试：真实内嵌运行时与网络，窗口创建前将生命周期置为 `inactive` | `0.3.1` 窗口 20 秒内未调用运行时，停在「正在生成登录二维码…」；修复后约 4 秒显示二维码，首次检测返回 `pending` |
| 修复后的测试签名 release APK（arm64） | 前台打开即生成；切到桌面再返回保持同一二维码，不重新生成 |
| Flutter | 新增 4 项生命周期回归（修复前 2 项失败），`flutter analyze` 无问题，全量 914 项通过、2 项可选跳过 |

设备测试使用源码当前运行时（含本页上文的依赖与状态修复），只替换窗口代码做前后对比；临时测试会发起真实二维码生成与查询请求，未加入仓库测试。未在报告问题的 Pixel 真机复验，未进行真实扫码登录。

## 检查范围

- 逐项检查 `qr_start`、`qr_poll`、`login_cookie`、`login_state`、`search`、`purchase_context`、`build_config`、`validate` 与 `payment_qr`；核对移动端拒绝 `run`。
- 使用 Android 锁定依赖、真实 vendor 源码和虚构平台响应覆盖查询、配置、二维码、压缩响应、连续调用、账号隔离与异常后恢复；网络替身只替换传输响应，不替换业务引擎。
- 检查 Flutter MethodChannel 的 JSON、异常与超时，以及扫码会话前后台切换、旧结果丢弃、账号巡检协调和付款码显示。
- 检查 Chaquopy 3.11、API 36、arm64-v8a/x86_64 配置、JNI、私有目录权限、Keystore、打包模块和原生库对齐。
- API 36 模拟器使用独立测试应用身份，避免覆盖已有应用和资料；只使用合成数据。已有远程部署包没有随本次排查重建，因此本轮不把资源解包或实际 SSH 部署列为验收结果。

## 安全复核

新增依赖仅补齐上游查询原本使用的标准 HTTPX/HTTP2 路径；版本与桌面锁一致。标准客户端保持证书链和域名校验，新增离线 TLS 握手回归检查未受信证书和域名不匹配。请求压缩协商只减少编码类型，不增加网络地址或自制 TLS 实现。

Cookie、购票人、地址和配置仍通过内存及已认证通道处理；上游 Cookie 存储仍为内存，原始日志保持禁用。客户端拒绝本地抢票，不调用通知构造或发送，不启动 Web UI、Gradio、分享或上游启动器。Sisters 的 `standard`、单请求批次、固定尝试上限、空通知与运行参数白名单保持不变。环境代理与 CA 配置仍可能影响 HTTP 客户端，未新增“完全忽略环境”的承诺。

依赖许可复核：补入的 Python 包及版本已包含于桌面运行时与既有离线许可资产，核对覆盖后同步更新许可输入清单。此次没有新增未收集的依赖许可文本。

## 验证边界

本次工作区修复尚未发布。源码测试、模拟响应、模拟器测试和 APK 静态检查分别记录，不等同于 Android 真机、全部设备/页大小、x86_64 实际运行或真实账号登录、下单、付款、出票验收。Flutter 的请求超时不会强制中断共享 Python 解释器；网络超时和串行队列仍是其现有运行边界。

## 本地验证结果（2026-11-14）

| 检查 | 结果 |
| --- | --- |
| Android 锁定依赖环境 runtime 全套 | 115 项中 112 项通过，3 项需要桌面原生依赖的检查跳过；Android 专项 17 项全通过，`pip check` 通过。 |
| 桌面依赖环境 runtime 全套 | 115 项中 106 项通过，9 项需要 PyPNG 的 Android 专项跳过；与 Android 环境互补。 |
| Python 构建与发布脚本 | 122 项通过；包含缺模块、错版本、缺 CA、损坏资产、ELF/APK 对齐不足等拒绝用例；离线许可输入与覆盖检查通过。 |
| Flutter | `flutter analyze` 无问题；全量 910 项通过，2 项可选测试跳过。 |
| Go | `go test -race ./...` 与 `go vet ./...` 通过。 |
| API 36 arm64 模拟器 | 原生集成 5 项通过：真实客户端自检/非法操作拒绝、JNI/路径权限、连续二维码与 Flutter PNG 解码、合成任务配置生成/校验、Keystore 读写删除。模拟器实际页大小为 4096 字节。 |
| 两种 Android 架构本地测试构建 | arm64-v8a 与 x86_64 debug APK 均构建成功；两者均通过 Python/上游源码模块、锁定依赖版本、CA、Chaquopy 资产校验和、全部原生库 ELF 与未压缩库 APK 数据偏移的 16 KB 静态检查。没有在 16 KB 页设备或 x86_64 模拟器上执行。 |
| CI | 工作流 YAML 本地解析通过，已增加 API 36 x86_64 原生测试；本轮没有推送或运行远程 CI。 |

原生测试命令：准备 Android 源码与 JNI 后，在 LastOrder 下执行 `flutter test integration_test/android_embedded_test.dart -d <设备ID> --name 'Android (embedded|JNI|Keystore)'`。该过滤器明确排除需要完整四平台部署包的资源解包用例。本次使用隔离构建副本与独立应用身份，未覆盖已有应用；构建产物没有完整部署包，只作为本地审计测试包，不能分发为正式 LastOrder。

16 KB 检查分别核对 ELF 的 LOAD 段和 APK 内可直接映射的库文件数据偏移，依据 [Android 官方页大小说明](https://developer.android.com/guide/practices/page-sizes)。Chaquopy 内嵌归档中运行时解包的库只做 ELF 对齐检查。静态通过不等于 16 KB 真机已运行。

公开版本仍以发布记录为准。
