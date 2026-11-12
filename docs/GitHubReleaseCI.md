# GitHub Release CI

本流程由 `.github/workflows/release.yml`、可复用的 `package.yml`、`scripts/release_ci.py` 与 `scripts/publish_release.py` 组成。本次只完成本地实现与验证，未推送代码、创建远程 Tag/Release 或运行 Actions；没有新增版本，也没有修改既有安装包的交付记录。

## 三种入口

| 工作流 | 用途 | 触发方式 | 公开 Release |
| --- | --- | --- | --- |
| `verify.yml` | 源码测试 | Pull Request、手动 | 否 |
| `package.yml` | 全平台完整包 | 手动，或由 Release 工作流调用 | 否，只保存 Actions artifacts |
| `release.yml` | 构建并发布 | 推送版本 Tag、手动指定已有版本 Tag | 全部校验通过后发布 |

普通分支 push 不触发发布。版本 Tag 支持 `<版本号>` 和 `v<版本号>`，同一版本只允许发布一次，不允许用另一种前缀重复发布。当前历史 Tag 保持原样，不移动、重建或自动推送。

手动 Release 也必须运行在已有 Tag 上；通过 GitHub CLI 使用 `gh workflow run release.yml --ref <版本Tag>`，或在支持 Tag 选择的界面指定 Tag。选择分支会在预检阶段失败。手动运行要求默认分支上已存在工作流。工作流使用触发 Tag 对应的源码和打包配置，不能从新分支借用工作流为旧源码发布。**这些触发操作只在明确准备发布时执行。**

## 发布前配置

仓库启用 Actions，并允许最终发布作业使用 `contents: write`。其余作业仅有 `contents: read`；不需要额外个人访问令牌。使用 GitHub 托管的 Ubuntu 24.04 x64/arm64、macOS 15 Intel/arm64 和 Windows 2022 runner，仓库必须可以使用这些运行环境。

在仓库的 Actions secrets 中配置以下四项，供 Android 正式签名使用：

| Secret | 内容 |
| --- | --- |
| `MISAKA_ANDROID_KEYSTORE_BASE64` | 发布 keystore 文件的单行 Base64 内容 |
| `MISAKA_ANDROID_STORE_PASSWORD` | keystore 口令 |
| `MISAKA_ANDROID_KEY_ALIAS` | 签名密钥别名 |
| `MISAKA_ANDROID_KEY_PASSWORD` | 签名密钥口令 |

正式密钥需长期保管，以支持后续覆盖升级。预检在启动原生构建前确认四项齐全、Base64 格式有效；密钥格式、别名和口令由 Android 实际签名步骤验证。密钥只写入 runner 临时目录并在打包步骤结束后清除，不上传。macOS 仍为 ad-hoc 签名且未公证，Windows 仍不包含 Authenticode 签名；本工作流没有实现 Apple Developer ID、公证或 Windows 签名。

仅想打测试包时，手动运行 `package.yml` 并明确选择 `android_test_signing=true`，即可使用测试签名且不需要上述 secrets。Release 调用固定为 `false`，发布前还会核对两个 APK 的清单签名模式必须为 `release-keystore`。

## 发布准备与执行顺序

1. 按[打包与发布](打包与发布.md)更新统一版本、递增构建号、发布日期和所有版本引用；内嵌 biliTickerBuy 版本与依赖仍遵守既有安全复核要求。
2. 将本次改动从 `CHANGELOG.md` 的 `## unstaged` 移入 `## <版本号> — <YYYY-MM-DD>`，前方保留空的 `unstaged`。新增 `docs/releases/<版本号>.md`，明确升级操作与已知限制。CI 尚未执行时记录为待构建，不能预写 CI 通过或真实业务验收。
3. 完成本地源码测试及发布准备，提交所需源码。后续正式发布时再创建并推送版本 Tag；或者为已存在且包含工作流的版本 Tag 手动运行 Release。预检拒绝分支、版本/构建号不一致、非空 `unstaged`、日期不一致或缺少发布说明。
4. CI 在四种原生平台构建 Python 运行时及 Sisters 包，执行 Go/Python 测试、依赖闭合检查、运行时离线检查和隐私检查。每份运行时使用独立 venv，避免混入 runner 预装的 Python 包。
5. macOS 两种架构、Windows x64 和 Android 两种架构全部重新构建，每份完整应用均包含四种 Sisters 包。macOS/Windows 执行 Flutter 静态检查与测试；Android 固定 SDK、JDK 与 NDK，使用正式密钥签名。
6. 所有平台成功后合并清单，检查版本、平台、内嵌部署包、字节数和校验和。缺少任何目标都不会进入发布作业。
7. 发布作业将必要文件复制到全新的 staging 目录，再次校验文件集合、完整状态、当前版本和 Android 签名模式。只允许非空、普通文件，单个文件须小于 2 GiB；不接受符号链接。
8. 发布脚本核对本地 HEAD、本地 Tag 和远程 Tag 的提交一致，拒绝已存在的同版本 Release，创建草稿并逐项上传。远端文件名集合、上传状态、大小和 SHA-256 全部一致后，再次核对 Tag，最后公开正式 Release 并标记为 Latest。创建与公开均显式关闭 prerelease，公开前后核对 Release 类型；不会因版本号为 `0.x` 自动改成预发布。1.0.0 前仍属于早期研发版本。

