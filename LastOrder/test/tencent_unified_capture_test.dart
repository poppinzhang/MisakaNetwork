// Opt-in capture using synthetic cloud resources and a caller-supplied CJK font.
// Set CLOUD_PREVIEW_FONT and CLOUD_PREVIEW_OUTPUT to render the unified card.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/cloud_ui.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'tencent_deployment_test.dart' show DeployHarness, resourceId;

void main() {
  final fontPath = Platform.environment['CLOUD_PREVIEW_FONT'];
  final output = Platform.environment['CLOUD_PREVIEW_OUTPUT'];
  testWidgets('capture unified cloud deployment card', (tester) async {
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
    tester.view.physicalSize = const Size(1360, 1080);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final h = DeployHarness();
    await h.init();
    h.failDeployment = true;
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: LastOrderApp(controller: h.controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('机器管理'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await precacheImage(
        const AssetImage('assets/cloud_providers/tencent.png'),
        tester.element(find.byType(LastOrderApp)),
      );
    });
    await tester.tap(find.byKey(const ValueKey('cloud-deploy-$resourceId')));
    await tester.pumpAndSettle();
    expect(find.byType(CloudMachineCard), findsOneWidget);
    expect(find.text('测试部署失败'), findsOneWidget);

    Future<void> capture(String name) async {
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

    await capture('unified-cloud-failed');
    h.failDeployment = false;
    await tester.tap(find.byKey(const ValueKey('cloud-deploy-$resourceId')));
    await tester.pumpAndSettle();
    expect(find.text('在线'), findsOneWidget);
    await capture('unified-cloud-online');
    await h.controller.setThemeMode(AppThemeMode.dark);
    await tester.pumpAndSettle();
    await capture('unified-cloud-online-dark');
    tester.view.physicalSize = const Size(390, 1200);
    await tester.pumpAndSettle();
    await capture('unified-cloud-online-mobile');
    await tester.pumpWidget(const SizedBox.shrink());
    h.controller.dispose();
  }, skip: fontPath == null || output == null);
}
