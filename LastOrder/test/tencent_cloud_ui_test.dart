import 'dart:async';

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
  'runInstances': {
    'Placement': {'Zone': 'ap-guangzhou-6'},
    'InstanceType': 'S5.MEDIUM4',
    'ImageId': 'img-uitest',
    'SystemDisk': {'DiskType': 'CLOUD_PREMIUM', 'DiskSize': 40},
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
  bool createSubmitted = true,
  String selectedZone = '',
}) => CloudMachine(
  id: 'ui-operation',
  name: '测试云服务器',
  provider: CloudProvider.tencent,
  template: _template,
  phase: phase,
  isReal: true,
  createSubmitted: createSubmitted,
  selectedZone: selectedZone,
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

  bool deploymentLocked = false;
  @override
  bool isDeployingTencent(String id) => deploymentLocked;

  int creates = 0;
  final releases = <String>[];
  final refreshes = <String>[];
  final retries = <String>[];

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

  @override
  Future<void> retryTencentPreparation(String id) async => retries.add(id);
}

Future<_UiController> _controller({bool empty = false}) async {
  final controller = _UiController(empty: empty);
  await controller.initialize();
  await controller.saveCredential(
    CloudProvider.tencent,
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
  bool settle = true,
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
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 300));
  }
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
      'Tencent creation discloses billing and fixed ubuntu access at scale $scale',
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
        expect(find.textContaining('SSH 登录：ubuntu（密钥）'), findsOneWidget);
        expect(find.textContaining('SSH TCP 22 来源：0.0.0.0/0'), findsOneWidget);
        expect(
          find.textContaining('Sisters TCP 20001 来源：0.0.0.0/0'),
          findsOneWidget,
        );
        expect(find.textContaining('按小时后付费'), findsOneWidget);
        expect(find.textContaining('5 Mbps'), findsOneWidget);
        expect(find.textContaining('建议可用区：ap-guangzhou-6'), findsOneWidget);
        expect(find.textContaining('同地域其他可用区'), findsOneWidget);
        expect(find.textContaining('保持相同机型、镜像、系统盘和带宽'), findsOneWidget);
        expect(find.textContaining('创建结果不确定时暂停尝试'), findsOneWidget);
        expect(find.textContaining('Sisters 需另行部署'), findsOneWidget);
        expect(find.textContaining('自动创建并复用 VPC 和子网'), findsOneWidget);
        expect(controller.creates, 0);
        await _tap(tester, find.text('确认按量付费创建'));
        expect(controller.creates, 1);
        expect(find.byType(CloudCreateDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'real release identifies the server without cloud identifiers and requires confirmation',
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
      expect(find.textContaining('点击「部署 Sisters」'), findsOneWidget);
      expect(find.textContaining('ap-guangzhou'), findsNothing);
      expect(find.textContaining('ins-uitest'), findsNothing);
      expect(find.text('测试地域'), findsNothing);
      await _tap(tester, find.text('释放云服务器'));
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.textContaining('测试云服务器'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('ap-guangzhou'), findsNothing);
      expect(find.textContaining('ins-uitest'), findsNothing);
      expect(find.textContaining('公网地址：192.0.2.100'), findsNWidgets(2));
      expect(find.textContaining('删除系统盘数据'), findsOneWidget);
      expect(find.textContaining('VPC 和子网会保留'), findsOneWidget);
      expect(find.textContaining('费用已停止'), findsOneWidget);
      await _tap(tester, find.text('保留服务器'));
      expect(controller.releases, isEmpty);
      await _tap(tester, find.text('释放云服务器'));
      await _tap(tester, find.text('确认释放并删除数据'));
      expect(controller.releases, ['ui-operation']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('created server hides cloud location and instance identifiers', (
    tester,
  ) async {
    final controller = await _controller();
    await _frame(
      tester,
      SingleChildScrollView(
        child: CloudMachineCard(
          machine: _machine(selectedZone: 'ap-guangzhou-7'),
          controller: controller,
        ),
      ),
      width: 390,
      textScale: 2,
    );
    expect(find.textContaining('ap-guangzhou'), findsNothing);
    expect(find.textContaining('ins-uitest'), findsNothing);
    expect(find.text('测试地域'), findsNothing);
    expect(find.textContaining('当前尝试可用区'), findsNothing);
    expect(find.textContaining('公网地址：192.0.2.100'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final phase in [CloudMachinePhase.creating, CloudMachinePhase.unknown]) {
    testWidgets('unconfirmed $phase hides technical cloud identifiers', (
      tester,
    ) async {
      final controller = await _controller();
      await _frame(
        tester,
        SingleChildScrollView(
          child: CloudMachineCard(
            machine: _machine(
              phase: phase,
              instanceId: '',
              selectedZone: 'ap-guangzhou-7',
              error: phase == CloudMachinePhase.unknown ? '创建结果尚未确认。' : '',
            ),
            controller: controller,
          ),
        ),
        settle: phase != CloudMachinePhase.creating,
      );
      expect(find.textContaining('ap-guangzhou'), findsNothing);
      expect(find.text('测试地域'), findsNothing);
      expect(find.textContaining('实例可用区'), findsNothing);
      expect(find.textContaining('尚未取得实例 ID'), findsNothing);
      expect(find.textContaining('公网地址：等待云端返回'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

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
  testWidgets(
    'failed preparation offers explicit retry while unknown purchase does not',
    (tester) async {
      final controller = await _controller();
      await _frame(
        tester,
        SingleChildScrollView(
          child: CloudMachineCard(
            machine: _machine(
              phase: CloudMachinePhase.createFailed,
              instanceId: '',
              createSubmitted: false,
              error: '共享网络创建结果待核实。',
            ),
            controller: controller,
          ),
        ),
      );
      expect(find.text('查询云端状态'), findsNothing);
      expect(find.text('释放云服务器'), findsNothing);
      await _tap(tester, find.text('重试准备并创建'));
      expect(controller.retries, ['ui-operation']);
      expect(controller.creates, 0);
    },
  );

  testWidgets(
    'created cloud offers built-in-key deployment at narrow large text',
    (tester) async {
      final controller = await _controller();
      var deploys = 0;
      await _frame(
        tester,
        SingleChildScrollView(
          child: CloudMachineCard(
            machine: _machine(),
            controller: controller,
            onDeploy: () async => deploys++,
          ),
        ),
        width: 390,
        textScale: 2,
      );
      expect(find.textContaining('使用已保存的 SSH 密钥部署'), findsOneWidget);
      expect(find.text('部署 Sisters'), findsOneWidget);
      await _tap(
        tester,
        find.byKey(const ValueKey('cloud-deploy-ui-operation')),
      );
      expect(deploys, 1);
      expect(controller.creates, 0);
      expect(controller.releases, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('deployment start disables deploy and release until it settles', (
    tester,
  ) async {
    final controller = await _controller();
    final gate = Completer<void>();
    var deploys = 0;
    await _frame(
      tester,
      SingleChildScrollView(
        child: CloudMachineCard(
          machine: _machine(),
          controller: controller,
          onDeploy: () async {
            deploys++;
            await gate.future;
          },
        ),
      ),
    );
    await _tap(tester, find.text('部署 Sisters'));
    expect(deploys, 1);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('cloud-deploy-ui-operation')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '释放云服务器'))
          .onPressed,
      isNull,
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const ValueKey('cloud-deploy-ui-operation')),
          )
          .onPressed,
      isNotNull,
    );
    expect(controller.releases, isEmpty);
  });

  testWidgets(
    'active cloud deployment runs without fingerprint controls and blocks release',
    (tester) async {
      final controller = await _controller();
      controller.deploymentLocked = true;
      await _frame(
        tester,
        SingleChildScrollView(
          child: CloudMachineCard(
            machine: _machine(),
            controller: controller,
            sistersLinked: true,
            sistersProgress: const Text('正在验证服务器身份'),
            onDeploy: () async =>
                fail('active deployment must not start again'),
          ),
        ),
        width: 390,
        textScale: 2,
      );
      expect(find.text('正在验证服务器身份'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('cloud-deploy-ui-operation')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '释放云服务器'),
            )
            .onPressed,
        isNull,
      );
      expect(find.text('核对 SSH 指纹'), findsNothing);
      expect(find.text('取消部署'), findsNothing);
      expect(controller.releases, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  for (final layout in [(600.0, 1.0, 2), (390.0, 1.0, 1), (600.0, 2.0, 1)]) {
    testWidgets(
      'cloud actions align at width ${layout.$1} and scale ${layout.$2}',
      (tester) async {
        final controller = await _controller();
        var removals = 0;
        await _frame(
          tester,
          SingleChildScrollView(
            child: IntrinsicHeight(
              child: CloudMachineCard(
                machine: _machine(),
                controller: controller,
                sistersLinked: true,
                sistersReady: true,
                onDeploy: () async {},
                onRemoveConnection: () async => removals++,
              ),
            ),
          ),
          width: layout.$1,
          textScale: layout.$2,
        );
        final actions = [
          for (final name in [
            'deploy',
            'refresh',
            'release',
            'remove-connection',
          ])
            tester.getRect(find.byKey(ValueKey('cloud-$name-ui-operation'))),
        ];
        for (final rect in actions) {
          expect(rect.size, actions.first.size);
          expect(rect.height, greaterThanOrEqualTo(48));
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(layout.$1));
        }
        if (layout.$3 == 2) {
          expect(actions[0].top, actions[1].top);
          expect(actions[2].top, actions[3].top);
          expect(actions[0].left, actions[2].left);
          expect(actions[1].left, actions[3].left);
          expect(actions[1].left - actions[0].right, closeTo(10, .01));
          expect(actions[2].top - actions[0].bottom, closeTo(10, .01));
        } else {
          for (var i = 1; i < actions.length; i++) {
            expect(actions[i].left, actions[0].left);
            expect(actions[i].top - actions[i - 1].bottom, closeTo(10, .01));
          }
        }
        await _tap(
          tester,
          find.byKey(const ValueKey('cloud-remove-connection-ui-operation')),
        );
        expect(removals, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'linked installed node offers redeploy without claiming pending deployment',
    (tester) async {
      final controller = await _controller();
      var deploys = 0;
      await _frame(
        tester,
        SingleChildScrollView(
          child: CloudMachineCard(
            machine: _machine(),
            controller: controller,
            sistersLinked: true,
            sistersReady: true,
            onDeploy: () async => deploys++,
          ),
        ),
      );
      expect(find.text('已创建 · Sisters 已部署'), findsOneWidget);
      expect(find.text('已创建 · 待部署'), findsNothing);
      expect(find.textContaining('查看连接状态并分发任务'), findsOneWidget);
      await _tap(tester, find.text('重新部署 Sisters'));
      expect(deploys, 1);
      expect(controller.creates, 0);
    },
  );

  testWidgets(
    'cloud actions reflow when text scaling changes with an odd final row',
    (tester) async {
      final controller = await _controller();
      await _frame(
        tester,
        SingleChildScrollView(
          child: IntrinsicHeight(
            child: CloudMachineCard(
              machine: _machine(),
              controller: controller,
              onDeploy: () async {},
            ),
          ),
        ),
        width: 600,
      );
      Rect action(String name) =>
          tester.getRect(find.byKey(ValueKey('cloud-$name-ui-operation')));
      expect(action('deploy').top, action('refresh').top);
      expect(action('release').left, action('deploy').left);
      expect(action('release').size, action('deploy').size);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      await tester.pumpAndSettle();
      expect(action('deploy').left, action('refresh').left);
      expect(action('release').left, action('deploy').left);
      expect(action('refresh').top, greaterThan(action('deploy').bottom));
      expect(action('release').size, action('deploy').size);
      await _tap(
        tester,
        find.byKey(const ValueKey('cloud-refresh-ui-operation')),
      );
      expect(controller.refreshes, ['ui-operation']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unconfirmed server without available actions keeps an intact card',
    (tester) async {
      final controller = await _controller();
      await _frame(
        tester,
        SingleChildScrollView(
          child: IntrinsicHeight(
            child: CloudMachineCard(
              machine: _machine(
                phase: CloudMachinePhase.unknown,
                instanceId: '',
                createSubmitted: false,
              ),
              controller: controller,
            ),
          ),
        ),
        width: 390,
      );
      expect(find.byType(ButtonStyleButton), findsNothing);
      expect(find.text('创建结果待核实'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('linked failed node keeps retry entry with its error', (
    tester,
  ) async {
    final controller = await _controller();
    var deploys = 0;
    await _frame(
      tester,
      SingleChildScrollView(
        child: CloudMachineCard(
          machine: _machine(),
          controller: controller,
          sistersLinked: true,
          sistersProgress: const Text('部署失败，请检查远端服务运行条件。'),
          onDeploy: () async => deploys++,
        ),
      ),
    );
    expect(find.textContaining('部署失败'), findsOneWidget);
    await _tap(tester, find.text('重试部署 Sisters'));
    expect(deploys, 1);
    expect(controller.creates, 0);
  });

  for (final phase in [CloudMachinePhase.unknown, CloudMachinePhase.released]) {
    testWidgets('$phase never offers SSH deployment', (tester) async {
      final controller = await _controller();
      await _frame(
        tester,
        SingleChildScrollView(
          child: CloudMachineCard(
            machine: _machine(phase: phase),
            controller: controller,
            onDeploy: () async =>
                fail('unconfirmed or released must not deploy'),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey('cloud-deploy-ui-operation')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
