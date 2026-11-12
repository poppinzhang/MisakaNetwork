import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:animations/animations.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:uuid/uuid.dart';

import '../generated/misaka/v1/sisters.pbgrpc.dart';
import 'about_dialog.dart';
import 'app_info.dart';
import 'controller.dart';
import 'models.dart';
import 'services.dart';
import 'theme.dart';

class LastOrderApp extends StatefulWidget {
  const LastOrderApp({super.key, required this.controller});
  final AppController controller;
  @override
  State<LastOrderApp> createState() => _LastOrderAppState();
}

class _LastOrderAppState extends State<LastOrderApp> {
  late final AppLifecycleListener _lifecycle;
  final _navigator = GlobalKey<NavigatorState>();
  final _lightTheme = buildAppTheme(Brightness.light);
  final _darkTheme = buildAppTheme(Brightness.dark);
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onResume: () {
        unawaited(widget.controller.refresh());
        unawaited(widget.controller.checkAccounts());
      },
      onExitRequested: () async {
        if (widget.controller.deploying > 0 && !await _confirmQuitDeploy()) {
          return AppExitResponse.cancel;
        }
        await terminateAllChildProcesses();
        return AppExitResponse.exit;
      },
    );
  }

  /// Quitting kills the deploy helper before it can verify or roll back.
  Future<bool> _confirmQuitDeploy() async {
    final context = _navigator.currentContext;
    if (context == null) return true;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('部署仍在进行'),
            content: const Text(
              '现在退出会中断部署且无法回滚，远程 Sisters 可能停在未验证的新版本或已停止。建议等待部署完成。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('继续等待'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('仍然退出'),
              ),
            ],
          ),
        ) ??
        false;
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => MaterialApp(
      navigatorKey: _navigator,
      title: 'LastOrder · MisakaNetwork',
      debugShowCheckedModeBanner: false,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: materialThemeMode(widget.controller.state.themeMode),
      builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
        value: systemUiStyleFor(Theme.of(context)),
        child: child!,
      ),
      home: ControlCenter(controller: widget.controller),
    ),
  );
}

class ControlCenter extends StatefulWidget {
  const ControlCenter({super.key, required this.controller});
  final AppController controller;
  @override
  State<ControlCenter> createState() => _ControlCenterState();
}

