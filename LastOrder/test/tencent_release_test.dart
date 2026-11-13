import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/generated/misaka/v1/sisters.pb.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/payments.dart';

import 'tencent_controller_test.dart' show Harness;
import 'tencent_deployment_test.dart' show DeployHarness, resourceId;

Future<Harness> runningCloud(WidgetTester tester) async {
  final h = Harness();
  await h.init();
  addTearDown(() {
    if (!h.disposed) h.c.dispose();
  });
  await h.create();
  await tester.pump();
  await h.c.refreshTencentMachine(h.c.jobs.single.id);
  expect(h.c.jobs.single.phase, CloudMachinePhase.created);
  return h;
}

Future<void> reopenCloud(Harness h) async {
  h.c.dispose();
  h.c = h.controllerFor(h.store);
  await h.c.initialize();
  expect(h.c.initialized, isTrue);
}

int calls(Harness h, String action) =>
    h.helper.requests.where((request) => request['action'] == action).length;

Machine linkedMachine() => Machine(
  id: 'tencent-$resourceId',
  name: '测试云服务器',
  host: '192.0.2.20',
  caCert: 'test-ca',
  clientCert: 'test-client-cert',
  clientKey: 'test-client-key',
  deploymentUsername: 'ubuntu',
);

Future<DeployHarness> linkedCloud({List<Machine>? machines}) async {
  final h = DeployHarness();
  h.store.state = SavedState(machines: machines ?? [linkedMachine()]);
  await h.init();
  addTearDown(() => h.controller.dispose());
  return h;
}

