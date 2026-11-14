# biliTickerBuy 运行时

当前 MisakaNetwork 源码锁定 biliTickerBuy **v2.15.18** 的 Python 核心代码。LastOrder 本地登录、查询活动和生成配置；Sisters 在隔离子进程中执行同一版本的抢票引擎。界面和服务均不通过拼接命令行传递 Cookie，也不需要用户另装 Python 或下载引擎。既有安装包的内嵌版本以各自发布记录为准。

## 上游版本锁定

2026-11-05 核对 [GitHub 最新发布 v2.15.18](https://github.com/mikumifa/biliTickerBuy/releases/tag/v2.15.18)，标签和主分支均指向提交 `227ebf73f5af3eec0019984a7cbcb722977453e8`。该提交的 `pyproject.toml` 仍声明包版本 `2.15.17`，因此不能仅用 Python 包版本识别源码。本项目对外回报 GitHub 发布版本 `2.15.18`，来源清单同时记录 `tag`、`revision` 和 `package_version`。

升级核对发现，此前内嵌的 56 个上游文件已与此提交逐一匹配；本次同步版本标识并补齐固定提交导入与来源记录，核心 API、依赖锁定版本、Cookie 内存隔离和任务结果语义不变。既有配置无需迁移；安装包与已部署 Sisters 需重新构建、部署后才会回报新版本。

重新导入时，从包含该提交的本地 Git 仓库导出固定提交的白名单文件（命令不会联网）：

```sh
python3.11 runtime/vendor_bili.py /path/to/biliTickerBuy
```

导入直接读取 Git tree/blob 对象，忽略工作区修改、未跟踪文件和本机 archive 属性，在替换目标前校验源码类型、上游包版本和嵌入补丁锚点。替换失败时恢复原目录；若恢复也失败，保留原文件备份并在错误中给出恢复路径。测试覆盖这些失败分支及各组件的版本一致性。后续升级需要先审核新提交，完成下述[升级安全核查](#升级安全核查)，再调整脚本中的版本、标签、提交和包版本约束，重新生成清单并运行测试。

## 接入安全约束

以下限制适用于 LastOrder 与 Sisters 的全部平台，以及开发调试、打包与部署过程。只通过本项目的内嵌 bridge 调用上游核心接口；上游支持某项功能不代表本项目允许启用。

| 禁用功能 | 本项目要求 | 核查依据 |
| --- | --- | --- |
| 代理池并发 `local_fanout` | 创建订单策略保持 `standard`，禁止使用其自制 TLS 客户端；平台 HTTPS 请求保留服务器证书链和域名验证。 | 当前上游自制 TLS 握手未验证服务器证书链、域名及 `CertificateVerify`，可能让恶意代理或劫持连接的对端取得 Cookie 与购票资料。 |
| 上游 Docker 与 Web UI | 不使用上游 Docker 镜像或启动器运行服务，不启动上游 Gradio Web UI、文件下载接口或公网分享；不能仅以“不使用 Docker”作为隔离条件。 | 当前上游 Docker 分支自动请求 Gradio 分享，Web UI 未配置访问鉴权且提供登录 Cookie 文件下载。 |
| 第三方通知 | Server酱、PushPlus、Bark、ntfy、MeoW、Telegram 及自定义推送渠道均不启用，相关密钥、地址与账号配置保持为空。 | 当前上游成功通知包含账号昵称、活动、票档和购票人姓名；其中 PushPlus 使用明文 HTTP。 |

Docker 限制针对上游应用的运行与服务入口，不禁止本项目为目标平台准备依赖、构建产物而使用的隔离构建容器。代理池并发限制不影响 LastOrder 向多个 Sisters 分发任务；任务状态仍按本项目协议回传 LastOrder，不转交上游第三方推送渠道。

2026-11-12 对固定提交 `227ebf73f5af3eec0019984a7cbcb722977453e8` 的源码审查与离线模拟确认了上述行为：自制 TLS 接受自签名且域名不匹配的测试证书，标准验证客户端拒绝同一证书；模拟通知包含姓名，但正常生成的通知正文不含 Cookie、证件号、手机号或地址。未发现向固定第三方接收账号暗传完整凭据的直接代码证据。这不代表已证明历史上没有泄露，也不覆盖所有第三方依赖、发行二进制或真实业务行为；验证使用虚构数据，未执行真实登录、购票或公网分享。

当前隔离由以下调用与构建边界共同维持，不能只依赖用户在界面上关闭开关：

- `runtime/bridge.py` 的 `run_task` 仅接受明确的 `runtime_options` 白名单，不开放并发策略或通知参数。`BuyConfig.from_runtime_options` 从运行参数构建配置，不合并上游 `BTB_*` 买票与通知环境配置；当前 `RuntimeOptions` 的策略为 `standard`，通知配置为空。不得通过环境变量、配置文件、命令行或新增参数绕过这些限制。进程仍继承其他环境设置，HTTP 客户端也未统一禁用环境代理或 CA 配置，不能将当前隔离描述为完全忽略环境变量或强制所有请求直连。
- `runtime/vendor_bili.py` 的导入白名单不包含上游 Web UI、Docker 启动文件和更新器；`runtime/build.py` 不打包 Gradio。独立运行时与 Android 内嵌客户端均不得新增这些服务入口。
- 自制 TLS 和通知模块仍可能作为核心源码的一部分出现在内嵌目录中，当前结论是调用路径未启用，并非相关缺陷已修复或代码已全部移除。默认值、导入副作用或调用方式变化后必须重新核查。

### 请求间隔与固定尝试上限复核（2026-11-13，未发布）

本次接通任务请求间隔并将每轮尝试上限固定为 40；上游仍为 v2.15.18 / `227ebf73f5af3eec0019984a7cbcb722977453e8`，导入白名单、内嵌快照和依赖锁定未变。重新审查 `interface/auth.py`、`interface/search.py`、`interface/common.py`、`util/request/BiliRequest.py`、`task/buy.py`、配置与通知构造及 bridge 入口，未增加网络目标或敏感数据出口。扫码、身份校验与搜索使用默认验证的 requests；场次、购票人与地址查询以及标准下单路径使用 httpx，沿用 `Session.verify=True`，超时或协议错误重建同一客户端，不切换自制 TLS。环境代理与 CA 设置仍可能影响请求路径和信任边界。

`runtime/tests/test_bridge.py` 补充间隔默认值、边界、非法值、固定 40 次以及禁止覆盖上限、并发策略、代理、通知和分享参数的离线回归；源码与锁定依赖检查没有引入上游 Web UI、Gradio 或 Docker 启动入口。`runtime/tests/test_runtime_security.py` 使用真实内嵌配置构造与依赖、虚构购票资料、禁止网络的替身验证：购票配置、`BTB_*` 环境变量及配置数据库中的覆盖值不能改变间隔、固定上限、`standard` 策略、单请求批次或空通知设置；通知管理器无注册渠道，调用发送也不产生 HTTP 请求。Cookie 继续经内存 CookieManager 供平台请求使用，购票资料进入原订单载荷，原始日志不回传。上游成功通知正文仍可能包含姓名，因此空通知约束继续保留。

TLS 回归从实际 `BiliRequest` 创建的 httpx 传输取得 SSLContext，以内存 BIO 完成握手：拒绝未受信的自签名证书，拒绝受信但域名错误的证书，接受受信且域名正确的测试证书。完整运行时依赖环境中，`python -m unittest discover -s runtime/tests -v` 的 73 项测试全部通过，无跳过；未安装依赖时上述两项真实引擎测试会明确跳过。此结论限于固定源码、当前开发环境依赖和离线模拟路径，不是所有第三方依赖、各平台发行二进制或真实登录、下单、出票的安全验收；本次未构建发布安装包。

### 付款码回显接入复核（未发布）

本次扩展的是支付结果过滤与本地二维码编码，固定上游版本、vendor 快照、导入白名单、依赖及 `standard` 下单参数均未改变。取码仍走上游已有 `getPayParam` 与下单的同一 `BiliRequest`；新增 `payment_qr` 仅把经过严格白名单校验的字符串编码成内存 PNG，不访问支付 URL，不请求新付款参数或订单状态。Python、Go、Dart 分别检查输入，订单详情只由合法订单号构造；支付 token、链接及二维码不进入日志、事件或普通持久化文件。

平台 HTTPS 验证、内存 Cookie、空通知配置和无 Web UI/Gradio 分享限制继续保留；本地编码复用既有二维码依赖，不新增推送器或服务入口。源码核查范围、白名单依据与需要覆盖的离线回归见[付款码回显](付款码回显.md#接入安全核查范围)。这些结论限于源码与离线模拟，不是全部依赖、发行二进制或真实支付业务的安全验收。

### 登录二维码编码修复复核

本次只调整 bridge 的本地二维码编码：`qr_start` 与 `payment_qr` 改用同一 `encode_qr_png`，显式选择 Pillow 的 `PilImage`，无法导入时选择 PyPNG 的 `PyPNGImage`，在内存生成 PNG。qrcode 8.2 未指定工厂时会先无条件导入 Pillow，源码中的 PyPNG 回退实际不可达；Android 内嵌客户端按 `runtime/requirements-android.lock` 只携带 qrcode 与 PyPNG，因此已交付的 0.3.0 Android 登录二维码始终生成失败，异常又被通用处理报成「biliTickerBuy 操作失败，请检查登录状态、活动信息与网络连接」。源码历史显示更早的 Android 版本使用同一实现。现在编码组件缺失返回固定的 `qr_encoder_unavailable`（「内置二维码组件不完整，请重新安装此版本」），不回显二维码内容或原始异常；其他编码异常仍按通用脱敏错误处理。

上游 v2.15.18 / `227ebf73f5af3eec0019984a7cbcb722977453e8`、vendor 快照、导入白名单、依赖锁定、`standard` 下单参数与运行参数均未改变。`start_qr_login(qr_image_path=False)` 仍只请求平台二维码生成接口，使用默认验证的 requests，不写二维码文件；新增编码只在内存处理上游返回的登录链接，不访问该链接，不新增网络目标、通知、遥测或服务入口，Cookie 与购票资料不经过此路径。空通知配置与无 Web UI/Gradio 分享限制保持不变。

`runtime/tests/test_bridge.py` 补充有 Pillow 时使用 `PilImage`、无 Pillow 时显式使用 `PyPNGImage`、编码组件缺失时两种二维码操作均返回固定错误且不回显内容的离线回归。`runtime/tests/test_android_bridge.py` 在可导入 qrcode 与 PyPNG 时隐藏 Pillow，经 Android 适配层真实生成登录与付款二维码，禁止网络，确认私有缓存未落盘，并逐模块核对 PNG 与二维码矩阵；这些用例在修复前的 bridge 上失败。CI 的 Android 作业先按 Android 依赖锁建立独立环境，断言包含 qrcode 与 PyPNG 且不含 Pillow，再运行全部 runtime 测试。

2026-11-14 本地结果：修复提交阶段 runtime 测试在 Android 依赖集合（Python 3.11.13、qrcode 8.2、pypng 0.20220715.0，无 Pillow）、完整桌面运行时依赖（Python 3.11.13）与未安装依赖的 Python 3.13.5 下均为 92 项通过，分别跳过 3、2、7 项依赖不满足的真实环境测试；后续 `0.3.1` 发布构建阶段，Android 依赖集为 105 项通过、3 项跳过，完整桌面依赖集为 106 项通过、2 项跳过。Android 依赖集合生成的登录与付款二维码经本机系统识别器离线解码，与虚构内容一致；实际 `LoginDialog` 在 Flutter 测试环境中能解码并显示这种 1 位灰度 PNG。`0.3.1` 的 GitHub Actions（[43576574662](https://github.com/poppinzhang/MisakaNetwork/actions/runs/43576574662)）`package / android` 作业已在独立无 Pillow 环境中运行上述 Android 依赖集回归测试并完成双架构 APK 构建与发布。结论仍限于源码、离线模拟、CI 构建校验与宿主环境，未在 Android 真机或模拟器上验证，未执行真实哔哩哔哩扫码登录，也不是全部依赖或发行二进制的安全验收。

### 自动扫码轮询适配复核

0.3.1 起将 `qr_poll` 从上游阻塞轮询改为本项目 bridge 内的一次平台状态查询，由 LastOrder 在前一次完成后等待 2 秒调度。参数只接受 `qrcode_key`；不再接受 `timeout_seconds`、自定义地址、TLS 开关或其它扩展参数。只有 HTTP 成功、外层业务成功且平台状态为 `86038` 时才返回 `expired`，不按本地 180 秒或响应中的通用 `ttl` 判定过期。`86101` / `86090` 分别返回 `pending` / `scanned`；网络异常、HTTP 429 和 5xx 返回 `transient_error`，其余不明确响应返回 `failed`。确认后身份验证失败必须重新扫码，不能继续轮询来假定可再次领取一次性凭据。

核查范围与隔离方式：

- 网络目标仍是固定官方 HTTPS `passport.bilibili.com/x/passport-login/web/qrcode/poll` 与既有 `api.bilibili.com/x/web-interface/nav`。轮询禁止重定向，连接/读取超时固定为 `(3.05, 8)` 秒，保留 requests 默认的证书链与域名验证；不跟随响应的登录链接，不引入新域名、HTTP 客户端或自制 TLS。
- `Set-Cookie` 由 requests 在内存中解析。扁平化为运行时凭据前，仅保留显式指定 `bilibili.com` / `.bilibili.com`、根路径 `/`、当前未过期的 Cookie；host-only、passport 子域或非根路径等较窄作用域不扩大使用范围。合格候选中同名 Cookie 一律拒绝，不按顺序任选。候选还须通过既有 Cookie 格式检查和平台 UID 验证才返回 LastOrder。
- 非成功结果只返回白名单状态与固定提示；不转发原始消息、异常、登录链接或 `refresh_token`。二维码标识、Cookie 与图片仅经内存、本机管道或 Android 原生桥接流转，不进入普通日志或临时文件。LastOrder 的后台待处理成功结果和保存重试结果仅在当前窗口内存保留，明确取消、切换方式或重新生成时丢弃。
- 上游 v2.15.18 / `227ebf73f5af3eec0019984a7cbcb722977453e8`、vendor 快照、导入白名单、依赖锁定与 `standard` 下单参数均未改变；通知仍为空，环境与配置白名单未放宽，无上游 Docker、Web UI、Gradio 或分享入口。

离线回归覆盖单次调用与平台状态分类、未知状态与错误响应不误判过期、明确拒绝输入参数覆盖策略、requests 实际传递 TLS 验证参数及禁止重定向、确认后身份验证失败不返回 Cookie，以及真实 `Set-Cookie → RequestsCookieJar` 解析的域、路径、到期和重名约束。Android 适配同时覆盖结构化结果、无敏感日志与无文件落地；原有 `standard`、通知、环境白名单与 Web UI 隔离测试继续执行。2026-11-14 的三组本地 runtime 回归各收集 108 项：Android 锁定依赖环境通过 105 项、跳过 3 项；完整桌面依赖环境通过 106 项、跳过 2 项；未安装运行时依赖的系统 Python 通过 95 项、跳过 13 项。

本次结论限于源码核查、模拟平台响应、宿主环境离线验证与 CI 打包校验；未在真机设备上或真实平台执行扫码登录，不代表所有依赖或真实业务已安全验收。窗口调度、账号巡检协调与前后台语义见 [Cookie 生命周期](LastOrder/Cookie生命周期.md#扫码自动检测与例行检查协调)。

### Android 客户端兼容性复核（2026-11-14，纳入 0.3.2）

本次确认原 Android lock 缺少 `purchase_context` 实际使用的 HTTPX/HTTP2 依赖，且上游请求头声明了未安装的 Brotli/Zstandard 编码；原 `ping` 和替换引擎的测试不能发现这一组合。源码补齐桌面同版本的纯 Python HTTP 栈，Android 仅协商 gzip/deflate，自检离线构造实际传输。共享解释器每次调用独立初始化并关闭上游连接与数据库，清理模块及环境，避免复用已删除的临时目录。

固定上游源码、导入白名单、Sisters 下单参数与通知约束不变；标准 TLS 证书链与域名验证保持开启，新增真实客户端 TLS、完整查询/配置链、资源清理和 APK 结构回归。检查依据、问题复现、模拟器验证与限制见 [Android 兼容性排查](LastOrder/Android兼容性排查.md)。上述改动已随 `0.3.2+12` 进入发布准备（待 GitHub Actions 完成构建与发布核验），不是全部依赖或真实业务的安全验收。

### 升级安全核查

每次升级上游版本、固定提交或相关依赖，以及调整导入白名单、嵌入补丁、启动方式或运行参数时，必须完成以下核查。即使上游宣称已修复问题，也不能自动解除上述禁用约束。

1. 核对目标标签、提交、包版本、依赖锁定与来源清单，审查相对已审核提交的变更，特别是新增网络请求、远程脚本、动态执行与导入副作用。文件哈希一致仅证明来源一致，不替代安全审查。
2. 追踪登录与下单实际使用的 HTTP/TLS 客户端，确认 `standard` 仍执行证书链与域名验证，且不会回退或切换到 `local_fanout` 等未认证对端的实现。检查所有运行入口、默认值、重定向和环境继承，特别是 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 及 CA 配置能否改变请求目标或信任边界。
3. 检查通知配置构造、预检和发送路径，确认所有第三方通知仍禁用；检查 Cookie、购票人姓名、证件、电话和地址的数据去向，不能因新增通知或遥测功能而发送到未经允许的第三方服务。
4. 检查导入白名单、依赖、启动入口与各平台打包结果，确认没有引入上游 Docker/Web UI、Gradio 公网分享或可下载敏感文件的服务；保持 Cookie 内存隔离及原始日志禁用适配有效。
5. 补充或更新离线回归验证，使用虚构凭据与模拟网络覆盖禁用参数拒绝、通知不发送、环境与配置不能绕过限制，以及实际使用的 TLS 路径拒绝不可信或域名不匹配证书。按本文与 `AGENTS.md` 运行适用测试，在本文和 `CHANGELOG.md` 记录审核版本、结果及验证边界；核查未通过前不得将升级引擎接入发布产物。

## 进程协议 v1

0.1.1 起的认证协议：`login_state` 与 `login_cookie` 另返回 `status: valid/expired/unknown`、`uid` 和固定安全提示 `message`；`qr_poll` 的 `confirmed` 结果须在线确认登录身份并返回 `uid`。`logged_in:false` 本身不能作为删除凭据的依据，必须检查 `status:expired`。已有 Cookie 验证的网络异常和不明确响应返回 `unknown`；0.3.1 起的单次扫码查询使用下表状态，扫码确认后无法验证身份返回 `failed` 并要求重新扫码，不返回未经验证的 Cookie。二维码的 `expired` 不代表已保存 Cookie 失效。详见 [Cookie 生命周期](LastOrder/Cookie生命周期.md)。下表记录 0.3.1 起协议；0.3.0 安装包仍使用此前 `qr_poll` 的 `timeout_seconds` 和 `confirmed/timeout/failed` 结果，变更需随完整应用及其运行时一起打包。

启动打包后的 `misaka-runtime/misaka-runtime`，向标准输入写一行 UTF-8 JSON，随后关闭输入。开发环境可使用 `python runtime/bridge.py`。每个进程只处理一个请求；QR 轮询由调用方重复启动进程并携带二维码标识，进程之间没有共享账户状态。

```json
{"op":"ping","params":{}}
```

所有输出都是一行一个 JSON 的标准输出事件，最后一行固定为 `type: result`。输出只含 ASCII，非 ASCII 字符以 `\uXXXX` 转义，因此不受系统代码页影响（Windows 管道默认使用 ANSI 代码页）。普通成功返回 `{"type":"result","ok":true,"data":{...}}`。失败返回 `{"type":"result","ok":false,"error":{"code":"...","message":"..."}}`，退出码为 1。SIGTERM/SIGINT 返回取消结果（退出码 130）；调用方还须处理崩溃、超时、无终态和强制终止。仅退出码为 0 不代表创建了订单。

| op | params | data |
| --- | --- | --- |
| `ping` | 无 | `version`、`bili_version`、`protocol:1`、`ready:true`；导入真实引擎验证依赖，不访问网络 |
| `qr_start` | 无 | `login_url`、`qrcode_key`、`qr_png_base64`；PNG 在内存编码（有 Pillow 用 Pillow，否则用 PyPNG），不落盘 |
| `payment_qr`（未发布） | `payment_code_url`，完整字符串须符合支付白名单 | `qr_png_base64`；仅本地内存生成，不请求平台或支付网站 |
| `qr_poll` | 仅 `qrcode_key`，单次平台查询 | `status:pending/scanned/expired/transient_error/failed/confirmed`；非成功仅含固定 `message`；只有已验证的 confirmed 返回 `cookies`、`username`、`uid` |
| `login_cookie` | `cookies` | `status:valid/expired/unknown`、`logged_in`、`username`、`uid`、`message`；valid 才返回 `cookies` |
| `login_state` | `cookies` | `status:valid/expired/unknown`、`logged_in`、`username`、`uid`、`message` |
| `search` | `keyword`、`cookies`、可选 `page` | `keyword`、`page`、`pagesize`、`total`、`results` |
| `purchase_context` | `project_input`（活动编号或链接）、`cookies`、可选 `selected_date` | `project_id`、`project_name`、`ticket_options`、`buyers`、`addresses`、`cookies` 等上游购买上下文 |
| `build_config` | `purchase_context`、`selection` | 已校验的 biliTickerBuy 任务配置对象 |
| `validate` | `config` | `ok`、`errors`、`warnings`、`error_count`；不回显配置及敏感字段 |
| `run` | `config`、可选 `cookies` 覆盖配置账户、可选 `runtime_options` | `status` 及允许的订单/付款字段 |

Cookie 支持 `[{"name":"...","value":"..."}]`、`{"cookie":[...]}`、`{"cookies":[...]}` 或名称到字符串值的映射。Cookie、二维码标识、购买上下文、生成配置与订单支付信息属于敏感结果：仅通过本机管道或已认证 TLS 信道传递，禁止写入普通日志。LastOrder 持久化账户应使用系统安全凭据存储；付款码回显仅保留在内存，不写普通状态文件。

`selection` 包含从零起的 `ticket_index`、非空 `buyer_indices`、`address_index`，以及 `buyer`（联系人）、`tel`（联系电话），可选 `phone`。当前沿用上游校验：必须选择收货地址，即使活动提供电子票。场次、实名购票人或地址不完整会真实失败，不构造虚假的可执行配置。

`runtime_options` 仅支持 `interval`（整数毫秒，100–60000，默认 1000）、`time_start`（北京时间 `YYYY-MM-DDTHH:MM:SS`，只接受完整日期时间；只写时分的写法会按主机时区补全日期，因此拒绝）和 `wait_for_buy_button`。源码未发布的任务创建支持填写间隔，Sisters 将 `request_interval_ms` 校验后转交为 `interval`，并可同时转交 `time_start`。每轮下单尝试上限由 bridge 固定为 `create_retry_limit=40`，该选项不在输入白名单内，即使传入 40 也会被拒绝；未调整上游快照中的默认值。每轮上限不代表任务累计尝试上限，请求之间的实际时间还受响应耗时、重新准备与冷却逻辑影响。每个任务采用单请求创建订单批次，禁用声音、外部通知、自动打开浏览器与随机日志。上游按北京时间（UTC+8）倒计时，与 Sisters 主机时区无关；LastOrder 在界面标注北京时间。

执行期间会输出 `{"type":"progress","status":"running","stage":"preparing","message":"抢票任务执行中","attempt_current":1,"attempt_total":40}`。`stage` 是稳定的协议代码，由上游阶段名翻译而来：`starting`（启动）、`waiting`（等待开票，可带 `countdown_seconds`）、`preparing`（订单准备）、`ordering`（创建订单）、`ordered`（抢票成功）、`page_timeout`（购票页校验超时）；其他上游阶段统一为 `working`。`status` 取 `running`、`cooldown`、`succeeded`、`duplicate_order`、`failed`、`cancelled`、`completed` 之一。消息与 stage 都不转发上游原文、HTTP 响应、代理信息或原始错误字符串。上游新增阶段名时测试会失败，提醒同步更新 bridge 与 Sisters 的词表。终态 `succeeded` 表示上游结构化状态确认创建订单；`duplicate_order` 表示检测到已有订单：上游在限购已有订单（100003）、存在未完成订单（100048）或重复订单（100079）时以 `completed` 停止，bridge 启动任务时把这三条停止规则改报为 `duplicate_order`。`completed` 表示结束但尚未确认创建订单，不能向用户展示抢票成功；`failed` / `cancelled` 返回 `ok:false`。一旦出现 `succeeded` 或 `duplicate_order`，之后的上游异常或取消只会停止任务，不再改变终态。

源码未发布的付款字段规则：`order_id` 必须是 1–80 位 ASCII 正整数且没有前导零；`order_detail_url` 从订单号固定生成为 `https://show.bilibili.com/platform/orderDetail.html?order_id=<order_id>`。`payment_code_url` 只接受 `weixin://wxpay/bizpayurl?pr=<token>` 或 `https://qr.alipay.com/<token>` 的整串匹配，token 为 1–512 个 `[A-Za-z0-9_-]` 字符，输入总长最多 2048 个 ASCII 字符；不接受额外参数、片段、端口、用户信息或编码变体。上游 `payment_qr_url` 实际是订单详情页，不能当作付款码，不再随新的付款结果透传。非法支付码不影响合法订单详情兜底；缺少合法订单号不返回支付字段。运行时不自动付款，不查询支付状态，不根据二维码推断订单已付款或出票。完整链路见[付款码回显](付款码回显.md)。

## 嵌入与隐私隔离

`runtime/vendor_bili.py` 只复制明确白名单中的 Python 文件、失败提示资源和许可证，不复制上游工作目录、账户文件、配置、缓存、日志、备份或构建产物。`vendor/biliTickerBuy/MANIFEST.json` 记录每个文件的原始与实际 SHA-256，以及两处嵌入适配：

1. 将原引擎的可写目录重定向至每进程独立的临时目录，并关闭原始 Loguru 文件/控制台输出。
2. 接口 Cookie 存储改为内存；启动时跳过自动 NTP 查询，`ping` 与配置校验不会请求平台。

CLI 进程在删除临时目录之前关闭上游全局 `ConfigDB` 与 `main_request.cookieManager.db`。引擎导入中途失败时，同样从明确的上游模块与构造上下文释放已打开的数据库；一个句柄关闭失败不妨碍尝试关闭其余句柄。清理失败以非零退出码回报，不输出原始异常或临时路径，不追加第二条 result，不覆盖已确认订单结果；尚未输出结果时返回脱敏错误。此处理修复 Windows 不允许删除仍被打开文件而导致的正常请求退出失败。

进程使用 `umask 077`，临时配置目录在正常结束和可处理取消后清理；SIGKILL 可能遗留空配置目录，但不写入任务 Cookie。共享进程内的多个引擎实例可能共享上游全局状态，因此 Sisters 必须为每个任务启动独立 bridge 进程。

上游 LICENSE 为 **PolyForm Noncommercial License 1.0.0**，包含 `Required Notice: Copyright (c) 2023 mikumifa`。分发包附完整许可证、NOTICE、源文件清单与依赖许可；使用范围以许可证原文为准。

## 构建与验证

Python 开发/构建环境最低 3.11。核心依赖版本固定在 `runtime/requirements.lock`，打包依赖在 `runtime/requirements-build.lock`。PyInstaller 的 onedir 产物携带 Python、核心引擎与依赖，运行目标机不需要联网安装依赖。引擎请求票务平台仍然需要网络。

```sh
python3.11 -m venv .build/runtime-venv
.build/runtime-venv/bin/python -m pip install -r runtime/requirements-build.lock
.build/runtime-venv/bin/python -m unittest discover -s runtime/tests -v
.build/runtime-venv/bin/python runtime/build.py --output .build/runtime/macos-arm64
```

Android 内嵌客户端携带 `runtime/requirements-android.lock` 中的纯 Python 依赖（含 HTTPX/HTTP2、qrcode 与 PyPNG，不含 Pillow/Brotli/Zstandard）。修改 bridge、二维码编码或客户端操作后，还需在这一依赖集合中运行测试；完整桌面依赖包含 Pillow，无法发现 Android 缺少 Pillow 导致的问题。CI 的 Android 作业执行同样检查。

```sh
python3.11 -m venv .build/android-client-venv
.build/android-client-venv/bin/python -m pip install --only-binary=:all: -r runtime/requirements-android.lock
.build/android-client-venv/bin/python -m unittest discover -s runtime/tests -v
```

必须在各目标系统和架构原生构建，Linux 使用 Ubuntu 24.04 同代构建环境，macOS 使用 15.0+。`build.py` 将源码复制至不含个人信息的通用临时目录，构建后执行真实引擎依赖 `ping`，不会创建订单。禁止把 macOS runtime 放入 Linux 包；Go 二进制可交叉编译，但 Python 运行时必须匹配操作系统和架构。

测试覆盖协议、二维码状态、有无 Pillow 时的二维码编码与组件缺失错误、Cookie 格式、配置拒绝、取消、日志敏感数据隔离、订单链接验证、真实状态判定、已有订单停止规则映射（并与内嵌上游规则表比对）、确认终态不被后续异常覆盖、模拟 Windows 代码页的 ASCII 输出、源文件清单及无效请求。自动化验证只进行离线导入、配置与模拟上游事件，不执行真实抢票、下单或支付。在线登录与真实购票验收需要用户账户与明确的目标场次。
