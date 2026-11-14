# Windows Sisters（0.4.0）

0.4.0 新增 Windows 10 及以上的 **x64 / amd64** Sisters 实现，不支持 Windows 7/8/8.1、32 位 Windows 或 Windows arm64。每份完整 LastOrder 携带 Linux/macOS arm64/x64 与 Windows x64 共五种同版本离线包；0.3.2 及更早安装包不包含 Windows Sisters。本文描述 `0.4.0+13` 的实现与部署要求，全平台预构建和 Windows 原生 CI 证据见 [0.4.0 发布记录](../releases/0.4.0.md)，正式交付以实际 Release Assets 及其清单为准。

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

安装包和配置在受限目录中准备，运行时自检通过后才切换服务程序路径。新服务通过 SSH 隧道完成 mTLS 检查后，再从 LastOrder 直接检查所选端口；直连失败保留已启动的服务并提示检查网络。切换失败会停止新服务并恢复旧服务配置；首次部署失败则清理新服务。回滚失败明确报错，不能将“已尝试恢复”视为旧服务已正常运行。

源码离线包为 `windows-amd64.tar.gz`，根目录包含 `sisters.exe`、`runtime/misaka-runtime.exe` 与依赖、许可证和版本清单，不包含节点私钥或用户 Cookie。Windows Python 运行时必须原生构建，不能用交叉编译的 Go EXE 替代完整包。全部 LastOrder 目标须包含 Linux/macOS arm64/x64 加 Windows x64 共五份同版本包。

## 验证范围

本次修改未升级 biliTickerBuy v2.15.18 固定提交或依赖，不修改导入白名单、网络地址、TLS 验证、`standard` 下单策略、空第三方通知配置或 Web UI/Gradio 限制。新增的是服务运行、进程生命周期与部署打包路径；Windows 服务继承环境的既有影响仍存在，不声称完全忽略代理和 CA 环境设置。离线运行时安全回归继续覆盖真实标准客户端的证书链/域名校验以及配置与环境不能打开被禁用策略的约束。

本地验证和实际原生验收分别记录；Windows 测试包含 SCM 控制与 Job Object 进程树用例，CI Windows 作业运行全量 Go 测试和真实离线运行时冒烟。CI 使用 Windows Server runner，通过也不能替代 Windows 10 实机安装、自启动、SSH 部署/重部署、故障回滚及断连后继续服务的验收。未执行真实账号登录、下单或出票测试，不把源码和模拟验证表述为发行二进制或业务安全验收。

2026-11-14 的 `0.4.0+13` 验证记录（标签前预构建 [43595038721](https://github.com/poppinzhang/MisakaNetwork/actions/runs/43595038721)，完整范围以 [发布记录](../releases/0.4.0.md) 为准）：

| 范围 | 结果 |
| --- | --- |
| Go 源码与 Windows 原生服务 | 本地全量 Go race/vet 通过；Windows Server CI 全量 Go race/vet、PowerShell 与隔离 SCM 测试通过，覆盖服务账户、权限、mTLS、失败回滚与进程树清理 |
| Flutter | 本地 macOS analyze 通过、915 项测试通过/2 项跳过；Windows 原生 CI analyze 通过、910 项测试通过/2 项跳过 |
| 打包脚本 | 本地 135 项通过；Windows CI 113 项通过、22 项 POSIX/macOS 专用测试跳过 |
| Windows runtime | 117 项中 108 项通过、9 项跳过；4 项离线检查、覆盖 1208 项内容的隐私扫描通过，标准 TLS 与空通知约束保持有效 |
| Windows Sisters 冒烟 | 真实 Sisters + runtime 的 8 项 `windows/amd64` 回环 mTLS 冒烟通过，版本为 `0.4.0` / biliTickerBuy `2.15.18` |
| 全平台完整包 | 五种 Sisters、五种 LastOrder 和聚合校验全部通过；正式 Release 从 Tag 全量重建并核验独立产物 |
| Windows 10 真机与业务 | 未执行真机 SSH 部署、自启动、实际断连场景或真实账号登录、下单、付款与出票验收；Windows Server CI 不代替这些验证 |

原生 SCM 用例只允许在没有现存 `MisakaSisters` 服务的隔离管理员环境运行，不接管用户服务。它使用随机目录与虚构 runtime，验证中文/空格/单引号路径、普通及悬空 Junction 拒绝、虚拟账户 SID、证书可读不可写、临时目录可写、mTLS 健康检查、失败恢复及首次失败删除；不使用实际账号或订单。
