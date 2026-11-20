import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/cloud_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';
import 'volcengine_controller_test.dart' show VolcHarness, volcTemplateData;

Future<void> frame(
  WidgetTester tester,
  Widget child, {
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(390, 1000);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: child)));
  await tester.pumpAndSettle();
}

Future<void> tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('empty Volc catalog provides no preview or purchase', (
    tester,
  ) async {
    final c = CloudController(
      store: MemoryStore(),
      helper: FakeHelper()..cloudSshReady = true,
      templateLoader: () async => [],
      volcengineTemplateLoader: () async => [],
    );
    addTearDown(c.dispose);
    await c.initialize();
    await c.saveCredential(
      CloudProvider.volcengine,
      accessKeyId: 'FixtureID',
      accessKeySecret: 'FixtureSecret',
    );
    await frame(tester, CloudCreateDialog(controller: c));
    await tap(
      tester,
      find.byKey(const ValueKey('cloud-select-provider-volcengine')),
    );
    expect(find.textContaining('当前安装包未内置火山引擎配置模板'), findsOneWidget);
    expect(find.byKey(const ValueKey('cloud-preview-outcome')), findsNothing);
    expect(find.text('轻量起步'), findsNothing);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('cloud-confirm-create')),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'Volc creation discloses EIP joint release on narrow screen scale $scale',
      (tester) async {
        final h = VolcHarness();
        await h.init();
        addTearDown(h.c.dispose);
        await frame(tester, CloudCreateDialog(controller: h.c), scale: scale);
        await tap(
          tester,
          find.byKey(const ValueKey('cloud-select-provider-volcengine')),
        );
        await tap(
          tester,
          find.byKey(const ValueKey('cloud-template-volc-fixture')),
        );
        expect(
          find.byKey(const ValueKey('cloud-preview-outcome')),
          findsNothing,
        );
        expect(find.textContaining('释放时同步删除系统盘与本次公网 IP'), findsOneWidget);
        expect(find.textContaining('SSH 账号 root（密钥登录）'), findsOneWidget);
        expect(find.textContaining('库存不足时自动尝试同地域其他可用区'), findsOneWidget);
        expect(find.textContaining('TCP 22 与 20001（0.0.0.0/0）'), findsOneWidget);
        expect(find.textContaining('5 Mbps'), findsOneWidget);
        expect(find.text('确认按量付费创建'), findsOneWidget);
        expect(h.calls('create'), 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'release confirmation names EIP and cancellation keeps resources',
    (tester) async {
      final h = VolcHarness();
      await h.init();
      addTearDown(h.c.dispose);
      await h.create(tester);
      await frame(
        tester,
        SingleChildScrollView(
          child: CloudMachineCard(machine: h.c.jobs.single, controller: h.c),
        ),
      );
      await tap(
        tester,
        find.byKey(ValueKey('cloud-release-${h.c.jobs.single.id}')),
      );
      expect(find.textContaining('随实例创建的独立公网 IP 将一并释放'), findsOneWidget);
      expect(find.textContaining('将保留记录供继续核对'), findsOneWidget);
      expect(find.textContaining('共享网络与 SSH 公钥会保留'), findsOneWidget);
      await tap(tester, find.text('保留服务器'));
      expect(h.calls('release'), 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'residual EIP card stays queryable and cannot delete local record',
    (tester) async {
      final h = VolcHarness();
      await h.init();
      addTearDown(h.c.dispose);
      final id = await h.create(tester);
      await h.c.requestCloudRelease(id);
      await tester.pump();
      h.state = 'EIP_RELEASE_PENDING';
      await h.c.refreshCloudMachine(id);
      await frame(
        tester,
        SingleChildScrollView(
          child: CloudMachineCard(
            machine: h.c.visibleJobs.single,
            controller: h.c,
          ),
        ),
        scale: 2,
      );
      expect(find.text('释放待核实'), findsOneWidget);
      expect(find.textContaining('公网 IP 尚未确认释放'), findsOneWidget);
      expect(find.byKey(ValueKey('cloud-refresh-$id')), findsOneWidget);
      expect(find.text('删除已释放记录'), findsNothing);
      expect(find.text('删除失败记录'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test('Volc catalog factory retains immutable snapshot fields', () {
    final t = CloudTemplate.fromJson(
      CloudTemplate.volcengine(volcTemplateData()).toJson(),
    );
    expect(t.zone, 'cn-beijing-a');
    expect(t.isReal, true);
    expect(t.tencent, isNull);
  });
}
