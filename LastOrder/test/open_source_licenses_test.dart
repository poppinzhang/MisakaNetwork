import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:last_order/src/about_dialog.dart';
import 'package:last_order/src/open_source_licenses.dart';

const _fixture = '''
[
  {
    "packages": ["biliTickerBuy"],
    "text": "PolyForm Noncommercial License 1.0.0\\n\\nRequired Notice: Copyright (c) 2023 mikumifa"
  },
  {"packages": ["Go"], "text": "Go license notice"}
]
''';

class _LicenseBundle extends CachingAssetBundle {
  _LicenseBundle(this.contents, {this.failures = 0});

  String contents;
  int failures;
  int reads = 0;

  @override
  Future<ByteData> load(String key) async {
    expect(key, thirdPartyLicensesAsset);
    reads++;
    if (failures > 0) {
      failures--;
      throw StateError('Simulated asset read failure');
    }
    return ByteData.sublistView(utf8.encode(contents));
  }
}

Widget _app(AssetBundle bundle, {bool viaAbout = false}) => DefaultAssetBundle(
  bundle: bundle,
  child: MaterialApp(
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () {
              if (viaAbout) {
                showDialog<void>(
                  context: context,
                  builder: (_) => const ProjectAboutDialog(),
                );
              } else {
                showOpenSourceLicenses(context);
              }
            },
            child: Text(viaAbout ? '打开关于' : '开源许可'),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    LicenseRegistry.reset();
    resetOpenSourceLicenseRegistration();
    // Stand in for Flutter's normal bundled NOTICES collector. Additional
    // notices must be appended, never replace the existing registry.
    LicenseRegistry.addLicense(
      () => Stream.value(
        LicenseEntryWithLineBreaks(['flutter'], 'Flutter license notice'),
      ),
    );
  });

  tearDown(() {
    LicenseRegistry.reset();
    resetOpenSourceLicenseRegistration();
  });

  test(
    'bundled notices include the upstream full text and copyright',
    () async {
      final entries = await loadOpenSourceLicenseEntries(rootBundle);
      final bili = entries.singleWhere(
        (entry) => entry.packages.contains('biliTickerBuy'),
      );
      final paragraphs = bili.paragraphs
          .map((paragraph) => paragraph.text)
          .join('\n');
      expect(paragraphs, contains('PolyForm Noncommercial License 1.0.0'));
      expect(
        paragraphs,
        contains('Required Notice: Copyright (c) 2023 mikumifa'),
      );
      expect(paragraphs, contains('Acceptance'));
      expect(paragraphs, contains('Definitions'));
      expect(entries.any((entry) => entry.packages.contains('Go')), isTrue);
    },
  );

  for (final malformed in [
    'not json',
    '{}',
    '[]',
    '[{"packages": [], "text": "notice"}]',
    '[{"packages": [1], "text": "notice"}]',
    '[{"packages": [" "], "text": "notice"}]',
    '[{"packages": ["test"], "text": ""}]',
    '[{"packages": ["test"]}]',
    '[{"packages": ["valid"], "text": "notice"}, null]',
  ]) {
    test('rejects incomplete license data: $malformed', () async {
      await expectLater(
        loadOpenSourceLicenseEntries(_LicenseBundle(malformed)),
        throwsFormatException,
      );
    });
  }

  for (final size in [const Size(800, 700), const Size(320, 640)]) {
    testWidgets('licenses show detail and return at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (size.width == 320) {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      final bundle = _LicenseBundle(_fixture);
      await tester.pumpWidget(_app(bundle));
      await tester.tap(find.text('开源许可'));
      await tester.pumpAndSettle();

      expect(find.byType(LicensePage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('biliTickerBuy'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('biliTickerBuy'));
      await tester.pumpAndSettle();
      expect(find.text('PolyForm Noncommercial License 1.0.0'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsNothing);
      expect(find.text('开源许可').hitTestable(), findsOneWidget);

      await tester.tap(find.text('开源许可'));
      await tester.pumpAndSettle();
      expect(bundle.reads, 1);
      final registered = await LicenseRegistry.licenses.toList();
      expect(
        registered.where((entry) => entry.packages.contains('biliTickerBuy')),
        hasLength(1),
      );
      expect(
        registered.where((entry) => entry.packages.contains('flutter')),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in [const Size(1360, 1000), const Size(320, 640)]) {
    testWidgets('about dialog opens licenses and remains closable at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      if (size.width == 320) {
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      }
      await tester.pumpWidget(_app(_LicenseBundle(_fixture), viaAbout: true));
      await tester.tap(find.text('打开关于'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectAboutDialog), findsOneWidget);

      final licensesButton = find.text('开源许可与第三方声明');
      await tester.ensureVisible(licensesButton);
      await tester.pumpAndSettle();
      expect(licensesButton.hitTestable(), findsOneWidget);
      await tester.tap(licensesButton);
      await tester.pumpAndSettle();
      expect(find.byType(LicensePage), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(
        find.text('biliTickerBuy'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(LicensePage),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('biliTickerBuy'));
      await tester.pumpAndSettle();
      expect(find.text('PolyForm Noncommercial License 1.0.0'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.pageBack();
      await tester.pumpAndSettle();
      // Wide screens show list and detail beside each other. Phones push a
      // detail route inside LicensePage before returning to the about dialog.
      if (size.width < 840) {
        expect(find.byType(LicensePage), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      expect(find.byType(LicensePage), findsNothing);
      expect(find.byType(ProjectAboutDialog), findsOneWidget);
      expect(find.text('关闭').hitTestable(), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(ProjectAboutDialog), findsNothing);
      expect(find.text('打开关于').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a failed read shows retry and registers only after success', (
    tester,
  ) async {
    final bundle = _LicenseBundle(_fixture, failures: 1);
    await tester.pumpWidget(_app(bundle));
    await tester.tap(find.text('开源许可'));
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsNothing);
    expect(find.text('无法读取开源许可，请重试。'), findsOneWidget);
    expect(await LicenseRegistry.licenses.toList(), hasLength(1));
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();

    expect(find.byType(LicensePage), findsOneWidget);
    expect(bundle.reads, 2);
    expect(await LicenseRegistry.licenses.toList(), hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('malformed data never registers a partial license list', (
    tester,
  ) async {
    final bundle = _LicenseBundle(
      '[{"packages": ["valid"], "text": "notice"}, null]',
    );
    await tester.pumpWidget(_app(bundle));
    await tester.tap(find.text('开源许可'));
    await tester.pumpAndSettle();
    expect(find.text('无法读取开源许可，请重试。'), findsOneWidget);
    expect(await LicenseRegistry.licenses.toList(), hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
