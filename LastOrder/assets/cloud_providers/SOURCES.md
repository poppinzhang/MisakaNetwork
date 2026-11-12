# 公有云服务商标志来源

获取与核对日期：2026-11-13。以下资源用于 LastOrder「公有云部署」中的服务商识别，保留原始品牌配色，不是项目自行绘制的图标。品牌名称、标志及相关商标权归各服务商或其权利人所有；收录不表示官方背书、合作或将品牌素材按本项目许可证重新授权。

应用直接加载随包提供的 PNG，不在运行时请求服务商网站。腾讯云保留官网 SVG 原件；阿里云和火山引擎的 PNG 与官方下载内容一致。

| 文件 | 来源页面与引用链 | 官方原始资源 | 尺寸与处理 |
| --- | --- | --- | --- |
| `tencent.svg` / `tencent.png` | [腾讯云官网](https://cloud.tencent.com/)；[腾讯云开发者社区品牌文章](https://developer.cloud.tencent.com/article/1154340) 页面引用[官网导航样式](https://cloudcache.tencentcs.cn/qcloud/ui/cloud-community/build/base/base-202607031707.css)，其中 `.cdc-m-header.is-sticky .cdc-m-header__logo-icon` 使用此独立云形符号 | [cloud-logo_84a.svg](https://cloudcache.tencentcs.cn/qcloud/ui/cloud-community/build/base/images/cloud-logo_84a.svg) | 原 SVG `viewBox="0 0 24 24"`，包含原生白色背景；等比渲染为 256×256 PNG，未修改路径、颜色或裁切内容 |
| `aliyun.png` | [阿里云官网](https://www.aliyun.com/)；[阿里云官方文档](https://help.aliyun.com/zh/ram/user-guide/create-an-accesskey-pair) 的 `apple-touch-icon` 直接引用此资源 | [128×128 PNG](https://img.alicdn.com/imgextra/i4/O1CN01jlcNT71YBfZJJI7qY_!!6000000003021-2-tps-128-128.png) | 128×128，橙色独立符号、透明背景；原样保存 |
| `volcengine.png` | [火山引擎官网](https://www.volcengine.com/) 的 `rel="icon"` / `apple-touch-icon-precomposed` 直接引用此资源 | [favicon.png](https://portal.volccdn.com/obj/volcfe/misc/favicon.png) | 192×192，蓝/青色山峰独立符号、透明背景；原样保存 |

## 完整性记录

SHA-256：

```text
856409ee1657df89c00beff6ebca4047502a3b7580dfe831b73845b73f9f99ee  tencent.svg
a0d6d233a266411354096b51ccf5e628136409c078dd5437389fee0c973de6d6  tencent.png
c686a80a460d8a09f3f162be9b461fca0a59def31ed6325e6c444e397f03db00  aliyun.png
187b85612796c9def2a0f328538bf249fd62d549379b44a68ed9fa949b531b9f  volcengine.png
```

腾讯云 PNG 使用现成的 Sharp 0.35.5 / librsvg 2.63.2 渲染器导出，不修改原始 SVG。按 `density: 768` 读取 24×24 的原图，再使用 `resize(256, 256, {fit: 'fill'})` 导出 PNG，确保完整 `viewBox` 精确映射到 256×256 画布。人工核对及像素范围检查确认彩色图形覆盖横向 0～255、纵向 32～213，保留原图自身上下留白和白色背景，没有附加边框、阴影或不对称缩小；原始 SVG 保持官网下载字节不变。
