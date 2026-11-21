import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:material_ui/material_ui.dart';

import 'controller.dart';
import 'models.dart';
import 'theme.dart';

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.controller});

  final AppController controller;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  bool saving = false;
  String? error;

  Future<void> save(Future<void> Function() change) async {
    if (saving) return;
    setState(() {
      error = null;
      saving = true;
    });
    try {
      await change();
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final state = controller.state;
        final warning =
            error ??
            (state.successNotificationsEnabled
                ? controller.notificationDeliveryError ??
                      controller.backgroundMonitoringError
                : null);
        return PopScope(
          canPop: !saving,
          child: AlertDialog(
            scrollable: true,
            title: const Text('配置'),
            content: SizedBox(
              width: 400,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PopupMenuButton<AppThemeMode>(
                    tooltip: '选择外观主题',
                    enabled: !saving,
                    initialValue: state.themeMode,
                    onSelected: (mode) {
                      if (mode != state.themeMode) {
                        save(() => controller.setThemeMode(mode));
                      }
                    },
                    itemBuilder: (context) => [
                      for (final mode in AppThemeMode.values)
                        CheckedPopupMenuItem(
                          value: mode,
                          checked: state.themeMode == mode,
                          child: Text(themeModeLabel(mode)),
                        ),
                    ],
                    child: ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('外观主题'),
                      subtitle: Text(themeModeLabel(state.themeMode)),
                      trailing: const Icon(LucideIcons.chevronDown, size: 20),
                    ),
                  ),
                  const Divider(),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('抢票成功通知'),
                    subtitle: Text(
                      Theme.of(context).platform == TargetPlatform.android
                          ? '抢到新订单时提醒。有任务时可切到后台或锁屏，通知栏会静默显示监控状态。'
                          : '同步到新订单时，在本机显示系统通知。',
                    ),
                    value: state.successNotificationsEnabled,
                    onChanged: saving
                        ? null
                        : (enabled) => save(
                            () => controller.setSuccessNotificationsEnabled(
                              enabled,
                            ),
                          ),
                  ),
                  if (warning != null)
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        warning,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: saving ? null : () => Navigator.pop(context),
                child: const Text('关闭'),
              ),
            ],
          ),
        );
      },
    );
  }
}
