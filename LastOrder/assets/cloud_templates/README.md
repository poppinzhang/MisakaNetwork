# 腾讯云配置模板

`tencent.json` 是随 LastOrder 打包的管理员配置，格式为 `{"schemaVersion":1,"templates":[...]}`。初始列表为空：没有经过管理员填写、核对的配置时，应用不能从示例参数购买服务器。

将完成的模板保存到此目录的 `tencent.json` 后，按项目完整应用打包流程重新构建。该文件由 `pubspec.yaml` 显式声明为 Flutter asset，随 macOS、Windows、Android 应用进入安装包；不需要在已安装应用旁边放额外文件。管理员填写网页是仓库外的本地开发工具，不是应用资产，不纳入本项目构建或发行。

## 字段

每个模板需要全部填写以下字段，不接受额外字段：

| 字段 | 说明 |
| --- | --- |
| `id` | 稳定且唯一的小写英文标识，以字母开头，可含数字和 `-`，最多 64 字符 |
| `name`、`description`、`regionLabel` | 用户可见的配置名、简介和地域名称；不要放账号、密钥或个人信息 |
| `cpu`、`memoryGb`、`diskGb` | 配置展示所需的整数规格；管理员须与真实机型核对，`diskGb` 必须等于下方系统盘容量 |
| `architecture`、`os` | `x64` 或 `arm64`；系统固定 `Ubuntu 24.04 LTS`，仅支持腾讯云官方公共镜像，不支持自定义或共享镜像；创建前会核对镜像状态、版本、架构和磁盘容量 |
| `region` | 腾讯云地域，例如 `ap-guangzhou` |
| `sshUsername` | 镜像实际 SSH 登录用户名 |
| `sshCidr`、`grpcCidr` | 允许访问 SSH TCP 22、Sisters TCP 20001 的来源 IPv4 CIDR；建议填写控制端实际公网地址 `/32`。填写 `0.0.0.0/0` 表示主动允许任意 IPv4 来源；拒绝 `0.0.0.0/1` 至 `0.0.0.0/32`，避免腾讯云将它们转换成开放全部来源 |
| `runInstances.Placement.Zone` | 与地域匹配的可用区 |
| `runInstances.InstanceType`、`ImageId` | 机型和官方公共镜像 ID，须确认库存、Ubuntu 24.04 版本及架构匹配 |
| `runInstances.SystemDisk` | `DiskType` 为 `CLOUD_PREMIUM`、`CLOUD_SSD`、`CLOUD_BSSD` 或 `CLOUD_HSSD`；`DiskSize` 为 20–4096 GiB |
| `runInstances.VirtualPrivateCloud` | 现有 `VpcId` 和 `SubnetId`，须与地域、可用区匹配 |
| `runInstances.InternetAccessible` | `InternetChargeType` 固定 `TRAFFIC_POSTPAID_BY_HOUR`，`PublicIpAssigned` 固定 `true`，`InternetMaxBandwidthOut` 为 1–100 Mbps |

运行层固定实例计费为 `POSTPAID_BY_HOUR`、数量为 1，并注入幂等标识、安全组和公钥。模板不能覆盖上述参数，也不接受密码、SecretId、SecretKey、UserData、数据盘、启动模板或其他任意 API 参数。保存的展示信息不是实时价格或云端校验结果，格式正确不代表可购买。修改模板后需要重新打包；不会热更新已经创建的服务器。

模板解析与资产加载的离线回归位于 `LastOrder/test/cloud_templates_test.dart`。这些测试不代表实际账号权限、资源库存、计费或部署已验收。
