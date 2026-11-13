import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';

import 'tencent_network_controller_test.dart' show NetworkHarness;

const preferred = 'ap-guangzhou-6';
const alternative = 'ap-guangzhou-7';
const third = 'ap-guangzhou-8';

class ZoneHarness extends NetworkHarness {
  final unavailable = <String>{};
  Object? zones = <String>[alternative, third];
  bool failQuery = false;
  bool failRefusalSave = false;
  bool failSelectionSave = false;
  bool failPurchaseIntentSave = false;
  String? lostPurchaseZone;
  String? lostSubnetZone;
  Map<String, dynamic>? createResponse;
  final purchaseSnapshots = <Map<String, dynamic>>[];

  List<Map<String, dynamic>> requests(String action) => helper.requests
      .where((request) => request['action'] == action)
      .map((request) => Map<String, dynamic>.from(request['cloud'] as Map))
      .toList();
  List<Map<String, dynamic>> get purchases => requests('tencent_create');
  List<String> get purchasedZones => [
    for (final purchase in purchases)
      purchase['template']['runInstances']['Placement']['Zone'] as String,
  ];

  @override
  String subnetId(String zone) => 'subnet-zone${zone.split('-').last}';

  @override
  String cidr(String zone) => '10.8.${int.parse(zone.split('-').last)}.0/24';

  @override
  Future<void> init() async {
    await super.init();
    final delegate = helper.handler!;
    helper.handler = (request, progress) async {
      final action = request['action'];
      if (action == 'tencent_zones') {
        final job = (saved['jobs'] as List).single as Map;
        expectSync(job['createSubmitted'], isFalse);
        expectSync(job['unavailableZones'], contains(preferred));
        if (failQuery) throw const UserError('private-query-response');
        if (failSelectionSave) {
          store.failWrite.add(CloudController.workspaceKey);
        }
        return {'zones': zones};
      }
      if (action == 'tencent_create') {
        final cloud = request['cloud'] as Map;
        final zone =
            cloud['template']['runInstances']['Placement']['Zone'] as String;
        final job = Map<String, dynamic>.from(
          (saved['jobs'] as List).single as Map,
        );
        purchaseSnapshots.add(job);
        expectSync(job['createSubmitted'], isTrue);
        expectSync(job['clientToken'], cloud['client_token']);
        expectSync(job['selectedZone'], zone);
        expectSync(job['subnetId'], subnetId(zone));
        expectSync(cloud['subnet_id'], subnetId(zone));
        expectSync(job['template']['tencent'], templates().first.tencent);
        final expected =
            jsonDecode(jsonEncode(templates().first.tencent)) as Map;
        expected['runInstances']['Placement']['Zone'] = zone;
        expectSync(cloud['template'], expected);
        if (zone == lostPurchaseZone) {
          throw const UserError('private-purchase-response');
        }
        if (createResponse != null) return createResponse!;
        if (unavailable.contains(zone)) {
          if (failRefusalSave) {
            store.failWrite.add(CloudController.workspaceKey);
          }
          return {'state': 'unavailable'};
        }
      }
      if (action == 'tencent_prepare' && failPurchaseIntentSave) {
        final zone =
            (request['cloud']
                as Map)['template']['runInstances']['Placement']['Zone'];
        if (zone != preferred) {
          store.failWrite.add(CloudController.workspaceKey);
        }
      }
      if (action == 'tencent_network_create' && lostSubnetZone != null) {
        final cloud = request['cloud'] as Map;
        if (cloud['network_kind'] == 'subnet' &&
            cloud['template']['runInstances']['Placement']['Zone'] ==
                lostSubnetZone) {
          lostKind = 'subnet';
          lostResourceExists = false;
        }
      }
      return delegate(request, progress);
    };
  }
}