void main() {
  for (final absent in [false, true]) {
    testWidgets(
      'release remains visible until ${absent ? 'exact absence' : 'TERMINATED'} is confirmed and stays hidden after restart',
      (tester) async {
        final h = await runningCloud(tester);
        final id = h.c.jobs.single.id;
        await h.c.requestTencentRelease(id);
        await tester.pump();
        expect(h.c.visibleJobs.single.phase, CloudMachinePhase.releasing);
        expect(calls(h, 'tencent_release'), 1);

        // An accepted request is not completion; a running instance stays.
        await tester.pump(const Duration(seconds: 5));
        expect(h.c.visibleJobs.single.phase, CloudMachinePhase.releasing);
        h.exists = !absent;
        h.state = 'TERMINATED';
        await tester.pump(const Duration(seconds: 5));
        expect(h.c.visibleJobs, isEmpty);
        expect(h.c.jobs.single.releaseConfirmed, isTrue);
        expect(h.c.jobs.single.instanceId, 'ins-test1234');

        final described = calls(h, 'tencent_describe');
        await reopenCloud(h);
        expect(h.c.visibleJobs, isEmpty);
        expect(h.c.jobs.single.releaseConfirmed, isTrue);
        await tester.pump(const Duration(seconds: 30));
        expect(calls(h, 'tencent_describe'), described);
        expect(calls(h, 'tencent_release'), 1);
      },
    );
  }

  testWidgets('absence before a release does not hide an unknown result', (
    tester,
  ) async {
    final h = await runningCloud(tester);
    h.exists = false;
    await h.c.refreshTencentMachine(h.c.jobs.single.id);
    expect(h.c.visibleJobs.single.phase, CloudMachinePhase.unknown);
    expect(h.c.jobs.single.releaseConfirmed, isFalse);
    expect(calls(h, 'tencent_release'), 0);
  });

  testWidgets('failed release response keeps card until a successful query', (
    tester,
  ) async {
    final h = await runningCloud(tester);
    final id = h.c.jobs.single.id;
    h.failAction = 'tencent_release';
    await h.c.requestTencentRelease(id);
    await tester.pump();
    expect(h.c.visibleJobs.single.phase, CloudMachinePhase.releaseFailed);
    h.failAction = 'tencent_describe';
    await h.c.refreshTencentMachine(id);
    expect(h.c.visibleJobs.single.phase, CloudMachinePhase.releaseFailed);
    h.failAction = null;
    h.exists = false;
    await h.c.refreshTencentMachine(id);
    expect(h.c.visibleJobs, isEmpty);
    expect(h.c.jobs.single.releaseConfirmed, isTrue);
    expect(calls(h, 'tencent_release'), 1);
  });

  for (final restart in [false, true]) {
    testWidgets(
      'release confirmation write failure stays visible and recovers ${restart ? 'after restart' : 'on refresh'}',
      (tester) async {
        final h = await runningCloud(tester);
        final id = h.c.jobs.single.id;
        await h.c.requestTencentRelease(id);
        await tester.pump();
        h.store.failWrite.add(CloudController.workspaceKey);
        h.state = 'TERMINATED';
        await h.c.refreshTencentMachine(id);
        expect(h.c.visibleJobs.single.phase, CloudMachinePhase.releaseFailed);
        expect(h.c.jobs.single.error, isNotEmpty);
        expect(h.c.jobs.single.releaseConfirmed, isFalse);
        final saved =
            jsonDecode(h.store.secrets[CloudController.workspaceKey]!) as Map;
        expect((saved['jobs'] as List).single['phase'], 'releasing');

        h.store.failWrite.clear();
        if (restart) {
          await reopenCloud(h);
          expect(h.c.visibleJobs.single.phase, CloudMachinePhase.releaseFailed);
          await tester.pump(const Duration(seconds: 5));
        } else {
          await h.c.refreshTencentMachine(id);
        }
        expect(h.c.visibleJobs, isEmpty);
        expect(h.c.jobs.single.releaseConfirmed, isTrue);
        expect(calls(h, 'tencent_release'), 1);
      },
    );
  }

  testWidgets(
    'released history does not block replacement of a lost SSH identity',
    (tester) async {
      final h = await runningCloud(tester);
      h.state = 'TERMINATED';
      await h.c.refreshTencentMachine(h.c.jobs.single.id);
      expect(h.c.visibleJobs, isEmpty);
      final generated = calls(h, 'generate_cloud_ssh_key');
      h.store.secrets.remove(CloudController.sshIdentityKey);
      await reopenCloud(h);
      expect(h.c.sshReady, isTrue);
      expect(h.c.keyError, isNull);
      expect(calls(h, 'generate_cloud_ssh_key'), generated + 1);
      expect(h.c.jobs.single.releaseConfirmed, isTrue);
    },
  );

  for (final unknown in [false, true]) {
    testWidgets(
      '${unknown ? 'unknown' : 'live'} resources still protect a lost SSH identity',
      (tester) async {
        final h = await runningCloud(tester);
        if (unknown) {
          h.exists = false;
          await h.c.refreshTencentMachine(h.c.jobs.single.id);
        }
        final generated = calls(h, 'generate_cloud_ssh_key');
        h.store.secrets.remove(CloudController.sshIdentityKey);
        await reopenCloud(h);
        expect(h.c.visibleJobs, hasLength(1));
        expect(h.c.sshReady, isFalse);
        expect(h.c.keyError, isNotEmpty);
        expect(calls(h, 'generate_cloud_ssh_key'), generated);
        // Restoring an unresolved resource schedules a read-only poll. Close
        // it before widget-test timer invariants run (before addTearDown).
        h.c.dispose();
        h.disposed = true;
      },
    );
  }

  testWidgets(
    'confirmation removes active node without dropping task and payment history',
    (tester) async {
      final machine = linkedMachine();
      final h = DeployHarness();
      h.store.state = SavedState(
        machines: [machine],
        accounts: [Account(id: 'account', name: '测试账号', uid: '123')],
        tasks: [
          TicketTask(
            id: 'task',
            name: '测试任务',
            accountId: 'account',
            dispatchedTo: [machine.id],
          ),
        ],
      );
      await h.init();
      addTearDown(() => h.controller.dispose());
      h.gateway.remoteTasks.add(
        TaskStatus(
          id: 'task',
          state: TaskState.TASK_STATE_SUCCEEDED,
          payment: OrderPayment(
            orderId: '123456',
            paymentCodeUrl: 'weixin://wxpay/bizpayurl?pr=TEST_ONLY',
          ),
        ),
      );
      final c = h.controller;
      await c.refresh();
      expect(c.currentMachines.map((m) => m.id), [machine.id]);
      expect(collectOrderPayments(c.state, c.statuses), hasLength(1));
      final dispatch = c.state.tasks.single.latestDispatch(machine.id)!;
      await c.cloud.requestTencentRelease(resourceId);
      await tester.pump();
      expect(c.currentMachines.map((m) => m.id), [machine.id]);
      expect(c.cloudMachineUsable(machine), isFalse);
      h.cloudState = 'TERMINATED';
      await c.cloud.refreshTencentMachine(resourceId);
      expect(c.currentMachines, isEmpty);
      expect(c.cloud.visibleJobs, isEmpty);
      expect(c.state.machines.single.id, machine.id);
      expect(h.store.state.machines.single.id, machine.id);
      expect(c.state.tasks.single.latestDispatch(machine.id), same(dispatch));
      expect(
        collectOrderPayments(c.state, c.statuses).single.orderId,
        '123456',
      );
      final polls = h.gateway.statusRequests.length;
      await c.refresh();
      expect(h.gateway.statusRequests.length, polls);

      await h.restart();
      expect(h.controller.currentMachines, isEmpty);
      expect(h.controller.state.machines.single.id, machine.id);
      expect(h.controller.state.tasks.single.dispatchedTo, [machine.id]);
    },
  );

  testWidgets(
    'released names and addresses can be reused for a new deployment',
    (tester) async {
      final h = await linkedCloud();
      final c = h.controller;
      final previous = c.state.machines.single;
      expect(
        () => c.requireUniqueMachineName(previous.name),
        throwsA(isA<UserError>()),
      );
      expect(
        () => c.requireUniqueDeploymentHost(previous.host),
        throwsA(isA<UserError>()),
      );
      h.cloudState = 'TERMINATED';
      await c.cloud.refreshTencentMachine(resourceId);
      final original = h.helper.handler!;
      h.helper.handler = (request, progress) async {
        if (request['action'] == 'deploy') {
          return {
            'ca_cert': 'new-ca',
            'client_cert': 'new-cert',
            'client_key': 'new-key',
          };
        }
        return original(request, progress);
      };
      await c.startDeployment(
        name: previous.name,
        host: previous.host,
        port: defaultSistersPort,
        request: {'username': 'test-user', 'password': 'test-password'},
      );
      await tester.pump();
      expect(c.currentMachines, hasLength(1));
      expect(c.currentMachines.single.id, isNot(previous.id));
      expect(c.currentMachines.single.canConnect, isTrue);
      expect(c.state.machines, hasLength(2));
      expect(c.tencentMachine(resourceId)?.id, previous.id);
    },
  );

  testWidgets(
    'ordinary and unconfirmed cloud nodes retain name and address protection',
    (tester) async {
      final ordinary = Machine(
        id: 'ordinary',
        name: '普通机器',
        host: '192.0.2.21',
        caCert: 'ca',
        clientCert: 'cert',
        clientKey: 'key',
      );
      final h = await linkedCloud(machines: [linkedMachine(), ordinary]);
      final original = h.helper.handler!;
      h.helper.handler = (request, progress) async =>
          request['action'] == 'tencent_describe'
          ? {'exists': false}
          : original(request, progress);
      await h.controller.cloud.refreshTencentMachine(resourceId);
      expect(
        h.controller.cloud.visibleJobs.single.phase,
        CloudMachinePhase.unknown,
      );
      expect(h.controller.currentMachines, hasLength(2));
      for (final machine in h.controller.state.machines) {
        expect(
          () => h.controller.requireUniqueMachineName(machine.name),
          throwsA(isA<UserError>()),
        );
        expect(
          () => h.controller.requireUniqueDeploymentHost(machine.host),
          throwsA(isA<UserError>()),
        );
      }
    },
  );
}
