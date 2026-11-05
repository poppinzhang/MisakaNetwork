# MisakaNetwork

这是 biliTickerBuy 抢票工具的分布式部署管控项目。

## 模块介绍

### LastOrder

LastOrder 模块 在本地部署，可以完成 抢票 Agent 部署、抢票平台登陆、保存登陆账户 Cookie、分发 Cookie 和抢票任务、等待抢票应用结果回传 等功能。

### Sisters

抢票服务的 Agent，它用来接收 LastOrder 模块的指令与任务，调用 biliTickerBuy 工具执行抢票任务。并回传 biliTickerBuy 工具的抢票进度与结果。

## 项目目标

* LastOrder 是一个跨平台的软件，需要图形界面。目前需要支持 Windows、macOS、Android 三个平台。
* Sisters 是一个跨平台的命令行工具，不需要图形界面。目前需要支持 Windows、macOS、Linux 三个平台。
* LastOrder 通过录入抢票机器的登陆信息，一键部署 Sisters 服务。根据抢票机器系统不同，支持不同的抢票机器连接方式，支持不同版本的 Sisters 服务部署。同时，需要支持重新部署，用于 Sisters 或 biliTickerBuy 的版本更新。
* LastOrder 使用 biliTickerBuy 提供的方式，在本地完成抢票账号登陆、Cookie 生成和抢票场次选择。我们将这种 Cookie 和 抢票场次的组合，称为一个抢票任务。
* LastOrder 可以将任务分发给不同 Sisters，由 Sisters 调用 biliTickerBuy 真正执行任务。相同任务可以发送给多个 Sisters，同时，一个 Sisters 也可以接受多个任务。LastOrder 需要提供一个任务分发和展示的管控界面。
* LastOrder 会定时向已部署的 Sisters 发送状态查询，这个查询用于 Sisters 存活监控和任务状态监控。
* Sisters 需要接收 LastOrder 的任务请求，调用 biliTickerBuy 工具完成抢票任务，同时获取工具的回报信息。
* Sisters 在接收到 LastOrder 的状态查询请求后，回报自己的状态和 biliTickerBuy 工具的信息。
* LastOrder 和 Sisters 的数据交互，需要位于安全的网络信道中，不能直接使用裸消息。

## 技术要求

### LastOrder 技术要求

* Windows 最低支持 Windows 10 以及后续版本；不兼容更早版本。
* Android 最低支持 Android 16（API 36）；不兼容 Android 15 及更早版本。
* macOS 最低支持 Sequoia 15.0，支持 Tahoe 26 及后续版本；不兼容更早版本。
* 由于项目需要跨平台运行，且需要图形节目，使用 Flutter 完成开发。
* UI 组件选型：Material 3，统一使用 Flutter 官方 `material_ui` 包；应用与测试不混用 SDK 内置的 `package:flutter/material.dart` 类型。
* 图标选型：Lucide
* 日常动效选型：flutter_animate
* 页面切换选型：animations 3.x

### Sisters 技术要求

* Windows 最低支持 Windows 10 以及后续版本；不兼容更早版本。
* macOS 最低支持 Sequoia 15.0，支持 Tahoe 26 及后续版本；不兼容更早版本。
* Linux 最低支持 Ubuntu 24.04 LTS 同代的桌面发行版（glibc 2.39+、GTK 3.24），提供 x64 与 arm64 包；不兼容更早的 glibc。
* 由于项目需要跨平台运行，但不需要图形界面支持，使用 Golang 语言完成开发。

### 公共技术要求

* LastOrder 与 Sisters 之间的网络交互使用 gRPC 完成，需要使用 TLS 进行加密。

## 开发与验证

本文件面向 AI 编程代理，集中记录项目目标、技术约束和开发流程。根目录 `README.md` 面向使用者，介绍产品用途、安装操作、已支持平台、功能与使用边界；工具链版本、测试命令、协议生成和实现约束维护在本文件或 `docs/` 中，不堆入 README。

### 工具链与依赖

