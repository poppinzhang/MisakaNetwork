// Opt-in captures render the actual widgets with a caller-supplied CJK font.
// Set CLOUD_PREVIEW_FONT and CLOUD_PREVIEW_OUTPUT to capture UI previews.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

void main() {
  final fontPath = Platform.environment['CLOUD_PREVIEW_FONT'];
  final output = Platform.environment['CLOUD_PREVIEW_OUTPUT'];
  testWidgets('capture cloud workflow with actual Flutter widgets', (
    tester,
  ) async {
    final font = FontLoader('Roboto')
      ..addFont(
        Future.value(ByteData.sublistView(File(fontPath!).readAsBytesSync())),
      );
    await font.load();
    final manifest =
        jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
    for (final family in manifest) {
      final loader = FontLoader(family['family'] as String);
      for (final entry in family['fonts'] as List) {
        loader.addFont(rootBundle.load(entry['asset'] as String));
      }
      await loader.load();
    }
    tester.view.physicalSize = const Size(1440, 1120);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = controller(helper: FakeHelper()..cloudSshReady = true);
    await c.initialize(poll: false);
    await c.cloud.initialize();
    addTearDown(c.dispose);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: LastOrderApp(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      for (final provider in CloudProvider.values) {
        await precacheImage(
          AssetImage('assets/cloud_providers/${provider.name}.png'),
          tester.element(find.byType(LastOrderApp)),
        );
      }
    });
    await tester.pumpAndSettle();
    Future<void> capture(String name) async {
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final directory = Directory(output!);
        await directory.create(recursive: true);
        await File('${directory.path}/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.tap(find.byTooltip('公有云部署'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-provider-aliyun')));
    await tester.pumpAndSettle();
    await capture('01-credentials-desktop');
    await c.cloud.saveCredential(
      CloudProvider.aliyun,
      accessKeyId: 'ExampleAccessId12345',
      accessKeySecret: 'ExampleSecret12345',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cloud-key-id')), findsNothing);
    expect(find.byKey(const ValueKey('cloud-save-credential')), findsNothing);
    await capture('01b-credentials-verified-desktop');
    await tester.tap(find.text('去创建云服务器'));
    await tester.pumpAndSettle();
    await capture('02-providers-desktop');
    await tester.tap(find.text('创建').first);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('cloud-template-aliyun-balanced')),
    );
    await tester.pumpAndSettle();
    await capture('03-templates-desktop');
    await tester.tap(find.byTooltip('关闭云服务器创建'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('机器管理'));
    await tester.pumpAndSettle();
    await c.cloud.startPreviewCreation(
      CloudProvider.aliyun,
      CloudTemplate.forProvider(CloudProvider.aliyun)[0],
      outcome: CloudPreviewOutcome.createFailure,
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await c.cloud.startPreviewCreation(
      CloudProvider.aliyun,
      CloudTemplate.forProvider(CloudProvider.aliyun)[1],
    );
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await c.cloud.startPreviewCreation(
      CloudProvider.aliyun,
      CloudTemplate.forProvider(CloudProvider.aliyun)[2],
    );
    await tester.pump();
    await capture('04-machines-desktop');
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    await c.setThemeMode(AppThemeMode.dark);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('公有云部署'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('cloud-provider-volcengine')));
    await tester.pumpAndSettle();
    await capture('05-credentials-dark');
    await c.setThemeMode(AppThemeMode.light);
    tester.view.physicalSize = const Size(390, 1000);
    await tester.pumpAndSettle();
    await capture('06-credentials-mobile');
    await c.cloud.saveCredential(
      CloudProvider.volcengine,
      accessKeyId: 'ExampleAccessId12345',
      accessKeySecret: 'ExampleSecret12345',
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('cloud-key-id')), findsNothing);
    expect(find.byKey(const ValueKey('cloud-save-credential')), findsNothing);
    await capture('07-credentials-verified-mobile');
  }, skip: fontPath == null || output == null);
}
