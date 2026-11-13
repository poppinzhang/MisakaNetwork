import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/cloud_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'fakes.dart';

// Deliberately synthetic resource identifiers and documentation-only addresses.
final _template = CloudTemplate.tencent({
  'id': 'tencent-ui',
  'name': '测试模板',
  'description': '界面测试，不连接云端',
  'cpu': 2,
  'memoryGb': 4,
  'diskGb': 40,
  'architecture': 'x64',
  'os': 'Ubuntu 24.04 LTS',
  'regionLabel': '测试地域',
  'region': 'ap-guangzhou',
  'sshUsername': 'ubuntu',
  'sshCidr': '192.0.2.1/32',
  'grpcCidr': '192.0.2.2/32',
  'runInstances': {
    'Placement': {'Zone': 'ap-guangzhou-6'},
    'InstanceType': 'S5.MEDIUM4',
    'ImageId': 'img-uitest',
    'SystemDisk': {'DiskType': 'CLOUD_PREMIUM', 'DiskSize': 40},
    'VirtualPrivateCloud': {'VpcId': 'vpc-uitest', 'SubnetId': 'subnet-uitest'},
    'InternetAccessible': {
      'InternetChargeType': 'TRAFFIC_POSTPAID_BY_HOUR',
      'InternetMaxBandwidthOut': 5,
      'PublicIpAssigned': true,
    },
  },
});

CloudMachine _machine({
  CloudMachinePhase phase = CloudMachinePhase.created,
  String instanceId = 'ins-uitest',
  String error = '',
}) => CloudMachine(
  id: 'ui-operation',
  name: '测试云服务器',
  provider: CloudProvider.tencent,
  template: _template,
  phase: phase,
  isReal: true,
  createSubmitted: true,
  instanceId: instanceId,
  publicIp: instanceId.isEmpty ? '' : '192.0.2.100',
  region: 'ap-guangzhou',
  clientToken: 'ui-client-token',
  error: error,
);

class _UiController extends CloudController {
  _UiController({bool empty = false})
    : super(
        store: MemoryStore(),
        helper: FakeHelper()..cloudSshReady = true,
        templateLoader: () async => empty ? [] : [_template],
      );

  int creates = 0;
  final releases = <String>[];
  final refreshes = <String>[];

  @override
  Future<CloudMachine> startTencentCreation(CloudTemplate template) async {
    expect(template.id, _template.id);
    creates++;
    return _machine(phase: CloudMachinePhase.creating);
  }

  @override
  Future<void> requestTencentRelease(String id) async => releases.add(id);

  @override
  Future<void> refreshTencentMachine(String id) async => refreshes.add(id);
}

Future<_UiController> _controller({bool empty = false}) async {
  final controller = _UiController(empty: empty);
  await controller.initialize();
  await controller.saveCredential(
    CloudProvider.tencent,
    alias: '测试凭证',
    accessKeyId: 'synthetic-ui-id',
    accessKeySecret: 'synthetic-ui-secret',
  );
  addTearDown(controller.dispose);
  return controller;
}

Future<void> _frame(
  WidgetTester tester,
  Widget child, {
  double width = 1100,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(colorSchemeSeed: Colors.blue, useMaterial3: true),
      home: Scaffold(body: child),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'empty Tencent templates cannot fall back to a preview purchase',
    (tester) async {
      final controller = await _controller(empty: true);
      await _frame(tester, CloudCreateDialog(controller: controller));
      await _tap(
        tester,
        find.byKey(const ValueKey('cloud-select-provider-tencent')),
      );
      expect(find.textContaining('管理员尚未配置腾讯云模板'), findsOneWidget);
      expect(find.text('轻量起步'), findsNothing);
      expect(find.byKey(const ValueKey('cloud-preview-outcome')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('cloud-confirm-create')),
            )
            .onPressed,
        isNull,
      );
      expect(controller.creates, 0);
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets(
      'Tencent creation discloses billing and CIDRs at scale $scale',
      (tester) async {
        final controller = await _controller();
        await _frame(
          tester,
          Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => CloudCreateDialog(controller: controller),
              ),
              child: const Text('打开'),
            ),
          ),
          width: 390,
          textScale: scale,
        );
        await _tap(tester, find.text('打开'));
        await _tap(
          tester,
          find.byKey(const ValueKey('cloud-select-provider-tencent')),
        );
        await _tap(
          tester,
          find.byKey(const ValueKey('cloud-template-tencent-ui')),
        );
        expect(
          find.byKey(const ValueKey('cloud-preview-outcome')),
          findsNothing,
        );
        expect(find.textContaining('SSH 22：192.0.2.1/32'), findsOneWidget);
        expect(
          find.textContaining('Sisters 20001：192.0.2.2/32'),
          findsOneWidget,
        );
        expect(find.textContaining('按小时后付费'), findsOneWidget);
        expect(find.textContaining('5 Mbps'), findsOneWidget);
        expect(find.textContaining('Sisters 需另行部署'), findsOneWidget);
        expect(controller.creates, 0);
        await _tap(tester, find.text('确认按量付费创建'));
        expect(controller.creates, 1);
        expect(find.byType(CloudCreateDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'real release identifies the instance and requires confirmation',
    (tester) async {
      final controller = await _controller();
      await _frame(
        tester,
        SingleChildScrollView(
          child: CloudMachineCard(machine: _machine(), controller: controller),
        ),
      );
      expect(find.text('已创建 · 待部署'), findsOneWidget);
      expect(find.text('部署完成'), findsNothing);
      expect(find.text('交互预览'), findsNothing);
      expect(find.text('删除预览记录'), findsNothing);
      expect(find.textContaining('Sisters 尚未部署'), findsOneWidget);
      await _tap(tester, find.text('释放云服务器'));
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('实例：ins-uitest'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('删除系统盘数据'), findsOneWidget);
      expect(find.textContaining('费用已停止'), findsOneWidget);
      await _tap(tester, find.text('保留服务器'));
      expect(controller.releases, isEmpty);
      await _tap(tester, find.text('释放云服务器'));
      await _tap(tester, find.text('确认释放并删除数据'));
      expect(controller.releases, ['ui-operation']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unknown creation offers reconciliation without deleting evidence',
    (tester) async {
      final controller = await _controller();
      await _frame(
        tester,
        SingleChildScrollView(
          child: CloudMachineCard(
            machine: _machine(
              phase: CloudMachinePhase.unknown,
              instanceId: '',
              error: '创建结果尚未确认，请查询云端状态或到控制台核实。',
            ),
            controller: controller,
          ),
        ),
      );
      expect(find.text('创建结果待核实'), findsOneWidget);
      expect(find.text('释放云服务器'), findsNothing);
      expect(find.byIcon(LucideIcons.trash2), findsNothing);
      await _tap(tester, find.text('查询云端状态'));
      expect(controller.refreshes, ['ui-operation']);
      expect(controller.releases, isEmpty);
      expect(controller.creates, 0);
    },
  );
}
