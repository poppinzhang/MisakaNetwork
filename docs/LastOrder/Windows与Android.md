# LastOrder Windows 与 Android（0.2.3）

源码版本统一为 `0.2.3+9`，Sisters、部署 helper 与运行时版本同为 `0.2.3`；Python 桥接协议仍为 `1`。实际构建、签名与测试状态见 [0.2.3 交付记录](../releases/0.2.3.md)，源码支持不等同于已交付所有安装包。

## 平台与功能

Windows 管理台最低 Windows 10，目标 x64；Android 最低 Android 16（API 36），目标 arm64-v8a 与 x86_64。macOS 继续支持 15.0+ 的 arm64 与 x64。三端复用 Flutter Material 3 界面、账号生命周期、任务配置、分发及 mTLS gRPC 客户端。手机宽度低于 600 时使用底部导航，概览卡片和任务操作适配窄屏；恢复前台时刷新机器与账号状态。

三端均部署现有 Linux/macOS、x64/arm64 四种 Sisters 包。Windows 是本次新增的管控端平台，Windows Sisters 及 Windows 服务部署仍未实现。Android 后台状态同步由系统调度限制，不承诺后台常驻；部署在后台线程执行，切换应用不会中断，但系统回收进程时无法拦截，部署可能中断且无法回滚；切换应用或关闭 LastOrder 不会停止远程 Sisters 已接受的任务。

## Windows

原生 runner 使用 Unicode Win32 窗口，声明 Windows 10、Per Monitor V2 DPI 与 asInvoker，不要求管理员权限。启动时检查系统版本，使用 Kill-on-close Job 管理应用子进程。

完整目录包括 `LastOrder.exe`、Flutter 所需 DLL/data、`resources/misakactl.exe`、`resources/runtime/misaka-runtime.exe` 及运行时依赖，以及 `resources/bundles/` 四种部署包。不能只复制单个 EXE。本地 Python 解释器及扩展必须在 Windows 原生构建，不能用 macOS 运行时或交叉编译的 Go 程序替代。

Cookie 与含购票人信息的任务配置由 `flutter_secure_storage` 的 Windows 实现加密保存。应用数据目录、导入私钥、元数据与 PKI 文件通过 Go helper 设置受保护的 DACL，只授权当前用户与 SYSTEM；目录继承 ACL 使新文件在写入时即受保护。拒绝相对路径、符号链接和非普通文件。`protect_path` 失败会阻止继续保存，不以无效的 POSIX chmod 代替 Windows ACL。

## Android

首页统计区在可用宽度小于 500 逻辑像素时采用两列两行，卡片间距为 12 像素、内边距为水平 14／垂直 12 像素，数字字号为 30。标题为图标旁的弹性文本，说明保留完整内容并自然换行，避免小屏横向溢出。该紧凑样式仅用于 Android；Windows、macOS 的原有列数与卡片尺寸不变。此项为未发布源码调整，通过 Flutter 模拟平台检查布局并生成预览图，不代表原生设备或安装包已验收。

Android 不运行桌面 EXE 或 PyInstaller 子进程。原生 `misaka/embedded` MethodChannel 在后台线程调用嵌入式服务：

- `runtime`：传入单个 JSON 请求，返回一个 JSON result。Chaquopy 嵌入 Python 3.11，调用同一份 biliTickerBuy 的登录、查询、配置接口；共享 `runtime/bridge.py` 的请求校验及账号身份验证。移动端只装管理端所需依赖，并拒绝 `run`，实际抢票始终由远程 Sisters 完成。
- `helper`：JSON 请求经 JNI 进入 Go `internal/mobile`，复用 `internal/control` 的 SSH 主机指纹验证、证书签发、完整包验证和远程部署。移动桥接限制文件路径位于本应用私有目录。
- `resources`：按应用版本将 APK 内置的四种 Sisters 包准备到应用私有目录，返回包含 `bundles` 的资源根目录。APK 内使用 `.bundle` 保存原始 gzip 字节，避免 Android 资源打包器自动解压并去掉 `.gz`；解包到私有目录时还原 `.tar.gz`。准备失败不继续部署。
- `protectFile`：仅接受应用私有目录内的规范化路径及 `600`/`700` 权限，使用系统文件权限 API，不调用 chmod 子进程。

Cookie 与任务秘密由 Android Keystore 支持的安全存储保护；显式关闭插件的存储错误自动重置，密钥读取失败不会静默清空账号。应用禁止备份与明文 HTTP，声明 INTERNET 权限；证书与 SSH 私钥副本保存在应用私有目录。不得把 APK 解包到外部存储执行，亦不需要用户另装 Python、Go 或终端。

两个 ABI 的 Go JNI 库使用 NDK 28.2 构建并设置 16 KB 对齐；Chaquopy 使用支持 16 KB 页的版本。离线打包包含客户端 Python 源码、锁定依赖、上游许可与四种服务端包。Android 使用系统文件选择器导入私钥和证书，不申请全盘存储权限。选择器会把所选文件以明文复制到应用缓存，并且从不删除；LastOrder 保存受保护副本后立即删除这份缓存副本及其空目录。删除只限应用缓存目录内的文件，桌面端选择器返回的是用户原文件，不会被删除。

## 升级与测试

沿用 schema 2、`state-v2.json` 与 `v2.` 安全存储命名空间；0.1.1 数据在同一平台和同一应用身份下继续读取。0.1.0 仍不迁移，需重新配置。跨平台不自动复制账号、密钥和机器配置；首次安装需添加机器并登录。必须将所有目标 Sisters 重新部署为 0.2.3，避免 helper/runtime 版本校验拒绝旧包。重部署会停止当前任务。

Android 测试签名与正式签名不能互相覆盖安装；改变签名需要卸载重装并重新登录、配置和部署，正式交付应保管稳定签名密钥。密钥、口令与构建主机信息不能进入源码或发布记录。

Flutter 测试覆盖桥接 JSON、错误与超时、敏感原生错误屏蔽、Windows 路径、手机导航与任务卡片；Python 测试覆盖移动端允许的操作与本地执行拒绝；Go 测试覆盖私有目录约束与 Windows ACL。原生集成测试验证真实安全存储、PKI 和运行时启动。模拟测试不等同于真实账号登录、下单、生产 SSH 部署或所有支持设备验收。
