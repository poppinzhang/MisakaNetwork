# 公有云配置模板

## 腾讯云

`tencent.json` 是随 LastOrder 打包的管理员配置，格式为 `{"schemaVersion":4,"templates":[...]}`。初始列表为空：没有经过管理员填写、核对的配置时，应用不能从示例参数购买服务器。格式 4 由 LastOrder 自动准备共享网络，新增管理员指定的 sshUsername，端口来源仍固定；旧格式需使用新版填写工具重新生成并重新打包。

将完成的模板保存到此目录的 `tencent.json` 后，按项目完整应用打包流程重新构建。该文件由 `pubspec.yaml` 显式声明为 Flutter asset，随 macOS、Windows、Android 应用进入安装包；不需要在已安装应用旁边放额外文件。管理员填写网页是仓库外的本地开发工具，不是应用资产，不纳入本项目构建或发行。

## 字段

每个模板需要全部填写以下字段，不接受额外字段：

| 字段 | 说明 |
| --- | --- |
| `sshUsername` | 镜像实际允许密钥登录的 Linux 账号，1–32 字符，以小写字母或下划线开头，其余可含数字和短横线；不自动创建或修改账号 |
| `id` | 稳定且唯一的小写英文标识，以字母开头，可含数字和 `-`，最多 64 字符 |
| `name`、`description`、`regionLabel` | 模板选择中的配置名、简介和地域名称（机器卡片不显示地域）；不要放账号、密钥或个人信息 |
| `cpu`、`memoryGb`、`diskGb` | 配置展示所需的整数规格；管理员须与真实机型核对，`diskGb` 必须等于下方系统盘容量 |
| `architecture`、`os` | `x64` 或 `arm64`；`os` 是非空系统显示名，不限制 Linux 发行版或 Ubuntu 版本；创建前核对镜像状态、架构和磁盘容量，实际部署检查 Linux/glibc 运行条件 |
| `region` | 腾讯云地域，例如 `ap-guangzhou` |
| `runInstances.Placement.Zone` | 与地域匹配的建议可用区；明确售罄时自动尝试同地域、相同机型的其他可用区 |
| `runInstances.InstanceType`、`ImageId` | 机型和管理员选择的镜像 ID，须确认库存、Linux 运行条件及架构匹配 |
| `runInstances.SystemDisk` | `DiskType` 为 `CLOUD_PREMIUM`、`CLOUD_SSD`、`CLOUD_BSSD` 或 `CLOUD_HSSD`；`DiskSize` 为 20–4096 GiB |
| `runInstances.InternetAccessible` | `InternetChargeType` 固定 `TRAFFIC_POSTPAID_BY_HOUR`，`PublicIpAssigned` 固定 `true`，`InternetMaxBandwidthOut` 为 1–100 Mbps |

运行层固定实例计费为 `POSTPAID_BY_HOUR`、数量为 1，并注入幂等标识、自动准备的 VPC/子网、安全组和公钥。登录账号由顶层 `sshUsername` 明确指定，必须适配镜像实际密钥登录配置；安全组入站 TCP 22 和 TCP 20001 的来源均固定为 `0.0.0.0/0`（所有 IPv4 地址），填写网页只展示这些规则。模板不能包含 `sshCidr`、`grpcCidr`、`VirtualPrivateCloud`、`VpcId`、`SubnetId` 或覆盖上述参数，也不接受密码、SecretId、SecretKey、UserData、数据盘、启动模板或其他任意 API 参数。保存的展示信息不是实时价格或云端校验结果，格式正确不代表可购买。修改模板后需要重新打包；不会热更新已经创建的服务器。

LastOrder 在账号目标地域创建或复用专用 `MisakaNetwork-VPC`，在所选可用区创建或复用 `MisakaNetwork-Subnet-<可用区>`。共享 VPC 使用 `10.8.0.0/16`，子网从中分配互不重叠的 `/24`；模板不配置网段或网络 ID。实际资源须通过管理标签与网络配置核验，创建结果未知时先查询恢复。释放单台云服务器保留共享网络，详细行为见[腾讯云接入](../../../docs/LastOrder/腾讯云接入.md)。

创建首先尝试模板中的建议可用区。只有购买接口明确拒绝且属于容量或库存不足时，才查询同地域的可售可用区，按相同 `InstanceType` 和按量计费筛选，逐个尝试未使用过的可用区。回退只调整可用区及对应子网，镜像、系统盘、带宽、架构及计费方式保持不变，不升级、降配或跨地域购买。实例记录分别保留原模板与本次选定可用区，机器卡片不展示地域、可用区或实例 ID，底层记录仍用于精确查询和释放。余额、配额、权限等错误或创建结果不确定时停止；超时与响应丢失仅查询恢复，不切换可用区再次购买。自动回退额外需要 `cvm:DescribeZoneInstanceConfigInfos` 查询权限。

