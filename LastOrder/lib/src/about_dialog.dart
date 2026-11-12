import 'package:material_ui/material_ui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_info.dart';
import 'models.dart';
import 'open_source_licenses.dart';

class ProjectAboutDialog extends StatelessWidget {
  const ProjectAboutDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      scrollable: true,
      title: const Text('关于 LastOrder'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  LucideIcons.network,
                  color: theme.colorScheme.primary,
                  size: 32,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('MisakaNetwork', style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        '版本 $appVersion · 构建 $appBuildNumber',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const _LinkedParagraph(
              before: '围绕 ',
              label: 'biliTickerBuy',
              url: 'https://github.com/mikumifa/biliTickerBuy',
              after:
                  ' 构建的分布式抢票管控项目。'
                  'LastOrder 管理账号、部署节点并分发任务；'
                  'Sisters 在各个节点执行任务，回报进度与结果。',
            ),
            const SizedBox(height: 24),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: DefaultTextStyle.merge(
                style: TextStyle(
                  color: theme.colorScheme.onPrimaryContainer,
                  height: 1.6,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '项目名字的由来',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                    const _LinkedParagraph(
                      label: 'Misaka Network（御坂网络）',
                      url: 'https://zh.moegirl.org.cn/%E5%BE%A1%E5%9D%82%E7%BD%91%E7%BB%9C',
                      after:
                          '取自作品《魔法禁书目录》，'
                          '项目中的管控前端被称为「LastOrder（最后之作）」，'
                          '任务的 Worker Agent 被称为「Sisters」，'
                          '项目使用的端口 $defaultSistersPort 是 LastOrder 的编号。'
                          '同时 bilibili 也是来源于「御坂美琴」的别称。',
                      inheritLinkColor: true,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () => showOpenSourceLicenses(context),
              icon: const Icon(LucideIcons.fileText, size: 18),
              label: const Text('开源许可与第三方声明'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _LinkedParagraph extends StatelessWidget {
  const _LinkedParagraph({
    this.before = '',
    required this.label,
    required this.url,
    required this.after,
    this.inheritLinkColor = false,
  });

  final String before;
  final String label;
  final String url;
  final String after;
  final bool inheritLinkColor;

  Future<void> _openLink(BuildContext context) async {
    try {
      if (await launchUrl(
        Uri.parse(url),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } on Exception {
      // A missing browser and a platform error both offer the same fallback.
    }
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('无法打开链接'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请复制以下地址，在浏览器中打开。'),
            const SizedBox(height: 12),
            SelectableText(url),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final color = inheritLinkColor
        ? style.color
        : Theme.of(context).colorScheme.primary;
    return Text.rich(
      TextSpan(
        children: [
          TextSpan(text: before),
          WidgetSpan(
            alignment: PlaceholderAlignment.baseline,
            baseline: TextBaseline.alphabetic,
            child: Semantics(
              link: true,
              child: Tooltip(
                message: url,
                child: TextButton(
                  onPressed: () => _openLink(context),
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    alignment: Alignment.centerLeft,
                    foregroundColor: color,
                    textStyle: style.copyWith(
                      decoration: TextDecoration.underline,
                      decorationColor: color,
                    ),
                  ),
                  child: Text(label),
                ),
              ),
            ),
          ),
          TextSpan(text: after),
        ],
      ),
    );
  }
}