void main() {
  final active = <ZoneHarness>[];
  void zoneTest(String description, Future<void> Function(WidgetTester) body) {
    testWidgets(description, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final h in active) {
          h.dispose();
        }
        active.clear();
      }
    });
  }

  Future<ZoneHarness> harness() async {
    final h = ZoneHarness();
    await h.init();
    active.add(h);
    return h;
  }

  zoneTest('preferred succeeds without alternative inventory lookup', (
    tester,
  ) async {
    final h = await harness();
    await h.start();
    await tester.pump();
    expect(h.purchasedZones, [preferred]);
    expect(h.requests('tencent_zones'), isEmpty);
    expect(h.controller.jobs.single.effectiveZone, preferred);
    expect(h.controller.jobs.single.instanceId, 'ins-test1');
  });

  zoneTest('fallback changes only zone and subnet with durable fresh tokens', (
    tester,
  ) async {
    final h = await harness();
    h.unavailable.addAll([preferred, alternative]);
    h.zones = [third, preferred, alternative, alternative, third];
    final initial = await h.start();
    await tester.pump();
    expect(h.purchasedZones, [preferred, alternative, third]);
    expect(h.purchases.map((p) => p['client_token']).toSet().length, 3);
    expect(h.requests('tencent_zones').length, 1);
    final job = h.controller.jobs.single;
    expect(job.id, initial.id);
    expect(job.effectiveZone, third);
    expect(job.instanceId, 'ins-test1');
    expect(job.unavailableZones, [preferred, alternative]);
    expect(job.template.tencent, h.templates().first.tencent);
    expect(h.creates('vpc'), 1);
    expect(h.creates('subnet'), 3);
    expect(h.purchaseSnapshots.map((s) => s['unavailableZones']), [
      [],
      [preferred],
      [preferred, alternative],
    ]);
    await h.restart();
    expect(h.controller.jobs.single.selectedZone, third);
    expect(h.controller.jobs.single.unavailableZones, [preferred, alternative]);
    await h.controller.refreshTencentMachine(initial.id);
    expect(h.purchases.length, 3);
    expect(
      h.requests('tencent_describe').last['client_token'],
      job.clientToken,
    );
  });

  zoneTest(
    'all zones unavailable stops once each and retry never rebuys them',
    (tester) async {
      final h = await harness();
      h.unavailable.addAll([preferred, alternative, third]);
      final job = await h.start();
      await tester.pump();
      expect(h.purchasedZones, [preferred, alternative, third]);
      expect(h.controller.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.controller.jobs.single.createSubmitted, isFalse);
      expect(h.controller.jobs.single.error, contains('相同规格'));
      await h.restart();
      await h.controller.retryTencentPreparation(job.id);
      await tester.pump();
      expect(h.purchases.length, 3);
      expect(h.controller.jobs.single.canRemove, isTrue);
    },
  );

  for (final value in <Object?>[
    [],
    [preferred],
    ['ap-shanghai-1'],
    ['ap-guangzhou-7\n'],
    [42],
    null,
    'ap-guangzhou-7',
  ]) {
    zoneTest('empty or invalid alternatives stop without purchase: $value', (
      tester,
    ) async {
      final h = await harness();
      h.unavailable.add(preferred);
      h.zones = value;
      await h.start();
      await tester.pump();
      expect(h.purchasedZones, [preferred]);
      expect(h.controller.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.controller.jobs.single.createSubmitted, isFalse);
      expect(h.controller.jobs.single.instanceId, isEmpty);
    });
  }

  zoneTest(
    'inventory permission failure can retry query without rebuying refusal',
    (tester) async {
      final h = await harness();
      h.unavailable.add(preferred);
      h.failQuery = true;
      final job = await h.start();
      await tester.pump();
      expect(h.purchasedZones, [preferred]);
      expect(h.controller.jobs.single.error, contains('查询'));
      expect(h.controller.jobs.single.error, isNot(contains('private-query')));
      h.failQuery = false;
      await h.controller.retryTencentPreparation(job.id);
      await tester.pump();
      expect(h.purchasedZones, [preferred, alternative]);
      expect(h.controller.jobs.single.instanceId, 'ins-test1');
    },
  );

  zoneTest('late timeout restarts with latest token and only recovers', (
    tester,
  ) async {
    final h = await harness();
    h.unavailable.add(preferred);
    h.lostPurchaseZone = alternative;
    final job = await h.start();
    await tester.pump();
    final token = h.purchases.last['client_token'];
    expect(h.purchasedZones, [preferred, alternative]);
    expect(h.controller.jobs.single.phase, CloudMachinePhase.unknown);
    expect(h.controller.jobs.single.createSubmitted, isTrue);
    expect(h.controller.jobs.single.error, isNot(contains('private-purchase')));
    await h.restart();
    h.instanceExists = false;
    await h.controller.refreshTencentMachine(job.id);
    expect(h.requests('tencent_recover').last['client_token'], token);
    expect(h.controller.jobs.single.phase, CloudMachinePhase.unknown);
    await expectLater(
      h.controller.retryTencentPreparation(job.id),
      throwsA(isA<UserError>()),
    );
    await expectLater(
      h.controller.removeMachine(job.id),
      throwsA(isA<UserError>()),
    );
    h.instanceExists = true;
    await h.controller.refreshTencentMachine(job.id);
    expect(h.controller.jobs.single.phase, CloudMachinePhase.created);
    expect(h.purchases.length, 2);
    expect(h.controller.jobs.single.effectiveZone, alternative);
  });

  for (final response in <Map<String, dynamic>>[
    {},
    {'state': 'unknown'},
    {'state': 'unavailable', 'instance_id': 'ins-test1'},
    {'state': 'unavailable', 'instance_id': 42},
  ]) {
    zoneTest('ambiguous create response never starts fallback: $response', (
      tester,
    ) async {
      final h = await harness();
      h.createResponse = response;
      await h.start();
      await tester.pump();
      expect(h.purchasedZones, [preferred]);
      expect(h.requests('tencent_zones'), isEmpty);
      expect(h.controller.jobs.single.phase, CloudMachinePhase.unknown);
      expect(h.controller.jobs.single.createSubmitted, isTrue);
    });
  }

  zoneTest(
    'refusal save failure halts and preserves last durable purchase token',
    (tester) async {
      final h = await harness();
      h.unavailable.add(preferred);
      h.failRefusalSave = true;
      final job = await h.start();
      await tester.pump();
      expect(h.purchasedZones, [preferred]);
      expect(h.requests('tencent_zones'), isEmpty);
      expect(h.controller.jobs.single.phase, CloudMachinePhase.unknown);
      final savedJob = (h.saved['jobs'] as List).single as Map;
      expect(savedJob['createSubmitted'], isTrue);
      expect(savedJob['unavailableZones'], isEmpty);
      h.store.failWrite.clear();
      await h.restart();
      await h.controller.refreshTencentMachine(job.id);
      expect(
        h.requests('tencent_recover').last['client_token'],
        h.purchases.single['client_token'],
      );
      expect(h.purchases.length, 1);
    },
  );

  for (final failure in ['selection', 'purchase intent']) {
    zoneTest('$failure persistence failure prevents alternate purchase', (
      tester,
    ) async {
      final h = await harness();
      h.unavailable.add(preferred);
      h.failSelectionSave = failure == 'selection';
      h.failPurchaseIntentSave = failure == 'purchase intent';
      await h.start();
      await tester.pump();
      expect(h.purchasedZones, [preferred]);
      expect(h.controller.jobs.single.createSubmitted, isFalse);
      expect(h.controller.jobs.single.phase, CloudMachinePhase.createFailed);
      h.store.failWrite.clear();
      await h.restart();
      expect(h.controller.jobs.single.createSubmitted, isFalse);
      expect(h.purchases.length, 1);
    });
  }

  zoneTest(
    'unknown fallback subnet stops subsequent purchases across restart',
    (tester) async {
      final h = await harness();
      h.unavailable.add(preferred);
      h.lostSubnetZone = alternative;
      final job = await h.start();
      await tester.pump();
      expect(h.purchasedZones, [preferred]);
      expect(h.controller.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.controller.jobs.single.createSubmitted, isFalse);
      expect(
        h.networks.singleWhere((r) => r['zone'] == alternative)['pending'],
        isTrue,
      );
      final subnetCreates = h.creates('subnet');
      await h.restart();
      await h.controller.retryTencentPreparation(job.id);
      await tester.pump();
      expect(h.purchases.length, 1);
      expect(h.creates('subnet'), subnetCreates);
      expect(h.controller.jobs.single.error, contains('共享网络'));
    },
  );
}
