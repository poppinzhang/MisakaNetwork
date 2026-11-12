import 'dart:async';

import 'package:flutter/services.dart'
    show
        LogicalKeyboardKey,
        MethodCall,
        MethodChannel,
        MissingPluginException,
        PlatformException;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:last_order/src/about_dialog.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/app_info.dart';
import 'package:last_order/src/models.dart';

import 'fakes.dart';

void main() {
  for (final layout in [
    (TargetPlatform.windows, const Size(1360, 1000)),
    (TargetPlatform.windows, const Size(800, 640)),
    (TargetPlatform.macOS, const Size(1360, 1000)),
    (TargetPlatform.macOS, const Size(800, 640)),
    (TargetPlatform.android, const Size(850, 390)),
    (TargetPlatform.android, const Size(320, 640)),
    (TargetPlatform.android, const Size(390, 850)),
  ]) {
    final size = layout.$2;
    testWidgets('version opens about on ${layout.$1.name} at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = controller();
      await c.initialize(poll: false);
      addTearDown(c.dispose);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();

      final button = find.byKey(const ValueKey('about-button'));
      final version = find.text('LASTORDER  /  $appVersion');
      expect(button.hitTestable(), findsOneWidget);
      expect(version.hitTestable(), findsOneWidget);
      expect(find.text('关于'), findsNothing);
      expect(find.byIcon(LucideIcons.info), findsNothing);
      expect(find.byTooltip('关于 LastOrder'), findsOneWidget);
      if (size.width >= 1000) {
        final status = find.text('mTLS 安全通信');
        expect(status, findsOneWidget);
        final statusRow = tester
            .element(status)
            .findAncestorWidgetOfExactType<Row>()!;
        expect(tester.getBottomLeft(version).dx, 24);
        expect(tester.getBottomLeft(version).dy, size.height - 24);
        expect(
          tester.getTopLeft(version).dy -
              tester.getBottomLeft(find.byWidget(statusRow)).dy,
          10,
        );
      } else {
        expect(find.text('mTLS 安全通信'), findsNothing);
        expect(tester.getBottomLeft(button).dy, lessThanOrEqualTo(78));
        final headerTitle = find.text('网络概览').first;
        expect(
          tester.getTopLeft(version).dy,
          greaterThan(tester.getBottomLeft(headerTitle).dy),
        );
      }
      if (size.width < 600) {
        expect(
          tester.widget<Scaffold>(find.byType(Scaffold)).bottomNavigationBar,
          isA<NavigationBar>(),
        );
      }
      await tester.tap(version);
      await tester.pumpAndSettle();

      expect(find.byType(ProjectAboutDialog), findsOneWidget);
      expect(find.text('关于 LastOrder'), findsOneWidget);
      expect(find.text('MisakaNetwork'), findsOneWidget);
      expect(find.text('版本 $appVersion · 构建 $appBuildNumber'), findsOneWidget);
      expect(find.textContaining('biliTickerBuy'), findsOneWidget);
      expect(find.text('项目名字的由来'), findsOneWidget);
      expect(find.text('Misaka Network（御坂网络）'), findsOneWidget);
      expect(
        find.textContaining('项目使用的端口 20001 是 LastOrder 的编号。'),
        findsOneWidget,
      );
      expect(
        find.textContaining('同时 bilibili 也是来源于「御坂美琴」的别称。'),
        findsOneWidget,
      );
      expect(find.text('开源许可与第三方声明'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(find.text('关闭').hitTestable(), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();

      expect(find.byType(ProjectAboutDialog), findsNothing);
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({layout.$1}));
  }

  for (final layout in [
    (TargetPlatform.windows, const Size(1360, 1000)),
    (TargetPlatform.macOS, const Size(800, 640)),
  ]) {
    testWidgets('version supports keyboard access on ${layout.$1.name}', (
      tester,
    ) async {
      tester.view.physicalSize = layout.$2;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = controller();
      await c.initialize(poll: false);
      addTearDown(c.dispose);
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();

      final button = find.byKey(const ValueKey('about-button'));
      final version = find.text('LASTORDER  /  $appVersion');
      expect(tester.getSemantics(button).flagsCollection.isButton, isTrue);
      final focus = Focus.of(tester.element(version));
      for (var i = 0; i < 20 && !focus.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(ProjectAboutDialog), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectAboutDialog), findsNothing);
      expect(focus.hasPrimaryFocus, isTrue);
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({layout.$1}));
  }

  testWidgets(
    'phone startup error header keeps version and sync reachable with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final c = controller();
      await c.initialize(poll: false);
      addTearDown(c.dispose);
      // Isolate the header from unrelated dashboard content at large text sizes.
      c.startupError = '测试错误';
      await tester.pumpWidget(LastOrderApp(controller: c));
      await tester.pumpAndSettle();

      final version = find.text('LASTORDER  /  $appVersion');
      final sync = find.byTooltip('立即同步');
      expect(version.hitTestable(), findsOneWidget);
      expect(sync.hitTestable(), findsOneWidget);
      expect(tester.getTopLeft(version).dx, greaterThanOrEqualTo(0));
      expect(
        tester.getBottomRight(version).dx,
        lessThanOrEqualTo(tester.getTopLeft(sync).dx),
      );
      expect(tester.getBottomRight(sync).dx, lessThanOrEqualTo(320));
      expect(tester.getBottomRight(sync).dy, lessThan(640));
      expect(tester.takeException(), isNull);
      await tester.tap(version);
      await tester.pumpAndSettle();
      expect(find.byType(ProjectAboutDialog), findsOneWidget);
      expect(find.text('关闭').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(version.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant({TargetPlatform.android}),
  );

  testWidgets(
    'about stays scrollable and closable on a phone with large text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (_) => const ProjectAboutDialog(),
                  ),
                  child: const Text('打开关于'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开关于'));
      await tester.pumpAndSettle();

      expect(find.byType(ProjectAboutDialog), findsOneWidget);
      expect(find.byType(SingleChildScrollView), findsOneWidget);
      expect(find.text('关闭').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('开源许可与第三方声明'));
      await tester.pumpAndSettle();
      expect(find.text('关闭').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectAboutDialog), findsNothing);
    },
  );

  const linkChannel = MethodChannel('plugins.flutter.io/url_launcher');
  const links = {
    'biliTickerBuy': 'https://github.com/mikumifa/biliTickerBuy',
    'Misaka Network（御坂网络）':
        'https://zh.moegirl.org.cn/%E5%BE%A1%E5%9D%82%E7%BD%91%E7%BB%9C',
  };

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.android,
  ]) {
    testWidgets('about links open externally on ${platform.name}', (
      tester,
    ) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        linkChannel,
        (call) async {
          calls.add(call);
          return true;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          linkChannel,
          null,
        );
      });
      await _pumpAbout(tester);
      for (final link in links.entries) {
        final text = find.text(link.key);
        await tester.ensureVisible(text);
        await tester.tap(text);
        await tester.pumpAndSettle();
        expect(calls.last.method, 'launch');
        expect(calls.last.arguments['url'], link.value);
        expect(calls.last.arguments['useSafariVC'], isFalse);
        expect(calls.last.arguments['useWebView'], isFalse);
        expect(find.byType(ProjectAboutDialog), findsOneWidget);
      }
      expect(calls, hasLength(2));
      expect(tester.takeException(), isNull);
    }, variant: TargetPlatformVariant({platform}));
  }

  testWidgets('about links support keyboard activation', (tester) async {
    final urls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      linkChannel,
      (call) async {
        urls.add(call.arguments['url'] as String);
        return true;
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        linkChannel,
        null,
      );
    });
    await _pumpAbout(tester);
    for (final link in links.entries) {
      final focus = Focus.of(tester.element(find.text(link.key)));
      for (var i = 0; i < 10 && !focus.hasPrimaryFocus; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
      }
      expect(focus.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(urls.last, link.value);
    }
    expect(urls, hasLength(2));
    expect(tester.takeException(), isNull);
  });

  for (final failure in ['false', 'platform error', 'missing plugin']) {
    testWidgets('about link handles $failure with a selectable URL', (
      tester,
    ) async {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        linkChannel,
        (_) async {
          if (failure == 'platform error') {
            throw PlatformException(code: 'unavailable');
          }
          if (failure == 'missing plugin') throw MissingPluginException();
          return false;
        },
      );
      addTearDown(() {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          linkChannel,
          null,
        );
      });
      await _pumpAbout(tester);
      await tester.tap(find.text('biliTickerBuy'));
      await tester.pumpAndSettle();
      expect(find.text('无法打开链接'), findsOneWidget);
      expect(
        tester.widget<SelectableText>(find.byType(SelectableText)).data,
        links['biliTickerBuy'],
      );
      await tester.tap(find.text('关闭').last);
      await tester.pumpAndSettle();
      expect(find.text('无法打开链接'), findsNothing);
      expect(find.byType(ProjectAboutDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('closing about during a failed launch does not open an error', (
    tester,
  ) async {
    final result = Completer<bool>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      linkChannel,
      (_) => result.future,
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        linkChannel,
        null,
      );
    });
    await _pumpAbout(tester);
    await tester.tap(find.text('biliTickerBuy'));
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    result.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('无法打开链接'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final existingPort in <int?>[null, 24443]) {
    testWidgets(
      existingPort == null
          ? 'new machine dialog defaults to port 20001'
          : 'existing machine dialog preserves its custom port',
      (tester) async {
        final c = controller();
        await c.initialize(poll: false);
        addTearDown(c.dispose);
        final existing = existingPort == null
            ? null
            : Machine(
                id: 'custom-port',
                name: '自定义端口节点',
                host: 'node.example',
                port: existingPort,
                caCert: 'ca.pem',
                clientCert: 'client.pem',
                clientKey: 'client.key',
              );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MachineDialog(controller: c, existing: existing),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final field = tester.widget<TextField>(
          find.byWidgetPredicate(
            (widget) =>
                widget is TextField &&
                widget.decoration?.labelText == 'gRPC 端口',
          ),
        );
        expect(field.controller!.text, '${existingPort ?? 20001}');
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Future<void> _pumpAbout(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showDialog<void>(
              context: context,
              builder: (_) => const ProjectAboutDialog(),
            ),
            child: const Text('打开关于'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开关于'));
  await tester.pumpAndSettle();
}
