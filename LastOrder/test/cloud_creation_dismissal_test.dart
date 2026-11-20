import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/cloud_ui.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

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
      await expectLater(
        h.c.removeCredential(job.provider),
        throwsA(isA<UserError>()),
      );
      await h.c.dismissCloudCreation(job.id);
      expect(h.c.visibleJobs, isEmpty);
      final retained = h.c.jobs.single;
      expect(retained.phase, CloudMachinePhase.unknown);
      expect(retained.clientToken, job.clientToken);
      expect(retained.releaseConfirmed, isFalse);
      await reopenCloud(h);
      expect(h.c.visibleJobs, isEmpty);
      await expectLater(h.c.removeMachine(job.id), throwsA(isA<UserError>()));
      await h.c.restoreDismissedCreations(CloudProvider.aliyun);
      expect(h.c.visibleJobs, isEmpty);
      await h.c.restoreDismissedCreations(job.provider);
      await reopenCloud(h);
      expect(h.c.visibleJobs.single.id, job.id);
      await expectLater(
        h.c.removeCredential(job.provider),
        throwsA(isA<UserError>()),
      );
      expect(h.helper.requests, hasLength(callsBefore));
    } finally {
      h.c.dispose();
    }
  });

  testWidgets(
    'removing credential succeeds once all provider cards are dismissed and clears them',
    (tester) async {
      final h = await lostCreation(tester);
      try {
        await h.c.saveCredential(
          CloudProvider.aliyun,
          accessKeyId: 'AliyunKey123',
          accessKeySecret: 'AliyunSecret123',
        );
        final job = h.c.jobs.single;
        final stored =
            jsonDecode(h.store.secrets[CloudController.workspaceKey]!)
                as Map<String, dynamic>;
        final released = job.copyWith(
          phase: CloudMachinePhase.released,
          instanceId: 'ins-released',
        );
        stored['jobs'] = [
          job.copyWith(creationDismissed: true).toJson(),
          CloudMachine(
            id: 'released-history',
            name: '已释放历史',
            provider: CloudProvider.tencent,
            template: released.template,
            phase: CloudMachinePhase.released,
            isReal: true,
            createSubmitted: true,
            instanceId: 'ins-released',
            region: released.region,
            credentialId: released.credentialId,
            clientToken: 'released-token',
            selectedZone: released.selectedZone,
          ).toJson(),
          CloudMachine(
            id: 'other-provider-dismissed',
            name: '阿里云已隐藏',
            provider: CloudProvider.aliyun,
            template: CloudTemplate.aliyun({
              'id': 'aliyun-ui',
              'name': '阿里云模板',
              'description': '测试',
              'cpu': 2,
              'memoryGb': 4,
              'diskGb': 40,
              'architecture': 'x64',
              'os': 'Ubuntu 24.04',
              'sshUsername': 'root',
              'regionLabel': '杭州',
              'region': 'cn-hangzhou',
              'runInstances': {
                'ZoneId': 'cn-hangzhou-h',
                'InstanceType': 'ecs.c7.large',
                'ImageId': 'ubuntu_24_04_x64',
                'SystemDisk': {'Category': 'cloud_essd', 'Size': 40},
                'InternetChargeType': 'PayByTraffic',
                'InternetMaxBandwidthOut': 5,
              },
            }),
            phase: CloudMachinePhase.unknown,
            isReal: true,
            createSubmitted: true,
            creationDismissed: true,
            region: 'cn-hangzhou',
            credentialId: 'AliyunKey123',
            clientToken: 'aliyun-token',
            selectedZone: 'cn-hangzhou-h',
          ).toJson(),
        ];
        h.store.secrets[CloudController.workspaceKey] = jsonEncode(stored);
        await reopenCloud(h);
        expect(h.c.visibleJobs, isEmpty);

        await h.c.removeCredential(CloudProvider.tencent);
        expect(h.c.credentialFor(CloudProvider.tencent), isNull);
        expect(
          h.c.jobs.map((item) => item.id).toList(),
          ['released-history', 'other-provider-dismissed'],
        );
        expect(h.c.credentialFor(CloudProvider.aliyun), isNotNull);

        final callsAfterRemoval = h.helper.requests.length;
        await tester.pump(const Duration(seconds: 10));
        expect(
          h.helper.requests
              .skip(callsAfterRemoval)
              .where((r) => '${r['action']}'.startsWith('tencent_')),
          isEmpty,
        );

        await reopenCloud(h);
        expect(h.c.credentialFor(CloudProvider.tencent), isNull);
        expect(
          h.c.jobs.map((item) => item.id).toList(),
          ['released-history', 'other-provider-dismissed'],
        );
        final callsAfterRestart = h.helper.requests.length;
        await tester.pump(const Duration(seconds: 10));
        expect(
          h.helper.requests
              .skip(callsAfterRestart)
              .where((r) => '${r['action']}'.startsWith('tencent_')),
          isEmpty,
        );

        // Binding a fresh credential works with no stale dismissed cards.
        await h.c.saveCredential(
          CloudProvider.tencent,
          accessKeyId: 'NewTencentKey',
          accessKeySecret: 'NewTencentSecret',
        );
        expect(h.c.credentialFor(CloudProvider.tencent)?.onlineVerified, isTrue);
        expect(
          h.c.jobs.where(
            (item) =>
                item.provider == CloudProvider.tencent &&
                item.creationDismissed,
          ),
          isEmpty,
        );
      } finally {
        h.c.dispose();
      }
    },
  );

  testWidgets(
    'another visible cloud machine still blocks credential removal',
    (tester) async {
      final h = await lostCreation(tester);
      try {
        final dismissed = h.c.jobs.single;
        await h.c.dismissCloudCreation(dismissed.id);
        h.failAction = 'tencent_create';
        final second = await h.create();
        await tester.pump();
        expect(h.c.visibleJobs.single.id, second.id);

        await expectLater(
          h.c.removeCredential(CloudProvider.tencent),
          throwsA(
            isA<UserError>().having(
              (e) => e.toString(),
              'blocked while visible machine remains',
              contains('未释放或待核实'),
            ),
          ),
        );
        expect(h.c.credentialFor(CloudProvider.tencent), isNotNull);
        expect(h.c.jobs, hasLength(2));

        await h.c.dismissCloudCreation(second.id);
        expect(h.c.visibleJobs, isEmpty);
        await h.c.removeCredential(CloudProvider.tencent);
        expect(h.c.credentialFor(CloudProvider.tencent), isNull);
        expect(h.c.jobs, isEmpty);
      } finally {
        h.c.dispose();
      }
    },
  );

  for (final querySucceeds in [true, false]) {
    testWidgets(
      'removing credential while dismissed recovery is in flight discards late result (success: $querySucceeds)',
      (tester) async {
        final h = await lostCreation(tester);
        try {
          final job = h.c.jobs.single;
          await h.c.dismissCloudCreation(job.id);
          final delegate = h.helper.handler!;
          final response = Completer<void>();
          h.helper.handler = (request, progress) async {
            if (request['action'] == 'tencent_recover') {
              await response.future;
              if (!querySucceeds) throw const UserError('transient failure');
            }
            return delegate(request, progress);
          };

          h.exists = true;
          final query = h.c.refreshCloudMachine(job.id);
          await h.c.removeCredential(CloudProvider.tencent);
          expect(h.c.credentialFor(CloudProvider.tencent), isNull);
          expect(h.c.jobs, isEmpty);

          response.complete();
          await query;
          expect(h.c.credentialFor(CloudProvider.tencent), isNull);
          expect(h.c.jobs, isEmpty);
          expect(h.c.visibleJobs, isEmpty);

          final calls = h.helper.requests.length;
          await tester.pump(const Duration(seconds: 10));
          expect(h.helper.requests, hasLength(calls));
        } finally {
          h.c.dispose();
        }
      },
    );
  }

  testWidgets(
    'write failure during credential removal preserves credential and dismissed card',
    (tester) async {
      final h = await lostCreation(tester);
      try {
        final job = h.c.jobs.single;
        await h.c.dismissCloudCreation(job.id);
        h.store.failWrite.add(CloudController.workspaceKey);
        await expectLater(
          h.c.removeCredential(CloudProvider.tencent),
          throwsA(isA<UserError>()),
        );
        expect(h.c.credentialFor(CloudProvider.tencent), isNotNull);
        expect(h.c.jobs.single.id, job.id);
        expect(h.c.jobs.single.creationDismissed, isTrue);
      } finally {
        h.c.dispose();
      }
    },
  );

  testWidgets(
    'old unverified credential with only dismissed cards allows replacing identity and clears stale dismissed cards',
    (tester) async {
      final h = await lostCreation(tester);
      try {
        final job = h.c.jobs.single;
        await h.c.dismissCloudCreation(job.id);
        final raw =
            jsonDecode(h.store.secrets[CloudController.workspaceKey]!)
                as Map<String, dynamic>;
        ((raw['credentials'] as List).single as Map).remove('onlineVerified');
        h.store.secrets[CloudController.workspaceKey] = jsonEncode(raw);
        await reopenCloud(h);
        expect(
          h.c.credentialFor(CloudProvider.tencent)!.onlineVerified,
          isFalse,
        );

        await h.c.saveCredential(
          CloudProvider.tencent,
          accessKeyId: 'ReplacementKey123',
          accessKeySecret: 'ReplacementSecret123',
        );
        expect(
          h.c.credentialFor(CloudProvider.tencent)!.onlineVerified,
          isTrue,
        );
        expect(h.c.jobs, isEmpty);
      } finally {
        h.c.dispose();
      }
    },
  );

  testWidgets(
    'credential page confirms clearing hidden cards when removing credential',
    (tester) async {
      final h = await lostCreation(tester);
      try {
        final job = h.c.jobs.single;
        await h.c.dismissCloudCreation(job.id);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: CloudCredentialForm(
                  controller: h.c,
                  provider: CloudProvider.tencent,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('（1）'), findsOneWidget);

        await tester.tap(find.text('移除凭证'));
        await tester.pumpAndSettle();
        expect(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.textContaining('1 条待核实卡片记录'),
          ),
          findsOneWidget,
        );

        await tester.tap(find.text('移除'));
        await tester.pumpAndSettle();
        expect(h.c.credentialFor(CloudProvider.tencent), isNull);
        expect(h.c.jobs, isEmpty);
        expect(find.text('已从本机移除凭证。'), findsOneWidget);
        expect(find.byKey(const ValueKey('cloud-key-id')), findsOneWidget);
        expect(find.textContaining('（1）'), findsNothing);
      } finally {
        h.c.dispose();
      }
    },
  );

  for (final provider in CloudProvider.values) {
    testWidgets(
      '${provider.name} allows removing credential after dismissing its only unresolved card',
      (tester) async {
        final h = Harness();
        await h.init();
        try {
          if (provider != CloudProvider.tencent) {
            await h.c.saveCredential(
              provider,
              accessKeyId: '${provider.name}-key',
              accessKeySecret: '${provider.name}-secret',
            );
          }
          final template = switch (provider) {
            CloudProvider.tencent => h.c.templatesFor(CloudProvider.tencent).single,
            CloudProvider.aliyun => CloudTemplate.aliyun({
              'id': 'aliyun-dismiss',
              'name': '阿里云模板',
              'description': '测试',
              'cpu': 2,
              'memoryGb': 4,
              'diskGb': 40,
              'architecture': 'x64',
              'os': 'Ubuntu 24.04',
              'sshUsername': 'root',
              'regionLabel': '杭州',
              'region': 'cn-hangzhou',
              'runInstances': {
                'ZoneId': 'cn-hangzhou-h',
                'InstanceType': 'ecs.c7.large',
                'ImageId': 'ubuntu_24_04_x64',
                'SystemDisk': {'Category': 'cloud_essd', 'Size': 40},
                'InternetChargeType': 'PayByTraffic',
                'InternetMaxBandwidthOut': 5,
              },
            }),
            CloudProvider.volcengine => CloudTemplate.volcengine({
              'id': 'volc-dismiss',
              'name': '火山模板',
              'description': '测试',
              'cpu': 2,
              'memoryGb': 4,
              'diskGb': 40,
              'architecture': 'x64',
              'os': 'Ubuntu 24.04',
              'sshUsername': 'root',
              'regionLabel': '北京',
              'region': 'cn-beijing',
              'runInstances': {
                'ZoneId': 'cn-beijing-a',
                'InstanceTypeId': 'ecs.g3i.large',
                'ImageId': 'image-fixture',
                'Volumes': [
                  {'VolumeType': 'ESSD_PL0', 'Size': 40},
                ],
                'EipAddress': {
                  'ISP': 'BGP',
                  'ChargeType': 'PayByTraffic',
                  'BandwidthMbps': 5,
                  'ReleaseWithInstance': true,
                },
              },
            }),
          };
          final region = template.configuration!['region'] as String;
          final stored =
              jsonDecode(h.store.secrets[CloudController.workspaceKey]!)
                  as Map<String, dynamic>;
          stored['jobs'] = [
            CloudMachine(
              id: 'unresolved-${provider.name}',
              name: '待核实-${provider.name}',
              provider: provider,
              template: template,
              phase: CloudMachinePhase.unknown,
              isReal: true,
              createSubmitted: true,
              region: region,
              credentialId: provider == CloudProvider.tencent
                  ? 'TestAccessId'
                  : '${provider.name}-key',
              clientToken: 'token-${provider.name}',
              selectedZone: template.zone,
            ).toJson(),
          ];
          h.store.secrets[CloudController.workspaceKey] = jsonEncode(stored);
          await reopenCloud(h);
          expect(h.c.visibleJobs.single.canDismissCreation, isTrue);

          await expectLater(
            h.c.removeCredential(provider),
            throwsA(isA<UserError>()),
          );
          await h.c.dismissCloudCreation('unresolved-${provider.name}');
          expect(h.c.visibleJobs, isEmpty);
          await h.c.removeCredential(provider);
          expect(h.c.credentialFor(provider), isNull);
          expect(
            h.c.jobs.where((job) => job.provider == provider),
            isEmpty,
          );
        } finally {
          h.c.dispose();
        }
      },
    );
  }

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