Release 正文包含构建提交、签名状态、验证边界、当前版本 CHANGELOG 内容与固定到该提交的发布文档链接。CI 构建记录不代表真实账号登录、下单、付款或出票已验收；真实平台集成和业务验证仍分别记录。

## Release Assets 只保留必要文件

下表中的 `<版本号>` 来自统一发布配置；目前固定上传 12 个文件。

| 文件 | 数量 | 用途 |
| --- | --- | --- |
| `LastOrder-<版本号>-macos-amd64.zip`、`LastOrder-<版本号>-macos-arm64.zip` | 2 | macOS 完整应用 |
| `LastOrder-<版本号>-windows-amd64.zip` | 1 | Windows 完整便携应用 |
| `LastOrder-<版本号>-android-arm64.apk`、`LastOrder-<版本号>-android-amd64.apk` | 2 | Android 安装包 |
| 上述每个文件对应的 `.sha256` | 5 | 单包校验和 |
| `SHA256SUMS` | 1 | 五个程序包的联合校验和 |
| `release.json` | 1 | 版本、构建号、平台、签名状态、大小及 SHA-256 |

许可证随完整程序包提供，不单独上传构建时收集的许可工作目录。四份 Sisters `.tar.gz`、原生 Python 运行时、`bundles.json`、展开的 `.app`、调试符号、日志、签名材料、缓存及完整 Actions artifact 的外层 ZIP 均不单独进入 Release Assets。没有独立 Linux LastOrder 或 Windows Sisters 安装包；Linux Sisters 已内嵌在每份 LastOrder 中。

GitHub 自行显示的 `Source code (zip)` / `Source code (tar.gz)` 是平台根据 Tag 提供的源码入口，不是本工作流上传的中间文件。

内部 `internal-bundle-*`、`internal-app-*` Actions artifacts 保留 1 天，完整 `LastOrder-<版本号>-complete` artifact 保留 7 天；已经压缩的文件关闭二次压缩以减少等待。Release Assets 不受这些 Actions artifact 保留期限制。

## 失败与重试

- 原生构建或完整校验失败：不创建 Release。修复后重新运行；部分作业重跑依赖的内部 artifacts 必须仍在保留期内，已过期时重跑整个工作流以重新生成所有平台包。
- 上传、远端校验或公开操作前的检查失败：保留未发布草稿供排查，不自动公开，不自动删除，也不覆盖文件。先核对失败原因与草稿内容，删除该失败草稿后再运行发布作业；完整 artifact 已过期时需重跑全部构建。不得删除或移动版本 Tag 来绕过检查。
- 已公开同版本 Release：拒绝覆盖，即使切换 `v` 前缀也会拒绝。需要改变源码或替换交付包时按统一发布规则使用新版本。
- 最后公开请求成功但确认请求因网络异常失败：工作流可能报告失败而 Release 已公开；先查看实际 Release 状态，不直接删除或覆盖。

同一个 Tag 的发布工作流按并发组排队，不主动取消正在进行的发布。两种前缀不要用于并行发布同一版本。

## 本地验证

以下命令不会触发 GitHub 工作流，也不创建 Release：

```sh
python3 scripts/release_ci.py metadata
python3 -m unittest discover -s scripts -p 'test_*.py' -v
python3 -m unittest discover -s runtime/tests -v
actionlint
```

准备好新版本记录后，可使用 `python3 scripts/release_ci.py preflight --ref refs/tags/<版本号>` 检查发布元数据；这里只校验 ref 格式和本地文档，远程 Tag 存在性由发布步骤确认。`stage` 子命令只复制白名单文件且拒绝已存在的输出目录。**`scripts/publish_release.py` 会写入 GitHub，仅正式发布时由 CI 执行，不用于本地试跑。**

本次本地验证包括脚本及运行时单元测试、工作流 actionlint 检查；发布测试模拟 GitHub CLI，覆盖缺包、额外文件、损坏校验和、测试签名、Tag 变更、已存在 Release、上传失败和远端资产不一致。没有执行云端 runner 构建、真实上传或真实业务验收。

参考：[GitHub 托管运行环境](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[复用工作流](https://docs.github.com/en/actions/how-tos/reuse-automations/reuse-workflows)、[草稿与已有 Tag](https://cli.github.com/manual/gh_release_create)、[Release assets API](https://docs.github.com/en/rest/releases/assets)。
