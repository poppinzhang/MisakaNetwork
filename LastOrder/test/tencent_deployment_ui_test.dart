import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/cloud_ui.dart';
import 'package:last_order/src/dispatch_dialog.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/payments.dart';
import 'package:last_order/src/services.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';
import 'package:material_ui/material_ui.dart';

import 'tencent_deployment_test.dart'
    show DeployHarness, resourceId, fingerprint;

Future<void> openMachines(
  WidgetTester tester,
  DeployHarness h, {
  double width = 1360,
  double textScale = 1,
}) async {
  tester.view.physicalSize = Size(width, 1200);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(LastOrderApp(controller: h.controller));
  await tester.pumpAndSettle();
  await tester.tap(
    width >= 600 ? find.byTooltip('机器管理') : find.text('机器管理').first,
  );
  await tester.pumpAndSettle();
}

void expectUnifiedCard() {
  expect(find.byType(CloudMachineCard), findsOneWidget);
  expect(
    find.byKey(const ValueKey('machine-card-tencent-$resourceId')),
    findsNothing,
  );
  expect(find.text('测试云服务器'), findsOneWidget);
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> releaseThroughCard(WidgetTester tester) async {
  await tapVisible(tester, find.widgetWithText(OutlinedButton, '释放云服务器'));
  await tester.tap(find.text('确认释放并删除数据'));
  // The release-in-progress indicator deliberately keeps animating while the
  // cloud result is unknown, so do not pumpAndSettle at this point.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
    'existing cloud card deploys with stored key without fingerprint interaction',
    (tester) async {
      tester.view.physicalSize = const Size(1360, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = DeployHarness();
      await h.init();
      h.confirmation = true;
      try {
        await tester.pumpWidget(LastOrderApp(controller: h.controller));
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('机器管理'));
        await tester.pumpAndSettle();
        final deploy = find.byKey(const ValueKey('cloud-deploy-$resourceId'));
        expect(deploy, findsOneWidget);
        await tester.ensureVisible(deploy);
        await tester.tap(deploy);
        await tester.pumpAndSettle();
        expect(find.byType(MachineDialog), findsNothing);
        expect(find.text('核对 SSH 指纹'), findsNothing);
        expect(find.text('确认 SSH 主机指纹'), findsNothing);
        expect(find.text(fingerprint), findsNothing);
        expect(h.deployments.last['host_key_fingerprint'], fingerprint);
        expect(h.deployments.length, 2);
        expectUnifiedCard();
        expect(h.controller.tencentMachine(resourceId)!.canConnect, isTrue);
        expect(find.text('已创建 · Sisters 已部署'), findsOneWidget);
        expect(find.text('重新部署 Sisters'), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        h.controller.dispose();
      }
    },
  );

  testWidgets(
    'failed deployment and persisted error stay on the same cloud card',
    (tester) async {
      final h = DeployHarness();
      await h.init();
      h.failDeployment = true;
      try {
        await openMachines(tester, h, width: 390, textScale: 2);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('cloud-deploy-$resourceId')),
        );
        expectUnifiedCard();
        expect(find.text('部署失败'), findsOneWidget);
        expect(find.text('测试部署失败'), findsOneWidget);
        expect(find.text('重试部署 Sisters'), findsOneWidget);
        expect(find.text('192.0.2.20:20001'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await h.restart();
        await openMachines(tester, h);
        expectUnifiedCard();
        expect(find.text('部署失败'), findsOneWidget);
        expect(find.text('测试部署失败'), findsOneWidget);
        h.failDeployment = false;
        await tapVisible(
          tester,
          find.byKey(const ValueKey('cloud-deploy-$resourceId')),
        );
        expectUnifiedCard();
        expect(find.text('测试部署失败'), findsNothing);
        expect(find.text('在线'), findsOneWidget);
        expect(find.text('Sisters 0.4.0'), findsOneWidget);
        expect(find.text('并发上限 2'), findsOneWidget);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        h.controller.dispose();
      }
    },
  );

  testWidgets(
    'progress is inline and local removal stays disabled during deployment',
    (tester) async {
      final h = DeployHarness();
      await h.init();
      h.deploymentGate = Completer<void>();
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'deploy') {
          progress?.call(const DeploymentProgress(percent: 47, stage: '上传安装包'));
        }
        return delegate(request, progress);
      };
      try {
        await openMachines(tester, h);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('cloud-deploy-$resourceId')),
        );
        expectUnifiedCard();
        expect(find.text('上传安装包'), findsOneWidget);
        expect(find.text('47%'), findsOneWidget);
        expect(find.text('正在部署 Sisters'), findsOneWidget);
        final remove = find.byKey(
          const ValueKey('cloud-remove-connection-$resourceId'),
        );
        expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, '释放云服务器'),
              )
              .onPressed,
          isNull,
        );
        h.deploymentGate!.complete();
        await tester.pumpAndSettle();
        expectUnifiedCard();
        expect(find.text('47%'), findsNothing);
        expect(find.text('在线'), findsOneWidget);
      } finally {
        if (!h.deploymentGate!.isCompleted) h.deploymentGate!.complete();
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox.shrink());
        h.controller.dispose();
      }
    },
  );

  testWidgets(
    'connection errors and runtime details are visible in unified cloud card',
    (tester) async {
      final h = DeployHarness();
      await h.init();
      try {
        await h.controller.startTencentDeployment(resourceId);
        await openMachines(tester, h);
        await tester.pumpAndSettle();
        final id = h.controller.tencentMachine(resourceId)!.id;
        h.gateway.statusHandler = (_) async => AgentStatus(
          version: '0.4.0',
          biliVersion: '2.15.18',
          platform: 'linux/arm64',
          runtimeReady: false,
          maxConcurrency: 3,
        );
        await h.controller.refresh();
        await tester.pumpAndSettle();
        expectUnifiedCard();
        expect(find.text('linux/arm64'), findsOneWidget);
        expect(find.text('biliTickerBuy 2.15.18'), findsOneWidget);
        expect(find.text('并发上限 3'), findsOneWidget);
        expect(find.text('运行时尚未就绪，请重新部署完整安装包。'), findsOneWidget);
        h.gateway.statusHandler = (_) async => throw const UserError('模拟连接中断');
        await h.controller.refresh();
        await tester.pumpAndSettle();
        expectUnifiedCard();
        expect(find.text('连接异常'), findsOneWidget);
        expect(find.textContaining('模拟连接中断'), findsOneWidget);
        expect(h.controller.statuses[id], isNotNull);
        expect(find.text('在线'), findsNothing);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        h.controller.dispose();
      }
    },
  );

  testWidgets(
    'removing linked connection keeps cloud resource and deployment entry',
    (tester) async {
      final h = DeployHarness();
      await h.init();
      try {
        await h.controller.startTencentDeployment(resourceId);
        await openMachines(tester, h);
        await tester.pumpAndSettle();
        expectUnifiedCard();
        await tapVisible(
          tester,
          find.byKey(const ValueKey('cloud-remove-connection-$resourceId')),
        );
        expect(find.textContaining('服务器不会释放或停止计费'), findsOneWidget);
        await tester.tap(find.text('确认'));
        await tester.pumpAndSettle();
        expect(h.controller.state.machines, isEmpty);
        expect(h.controller.cloud.jobs, hasLength(1));
        expectUnifiedCard();
        expect(find.text('部署 Sisters'), findsOneWidget);
        expect(
          h.helper.requests.where((r) => r['action'] == 'tencent_release'),
          isEmpty,
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        h.controller.dispose();
      }
    },
  );

  testWidgets(
    'ordinary node stays visible and missing cloud record falls back to its connection card',
    (tester) async {
      final h = DeployHarness();
      await h.init();
      try {
        await h.controller.startTencentDeployment(resourceId);
        await openMachines(tester, h);
        await tester.pumpAndSettle();
        await h.controller.addMachine(
          Machine(
            id: 'manual-fixture',
            name: '手动添加节点',
            host: '192.0.2.30',
            caCert: 'ca',
            clientCert: 'cert',
            clientKey: 'key',
          ),
        );
        await tester.pumpAndSettle();
        expectUnifiedCard();
        expect(
          find.byKey(const ValueKey('machine-card-manual-fixture')),
          findsOneWidget,
        );
        h.cloudState = 'TERMINATED';
        await h.controller.cloud.refreshTencentMachine(resourceId);
        await h.controller.cloud.removeMachine(resourceId);
        await tester.pumpAndSettle();
        expect(find.byType(CloudMachineCard), findsNothing);
        expect(
          find.byKey(const ValueKey('machine-card-tencent-$resourceId')),
          findsOneWidget,
        );
        expect(
          find.byKey(const ValueKey('machine-card-manual-fixture')),
          findsOneWidget,
        );
        expect(find.text('移除连接'), findsNWidgets(2));
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        h.controller.dispose();
      }
    },
  );

  for (final absent in [false, true]) {
    testWidgets(
      'confirmed release ${absent ? 'absence' : 'termination'} removes its card without removing history or returning after restart',
      (tester) async {
        final h = DeployHarness();
        await h.init();
        var instanceAbsent = false;
        final delegate = h.helper.handler!;
        h.helper.handler = (request, progress) async {
          if (request['action'] == 'tencent_describe' && instanceAbsent) {
            return {'exists': false};
          }
          return delegate(request, progress);
        };
        try {
          await h.controller.startTencentDeployment(resourceId);
          await openMachines(tester, h);
          final machine = h.controller.tencentMachine(resourceId)!;
          if (absent) {
            await h.controller.addMachine(
              Machine(
                id: 'remaining-node',
                name: '保留的机器',
                host: '192.0.2.30',
                caCert: 'ca',
                clientCert: 'cert',
                clientKey: 'key',
              ),
            );
          }
          await h.controller.refresh();
          h.controller.state.accounts.add(
            Account(id: 'release-account', name: '测试账号', uid: '10001'),
          );
          h.controller.state.tasks.add(
            TicketTask(
              id: 'release-task',
              name: '已结束任务',
              accountId: 'release-account',
              dispatches: [
                TaskDispatch(
                  machineId: machine.id,
                  executionId: 'release-execution',
                  finished: true,
                ),
              ],
            ),
          );
          h.controller.statuses[machine.id] = AgentStatus(
            tasks: [
              TaskStatus(
                id: 'release-execution',
                state: TaskState.TASK_STATE_SUCCEEDED,
                payment: OrderPayment(
                  orderId: '12345',
                  paymentCodeUrl: 'weixin://wxpay/bizpayurl?pr=synthetic_1',
                ),
              ),
            ],
          );
          await h.store.save(h.controller.state);
          expect(
            collectOrderPayments(
              h.controller.state,
              h.controller.statuses,
            ).single.orderId,
            '12345',
          );

          await releaseThroughCard(tester);
          expectUnifiedCard();
          expect(
            h.controller.cloud.jobs.single.phase,
            CloudMachinePhase.releasing,
          );
          // An accepted request and a still-running instance are insufficient.
          await tester.pump(const Duration(seconds: 5));
          expectUnifiedCard();
          expect(find.text('删除本地记录'), findsNothing);
          if (absent) {
            instanceAbsent = true;
          } else {
            h.cloudState = 'TERMINATED';
          }
          await tester.pump(const Duration(seconds: 5));
          await tester.pumpAndSettle();
          expect(find.byType(CloudMachineCard), findsNothing);
          expect(
            find.byKey(ValueKey('machine-card-${machine.id}')),
            findsNothing,
          );
          expect(find.text('测试云服务器'), findsNothing);
          expect(
            h.controller.cloud.jobs.single.phase,
            CloudMachinePhase.released,
          );
          expect(h.controller.state.machines, contains(machine));
          expect(h.controller.state.tasks.single.id, 'release-task');
          expect(
            collectOrderPayments(
              h.controller.state,
              h.controller.statuses,
            ).single.paymentCode,
            'weixin://wxpay/bizpayurl?pr=synthetic_1',
          );
          if (absent) {
            expect(find.text('保留的机器'), findsOneWidget);
          } else {
            expect(find.text('还没有 Sisters'), findsOneWidget);
          }

          await tester.pumpWidget(const SizedBox.shrink());
          await h.restart();
          await openMachines(tester, h);
          expect(find.byType(CloudMachineCard), findsNothing);
          expect(
            find.byKey(ValueKey('machine-card-${machine.id}')),
            findsNothing,
          );
          expect(h.controller.state.tasks.single.id, 'release-task');
          expect(
            h.helper.requests.where((r) => r['action'] == 'tencent_release'),
            hasLength(1),
          );
          await tester.tap(find.byTooltip('网络概览'));
          await tester.pumpAndSettle();
          expect(find.text('共 ${absent ? 1 : 0} 台机器'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          h.controller.dispose();
        }
      },
    );
  }

  testWidgets('unknown disappearance keeps the cloud card until verified', (
    tester,
  ) async {
    final h = DeployHarness();
    await h.init();
    final delegate = h.helper.handler!;
    h.helper.handler = (request, progress) async {
      if (request['action'] == 'tencent_describe') return {'exists': false};
      return delegate(request, progress);
    };
    try {
      await openMachines(tester, h);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-refresh-$resourceId')),
      );
      expectUnifiedCard();
      expect(h.controller.cloud.jobs.single.phase, CloudMachinePhase.unknown);
      expect(find.text('创建结果待核实'), findsOneWidget);
      expect(
        h.helper.requests.where((r) => r['action'] == 'tencent_release'),
        isEmpty,
      );
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      h.controller.dispose();
    }
  });

  testWidgets(
    'open dispatch dialog disables releasing cloud node then removes confirmed release',
    (tester) async {
      final h = DeployHarness();
      await h.init();
      List<String>? selected;
      try {
        await h.controller.startTencentDeployment(resourceId);
        await openMachines(tester, h);
        await h.controller.addMachine(
          Machine(
            id: 'remaining-node',
            name: '保留的机器',
            host: '192.0.2.30',
            caCert: 'ca',
            clientCert: 'cert',
            clientKey: 'key',
          ),
        );
        await h.controller.refresh();
        final task = TicketTask(
          id: 'dispatch-after-release',
          name: '测试分发',
          accountId: 'test-account',
        );
        h.controller.state.tasks.add(task);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    selected = await showDialog<List<String>>(
                      context: context,
                      builder: (_) => DispatchDialog(
                        controller: h.controller,
                        task: task,
                        startDescription: '分发后立即开始',
                      ),
                    );
                  },
                  child: const Text('打开分发'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开分发'));
        await tester.pumpAndSettle();
        final cloudChoice = find.byKey(
          const ValueKey('dispatch-machine-tencent-$resourceId'),
        );
        final ordinaryChoice = find.byKey(
          const ValueKey('dispatch-machine-remaining-node'),
        );
        await tapVisible(tester, cloudChoice);
        await tapVisible(tester, ordinaryChoice);
        expect(find.text('提交到 2 台机器'), findsOneWidget);
        expect(tester.widget<CheckboxListTile>(cloudChoice).value, isTrue);

        await h.controller.cloud.requestTencentRelease(resourceId);
        await tester.pumpAndSettle();
        expect(cloudChoice, findsOneWidget);
        expect(tester.widget<CheckboxListTile>(cloudChoice).onChanged, isNull);
        expect(tester.widget<CheckboxListTile>(cloudChoice).value, isFalse);
        expect(tester.widget<CheckboxListTile>(ordinaryChoice).value, isTrue);
        expect(find.text('提交到 1 台机器'), findsOneWidget);

        h.cloudState = 'TERMINATED';
        await h.controller.cloud.refreshTencentMachine(resourceId);
        await tester.pumpAndSettle();
        expect(cloudChoice, findsNothing);
        expect(ordinaryChoice, findsOneWidget);
        expect(
          tester.widget<CheckboxListTile>(ordinaryChoice).onChanged,
          isNotNull,
        );
        await tester.tap(find.text('提交到 1 台机器'));
        await tester.pumpAndSettle();
        expect(selected, ['remaining-node']);
        expect(h.gateway.submitted, isEmpty);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        h.controller.dispose();
      }
    },
  );

  testWidgets(
    'release query failure preserves the card until refresh confirms',
    (tester) async {
      final h = DeployHarness();
      await h.init();
      var queryFails = false;
      final delegate = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'tencent_describe' && queryFails) {
          throw const UserError('模拟查询失败');
        }
        return delegate(request, progress);
      };
      try {
        await openMachines(tester, h);
        await releaseThroughCard(tester);
        queryFails = true;
        await tester.pump(const Duration(seconds: 5));
        await tester.pumpAndSettle();
        expectUnifiedCard();
        expect(
          h.controller.cloud.jobs.single.phase,
          CloudMachinePhase.releaseFailed,
        );
        expect(find.text('释放待核实'), findsOneWidget);
        queryFails = false;
        h.cloudState = 'TERMINATED';
        await tapVisible(
          tester,
          find.byKey(const ValueKey('cloud-refresh-$resourceId')),
        );
        expect(find.byType(CloudMachineCard), findsNothing);
        expect(find.text('还没有 Sisters'), findsOneWidget);
        expect(
          h.helper.requests.where((r) => r['action'] == 'tencent_release'),
          hasLength(1),
        );
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        h.controller.dispose();
      }
    },
  );
}