* 当前工具链：Flutter 3.47.6 / Dart 3.13.5、Go 1.26、Python 3.11+；macOS 打包需要 Xcode。
* Windows 完整打包需要 Windows 10+ x64 与 Visual Studio 2022 C++ 工具链；Android 需要 JDK 17、SDK/build-tools 36、NDK 28.2.13676358 和 Python 3.11。平台与签名步骤见 `docs/打包与发布.md`。
* 协议重新生成需要 Protobuf 31+、`protoc-gen-go`、`protoc-gen-go-grpc` 和 Dart `protoc_plugin`。
* 依赖锁定文件为 `go.sum`、`LastOrder/pubspec.lock` 和 `runtime/requirements*.lock`。调整依赖时同步维护对应锁定文件。

### 常规验证

从项目根目录执行：

```sh
go mod download
go test -race ./...
go vet ./...
python3 -m unittest discover -s runtime/tests -v
python3 -m unittest discover -s scripts -p 'test_*.py' -v
cd LastOrder
flutter pub get
flutter analyze
flutter test
```

依赖就绪后，也可以在根目录执行 `scripts/test.sh`，统一运行 Go race 测试、Python 运行时与发行校验测试、Flutter 静态检查与测试；`go vet ./...` 仍需单独执行。真实钥匙串与沙盒内辅助进程的集成验证方式见 [LastOrder 实现文档](docs/LastOrder/0.1.0实现.md#测试与构建)。自动化测试使用模拟账号和响应，不代表真实登录、下单或出票已验收；记录验证结果时必须区分源码测试、本地包验证、远程 CI 与真实业务验收。

### 协议与完整应用构建

* 公共协议源文件为 `proto/misaka/v1/sisters.proto`。修改后在根目录执行 `scripts/generate.sh`，同步生成 Go 与 Dart 代码，不手工修改生成文件。
* 独立 `flutter run` 或 `flutter build` 不会自动带齐本地运行时与 Sisters 部署包。验证登录、部署或发布应用时，按[打包与发布](docs/打包与发布.md)生成包含辅助进程、运行时及全部目标 Sisters 包的完整应用。
* LastOrder 与内嵌 Sisters 的版本和支持范围按统一发布约定维护；源码版本号已更新不代表安装包已交付。README 的安装入口和版本说明只能引用实际存在的产物记录与发布说明。
* 账号存储格式、钥匙串命名空间与 Cookie 生命周期等实现细节维护在 [Cookie 生命周期](docs/LastOrder/Cookie生命周期.md)；README 只保留用户需要执行的升级操作。任务语义和通信边界见[架构与通信](docs/架构与通信.md)，运行时接入见 [biliTickerBuy 运行时](docs/biliTickerBuy运行时.md)。

## 流程规范

* **1.0.0 之前的所有版本均属于早期研发版本。方案调整时，优先采用正确性、架构与可维护性更优的实现，不受历史研发版本兼容性约束，不为兼容旧方案而妥协；无需专门保留兼容分支或数据迁移逻辑。** 允许调整数据格式、接口与行为；发布说明必须明确重新登录、重建配置或重新部署等升级影响。
* **所有平台统一版本号，每次新增版本号都必须同步打包所有已支持的平台与架构。** LastOrder 与内嵌 Sisters 使用同一项目版本号；即使某个平台或模块没有修改，也必须随本次版本重新打包，不能保留旧版本或跳过该平台。这是为简化后续开发与版本管理而采用的统一发布约定。
* 不要把开发、打包、测试的环境隐私信息记录到项目中，包括内网地址、机器名、登录账号、SSH 连接信息、个人目录路径、密钥及凭据；代码、文档、日志和发布产物中的说明只保留必要的通用环境要求与脱敏验证结果。
* 每次修改或新增功能同步维护根目录 `CHANGELOG.md`，未发布改动放在 `## unstaged`；发布时改为 `## <版本号>` 并记录日期、已完成功能、改进、修复和已知限制，具体遵循 `docs/打包与发布.md`。
* 功能确保提供完整的测试用例，新功能开发完后自动补全测试
* 能正确捕捉、处理异常错误
* 新功能的开发将实现细节自动记录到 docs 目录下，LastOrder 和 Sisters 自身功能放入以模块命名的目录中，公共功能直接放到 docs 目录下。
* 版本发布前需要所有测试全部通过
* 项目要支持发布与打包