模板解析与资产加载的离线回归位于 `LastOrder/test/cloud_templates_test.dart`。这些测试不代表实际账号权限、资源库存、计费或部署已验收。


## 火山引擎

`volcengine.json` 顶层格式为 `{"schemaVersion":2,"templates":[]}`，默认空集合，管理员通过仓库外本地网页填写后重新构建完整应用。三端 Flutter assets 均携带此文件；配置网页不进入源码或安装包。

每个模板的展示字段与腾讯云一致，`runInstances` 使用火山原生字段而非腾讯参数：

| 字段 | 约束 |
| --- | --- |
| `ZoneId` | 与 `region` 匹配的建议可用区，如 `cn-beijing-a` 或 `ap-southeast-1a`；明确库存不足后仅尝试同地域相同规格 |
| `InstanceTypeId`、`ImageId` | 规格与管理员选择的镜像，分别使用 `ecs.` / `image-` 标识 |
| `Volumes` | 一个系统盘对象，`VolumeType` 为 `ESSD_PL0` 或 `ESSD_FlexPL`；`Size` 为 20–2048 GiB，等于 `diskGb` |
| `EipAddress` | `BandwidthMbps` 为 1–200，`ISP=BGP`、`ChargeType=PayByTraffic`、`ReleaseWithInstance=true` |

创建层固定按量 `PostPaid`、数量 1、`NoSpot`，自动创建/复用专用 VPC、子网、安全组和登录公钥。使用 `sshUsername` 指定账号密钥登录，固定 TCP 22/20001 的所有 IPv4 来源，系统盘随实例删除；上述策略不能由模板覆盖。EIP 是独立资源，创建时必须设置随实例释放；释放后分别查询 ECS 与记录的 EIP，两者均确认消失才清除卡片。详细异常恢复、权限和验证边界见[火山引擎接入](../../../docs/LastOrder/火山引擎接入.md)。

模板不接受凭据、端点、网络 ID、密码、脚本、额外数据盘或任意 API 参数。不要把个人环境配置或真实资源 ID 提交公共仓库；默认模板为空不代表该云厂商不支持。

火山引擎换区仅修改执行时可用区及对应子网，其余规格和 EIP 释放策略不变。每次换区购买使用先保存的新 token，原模板仍保留建议值；超时、响应丢失或结果未知时只查询恢复，不换区重购。新增运行时库存查询权限 `ecs:DescribeAvailableResource`；无需升级模板格式，需重新打包完整应用。


## 阿里云

`aliyun.json` 顶层格式为 `{"schemaVersion":2,"templates":[]}`，初始为空，管理员通过仓库外本地网页填写后重新构建完整应用。该文件由 `pubspec.yaml` 声明为 Flutter asset，随 Windows、macOS、Android 应用携带；网页不纳入项目或安装包。

展示字段与另外两家一致，`runInstances` 仅接受阿里云字段：`ZoneId`、`InstanceType`、`ImageId`、`SystemDisk`（`Category` 和 `Size`）、`InternetChargeType`（固定 `PayByTraffic`）与 `InternetMaxBandwidthOut`（整数 1–100）。系统盘为 20–2048 GiB，必须等于 `diskGb`，类型允许 `cloud_efficiency`、`cloud_ssd`、`cloud_essd`、`cloud_essd_entry`、`cloud_auto`；镜像不限发行版、版本或来源，在创建前核对 Linux 类型、架构、可用状态、磁盘容量及单系统盘映射。

`ZoneId` 是建议值，例如 `cn-hangzhou-h` 或 `ap-southeast-1a`，只在明确容量不足拒绝时回退同地域相同机型；未知创建只查询恢复。实际可用区与交换机保存在执行记录中，不覆盖原模板。

创建层固定单实例普通按量付费及直接公网 IP，使用 `sshUsername` 指定账号密钥登录，不申请独立 EIP。VPC、交换机、安全组与公钥由运行时准备，模板不填写其 ID、凭据、密码、脚本或其他 API 参数。释放前核验云盘及外部附属资源，具体生命周期与权限见[阿里云接入](../../../docs/LastOrder/阿里云接入.md)。

三家编辑器已合并到独立 `MisakaNetwork-config` 工具：首页选择云厂商，再进入对应编辑页。镜像完整展示账号在地域内通过 API 可查询的结果，不按系统版本、来源、机型或架构自动隐藏。格式升级、运行底线、登录账号和验证边界见[云模板与 Linux 镜像](../../../docs/LastOrder/云模板与Linux镜像.md)。
