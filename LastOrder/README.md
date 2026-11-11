# LastOrder

MisakaNetwork 的 Flutter 管理台，源码版本 **0.2.0+7**。目标平台为 macOS 15.0+（arm64/x64）、Windows 10+（x64）、Android 16 / API 36（arm64/x64）。实际安装包及验证状态见 [0.2.0 交付记录](../docs/releases/0.2.0.md)，本轮五种完整测试包均已核验，真实业务范围以该记录为准。

提供 Sisters 部署、账号登录、任务创建、分发与监控。基础功能见 [实现文档](../docs/LastOrder/0.1.0实现.md)，账号状态见 [Cookie 生命周期](../docs/LastOrder/Cookie生命周期.md)，新增平台见 [Windows 与 Android](../docs/LastOrder/Windows与Android.md)。

三端使用相同 schema 2 账号和任务模型。macOS 登录钥匙串、Windows 加密存储与 Android Keystore 支持的安全存储负责保护凭据。0.1.0 数据不迁移；新平台安装需要重新登录和配置机器。Android 的 Python 客户端与 Go 部署 helper 以内嵌库运行，任务仍由远程 Sisters 执行。

```sh
flutter pub get --enforce-lockfile
flutter analyze
flutter test
```

独立 `flutter build` 不会带齐远端部署包和本地运行时。请按[打包与发布](../docs/打包与发布.md)生成完整应用；Windows 完整包必须在 Windows 原生构建，Android 测试签名 APK 不等于正式签名发行。
