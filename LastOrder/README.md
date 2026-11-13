# LastOrder

MisakaNetwork 的 Flutter 管理台，源码版本 **0.3.0+10**。目标平台为 macOS 15.0+（arm64/x64）、Windows 10+（x64）、Android 16 / API 36（arm64/x64）。实际安装包及验证状态见 [0.3.0 交付记录](../docs/releases/0.3.0.md)，五种完整包已通过 GitHub Actions 构建并发布为正式 Release，实际验证范围以该记录为准。

提供 Sisters 部署、账号登录、任务创建、分发与监控。基础功能见 [实现文档](../docs/LastOrder/0.1.0实现.md)，账号状态见 [Cookie 生命周期](../docs/LastOrder/Cookie生命周期.md)，新增平台见 [Windows 与 Android](../docs/LastOrder/Windows与Android.md)。

三端使用相同 schema 2 账号和任务模型。0.2.3 及更早 macOS 使用逐条登录钥匙串；0.3.0 起 macOS 改用单一钥匙串主密钥和独立 `macos-vault-v1` 本地加密文件，Windows 加密存储与 Android Keystore 支持的安全存储保持不变。macOS 新资料目录不读取、迁移或删除旧数据，切换前先处理远端任务和云资源，之后重新添加/部署机器、登录账号和创建任务；详见 [macOS 加密存储](../docs/LastOrder/macOS加密存储.md)。0.1.0 数据不迁移；新平台安装需要重新登录和配置机器。Android 的 Python 客户端与 Go 部署 helper 以内嵌库运行，任务仍由远程 Sisters 执行。

0.3.0 中的腾讯云 Ubuntu 实例使用模板指定的默认账号（如 `ubuntu`）与应用内置 SSH 密钥部署。云资源和关联 Sisters 的部署进度、错误、连接状态与操作集中在原云服务器卡片，底层机器及任务关联继续保留；细节见[腾讯云接入](../docs/LastOrder/腾讯云接入.md)。

0.3.0 的「公有云部署」凭证提交会调用三家官方只读身份接口，验证通过后才安全保存；每厂商仅保留一份，不再填写账号备注。保存成功后隐藏输入框与提交按钮，只有成功移除当前凭证后才显示空白表单，不能直接覆盖已验证凭证；失败保留原来的未验证记录。旧的仅格式检查记录需重新提交验证；仍有未释放或待核实云资源或未确认网络意图时继续保护管理凭证。验证不代表已具备所有资源操作权限或购买条件，详见[公有云接入方案](../docs/LastOrder/公有云接入方案.md#01-凭证入口与联网验证)。

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
```

独立 `flutter build` 不会带齐远端部署包和本地运行时。请按[打包与发布](../docs/打包与发布.md)生成完整应用；Windows 完整包必须在 Windows 原生构建，Android 测试签名 APK 不等于正式签名发行。
