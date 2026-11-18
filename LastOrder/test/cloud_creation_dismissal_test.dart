import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';

import 'tencent_controller_test.dart' show Harness;
import 'tencent_release_test.dart' show reopenCloud;

Future<Harness> lostCreation(WidgetTester tester) async {
  final h = Harness();
  await h.init();
  h.failAction = 'tencent_create';
  await h.create();
  await tester.pump();
  expect(h.c.visibleJobs.single.canDismissCreation, isTrue);
  h.failAction = null;
  h.exists = false;
  return h;
}

void main() {
  testWidgets('dismissing only changes local visibility across restarts', (
    tester,
  ) async {
    final h = await lostCreation(tester);
    try {
      final job = h.c.jobs.single;
      final callsBefore = h.helper.requests.length;
      await h.c.dismissCloudCreation(job.id);
      expect(h.c.visibleJobs, isEmpty);
      final retained = h.c.jobs.single;
      expect(retained.phase, CloudMachinePhase.unknown);
      expect(retained.clientToken, job.clientToken);
      expect(retained.releaseConfirmed, isFalse);
      await reopenCloud(h);
      expect(h.c.visibleJobs, isEmpty);
      await expectLater(
        h.c.removeCredential(job.provider),
        throwsA(isA<UserError>()),
      );
      await expectLater(h.c.removeMachine(job.id), throwsA(isA<UserError>()));
      await h.c.restoreDismissedCreations(CloudProvider.aliyun);
      expect(h.c.visibleJobs, isEmpty);
      await h.c.restoreDismissedCreations(job.provider);
      await reopenCloud(h);
      expect(h.c.visibleJobs.single.id, job.id);
      expect(h.helper.requests, hasLength(callsBefore));
    } finally {
      h.c.dispose();
    }
  });

  testWidgets('a local write failure preserves the previous visibility', (
    tester,
  ) async {
    final h = await lostCreation(tester);
    try {
      final job = h.c.jobs.single;
      final failures = h.store.failWrite;
      failures.add(CloudController.workspaceKey);
      await expectLater(
        h.c.dismissCloudCreation(job.id),
        throwsA(isA<UserError>()),
      );
      expect(h.c.visibleJobs.single.id, job.id);
      failures.clear();
      await h.c.dismissCloudCreation(job.id);
      failures.add(CloudController.workspaceKey);
      await expectLater(
        h.c.restoreDismissedCreations(job.provider),
        throwsA(isA<UserError>()),
      );
      expect(h.c.visibleJobs, isEmpty);
    } finally {
      h.c.dispose();
    }
  });

  testWidgets('a late instance reappears after reopening a dismissed card', (
    tester,
  ) async {
    final h = await lostCreation(tester);
    try {
      final job = h.c.jobs.single;
      await h.c.dismissCloudCreation(job.id);
      await reopenCloud(h);
      await tester.pump(const Duration(seconds: 5));
      expect(h.c.visibleJobs, isEmpty);
      h.exists = true;
      await tester.pump(const Duration(seconds: 5));
      expect(h.c.visibleJobs.single.id, job.id);
      expect(h.c.visibleJobs.single.phase, CloudMachinePhase.created);
      expect(h.c.visibleJobs.single.creationDismissed, isFalse);
      final purchases = h.helper.requests.where(
        (r) => r['action'] == 'tencent_create',
      );
      expect(purchases, hasLength(1));
    } finally {
      h.c.dispose();
    }
  });

  testWidgets('in-flight recovery respects the latest visibility choice', (
    tester,
  ) async {
    final h = await lostCreation(tester);
    try {
      final job = h.c.jobs.single;
      final handler = h.helper.handler!;
      var response = Completer<void>();
      h.helper.handler = (request, progress) async {
        expect(request['action'], 'tencent_recover');
        await response.future;
        return handler(request, progress);
      };

      var query = h.c.refreshCloudMachine(job.id);
      await h.c.dismissCloudCreation(job.id);
      response.complete();
      await query;
      expect(h.c.visibleJobs, isEmpty);

      response = Completer<void>();
      query = h.c.refreshCloudMachine(job.id);
      await h.c.restoreDismissedCreations(job.provider);
      response.complete();
      await query;
      expect(h.c.visibleJobs.single.id, job.id);

      response = Completer<void>();
      h.exists = true;
      query = h.c.refreshCloudMachine(job.id);
      await h.c.dismissCloudCreation(job.id);
      response.complete();
      await query;
      expect(h.c.visibleJobs.single.instanceId, 'ins-test1234');
      expect(h.c.visibleJobs.single.phase, CloudMachinePhase.created);
      await expectLater(
        h.c.dismissCloudCreation(job.id),
        throwsA(isA<UserError>()),
      );
      await reopenCloud(h);
      expect(h.c.visibleJobs.single.instanceId, 'ins-test1234');
    } finally {
      h.c.dispose();
    }
  });

  testWidgets('a known resource or release intent keeps its card visible', (
    tester,
  ) async {
    final h = await lostCreation(tester);
    try {
      final hidden = h.c.jobs.single.copyWith(creationDismissed: true);
      for (final job in [
        hidden.copyWith(instanceId: 'ins-test'),
        hidden.copyWith(eipId: 'eip-test'),
        hidden.copyWith(releaseSubmitted: true),
        hidden.copyWith(phase: CloudMachinePhase.creating),
        hidden.copyWith(createSubmitted: false),
      ]) {
        expect(job.canDismissCreation, isFalse);
        expect(job.creationDismissed, isFalse);
      }
    } finally {
      h.c.dispose();
    }
  });
}
