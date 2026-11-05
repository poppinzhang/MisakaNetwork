# biliTickerBuy 运行时

MisakaNetwork 0.1.1 内置 biliTickerBuy **2.15.17** 的 Python 核心代码。LastOrder 本地登录、查询活动和生成配置；Sisters 在隔离子进程中执行同一版本的抢票引擎。界面和服务均不通过拼接命令行传递 Cookie，也不需要用户另装 Python 或下载引擎。

## 进程协议 v1

0.1.1 认证协议：`login_state` 与 `login_cookie` 另返回 `status: valid/expired/unknown`、`uid` 和固定安全提示 `message`；`qr_poll` 的 `confirmed` 结果须在线确认登录身份并返回 `uid`。`logged_in:false` 本身不能作为删除凭据的依据，必须检查 `status:expired`。网络异常和不明确响应返回 `unknown`；扫码后无法验证身份则返回可重试错误，不返回未经验证的 Cookie。详见 [Cookie 生命周期](LastOrder/Cookie生命周期.md)。下表记录当前协议。

启动打包后的 `misaka-runtime/misaka-runtime`，向标准输入写一行 UTF-8 JSON，随后关闭输入。开发环境可使用 `python runtime/bridge.py`。每个进程只处理一个请求；QR 轮询由调用方重复启动进程并携带二维码标识，进程之间没有共享账户状态。

```json
{"op":"ping","params":{}}
```

所有输出都是一行一个 JSON 的标准输出事件，最后一行固定为 `type: result`。输出只含 ASCII，非 ASCII 字符以 `\uXXXX` 转义，因此不受系统代码页影响（Windows 管道默认使用 ANSI 代码页）。普通成功返回 `{"type":"result","ok":true,"data":{...}}`。失败返回 `{"type":"result","ok":false,"error":{"code":"...","message":"..."}}`，退出码为 1。SIGTERM/SIGINT 返回取消结果（退出码 130）；调用方还须处理崩溃、超时、无终态和强制终止。仅退出码为 0 不代表创建了订单。

| op | params | data |
| --- | --- | --- |
| `ping` | 无 | `version`、`bili_version`、`protocol:1`、`ready:true`；导入真实引擎验证依赖，不访问网络 |
| `qr_start` | 无 | `login_url`、`qrcode_key`、`qr_png_base64`；PNG 不落盘 |
| `qr_poll` | `qrcode_key`、可选 `timeout_seconds`（1–60，默认 5） | `status:confirmed/timeout/failed`；只有已验证的 confirmed 返回 `cookies`、`username`、`uid` |
| `login_cookie` | `cookies` | `status:valid/expired/unknown`、`logged_in`、`username`、`uid`、`message`；valid 才返回 `cookies` |
| `login_state` | `cookies` | `status:valid/expired/unknown`、`logged_in`、`username`、`uid`、`message` |
| `search` | `keyword`、`cookies`、可选 `page` | `keyword`、`page`、`pagesize`、`total`、`results` |
| `purchase_context` | `project_input`（活动编号或链接）、`cookies`、可选 `selected_date` | `project_id`、`project_name`、`ticket_options`、`buyers`、`addresses`、`cookies` 等上游购买上下文 |
| `build_config` | `purchase_context`、`selection` | 已校验的 biliTickerBuy 任务配置对象 |
| `validate` | `config` | `ok`、`errors`、`warnings`、`error_count`；不回显配置及敏感字段 |
| `run` | `config`、可选 `cookies` 覆盖配置账户、可选 `runtime_options` | `status` 及允许的订单/付款字段 |

Cookie 支持 `[{"name":"...","value":"..."}]`、`{"cookie":[...]}`、`{"cookies":[...]}` 或名称到字符串值的映射。Cookie、二维码标识、购买上下文与生成配置属于敏感结果：仅通过本机管道或已认证 TLS 信道传递，禁止写入普通日志。LastOrder 持久化账户应使用系统安全凭据存储。

