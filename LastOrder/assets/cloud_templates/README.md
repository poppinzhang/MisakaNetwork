# 腾讯云配置模板

`tencent.json` 是随 LastOrder 打包的管理员配置，格式为 `{"schemaVersion":3,"templates":[...]}`。初始列表为空：没有经过管理员填写、核对的配置时，应用不能从示例参数购买服务器。格式 3 由 LastOrder 自动准备共享网络，并固定 SSH 用户和端口来源，不接受旧格式 1/2；已有模板需使用新版填写工具重新生成并重新打包。

将完成的模板保存到此目录的 `tencent.json` 后，按项目完整应用打包流程重新构建。该文件由 `pubspec.yaml` 显式声明为 Flutter asset，随 macOS、Windows、Android 应用进入安装包；不需要在已安装应用旁边放额外文件。管理员填写网页是仓库外的本地开发工具，不是应用资产，不纳入本项目构建或发行。

## 字段

每个模板需要全部填写以下字段，不接受额外字段：

| 字段 | 说明 |
| --- | --- |
| `id` | 稳定且唯一的小写英文标识，以字母开头，可含数字和 `-`，最多 64 字符 |
| `name`、`description`、`regionLabel` | 模板选择中的配置名、简介和地域名称（机器卡片不显示地域）；不要放账号、密钥或个人信息 |
| `cpu`、`memoryGb`、`diskGb` | 配置展示所需的整数规格；管理员须与真实机型核对，`diskGb` 必须等于下方系统盘容量 |
| `architecture`、`os` | `x64` 或 `arm64`；系统固定 `Ubuntu 24.04 LTS`，仅支持腾讯云官方公共镜像，不支持自定义或共享镜像；创建前会核对镜像状态、版本、架构和磁盘容量 |
| `region` | 腾讯云地域，例如 `ap-guangzhou` |
| `runInstances.Placement.Zone` | 与地域匹配的建议可用区；明确售罄时自动尝试同地域、相同机型的其他可用区 |
| `runInstances.InstanceType`、`ImageId` | 机型和官方公共镜像 ID，须确认库存、Ubuntu 24.04 版本及架构匹配 |
| `runInstances.SystemDisk` | `DiskType` 为 `CLOUD_PREMIUM`、`CLOUD_SSD`、`CLOUD_BSSD` 或 `CLOUD_HSSD`；`DiskSize` 为 20–4096 GiB |
| `runInstances.InternetAccessible` | `InternetChargeType` 固定 `TRAFFIC_POSTPAID_BY_HOUR`，`PublicIpAssigned` 固定 `true`，`InternetMaxBandwidthOut` 为 1–100 Mbps |

运行层固定实例计费为 `POSTPAID_BY_HOUR`、数量为 1，并注入幂等标识、自动准备的 VPC/子网、安全组和公钥。当前支持的 Ubuntu 24.04 镜像使用固定的 `ubuntu` 账号和密钥登录；安全组入站 TCP 22 和 TCP 20001 的来源均固定为 `0.0.0.0/0`（所有 IPv4 地址），填写网页只展示这些规则。模板不能包含 `sshUsername`、`sshCidr`、`grpcCidr`、`VirtualPrivateCloud`、`VpcId`、`SubnetId` 或覆盖上述参数，也不接受密码、SecretId、SecretKey、UserData、数据盘、启动模板或其他任意 API 参数。保存的展示信息不是实时价格或云端校验结果，格式正确不代表可购买。修改模板后需要重新打包；不会热更新已经创建的服务器。

LastOrder 在账号目标地域创建或复用专用 `MisakaNetwork-VPC`，在所选可用区创建或复用 `MisakaNetwork-Subnet-<可用区>`。共享 VPC 使用 `10.8.0.0/16`，子网从中分配互不重叠的 `/24`；模板不配置网段或网络 ID。实际资源须通过管理标签与网络配置核验，创建结果未知时先查询恢复。释放单台云服务器保留共享网络，详细行为见[腾讯云接入](../../../docs/LastOrder/腾讯云接入.md)。

创建首先尝试模板中的建议可用区。只有购买接口明确拒绝且属于容量或库存不足时，才查询同地域的可售可用区，按相同 `InstanceType` 和按量计费筛选，逐个尝试未使用过的可用区。回退只调整可用区及对应子网，镜像、系统盘、带宽、架构及计费方式保持不变，不升级、降配或跨地域购买。实例记录分别保留原模板与本次选定可用区，机器卡片不展示地域、可用区或实例 ID，底层记录仍用于精确查询和释放。余额、配额、权限等错误或创建结果不确定时停止；超时与响应丢失仅查询恢复，不切换可用区再次购买。自动回退额外需要 `cvm:DescribeZoneInstanceConfigInfos` 查询权限。

模板解析与资产加载的离线回归位于 `LastOrder/test/cloud_templates_test.dart`。这些测试不代表实际账号权限、资源库存、计费或部署已验收。
