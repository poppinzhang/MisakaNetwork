import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/cloud_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';
import 'aliyun_controller_test.dart' show Harness, templateData;

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
  testWidgets('empty Aliyun catalog provides no preview or purchase', (
    tester,
  ) async {
    final c = CloudController(
      store: MemoryStore(),
      helper: FakeHelper()..cloudSshReady = true,
      templateLoader: () async => [],
      aliyunTemplateLoader: () async => [],
    );
    addTearDown(c.dispose);
    await c.initialize();
    await c.saveCredential(
      CloudProvider.aliyun,
      accessKeyId: 'FixtureID',
      accessKeySecret: 'FixtureSecret',
    );
    await frame(tester, CloudCreateDialog(controller: c));
    await tap(
      tester,
      find.byKey(const ValueKey('cloud-select-provider-aliyun')),
    );
    expect(find.textContaining('管理员尚未配置阿里云模板'), findsOneWidget);
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
      'Aliyun creation discloses direct public IP lifecycle on narrow screen scale $scale',
      (tester) async {
        final h = Harness();
        await h.init();
        addTearDown(h.c.dispose);
        await frame(tester, CloudCreateDialog(controller: h.c), scale: scale);
        await tap(
          tester,
          find.byKey(const ValueKey('cloud-select-provider-aliyun')),
        );
        await tap(
          tester,
          find.byKey(const ValueKey('cloud-template-test-aliyun')),
        );
        expect(
          find.byKey(const ValueKey('cloud-preview-outcome')),
          findsNothing,
        );
        expect(find.textContaining('本次公网地址与系统盘随实例释放'), findsOneWidget);
        expect(find.textContaining('SSH 登录：root（密钥）'), findsOneWidget);
        expect(find.textContaining('仅明确库存或容量不足时'), findsOneWidget);
        expect(find.textContaining('保持相同机型、镜像、系统盘和带宽'), findsOneWidget);
        expect(find.textContaining('创建结果不确定时暂停尝试'), findsOneWidget);
        expect(find.textContaining('5 Mbps'), findsOneWidget);
        expect(find.text('确认按量付费创建'), findsOneWidget);
        expect(
          h.helper.requests.where((r) => r['action'] == 'aliyun_create').length,
          0,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Aliyun confirmation invokes actual resource workflow once', (
    tester,
  ) async {
    final h = Harness();
    await h.init();
    addTearDown(h.c.dispose);
    await frame(tester, CloudCreateDialog(controller: h.c));
    await tap(
      tester,
      find.byKey(const ValueKey('cloud-select-provider-aliyun')),
    );
    await tap(tester, find.byKey(const ValueKey('cloud-template-test-aliyun')));
    await tap(tester, find.byKey(const ValueKey('cloud-confirm-create')));
    expect(h.c.jobs.single.isReal, isTrue);
    expect(h.c.jobs.single.provider, CloudProvider.aliyun);
    await tester.pump();
    await h.c.refreshCloudMachine(h.c.jobs.single.id);
    expect(
      h.helper.requests.where((r) => r['action'] == 'aliyun_create'),
      hasLength(1),
    );
    expect(
      h.helper.requests.where(
        (r) =>
            r['action'] == 'tencent_create' ||
            r['action'] == 'volcengine_create',
      ),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'release confirmation names Aliyun console and cancellation keeps resources',
    (tester) async {
      final h = Harness();
      await h.init();
      addTearDown(h.c.dispose);
      final job = await h.create();
      await tester.pump();
      await h.c.refreshCloudMachine(job.id);
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
      expect(find.textContaining('阿里云控制台'), findsOneWidget);
      expect(find.textContaining('腾讯云控制台'), findsNothing);
      expect(find.textContaining('共享安全组、SSH 公钥、VPC 和子网会保留'), findsOneWidget);
      await tap(tester, find.text('保留服务器'));
      expect(
        h.helper.requests.where((r) => r['action'] == 'aliyun_release').length,
        0,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('Aliyun catalog factory retains immutable snapshot fields', () {
    final t = CloudTemplate.fromJson(
      CloudTemplate.aliyun(templateData()).toJson(),
    );
    expect(t.zone, 'cn-hangzhou-a');
    expect(t.isReal, true);
    expect(t.tencent, isNull);
  });
}
