import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:last_order/src/about_dialog.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

void configureView(
  WidgetTester tester, {
  Size size = const Size(1360, 1000),
  Brightness brightness = Brightness.light,
}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.platformBrightnessTestValue = brightness;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
}

ThemeData appTheme(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(ControlCenter)));

Future<void> selectTheme(WidgetTester tester, String label) async {
  final button = find.byKey(const ValueKey('theme-mode-button'));
  expect(button.hitTestable(), findsOneWidget);
  await tester.tap(button);
  await tester.pumpAndSettle();
  for (final option in ['跟随系统', '浅色', '深色']) {
    expect(find.text(option), findsOneWidget);
  }
  await tester.tap(
    find.ancestor(
      of: find.text(label),
      matching: find.byType(CheckedPopupMenuItem<AppThemeMode>),
    ),
  );
  await tester.pumpAndSettle();
}

double contrast(Color foreground, Color background) {
  final foregroundLuminance = foreground.computeLuminance();
  final backgroundLuminance = background.computeLuminance();
  return (math.max(foregroundLuminance, backgroundLuminance) + .05) /
      (math.min(foregroundLuminance, backgroundLuminance) + .05);
}

void expectReadableText(WidgetTester tester, String label, Color background) {
  final finder = find.text(label);
  final text = tester.widget<Text>(finder);
  final inherited = DefaultTextStyle.of(tester.element(finder)).style;
  final foreground = inherited.merge(text.style).color!;
  expect(contrast(foreground, background), greaterThanOrEqualTo(4.5));
}

void main() {
  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets('system theme follows live brightness on ${platform.name}', (
      tester,
    ) async {
      configureView(tester);
      final c = controller();
      await c.initialize(poll: false);
      addTearDown(c.dispose);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();

      expect(c.state.themeMode, AppThemeMode.system);
      expect(appTheme(tester).brightness, Brightness.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(appTheme(tester).brightness, Brightness.dark);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(appTheme(tester).brightness, Brightness.light);
      expect(c.state.themeMode, AppThemeMode.system);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  for (final layout in [
    (TargetPlatform.windows, const Size(1360, 1000)),
    (TargetPlatform.macOS, const Size(800, 640)),
    (TargetPlatform.android, const Size(320, 640)),
  ]) {
    testWidgets('theme menu works on ${layout.$1.name} at ${layout.$2}', (
      tester,
    ) async {
      configureView(tester, size: layout.$2);
      final store = MemoryStore();
      final c = controller(store: store);
      await c.initialize(poll: false);
      addTearDown(c.dispose);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();

      await selectTheme(tester, '深色');
      expect(appTheme(tester).brightness, Brightness.dark);
      expect(c.state.themeMode, AppThemeMode.dark);
      expect(store.state.themeMode, AppThemeMode.dark);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(appTheme(tester).brightness, Brightness.dark);

      await selectTheme(tester, '浅色');
      expect(appTheme(tester).brightness, Brightness.light);
      expect(store.state.themeMode, AppThemeMode.light);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expect(appTheme(tester).brightness, Brightness.light);

      await selectTheme(tester, '跟随系统');
      expect(store.state.themeMode, AppThemeMode.system);
      expect(appTheme(tester).brightness, Brightness.dark);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      await tester.pumpAndSettle();
      expect(appTheme(tester).brightness, Brightness.light);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({layout.$1}));
  }

  testWidgets('saved preference is restored after initialization and restart', (
    tester,
  ) async {
    configureView(tester);
    final store = MemoryStore();
    final first = controller(store: store);
    await first.initialize(poll: false);
    addTearDown(first.dispose);
    await tester.pumpWidget(LastOrderApp(controller: first));
    await tester.pumpAndSettle();
    await selectTheme(tester, '深色');
    await tester.pumpWidget(const SizedBox.shrink());

    final restarted = controller(store: store);
    addTearDown(restarted.dispose);
    await tester.pumpWidget(LastOrderApp(controller: restarted));
    await restarted.initialize(poll: false);
    await tester.pumpAndSettle();
    expect(restarted.state.themeMode, AppThemeMode.dark);
    expect(appTheme(tester).brightness, Brightness.dark);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'saving a preference failure keeps the theme and shows an error',
    (tester) async {
      configureView(tester);
      final store = MemoryStore()..failSave = true;
      final c = controller(store: store);
      await c.initialize(poll: false);
      addTearDown(c.dispose);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();

      await selectTheme(tester, '深色');
      expect(c.state.themeMode, AppThemeMode.system);
      expect(store.state.themeMode, AppThemeMode.system);
      expect(appTheme(tester).brightness, Brightness.light);
      expect(find.textContaining('写入失败'), findsOneWidget);
      expect(find.byType(SnackBar), findsOneWidget);
      expect(tester.takeException(), isNull);

      store.failSave = false;
      await selectTheme(tester, '深色');
      expect(appTheme(tester).brightness, Brightness.dark);
      expect(store.state.themeMode, AppThemeMode.dark);
      await tester.pump(const Duration(seconds: 7));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('dark pages and dialogs use readable themed surfaces', (
    tester,
  ) async {
    configureView(tester, brightness: Brightness.dark);
    final c = controller();
    await c.initialize(poll: false);
    addTearDown(c.dispose);
    await tester.pumpWidget(LastOrderApp(controller: c));
    await tester.pumpAndSettle();

    final theme = appTheme(tester);
    expect(theme.brightness, Brightness.dark);
    expect(theme.scaffoldBackgroundColor.computeLuminance(), lessThan(.1));
    expectReadableText(tester, '让每个节点，协同工作', theme.scaffoldBackgroundColor);
    for (final entry in [
      ('机器管理', '还没有 Sisters'),
      ('账号与任务', '还没有登录账号'),
      ('任务监控', '暂无可显示的执行记录'),
    ]) {
      await tester.tap(find.text(entry.$1).first);
      await tester.pumpAndSettle();
      final cardColor = theme.cardTheme.color ?? theme.colorScheme.surface;
      expect(cardColor.computeLuminance(), lessThan(.1));
      expectReadableText(tester, entry.$2, cardColor);
      expect(tester.takeException(), isNull);
    }

    await tester.tap(find.text('机器管理').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加机器'));
    await tester.pumpAndSettle();
    final dialogTheme = Theme.of(tester.element(find.byType(MachineDialog)));
    expect(dialogTheme.brightness, Brightness.dark);
    final inputColor = dialogTheme.inputDecorationTheme.fillColor!;
    expect(inputColor.computeLuminance(), lessThan(.1));
    expect(
      contrast(dialogTheme.colorScheme.onSurface, inputColor),
      greaterThan(4.5),
    );
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('about-button')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(ProjectAboutDialog))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
  });

  testWidgets(
    'Android system bar icons follow the effective application theme',
    (tester) async {
      configureView(tester, size: const Size(390, 850));
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
      addTearDown(tester.view.resetPadding);
      final c = controller();
      await c.initialize(poll: false);
      addTearDown(c.dispose);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();

      void expectIcons(Brightness brightness) {
        expect(SystemChrome.latestStyle?.statusBarIconBrightness, brightness);
        expect(
          SystemChrome.latestStyle?.systemNavigationBarIconBrightness,
          brightness,
        );
      }

      expectIcons(Brightness.dark);
      await selectTheme(tester, '深色');
      expectIcons(Brightness.light);
      await selectTheme(tester, '浅色');
      expectIcons(Brightness.dark);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      await tester.pumpAndSettle();
      expectIcons(Brightness.dark);
      await selectTheme(tester, '跟随系统');
      expectIcons(Brightness.light);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );
}