`selection` 包含从零起的 `ticket_index`、非空 `buyer_indices`、`address_index`，以及 `buyer`（联系人）、`tel`（联系电话），可选 `phone`。当前沿用上游校验：必须选择收货地址，即使活动提供电子票。场次、实名购票人或地址不完整会真实失败，不构造虚假的可执行配置。

`runtime_options` 仅支持 `interval`（整数毫秒，100–60000，默认 1000）、`time_start`（北京时间 `YYYY-MM-DDTHH:MM:SS`，只接受完整日期时间；只写时分的写法会按主机时区补全日期，因此拒绝）、`create_retry_limit`（1–100，默认 20）和 `wait_for_buy_button`。每个任务采用单请求创建订单批次，禁用声音、外部通知、自动打开浏览器与随机日志。上游按北京时间（UTC+8）倒计时，与 Sisters 主机时区无关；LastOrder 在界面标注北京时间。目前 Sisters 只转交 `time_start`，其余选项使用默认值。

执行期间会输出 `{"type":"progress","status":"running","stage":"preparing","message":"抢票任务执行中","attempt_current":1,"attempt_total":20}`。`stage` 是稳定的协议代码，由上游阶段名翻译而来：`starting`（启动）、`waiting`（等待开票，可带 `countdown_seconds`）、`preparing`（订单准备）、`ordering`（创建订单）、`ordered`（抢票成功）、`page_timeout`（购票页校验超时）；其他上游阶段统一为 `working`。`status` 取 `running`、`cooldown`、`succeeded`、`duplicate_order`、`failed`、`cancelled`、`completed` 之一。消息与 stage 都不转发上游原文、HTTP 响应、代理信息或原始错误字符串。上游新增阶段名时测试会失败，提醒同步更新 bridge 与 Sisters 的词表。终态 `succeeded` 表示上游结构化状态确认创建订单；`duplicate_order` 表示检测到已有订单：上游在限购已有订单（100003）、存在未完成订单（100048）或重复订单（100079）时以 `completed` 停止，bridge 启动任务时把这三条停止规则改报为 `duplicate_order`。`completed` 表示结束但尚未确认创建订单，不能向用户展示抢票成功；`failed` / `cancelled` 返回 `ok:false`。一旦出现 `succeeded` 或 `duplicate_order`，之后的上游异常或取消只会停止任务，不再改变终态。

订单字段仅允许数字 `order_id` 与 HTTPS Bilibili 域名的 `order_detail_url`、`payment_qr_url`、`payment_code_url`。运行时不自动付款。调用方需提示用户前往平台订单页确认并付款。不要仅凭日志中的“成功”或进程正常退出推断下单成功。

## 嵌入与隐私隔离

`runtime/vendor_bili.py` 只复制明确白名单中的 Python 文件、失败提示资源和许可证，不复制上游工作目录、账户文件、配置、缓存、日志、备份或构建产物。`vendor/biliTickerBuy/MANIFEST.json` 记录每个文件的原始与实际 SHA-256，以及两处嵌入适配：

1. 将原引擎的可写目录重定向至每进程独立的临时目录，并关闭原始 Loguru 文件/控制台输出。
2. 接口 Cookie 存储改为内存；启动时跳过自动 NTP 查询，`ping` 与配置校验不会请求平台。

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

必须在各目标系统和架构原生构建，Linux 使用 Ubuntu 24.04 同代构建环境，macOS 使用 15.0+。`build.py` 将源码复制至不含个人信息的通用临时目录，构建后执行真实引擎依赖 `ping`，不会创建订单。禁止把 macOS runtime 放入 Linux 包；Go 二进制可交叉编译，但 Python 运行时必须匹配操作系统和架构。

测试覆盖协议、二维码状态、Cookie 格式、配置拒绝、取消、日志敏感数据隔离、订单链接验证、真实状态判定、已有订单停止规则映射（并与内嵌上游规则表比对）、确认终态不被后续异常覆盖、模拟 Windows 代码页的 ASCII 输出、源文件清单及无效请求。自动化验证只进行离线导入、配置与模拟上游事件，不执行真实抢票、下单或支付。在线登录与真实购票验收需要用户账户与明确的目标场次。