class _ControlCenterState extends State<ControlCenter> {
  AppController get c => widget.controller;
  ColorScheme get colors => Theme.of(context).colorScheme;
  bool savingTheme = false;
  int page = 0;
  bool busy = false;
  static const titles = ['网络概览', '机器管理', '账号与任务', '任务监控'];
  static const icons = [
    LucideIcons.layoutDashboard,
    LucideIcons.server,
    LucideIcons.ticket,
    LucideIcons.activity,
  ];
  Future<void> action(Future<void> Function() fn, {String? success}) async {
    setState(() => busy = true);
    try {
      await fn();
      if (success != null) message(success);
    } catch (e) {
      message(readableError(e), error: true);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void message(String text, {bool error = false}) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            text,
            style: TextStyle(
              color: error ? colors.onError : colors.onInverseSurface,
            ),
          ),
          backgroundColor: error ? colors.error : colors.inverseSurface,
          duration: const Duration(seconds: 6),
        ),
      );
    }
  }

  Future<void> showProjectAbout() => showDialog<void>(
    context: context,
    builder: (context) => const ProjectAboutDialog(),
  );

  Future<void> changeTheme(AppThemeMode mode) async {
    if (savingTheme || mode == c.state.themeMode) return;
    setState(() => savingTheme = true);
    try {
      await c.setThemeMode(mode);
    } catch (e) {
      message('无法保存外观设置：${readableError(e)}', error: true);
    } finally {
      if (mounted) setState(() => savingTheme = false);
    }
  }

  Widget themeButton() => PopupMenuButton<AppThemeMode>(
    key: const ValueKey('theme-mode-button'),
    tooltip: '外观主题',
    enabled: c.initialized && !savingTheme,
    initialValue: c.state.themeMode,
    icon: Icon(
      switch (c.state.themeMode) {
        AppThemeMode.system => LucideIcons.monitor,
        AppThemeMode.light => LucideIcons.sun,
        AppThemeMode.dark => LucideIcons.moon,
      },
      size: 19,
      semanticLabel: '外观主题：${themeModeLabel(c.state.themeMode)}',
    ),
    onSelected: changeTheme,
    itemBuilder: (context) => [
      for (final mode in AppThemeMode.values)
        CheckedPopupMenuItem(
          value: mode,
          checked: c.state.themeMode == mode,
          child: Text(themeModeLabel(mode)),
        ),
    ],
  );

  Widget aboutVersion({bool inHeader = false}) => Tooltip(
    message: '关于 LastOrder',
    child: Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: const ValueKey('about-button'),
        onTap: showProjectAbout,
        borderRadius: BorderRadius.circular(4),
        child: Semantics(
          button: true,
          child: Padding(
            padding: EdgeInsets.symmetric(vertical: inHeader ? 8 : 0),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                'LASTORDER  /  $appVersion',
                style: TextStyle(
                  color: colors.onSurfaceVariant,
                  fontSize: 10,
                  letterSpacing: 1.5,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Future<bool> confirm(String title, String body) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ) ??
      false;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) => Scaffold(
      bottomNavigationBar: MediaQuery.sizeOf(context).width < 600
          ? NavigationBar(
              selectedIndex: page,
              onDestinationSelected: (index) => setState(() => page = index),
              destinations: [
                for (var i = 0; i < titles.length; i++)
                  NavigationDestination(icon: Icon(icons[i]), label: titles[i]),
              ],
            )
          : null,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final wide = constraints.maxWidth >= 1000;
            return Row(
              children: [
                if (constraints.maxWidth >= 600)
                  SizedBox(
                    width: wide ? 222 : 78,
                    child: ColoredBox(
                      color: colors.surfaceContainerLow,
                      child: Column(
                        children: [
                          Expanded(
                            child: SingleChildScrollView(
                              child: Column(
                                children: [
                                  Padding(
                                    padding: EdgeInsets.fromLTRB(
                                      wide ? 24 : 18,
                                      34,
                                      12,
                                      34,
                                    ),
                                    child: Row(
                                      children: [
                                        Icon(
                                          LucideIcons.network,
                                          color: colors.primary,
                                          size: 30,
                                        ),
                                        if (wide) ...[
                                          const SizedBox(width: 12),
                                          Flexible(
                                            child: FittedBox(
                                              fit: BoxFit.scaleDown,
                                              alignment: Alignment.centerLeft,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    'LastOrder',
                                                    style: TextStyle(
                                                      color: colors.onSurface,
                                                      fontSize: 23,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                  Text(
                                                    'MISAKA NETWORK',
                                                    style: TextStyle(
                                                      color: colors
                                                          .onSurfaceVariant,
                                                      fontSize: 10,
                                                      letterSpacing: 1.4,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  for (var i = 0; i < titles.length; i++)
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                        vertical: 4,
                                      ),
                                      child: Tooltip(
                                        message: titles[i],
                                        child: Material(
                                          color: page == i
                                              ? colors.secondaryContainer
                                              : Colors.transparent,
                                          borderRadius: BorderRadius.circular(
                                            12,
                                          ),
                                          child: InkWell(
                                            borderRadius: BorderRadius.circular(
                                              12,
                                            ),
                                            onTap: () =>
                                                setState(() => page = i),
                                            child: Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 14,
                                                    vertical: 16,
                                                  ),
                                              child: Row(
                                                children: [
                                                  Icon(
                                                    icons[i],
                                                    size: 21,
                                                    color: page == i
                                                        ? colors.primary
                                                        : colors
                                                              .onSurfaceVariant,
                                                  ),
                                                  if (wide) ...[
                                                    const SizedBox(width: 14),
                                                    Text(
                                                      titles[i],
                                                      style: TextStyle(
                                                        color: page == i
                                                            ? colors
                                                                  .onSecondaryContainer
                                                            : colors
                                                                  .onSurfaceVariant,
                                                        fontWeight: page == i
                                                            ? FontWeight.w600
                                                            : FontWeight.w400,
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                          if (wide)
                            Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Icon(
                                        LucideIcons.shieldCheck,
                                        color: colors.primary,
                                        size: 15,
                                      ),
                                      SizedBox(width: 8),
                                      Text(
                                        'mTLS 安全通信',
                                        style: TextStyle(
                                          color: colors.onSurfaceVariant,
                                          fontSize: 12,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  aboutVersion(),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                Expanded(
                  child: Column(
                    children: [
                      Container(
                        constraints: const BoxConstraints(minHeight: 78),
                        padding: EdgeInsets.symmetric(
                          horizontal: constraints.maxWidth < 600 ? 16 : 32,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: colors.surfaceContainerLowest,
                          border: Border(
                            bottom: BorderSide(color: colors.outlineVariant),
                          ),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    titles[page],
                                    style: TextStyle(
                                      color: colors.onSurface,
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  if (!wide) aboutVersion(inHeader: true),
                                ],
                              ),
                            ),
                            if (constraints.maxWidth > 700)
                              Text(
                                'Sisters 每 5 秒同步',
                                style: TextStyle(
                                  color: colors.onSurfaceVariant,
                                  fontSize: 12,
                                ),
                              ),
                            const SizedBox(width: 14),
                            themeButton(),
                            IconButton(
                              tooltip: '立即同步',
                              onPressed: c.polling ? null : () => c.refresh(),
                              icon: Icon(
                                c.polling
                                    ? LucideIcons.loaderCircle
                                    : LucideIcons.refreshCw,
                                size: 19,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (busy) const LinearProgressIndicator(minHeight: 2),
                      Expanded(
                        child: c.startupError != null
                            ? Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(40),
                                  child: Text(c.startupError!),
                                ),
                              )
                            : !c.initialized
                            ? const Center(child: CircularProgressIndicator())
                            : PageTransitionSwitcher(
                                duration: const Duration(milliseconds: 240),
                                transitionBuilder:
                                    (child, primary, secondary) =>
                                        FadeThroughTransition(
                                          animation: primary,
                                          secondaryAnimation: secondary,
                                          child: child,
                                        ),
                                child: ColoredBox(
                                  key: ValueKey(page),
                                  color: colors.surface,
                                  child: SingleChildScrollView(
                                    padding: EdgeInsets.all(wide ? 32 : 16),
                                    child: Align(
                                      alignment: Alignment.topLeft,
                                      child: ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 1500,
                                        ),
                                        child: [
                                          overview,
                                          machines,
                                          tasks,
                                          monitor,
                                        ][page](),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
  Widget heading(
    String eyebrow,
    String title,
    String subtitle, {
    Widget? trailing,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 24),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 24,
      runSpacing: 16,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              eyebrow,
              style: TextStyle(
                color: colors.primary,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.6,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: TextStyle(
                color: colors.onSurface,
                fontSize: 30,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 13),
            ),
          ],
        ),
        ?trailing,
      ],
    ),
  );
  Widget panel(
    Widget child, {
    EdgeInsetsGeometry padding = const EdgeInsets.all(24),
  }) => Card(
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(18),
      side: BorderSide(color: colors.outlineVariant),
    ),
    child: Padding(padding: padding, child: child),
  );
  Widget empty(
    IconData icon,
    String title,
    String subtitle, {
    Widget? button,
  }) => panel(
    Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 36),
        child: Column(
          children: [
            Icon(icon, size: 42, color: colors.onSurfaceVariant),
            const SizedBox(height: 18),
            Text(
              title,
              style: TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 18,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
            if (button != null) ...[const SizedBox(height: 24), button],
          ],
        ),
      ),
    ),
  );
  Widget pill(String text, {Color? color}) {
    color ??= colors.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: .09),
        borderRadius: BorderRadius.circular(7),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget overview() {
    final online = c.state.machines
        .where(
          (m) =>
              c.lastSeen.containsKey(m.id) &&
              !c.connectionErrors.containsKey(m.id),
        )
        .length;
    final active = c.statuses.values
        .expand((s) => s.tasks)
        .where(
          (t) =>
              t.state == TaskState.TASK_STATE_RUNNING ||
              t.state == TaskState.TASK_STATE_QUEUED,
        )
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading('CONTROL CENTER', '让每个节点，协同工作', '从账号登录到远程执行，在一个工作台中管理。'),
        LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                Theme.of(context).platform == TargetPlatform.android &&
                constraints.maxWidth < 500;
            final spacing = compact ? 12.0 : 16.0;
            final columns = constraints.maxWidth >= 900
                ? 4
                : compact || constraints.maxWidth >= 500
                ? 2
                : 1;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final entry in [
                  (
                    LucideIcons.server,
                    '在线 Sisters',
                    '$online',
                    '共 ${c.state.machines.length} 台机器',
                  ),
                  (
                    LucideIcons.ticket,
                    '抢票任务',
                    '${c.state.tasks.length}',
                    '可分发到多个节点',
                  ),
                  (LucideIcons.activity, '执行中 / 排队', '$active', '以最近一次同步为准'),
                  (
                    LucideIcons.userRound,
                    '登录账号',
                    '${c.state.accounts.length}',
                    'Cookie 保存于安全存储',
                  ),
                ])
                  SizedBox(
                    width:
                        (constraints.maxWidth - spacing * (columns - 1)) /
                        columns,
                    child: panel(
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                entry.$1,
                                color: colors.primary,
                                size: compact ? 16 : 19,
                              ),
                              if (compact)
                                const SizedBox(width: 8)
                              else
                                const Spacer(),
                              if (compact)
                                Expanded(
                                  child: Text(
                                    entry.$2,
                                    textAlign: TextAlign.end,
                                    style: TextStyle(
                                      color: colors.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                                )
                              else
                                Text(
                                  entry.$2,
                                  style: TextStyle(
                                    color: colors.onSurfaceVariant,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                          SizedBox(height: compact ? 10 : 18),
                          Text(
                            entry.$3,
                            style: TextStyle(
                              fontSize: compact ? 30 : 36,
                              fontWeight: FontWeight.w600,
                              color: colors.onSurface,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            entry.$4,
                            style: TextStyle(
                              color: colors.onSurfaceVariant,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                      padding: compact
                          ? const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 12,
                            )
                          : const EdgeInsets.all(24),
                    ).animate().fadeIn(duration: 300.ms),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 28),
        panel(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '开始连接御坂网络',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '首次使用按以下步骤完成准备，任务执行状态会自动回传。',
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              const SizedBox(height: 24),
              for (final step in [
                (1, '部署 Sisters', '录入 Linux 或 macOS 主机，通过 SSH 安装内置版本。', 1),
                (2, '添加账号与任务', '扫码登录，选择演出、票档和购票人。', 2),
                (3, '分发并查看结果', '选择执行机器，在任务监控中查看实时进度。', 3),
              ])
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(
                    backgroundColor: colors.primaryContainer,
                    child: Text(
                      '0${step.$1}',
                      style: TextStyle(
                        color: colors.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  title: Text(step.$2),
                  subtitle: Text(step.$3),
                  trailing: const Icon(LucideIcons.arrowUpRight, size: 20),
                  onTap: () => setState(() => page = step.$4),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Icon(
              LucideIcons.lockKeyhole,
              size: 15,
              color: colors.onSurfaceVariant,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '账号与任务配置保存在系统安全存储；机器通信使用双向 TLS 认证。',
                style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget machines() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      heading(
        'SISTERS',
        '连接你的执行节点',
        '支持 Linux 与 macOS；部署时验证 SSH 主机指纹。',
        trailing: FilledButton.icon(
          onPressed: busy ? null : () => machineDialog(),
          icon: const Icon(LucideIcons.plus, size: 18),
          label: const Text('添加机器'),
        ),
      ),
      if (c.state.machines.isEmpty)
        empty(LucideIcons.server, '还没有 Sisters', '添加第一台机器，建立安全的任务执行连接。')
      else
        ...c.state.machines.map((m) {
          final status = c.statuses[m.id];
          final error = c.connectionErrors[m.id];
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: panel(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 14,
                    runSpacing: 10,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Icon(LucideIcons.server, color: colors.primary),
                      Text(
                        m.name,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      pill(
                        error != null
                            ? '连接异常'
                            : status == null
                            ? '等待同步'
                            : '在线',
                        color: error != null ? colors.error : colors.primary,
                      ),
                      if (status != null) pill(status.platform),
                    ],
                  ),
                  const SizedBox(height: 14),
                  SelectableText(
                    '${m.host}:${m.port}',
                    style: TextStyle(color: colors.onSurfaceVariant),
                  ),
                  const SizedBox(height: 10),
                  if (error != null)
                    Text(error, style: TextStyle(color: colors.error))
                  else if (status != null)
                    Text(
                      'Sisters ${status.version}  ·  biliTickerBuy ${status.biliVersion}  ·  并发上限 ${status.maxConcurrency}',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 12,
                      ),
                    ),
                  if (status != null && !status.runtimeReady)
                    Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        '运行时尚未就绪，请重新部署完整安装包。',
                        style: TextStyle(color: colors.warning),
                      ),
                    ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    children: [
                      OutlinedButton.icon(
                        onPressed: busy
                            ? null
                            : () => machineDialog(existing: m),
                        icon: const Icon(LucideIcons.upload, size: 16),
                        label: const Text('重新部署'),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () async {
                                if (await confirm(
                                  '移除机器',
                                  '仅移除本地连接。远程 Sisters 与已启动任务会继续运行。',
                                )) {
                                  await action(
                                    () => c.removeMachine(m),
                                    success: '已移除机器',
                                  );
                                }
                              },
                        child: const Text('移除连接'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          );
        }),
    ],
  );
  Widget tasks() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      heading('IDENTITY & TASKS', '准备每一次执行', '登录账号，选择演出与购票人，再将任务分发到 Sisters。'),
      Row(
        children: [
          Text(
            '登录账号',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const Spacer(),
          OutlinedButton.icon(
            onPressed: busy
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (_) => LoginDialog(controller: c),
                  ),
            icon: const Icon(LucideIcons.scanLine, size: 18),
            label: const Text('添加账号'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (c.state.accounts.isEmpty)
        empty(LucideIcons.userRound, '还没有登录账号', '使用哔哩哔哩手机客户端扫码登录。')
      else
        panel(
          Column(children: [for (final a in c.state.accounts) accountCard(a)]),
        ),
      const SizedBox(height: 30),
      Row(
        children: [
          Text(
            '抢票任务',
            style: TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: c.state.accounts.isEmpty || busy
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (_) => TaskDialog(controller: c),
                  ),
            icon: const Icon(LucideIcons.plus, size: 18),
            label: const Text('创建任务'),
          ),
        ],
      ),
      const SizedBox(height: 16),
      if (c.state.tasks.isEmpty)
        empty(LucideIcons.ticket, '暂无抢票任务', '添加账号后，选择演出场次、票档与购票人。')
      else
        ...c.state.tasks.map(
          (t) => Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: panel(
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(LucideIcons.ticket, color: colors.primary, size: 28),
                      const SizedBox(width: 18),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              t.name,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              c.state.accounts
                                      .where((a) => a.id == t.accountId)
                                      .map((a) => a.name)
                                      .firstOrNull ??
                                  '账号已移除',
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              startLabel(t),
                              style: TextStyle(color: colors.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: busy || c.state.machines.isEmpty
                            ? null
                            : () => dispatchDialog(t),
                        icon: const Icon(LucideIcons.send, size: 16),
                        label: const Text('分发'),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        tooltip: '删除任务',
                        onPressed: busy
                            ? null
                            : () async {
                                if (await confirm(
                                  '删除本地任务',
                                  '删除本地配置，不会停止远程运行的任务。停止任务请前往任务监控。',
                                )) {
                                  await action(
                                    () => c.removeTask(t),
                                    success: '已删除任务',
                                  );
                                }
                              },
                        icon: const Icon(LucideIcons.trash2, size: 18),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
    ],
  );
  Widget accountCard(Account account) {
    final checking = c.checkingAccounts.contains(account.id);
    final label = checking
        ? '正在验证登录状态…'
        : switch (account.authStatus) {
            AccountAuthStatus.valid => '登录有效 · 安全存储保护',
            AccountAuthStatus.expired => '登录已失效 · 请重新扫码登录',
            AccountAuthStatus.unknown => '登录状态待确认 · 暂停任务分发',
          };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: CircleAvatar(
              backgroundColor: colors.primaryContainer,
              child: Icon(
                LucideIcons.userRound,
                color: colors.onPrimaryContainer,
              ),
            ),
            title: Text(account.name),
            subtitle: Text(label),
          ),
          if (c.accountMessages[account.id] case final String message)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(message),
            ),
          if (account.lastChecked != null)
            Text(
              '上次检查：${account.lastChecked!.toLocal().toString().split('.').first}',
              style: TextStyle(color: colors.onSurfaceVariant, fontSize: 12),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton.icon(
                onPressed: busy || checking
                    ? null
                    : () => action(() async {
                        await c.checkAccount(account);
                      }),
                icon: const Icon(LucideIcons.refreshCw, size: 16),
                label: const Text('检查登录'),
              ),
              FilledButton.tonalIcon(
                onPressed: busy
                    ? null
                    : () => showDialog<void>(
                        context: context,
                        builder: (_) =>
                            LoginDialog(controller: c, account: account),
                      ),
                icon: const Icon(LucideIcons.scanLine, size: 16),
                label: const Text('重新登录'),
              ),
              IconButton(
                tooltip: '移除账号',
                icon: const Icon(LucideIcons.trash2, size: 18),
                onPressed: busy
                    ? null
                    : () async {
                        if (await confirm('移除账号', '移除此账号在系统安全存储中保存的 Cookie。')) {
                          await action(
                            () => c.removeAccount(account),
                            success: '已移除账号',
                          );
                        }
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget monitor() {
    final items = [
      for (final m in c.state.machines)
        for (final t in c.statuses[m.id]?.tasks ?? <TaskStatus>[]) (m, t),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        heading(
          'LIVE ACTIVITY',
          '每一步执行，都有回响',
          '展示 Sisters 返回的任务状态；连接失败时保留最后一次结果。',
        ),
        if (c.connectionErrors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: panel(
              Text(
                '${c.connectionErrors.length} 台机器连接异常，以下记录可能不是最新状态。',
                style: TextStyle(color: colors.warning),
              ),
            ),
          ),
        if (items.isEmpty)
          empty(LucideIcons.activity, '尚无执行记录', '分发任务后，这里将展示节点进度和执行结果。')
        else
          ...items.map((item) {
            final (m, t) = item;
            final active =
                t.state == TaskState.TASK_STATE_RUNNING ||
                t.state == TaskState.TASK_STATE_QUEUED;
            return Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: panel(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(
                          t.name,
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        pill(
                          stateName(t.state),
                          color: t.state == TaskState.TASK_STATE_FAILED
                              ? colors.error
                              : colors.primary,
                        ),
                        Text(
                          m.name,
                          style: TextStyle(color: colors.onSurfaceVariant),
                        ),
                        if (active)
                          TextButton.icon(
                            onPressed: busy
                                ? null
                                : () async {
                                    if (await confirm(
                                      '停止任务',
                                      '停止 ${m.name} 上的「${t.name}」。其他节点上的任务不受影响。',
                                    )) {
                                      await action(
                                        () => c.cancel(m, t.id),
                                        success: '已请求停止任务',
                                      );
                                    }
                                  },
                            icon: const Icon(LucideIcons.square, size: 14),
                            label: const Text('停止'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    SelectableText(t.message.isEmpty ? '等待执行信息' : t.message),
                    const SizedBox(height: 8),
                    Text(
                      '最后同步：${c.lastSeen[m.id]?.toLocal().toString().split('.').first ?? '—'}',
                      style: TextStyle(
                        color: colors.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    if (t.events.isNotEmpty)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(
                          '查看事件记录（${t.events.length}）',
                          style: const TextStyle(fontSize: 13),
                        ),
                        children: [
                          ConstrainedBox(
                            constraints: const BoxConstraints(maxHeight: 320),
                            child: SingleChildScrollView(
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: SelectableText(
                                  t.events
                                      .map(
                                        (e) =>
                                            '${DateTime.fromMillisecondsSinceEpoch(e.timestampUnixMs.toInt()).toLocal().toString().split('.').first}  [${e.level}]  ${e.message}',
                                      )
                                      .join('\n'),
                                  style: const TextStyle(
                                    fontFamily: 'Menlo',
                                    fontSize: 11,
                                    height: 1.7,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  Future<void> machineDialog({Machine? existing}) async {
    final warning = await showDialog<String>(
      context: context,
      builder: (_) => MachineDialog(controller: c, existing: existing),
    );
    if (warning != null) message(warning, error: true);
  }

  Future<void> dispatchDialog(TicketTask task) async {
    final chosen = <String>{};
    final saved =
        c.state.tasks.where((t) => t.id == task.id).firstOrNull ?? task;
    final submitted = saved.dispatchedTo;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, set) => AlertDialog(
          title: Text('分发「${task.name}」'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '提交后将执行真实抢票任务。相同任务可分发到多台机器，请留意重复订单并及时支付。'
                  '每台机器只提交一次，需要重新执行时请新建任务。',
                ),
                const SizedBox(height: 12),
                Text(
                  startPassed(saved)
                      ? '${startLabel(saved)}，时间已过，提交后立即开始'
                      : startLabel(saved),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 16),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final m in c.state.machines)
                          CheckboxListTile(
                            value: chosen.contains(m.id),
                            onChanged: submitted.contains(m.id)
                                ? null
                                : (v) => set(
                                    () => v == true
                                        ? chosen.add(m.id)
                                        : chosen.remove(m.id),
                                  ),
                            title: Text(m.name),
                            subtitle: Text(
                              submitted.contains(m.id)
                                  ? '${m.host}:${m.port} · 已提交，不会重复执行'
                                  : '${m.host}:${m.port}',
                            ),
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
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('返回'),
            ),
            FilledButton(
              onPressed: chosen.isEmpty ? null : () => Navigator.pop(ctx, true),
              child: Text('提交到 ${chosen.length} 台机器'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await action(() async {
        final errors = await c.dispatch(
          task,
          c.state.machines.where((m) => chosen.contains(m.id)).toList(),
        );
        if (errors.isNotEmpty) {
          message(
            '部分分发失败：${errors.entries.map((e) => '${e.key}：${e.value}').join('；')}',
            error: true,
          );
        } else {
          message('已提交任务，请查看任务监控');
        }
        if (mounted) setState(() => page = 3);
      });
    }
  }
}

String startLabel(TicketTask task) => task.startAt.isEmpty
    ? '分发后立即开始'
    : '开售 ${task.startAt.replaceFirst('T', ' ')}（北京时间）';

/// Whether the Beijing-time start has already passed on this device's clock.
bool startPassed(TicketTask task) =>
    DateTime.tryParse('${task.startAt}+08:00')?.isBefore(DateTime.now()) ??
    false;

String stateName(TaskState s) => switch (s) {
  TaskState.TASK_STATE_QUEUED => '排队中',
  TaskState.TASK_STATE_RUNNING => '执行中',
  TaskState.TASK_STATE_SUCCEEDED => '执行成功',
  TaskState.TASK_STATE_FAILED => '执行失败',
  TaskState.TASK_STATE_CANCELLED => '已停止',
  _ => '未知状态',
};

class MachineDialog extends StatefulWidget {
  const MachineDialog({super.key, required this.controller, this.existing});
  final AppController controller;
  final Machine? existing;
  @override
  State<MachineDialog> createState() => _MachineDialogState();
}

class _MachineDialogState extends State<MachineDialog> {
  late final name = TextEditingController(text: widget.existing?.name ?? '');
  late final host = TextEditingController(text: widget.existing?.host ?? '');
  final username = TextEditingController(),
      password = TextEditingController(),
      key = TextEditingController(),
      passphrase = TextEditingController(),
      sshPort = TextEditingController(text: '22');
  late final port = TextEditingController(
    text: '${widget.existing?.port ?? defaultSistersPort}',
  );
  late final ca = TextEditingController(text: widget.existing?.caCert ?? '');
  late final cert = TextEditingController(
    text: widget.existing?.clientCert ?? '',
  );
  late final privateKey = TextEditingController(
    text: widget.existing?.clientKey ?? '',
  );
  late final serverName = TextEditingController(
    text: widget.existing?.serverName ?? '',
  );
  bool manual = false, busy = false;
  final importedFiles = <String>[];
  bool saved = false;
  Future<void> pick(TextEditingController target) async {
    setState(() => busy = true);
    try {
      final path = await importProtectedFile(widget.controller.store);
      if (path != null) {
        if (!mounted) {
          await File(path).delete();
          return;
        }
        importedFiles.add(path);
        setState(() => target.text = path);
      }
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget fileField(TextEditingController target, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 14),
    child: Row(
      children: [
        Expanded(
          child: TextField(
            controller: target,
            readOnly: true,
            decoration: InputDecoration(labelText: label),
          ),
        ),
        const SizedBox(width: 8),
        IconButton(
          tooltip: '选择文件',
          onPressed: busy ? null : () => pick(target),
          icon: const Icon(LucideIcons.folderOpen),
        ),
      ],
    ),
  );
  String? error;
  @override
  void dispose() {
    for (final path in importedFiles) {
      if (!saved || ![ca.text, cert.text, privateKey.text].contains(path)) {
        File(path).delete().catchError((_) => File(path));
      }
    }
    for (final c in [
      name,
      host,
      username,
      password,
      passphrase,
      key,
      sshPort,
      port,
      ca,
      cert,
      privateKey,
      serverName,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (name.text.trim().isEmpty || host.text.trim().isEmpty) {
        throw const UserError('请填写机器名称和主机地址。');
      }
      final grpcPort = int.tryParse(port.text);
      if (grpcPort == null || grpcPort < 1 || grpcPort > 65535) {
        throw const UserError('gRPC 端口须在 1–65535 之间。');
      }
      widget.controller.requireUniqueMachineName(
        name.text.trim(),
        id: widget.existing?.id,
      );
      Map<String, dynamic> result = {};
      String fingerprint = widget.existing?.fingerprint ?? '';
      if (!manual) {
        final ssh = int.tryParse(sshPort.text);
        if (ssh == null || ssh < 1 || ssh > 65535) {
          throw const UserError('SSH 端口须在 1–65535 之间。');
        }
        if (username.text.trim().isEmpty ||
            (password.text.isEmpty && key.text.trim().isEmpty)) {
          throw const UserError('请填写 SSH 用户和密码或私钥路径。');
        }
        final request = <String, dynamic>{
          'host': host.text.trim(),
          'port': ssh,
          'username': username.text.trim(),
          'password': password.text,
          'private_key_path': key.text.trim(),
          'private_key_passphrase': passphrase.text,
          'host_key_fingerprint': fingerprint,
          'server_name': host.text.trim(),
          'grpc_port': grpcPort,
          'remote_directory': '.local/share/misaka',
        };
        result = await widget.controller.deploy(request);
        if (result['needs_confirmation'] == true) {
          fingerprint = result['fingerprint'] as String;
          if (!mounted) return;
          final approved =
              await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('确认 SSH 主机指纹'),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('请与服务器管理员提供的指纹核对一致后继续。'),
                      const SizedBox(height: 16),
                      SelectableText(
                        fingerprint,
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('指纹一致，部署'),
                    ),
                  ],
                ),
              ) ??
              false;
          if (!approved) return;
          result = await widget.controller.deploy({
            ...request,
            'host_key_fingerprint': fingerprint,
          });
        }
        if (result['needs_confirmation'] == true) {
          throw const UserError('SSH 指纹仍未通过验证，部署已停止。');
        }
      }
      final machine = Machine(
        id: widget.existing?.id ?? const Uuid().v4(),
        name: name.text.trim(),
        host: host.text.trim(),
        port: grpcPort,
        caCert: manual ? ca.text.trim() : (result['ca_cert'] ?? '') as String,
        clientCert: manual
            ? cert.text.trim()
            : (result['client_cert'] ?? '') as String,
        clientKey: manual
            ? privateKey.text.trim()
            : (result['client_key'] ?? '') as String,
        serverName: manual
            ? serverName.text.trim()
            : (result['server_name'] ?? host.text.trim()) as String,
        fingerprint: fingerprint,
      );
      await widget.controller.addMachine(machine);
      saved = true;
      // The service passed its checks through SSH, but this device could not
      // reach it directly, which is how tasks and status will travel.
      final unreachable = !manual && result['reachable'] == false;
      if (mounted) {
        Navigator.pop(
          context,
          unreachable
              ? '已部署「${machine.name}」，但本机无法直接连接 ${machine.host}:${machine.port}。'
                    '请确认防火墙或安全组已放行该 TCP 端口，且地址可从本机访问。'
              : null,
        );
      }
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => WorkDialog(
    title: widget.existing == null ? '添加 Sisters' : '重新部署 Sisters',
    busy: busy,
    error: error,
    onSubmit: submit,
    submitLabel: manual ? '保存连接' : '安全部署',
    children: [
      Text(
        'SSH 用于安装；任务与状态通过 mTLS 加密传输。部署包约 30–40 MB，'
        '网络较慢时上传可能需要十几分钟，期间请勿关闭应用。',
        style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 16),
      if (widget.existing == null)
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('连接已部署的 Sisters'),
          subtitle: const Text('手动提供 CA 与客户端证书'),
          value: manual,
          onChanged: busy ? null : (v) => setState(() => manual = v),
        ),
      field(name, '机器名称'),
      field(host, '主机地址', hint: 'IP 或域名，不含协议前缀'),
      field(port, 'gRPC 端口'),
      if (!manual) ...[
        field(username, 'SSH 用户'),
        field(sshPort, 'SSH 端口'),
        field(password, 'SSH 密码（仅用于本次部署）', secret: true),
        fileField(key, 'SSH 私钥（选择文件）'),
        field(passphrase, 'SSH 私钥口令（加密私钥时填写）', secret: true),
        Text(
          '安装内置的 Sisters 与 biliTickerBuy；重新部署会重启服务。',
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            fontSize: 12,
          ),
        ),
      ] else ...[
        fileField(ca, 'CA 证书'),
        fileField(cert, '客户端证书'),
        fileField(privateKey, '客户端私钥'),
        field(serverName, '证书服务端名称', hint: '留空使用主机地址'),
      ],
    ],
  );
}

Widget field(
  TextEditingController controller,
  String label, {
  String? hint,
  bool secret = false,
  int lines = 1,
}) => Padding(
  padding: const EdgeInsets.only(bottom: 14),
  child: TextField(
    controller: controller,
    decoration: InputDecoration(labelText: label, hintText: hint),
    obscureText: secret,
    maxLines: lines,
    autocorrect: false,
    enableSuggestions: !secret,
  ),
);

class WorkDialog extends StatelessWidget {
  const WorkDialog({
    super.key,
    required this.title,
    required this.children,
    required this.busy,
    required this.onSubmit,
    required this.submitLabel,
    this.error,
    this.width = 580,
  });
  final String title, submitLabel;
  final List<Widget> children;
  final bool busy;
  final VoidCallback? onSubmit;
  final String? error;
  final double width;
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !busy,
    child: AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: width,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ...children,
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        if (busy)
          const Padding(
            padding: EdgeInsets.only(right: 12),
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: busy ? null : onSubmit,
          child: Text(submitLabel),
        ),
      ],
    ),
  );
}

class LoginDialog extends StatefulWidget {
  const LoginDialog({super.key, required this.controller, this.account});
  final AppController controller;
  final Account? account;
  @override
  State<LoginDialog> createState() => _LoginDialogState();
}

class _LoginDialogState extends State<LoginDialog> {
  final cookie = TextEditingController();
  bool busy = false, manual = false;
  String? error, qr, qrKey;
  String status = '通过哔哩哔哩手机客户端扫码，并在手机上确认登录。';
  @override
  void dispose() {
    cookie.dispose();
    super.dispose();
  }

  Future<void> saveLogin(Map<String, dynamic> result) async {
    final uid = result['uid'];
    if (uid is! String || !Account.isValidUid(uid)) {
      throw const UserError('尚未确认登录账号身份，请重新检测登录。');
    }
    final cookies = result['cookies'];
    if (cookies is! List || cookies.isEmpty) {
      throw const UserError('登录结果未包含有效 Cookie，请重新登录。');
    }
    final name = (result['username'] ?? '').toString();
    if (widget.account case final Account account) {
      await widget.controller.refreshAccount(
        account,
        name: name,
        cookies: cookies,
        uid: uid,
      );
    } else {
      await widget.controller.addAccount(name, cookies, uid: uid);
    }
    if (mounted) Navigator.pop(context);
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (manual) {
        dynamic value;
        try {
          value = jsonDecode(cookie.text);
        } catch (_) {
          throw const UserError(
            '请输入 JSON Cookie 数组，例如 [{"name":"…","value":"…"}]。',
          );
        }
        if (value is! List) throw const UserError('Cookie 必须为 JSON 数组。');
        final result = await widget.controller.runtime.call('login_cookie', {
          'cookies': value,
        });
        if (result['status'] != 'valid' || result['logged_in'] != true) {
          throw UserError(
            result['status'] == 'expired'
                ? 'Cookie 已失效，请使用手机客户端重新扫码登录。'
                : '暂时无法验证登录状态，请检查网络后重试。尚未保存此 Cookie。',
          );
        }
        await saveLogin(result);
        return;
      }
      if (qrKey == null) {
        final result = await widget.controller.runtime.call('qr_start', {});
        if (mounted) {
          setState(() {
            qr = result['qr_png_base64'] as String?;
            qrKey = result['qrcode_key'] as String?;
            status = '使用手机客户端扫描二维码，然后点击「检测登录」。';
          });
        }
      } else {
        final result = await widget.controller.runtime.call('qr_poll', {
          'qrcode_key': qrKey,
          'timeout_seconds': 5,
        });
        if (result['status'] == 'confirmed') {
          await saveLogin(result);
        } else if (mounted) {
          setState(
            () => status = result['status'] == 'timeout'
                ? '暂未确认。请在手机端确认后再次检测；二维码失效时重新生成。'
                : '登录未完成，请重新生成二维码。',
          );
        }
      }
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => WorkDialog(
    title: widget.account == null ? '登录哔哩哔哩' : '重新登录账号',
    busy: busy,
    error: error,
    onSubmit: submit,
    submitLabel: manual
        ? '验证并保存'
        : qrKey == null
        ? '生成二维码'
        : '检测登录',
    children: [
      if (widget.account case final Account account) ...[
        Text('请使用「${account.name}」原账号扫码。登录成功后更新 Cookie，保留已有任务与场次选择。'),
        const SizedBox(height: 8),
        const Text('更新后不会自动启动任务；已分发到 Sisters 的执行不会被替换。'),
        const SizedBox(height: 12),
      ],
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: const Text('使用已有 Cookie'),
        value: manual,
        onChanged: busy ? null : (v) => setState(() => manual = v),
      ),
      if (manual) ...[
        const Text('仅接受 biliTickerBuy 兼容的 Cookie JSON 数组。验证成功后保存至系统安全存储。'),
        const SizedBox(height: 16),
        field(cookie, 'Cookie JSON', lines: 6),
      ] else ...[
        Text(status),
        const SizedBox(height: 20),
        if (qr != null)
          Center(
            child: Image.memory(
              base64Decode(qr!),
              width: 220,
              height: 220,
              errorBuilder: (_, error, stack) => const Text('二维码无法显示，请重新生成。'),
            ),
          ),
        if (qrKey != null)
          Center(
            child: TextButton(
              onPressed: busy
                  ? null
                  : () => setState(() {
                      qr = null;
                      qrKey = null;
                      status = '请生成新的二维码。';
                    }),
              child: const Text('重新生成二维码'),
            ),
          ),
      ],
      const SizedBox(height: 12),
      Text(
        '登录凭据不会写入普通配置文件。',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 12,
        ),
      ),
    ],
  );
}

class TaskDialog extends StatefulWidget {
  const TaskDialog({super.key, required this.controller});
  final AppController controller;
  @override
  State<TaskDialog> createState() => _TaskDialogState();
}

class _TaskDialogState extends State<TaskDialog> {
  final name = TextEditingController(),
      project = TextEditingController(),
      date = TextEditingController(),
      buyer = TextEditingController(),
      tel = TextEditingController(),
      startAt = TextEditingController();
  late String accountId = widget.controller.state.accounts.first.id;
  Map<String, dynamic>? purchase;
  int ticketIndex = 0, addressIndex = 0;
  final Set<int> buyers = {};
  bool busy = false;
  String? error;
  String suggestedStartAt = '';
  Account get account =>
      widget.controller.state.accounts.firstWhere((a) => a.id == accountId);
  @override
  void dispose() {
    for (final c in [name, project, date, buyer, tel, startAt]) {
      c.dispose();
    }
    super.dispose();
  }

  /// Prefills the selected ticket's sale start unless the user typed another.
  void suggestStartAt(Object? ticket) {
    var suggestion = '';
    try {
      final sale = ticket is Map ? ticket['sale_start'] : null;
      suggestion = normalizeStartAt('${sale ?? ''}').replaceFirst('T', ' ');
    } on UserError {
      // Upstream may report the sale start in another form; leave it to the user.
    }
    if (startAt.text.trim().isEmpty || startAt.text == suggestedStartAt) {
      startAt.text = suggestion;
    }
    suggestedStartAt = suggestion;
  }

  Future<void> submit() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      if (purchase == null) {
        if (project.text.trim().isEmpty) {
          throw const UserError('请填写演出 ID 或会员购链接。');
        }
        await widget.controller.ensureAccountValid(account);
        final result = await widget.controller.runtime.call(
          'purchase_context',
          {
            'project_input': project.text.trim(),
            'cookies': await widget.controller.cookies(account),
            if (date.text.trim().isNotEmpty) 'selected_date': date.text.trim(),
          },
        );
        if ((result['ticket_options'] as List? ?? []).isEmpty) {
          throw const UserError('此演出没有可选票档，请检查演出或日期。');
        }
        if (mounted) {
          setState(() {
            purchase = result;
            ticketIndex = 0;
            buyers.clear();
            if (name.text.trim().isEmpty) {
              name.text = (result['project_name'] ?? '抢票任务').toString();
            }
            suggestStartAt((result['ticket_options'] as List).first);
          });
        }
      } else {
        if (buyers.isEmpty) {
          throw const UserError('请至少选择一位购票人；缺少购票人时，请先在哔哩哔哩补齐。');
        }
        final addresses = purchase!['addresses'] as List? ?? [];
        if (addresses.isEmpty || addressIndex >= addresses.length) {
          throw const UserError('请先在哔哩哔哩添加收货地址，再重新读取演出。当前运行时要求电子票也提供地址。');
        }
        if (buyer.text.trim().isEmpty || tel.text.trim().isEmpty) {
          throw const UserError('联系人和联系电话为必填项。');
        }
        final start = normalizeStartAt(startAt.text);
        final config = await widget.controller.runtime.call('build_config', {
          'purchase_context': purchase,
          'selection': {
            'ticket_index': ticketIndex,
            'buyer_indices': buyers.toList(),
            'address_index': addressIndex,
            'buyer': buyer.text.trim(),
            'tel': tel.text.trim(),
          },
        });
        await widget.controller.addTask(
          name.text,
          account,
          config,
          startAt: start,
        );
        if (mounted) Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) setState(() => error = readableError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tickets = purchase?['ticket_options'] as List? ?? [];
    final people = purchase?['buyers'] as List? ?? [];
    final addresses = purchase?['addresses'] as List? ?? [];
    return WorkDialog(
      title: '创建抢票任务',
      busy: busy,
      error: error,
      onSubmit: submit,
      submitLabel: purchase == null ? '读取演出与购票人' : '保存任务',
      width: 650,
      children: [
        DropdownButtonFormField<String>(
          initialValue: accountId,
          decoration: const InputDecoration(labelText: '使用账号'),
          items: [
            for (final a in widget.controller.state.accounts)
              DropdownMenuItem(value: a.id, child: Text(a.name)),
          ],
          onChanged: busy || purchase != null
              ? null
              : (v) => setState(() => accountId = v!),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: busy
                ? null
                : () async {
                    await showDialog<void>(
                      context: context,
                      builder: (_) => LoginDialog(
                        controller: widget.controller,
                        account: account,
                      ),
                    );
                    if (mounted) {
                      setState(() {
                        purchase = null;
                        buyers.clear();
                        error = null;
                      });
                    }
                  },
            icon: const Icon(LucideIcons.scanLine, size: 16),
            label: const Text('重新登录此账号'),
          ),
        ),
        const SizedBox(height: 16),
        if (purchase == null) ...[
          field(project, '演出 ID 或会员购链接'),
          field(date, '日期（有日历场次时填写）', hint: 'YYYY-MM-DD'),
          Text(
            '将通过 biliTickerBuy 读取真实场次、票档和账号购票人。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ] else ...[
          field(name, '任务名称'),
          DropdownButtonFormField<int>(
            initialValue: ticketIndex,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '场次 / 票档'),
            items: [
              for (var i = 0; i < tickets.length; i++)
                DropdownMenuItem(
                  value: i,
                  child: Text(
                    (tickets[i]['display'] ??
                            tickets[i]['desc'] ??
                            '票档 ${i + 1}')
                        .toString(),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: busy
                ? null
                : (v) => setState(() {
                    ticketIndex = v!;
                    suggestStartAt(tickets[v]);
                  }),
          ),
          const SizedBox(height: 14),
          field(startAt, '开售时间（北京时间）', hint: '2026-11-20 20:00:00'),
          Text(
            '默认使用所选票档的起售时间，Sisters 按此倒计时后开始抢票；留空则分发后立即开始。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 20),
          const Text('购票人', style: TextStyle(fontWeight: FontWeight.w600)),
          if (people.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('账号未返回购票人。请先在哔哩哔哩账号中添加所需信息。'),
            ),
          for (var i = 0; i < people.length; i++)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text((people[i]['name'] ?? '购票人 ${i + 1}').toString()),
              value: buyers.contains(i),
              onChanged: busy
                  ? null
                  : (v) => setState(
                      () => v == true ? buyers.add(i) : buyers.remove(i),
                    ),
            ),
          const SizedBox(height: 12),
          if (addresses.isNotEmpty) ...[
            DropdownButtonFormField<int>(
              initialValue: addressIndex,
              isExpanded: true,
              decoration: const InputDecoration(labelText: '收货地址'),
              items: [
                for (var i = 0; i < addresses.length; i++)
                  DropdownMenuItem(
                    value: i,
                    child: Text(
                      '${addresses[i]['name'] ?? ''} ${addresses[i]['prov'] ?? ''}${addresses[i]['city'] ?? ''}${addresses[i]['area'] ?? ''}',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: busy ? null : (v) => setState(() => addressIndex = v!),
            ),
            const SizedBox(height: 14),
          ],
          if (addresses.isEmpty)
            Padding(
              padding: EdgeInsets.only(bottom: 14),
              child: Text(
                '请先在哔哩哔哩添加收货地址，再重新读取。当前运行时要求电子票也提供地址。',
                style: TextStyle(color: Theme.of(context).colorScheme.warning),
              ),
            ),
          field(buyer, '联系人（必填）'),
          field(tel, '联系电话（必填）'),
          TextButton(
            onPressed: busy ? null : () => setState(() => purchase = null),
            child: const Text('重新选择演出'),
          ),
          Text(
            '任务保存后不会立即执行。请在任务列表中选择机器并分发。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
        ],
      ],
    );
  }
}
