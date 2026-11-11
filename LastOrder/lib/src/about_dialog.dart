import 'package:material_ui/material_ui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'app_info.dart';
import 'models.dart';

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
            const Text(
              '围绕 biliTickerBuy 构建的分布式抢票管控项目。'
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
                      '$defaultSistersPort · 一个有来处的端口',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Last Order（最后之作）是第 20001 号。'
                      '项目选择 $defaultSistersPort 作为默认通信端口，'
                      '以这个编号向她致意，也留下一份属于 MisakaNetwork 的纪念。',
                    ),
                  ],
                ),
              ),
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
