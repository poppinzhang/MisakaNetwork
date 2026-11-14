# Windows Sisters（0.4.0）

0.4.0 新增 Windows 10 及以上的 **x64 / amd64** Sisters 实现，不支持 Windows 7/8/8.1、32 位 Windows 或 Windows arm64。每份完整 LastOrder 携带 Linux/macOS arm64/x64 与 Windows x64 共五种同版本离线包；0.3.2 及更早安装包不包含 Windows Sisters。本文描述已[公开发布的 0.4.0+13](https://github.com/poppinzhang/MisakaNetwork/releases/tag/0.4.0) 的实现与部署要求，全平台预构建、正式构建和 Windows 原生 CI 证据见 [0.4.0 发布记录](../releases/0.4.0.md)。

## 机器准备

1. 准备 Windows 10+ x64 机器，启用 OpenSSH Server，确认 LastOrder 可以通过 SSH 连接。Windows 自带可选组件的安装方法见 [Microsoft OpenSSH 文档](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)。该安装方式要求 Windows 10 1809+；更早的 Windows 10 需要管理员另外准备兼容的 OpenSSH Server，不由 LastOrder 安装或修改 SSH 服务。
2. 使用具有管理员权限的 SSH 账号。安装、更新和停止系统服务需要提升后的管理员令牌，普通 SSH 用户会在上传前被拒绝；LastOrder 不弹出远程 UAC、不保存 SSH 密码，也不修改远程认证策略。密码或私钥均沿用现有 SSH 表单。
3. 主机需提供 Windows PowerShell 和 .NET 的 ZIP 解包能力；无需安装 Python、Go、biliTickerBuy 或上游 Web UI。部署不依赖较新 Windows 才自带的 `tar.exe`。
4. 由管理员按实际网络范围开放 SSH 端口及所选 Sisters TCP 端口，默认分别为 22、20001。部署不会自动扩大防火墙开放范围。关闭电脑、睡眠或重启会中断任务，应保持机器运行。
5. 在 LastOrder「机器管理」选择「添加机器」，填写地址、SSH 账号和凭据后点击「安全部署」。首次连接自动保存服务器指纹，后续严格核对；与 Linux/macOS 一样，指纹异常无法跳过。

三家公有云创建模板仍只支持 Linux 镜像；Windows 使用已有机器的 SSH 部署入口。Android 管理端可以部署 Windows Sisters，但 Android 本身不运行 Sisters。

## 服务、权限与任务

部署创建固定名称 `MisakaSisters` 的 Windows 服务，使用独立虚拟账户 `NT SERVICE\MisakaSisters`，不保存运行账户密码，不以 LocalSystem 或 SSH 管理员身份执行抢票。虚拟服务账户的机制见 [Microsoft CreateService 文档](https://learn.microsoft.com/en-us/windows/win32/api/winsvc/nf-winsvc-createservicew)。每台 Windows 主机通过自动部署管理一份该服务。

服务创建通过 `Invoke-CimMethod` 调用 `Win32_Service.Create`，`ServiceType` 与 `ErrorControl` 按该方法的 MOF 定义传入 `uint8`（PowerShell `[byte]`）；不能沿用原生 Win32 API 的 `DWORD` 类型，否则 CIM 会在创建服务前拒绝参数。参数定义见 [Microsoft Win32_Service.Create 文档](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/create-method-in-class-win32-service)。

服务由 Windows SCM 管理，开机自动启动，收到停止或系统关机通知后取消任务并关闭 gRPC。重启只恢复空服务，不恢复执行中的任务、内存 Cookie、订单付款入口或幂等历史。关闭 LastOrder 不会停止这项后台服务。用户应优先在「任务监控」停止任务；管理员也可在 Windows「服务」中停止 `MisakaSisters`。重新部署前需停止或等待任务结束并核对已创建的订单。

服务命令为 `sisters.exe service --config <绝对路径> --temp-dir <绝对路径>`，仅由 SCM 调用；前台调试保留 `sisters.exe serve --config <配置文件>`。服务配置相对路径按配置文件目录解析，不依赖 SCM 的工作目录。服务模式使用受限的临时目录，配置/证书/程序目录向服务账户仅开放读取与执行权限，临时目录允许写入；管理员和 SYSTEM 可维护部署文件，其他普通用户没有访问权限。

每次运行时调用在继续执行前先绑定到 Windows Job Object，取消、超时、正常结束与服务退出都清理该任务的整个进程树，避免仅停止父进程后仍继续请求。此机制遵循 [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) 的子进程归属及关闭清理规则；不是对任意恶意程序的完整沙箱。Sisters 不把 Cookie 放入命令行或服务注册信息，仍只通过标准输入交给内嵌 runtime。

## 部署与回滚

默认安装到 `%ProgramData%\MisakaNetwork\Sisters`，每次上传使用独立版本目录。本地先校验 Windows 离线包，拒绝路径逃逸、链接、Windows 保留文件名、备用数据流和大小写冲突，再通过 SSH 流上传。PowerShell 脚本使用 UTF-16LE `-EncodedCommand`，用户路径作为数据引用，兼容空格与非 ASCII 字符。远端目录拒绝重解析点，不沿链接写入其他目录。

上传时，本地把已校验的 tar.gz 转为 Deflate 最快级别压缩的 ZIP 流，传输量接近离线包本身（以 Linux 包估算，由不压缩的 104 MB 降至 42 MB）；远端先写入版本目录内的临时 `payload.zip`，再用 .NET `ZipFile` 解压并删除。Win32-OpenSSH 为命令提供的标准输入是以 `FILE_FLAG_OVERLAPPED` 打开的命名管道（源码 `contrib/win32/win32compat/fileio.c` 的 `fileio_pipe`），而 Windows PowerShell 的 `[Console]::OpenStandardInput()` 是 .NET Framework 控制台流，每次读取前都会调用 `WaitForAvailableConsoleInput`，在这类管道暂时读空后不再返回（见 [PowerShell/PowerShell#14478](https://github.com/PowerShell/PowerShell/issues/14478#issuecomment-1064764004)）。因此上传和写入私有配置都改用在内存中定义的 `GetStdHandle` 取得继承的标准输入句柄，以同步 `FileStream` 读取；不调用 `Add-Type` 编译代码，也不从可写临时目录向提升后的会话加载 DLL。以 `DefinePInvokeMethod` 定义的 P/Invoke 必须显式设置 `PreserveSig`：缺少时运行时按返回 HRESULT 的方法调用，丢弃 `GetStdHandle` 返回的句柄并得到 0，Windows 11 真机上表现为「standard input unavailable」。

远端解压、安全软件扫描新文件和运行时首次启动期间，连接可能长时间没有数据。准备阶段（上传、写入配置与两项自检）每 30 秒发送一次 SSH keepalive，并等到应答后才发下一次：服务器停止应答时仍由停滞检测在约 2 分钟内中断，整个阶段仍受 15 分钟准备预算约束；切换服务前停止发送，服务切换与回滚继续只受停滞检测约束。上传失败按本地部署包读取失败、远程写入或解压失败（提示检查系统盘空间和安全软件拦截）以及 SSH 连接中断三类给出固定提示，不转发远程原始错误。

安装包和配置在受限目录中准备，运行时自检通过后才切换服务程序路径。新服务通过 SSH 隧道完成 mTLS 检查后，再从 LastOrder 直接检查所选端口；直连失败保留已启动的服务并提示检查网络。切换失败会停止新服务并恢复旧服务配置；首次部署失败则清理新服务。回滚失败明确报错，不能将“已尝试恢复”视为旧服务已正常运行。

源码离线包为 `windows-amd64.tar.gz`，根目录包含 `sisters.exe`、`runtime/misaka-runtime.exe` 与依赖、许可证和版本清单，不包含节点私钥或用户 Cookie。Windows Python 运行时必须原生构建，不能用交叉编译的 Go EXE 替代完整包。全部 LastOrder 目标须包含 Linux/macOS arm64/x64 加 Windows x64 共五份同版本包。

### 0.4.0 上传停滞问题

0.4.0 的上传脚本直接用 `[Console]::OpenStandardInput()` 读取数据。在真实 Win32-OpenSSH 会话中，读取一旦追上网络传入的数据就会停滞，约 2 分钟后连接被停滞检测中断，界面显示「上传或解压 Windows 部署包失败；当前版本未变更」。问题位于远程 Windows 一侧，与使用 Android、macOS 还是 Windows 管理端无关；写入私有配置的步骤使用同一读取方式，存在同样隐患。0.4.0 的 CI 以匿名管道直接启动 PowerShell，没有覆盖这一条件。修复随统一版本 [0.4.1](../releases/0.4.1.md) 交付，安装新版 LastOrder 并重新部署后才对用户生效；0.4.1 的构建与发布状态以该记录为准。

一台 Windows 11 开发机上的三次 0.4.0 部署留下了实际现场：每次都在 `%ProgramData%\MisakaNetwork\Sisters\releases` 下留下未启用的版本目录，其中 `payload.zip` 为 0 字节且仍被占用；对应的 `cmd.exe` 与 `powershell.exe` 在一个多小时后仍在运行。读取在第一段数据之后就停住（首段数据仍在 `FileStream` 缓冲中，未写入磁盘），而 sshd 把会话作业对象的句柄交给了 `cmd.exe`，`cmd.exe` 又在等待卡住的 PowerShell，所以 SSH 会话结束也不会回收它们。这些进程不影响已运行的服务，也不妨碍修复版重新部署；需要释放内存或删除这些版本目录时，重启机器，或结束命令行含 `-EncodedCommand`、父进程为 `cmd.exe` 的对应 `powershell.exe`，再在核对服务路径后删除目录。

## 验证范围

本次修改未升级 biliTickerBuy v2.15.18 固定提交或依赖，不修改导入白名单、网络地址、TLS 验证、`standard` 下单策略、空第三方通知配置或 Web UI/Gradio 限制。新增的是服务运行、进程生命周期与部署打包路径；Windows 服务继承环境的既有影响仍存在，不声称完全忽略代理和 CA 环境设置。离线运行时安全回归继续覆盖真实标准客户端的证书链/域名校验以及配置与环境不能打开被禁用策略的约束。

本地验证和实际原生验收分别记录；Windows 测试包含 SCM 控制与 Job Object 进程树用例，CI Windows 作业运行全量 Go 测试和真实离线运行时冒烟。CI 使用 Windows Server runner，通过也不能替代 Windows 10 实机安装、自启动、SSH 部署/重部署、故障回滚及断连后继续服务的验收。未执行真实账号登录、下单或出票测试，不把源码和模拟验证表述为发行二进制或业务安全验收。

2026-11-14 的 `0.4.0+13` 验证记录：标签前预构建 [43595038721](https://github.com/poppinzhang/MisakaNetwork/actions/runs/43595038721) 实际执行 Windows SCM 集成测试；正式构建 [43597192222](https://github.com/poppinzhang/MisakaNetwork/actions/runs/43597192222) 重新生成全部包并公开发布，Windows Go `internal/control` 测试显示 `cached`，不算新一次 SCM 实测。正式 runtime 检查与真实 Sisters 冒烟重新执行，完整范围以 [发布记录](../releases/0.4.0.md) 为准：

| 范围 | 结果 |
| --- | --- |
| Go 源码与 Windows 原生服务 | 本地全量 Go race/vet 通过；标签前 Windows Server CI 全量 Go race/vet、PowerShell 与隔离 SCM 实测通过，覆盖服务账户、权限、mTLS、失败回滚与进程树清理；正式 control 测试复用缓存结果 |
| Flutter | 本地 macOS analyze 通过、915 项测试通过/2 项跳过；Windows 原生 CI analyze 通过、910 项测试通过/2 项跳过 |
| 打包脚本 | 本地 135 项通过；Windows CI 113 项通过、22 项 POSIX/macOS 专用测试跳过 |
| Windows runtime | 117 项中 108 项通过、9 项跳过；4 项离线检查、覆盖 1208 项内容的隐私扫描通过，标准 TLS 与空通知约束保持有效 |
| Windows Sisters 冒烟 | 真实 Sisters + runtime 的 8 项 `windows/amd64` 回环 mTLS 冒烟通过，版本为 `0.4.0` / biliTickerBuy `2.15.18` |
| 全平台完整包 | 正式 Tag 全量重建五种 Sisters、五种 LastOrder，聚合校验及 12 个 Release 资产核验通过，已公开发布 |
| Windows 10 真机与业务 | 未执行真机 SSH 部署、自启动、实际断连场景或真实账号登录、下单、付款与出票验收；Windows Server CI 不代替这些验证 |

原生 SCM 用例只允许在没有现存 `MisakaSisters` 服务的隔离管理员环境运行，不接管用户服务。它使用随机目录与虚构 runtime，验证中文/空格/单引号路径、普通及悬空 Junction 拒绝、虚拟账户 SID、证书可读不可写、临时目录可写、mTLS 健康检查、失败恢复及首次失败删除；不使用实际账号或订单。

0.4.1 的上传停滞修复另有 Windows 原生回归（`internal/control/deploy_stdin_windows_test.go`）：按 Win32-OpenSSH 的方式启动 PowerShell，标准输入为以 `FILE_FLAG_OVERLAPPED` 打开、4 KiB 缓冲的命名管道，进程只继承三个标准句柄；脚本开始后再分段间歇写入，使读取方反复遇到空管道。用例覆盖标准输入辅助函数、上传解压与写入私有配置三个生产脚本，并记录 .NET 控制台流在同样条件下停滞（若将来的 Windows 更新不再停滞则跳过而非失败）。用例不经过 `cmd.exe /c` 与真实 sshd，只在 Windows CI 作业运行；本地 macOS 已完成全量 Go race/vet 与 Windows x64 测试程序交叉编译、vet，未在本机执行这些 Windows 测试。

可选真机用例 `internal/control/live_windows_ssh_test.go` 从控制端通过与生产相同的 `x/crypto/ssh` 连接真实 Windows OpenSSH，主机、账号与密钥只经环境变量（`MISAKA_TEST_WINDOWS_SSH` 等，见文件注释）传入，未设置时跳过，CI 不运行；完整部署用例另需 `MISAKA_TEST_WINDOWS_SSH_DEPLOY=1`，拒绝在已有 `MisakaSisters` 服务或 20001 端口被占用的主机运行，结束后删除测试服务与独立目录。2026-11-15 在一台 Windows 11（build 26200，内置 OpenSSH_9.5p2 for Windows，默认 `cmd.exe`，Windows PowerShell 5.1 / .NET Framework 4.8.1，Defender 实时保护开启）开发机上，从 macOS 运行的结果：

| 项目 | 结果 |
| --- | --- |
| 旧读取方式（`[Console]::OpenStandardInput()`） | 分段输入下 30 秒无输出，复现停滞；用例随后结束卡住的进程 |
| `Open-StandardInput` | 1 MiB 分段输入完整读取，SHA-256 一致，用时 2.4 秒；首次运行发现缺少 `PreserveSig` 时返回无效句柄，修正后通过 |
| 生产上传与写入配置脚本 + 0.4.0 正式 Windows 包 | 上传并解压 5.5 秒；182 个文件与 4 个私有配置文件哈希一致（配置以 1 KiB 分段间歇写入） |
| 通过 `Deploy` 完整部署 0.4.0 正式 Windows 包 | 37 秒完成；`sisters.exe` 与真实 biliTickerBuy 运行时自检通过，服务以 `NT SERVICE\MisakaSisters` 自动启动并通过 SSH 隧道 mTLS 检查；未放行防火墙，直连检查为不可达；测试服务与目录已删除 |

真机结果只覆盖这一台 Windows 11 与上述版本，不代表 Windows 10 或其他 OpenSSH 版本；Android 管理端运行同一 Go 部署代码，但本轮未在手机上实际运行，也未进行真实账号登录、下单、付款或长时间运行验收。
