import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/models.dart';

import 'volcengine_controller_test.dart' show VolcHarness, volcTemplateData;

const preferred = 'cn-beijing-a';
const alternative = 'cn-beijing-b';
const third = 'cn-beijing-c';

class ZoneHarness extends VolcHarness {
  final rejectedZones = <String>{};
  Object? zones = <String>[alternative, third];
  bool failQuery = false, failRefusalSave = false, failSelectionSave = false;
  bool failPurchaseIntentSave = false;
  String? lostPurchaseZone;
  String? failedSubnetZone;
  String? purchaseFailure;
  Map<String, dynamic>? createResponse;
  final purchaseSnapshots = <Map<String, dynamic>>[];
  Map<String, dynamic> get saved =>
      jsonDecode(store.secrets[CloudController.workspaceKey]!)
          as Map<String, dynamic>;
  List<Map<String, dynamic>> requests(String action) => helper.requests
      .where((request) => request['action'] == action)
      .map((request) => Map<String, dynamic>.from(request['volcengine'] as Map))
      .toList();
  List<Map<String, dynamic>> get purchases => requests('volcengine_create');
  List<String> get purchasedZones => [
    for (final p in purchases)
      p['template']['runInstances']['ZoneId'] as String,
  ];
  String subnetId(String zone) => 'subnet-zone${zone.split('-').last}';
  String cidr(String zone) =>
      '10.8.${zone.codeUnitAt(zone.length - 1) - 97}.0/24';

  @override
  Future<void> init() async {
    await super.init();
    final delegate = helper.handler!;
    helper.handler = (request, progress) async {
      final action = request['action'];
      if (action == 'volcengine_zones') {
        final job = saved['jobs'].single as Map;
        expectSync(job['createSubmitted'], false);
        expectSync(job['unavailableZones'], contains(preferred));
        expectSync(
          (request['volcengine'] as Map)['template'],
          volcTemplateData(),
        );
        if (failQuery) throw const UserError('private-inventory-error');
        if (failSelectionSave) {
          store.failWrite.add(CloudController.workspaceKey);
        }
        return {'zones': zones};
      }
      if (action == 'volcengine_network_lookup') {
        final input = request['volcengine'] as Map;
        final zone = input['template']['runInstances']['ZoneId'] as String;
        if (input['network_kind'] == 'subnet' && zone == failedSubnetZone) {
          throw const UserError('private-subnet-error');
        }
        return {
          'found': true,
          'vpc_id': 'vpc-fixture',
          'subnet_id': subnetId(zone),
          'subnet_cidr': cidr(zone),
        };
      }
      if (action == 'volcengine_prepare' && failPurchaseIntentSave) {
        final zone =
            (request['volcengine']
                as Map)['template']['runInstances']['ZoneId'];
        if (zone != preferred) {
          store.failWrite.add(CloudController.workspaceKey);
        }
      }
      if (action == 'volcengine_create') {
        final input = request['volcengine'] as Map;
        final zone = input['template']['runInstances']['ZoneId'] as String;
        final snapshot = Map<String, dynamic>.from(saved['jobs'].single as Map);
        purchaseSnapshots.add(snapshot);
        expectSync(snapshot['createSubmitted'], true);
        expectSync(snapshot['selectedZone'], zone);
        expectSync(snapshot['clientToken'], input['client_token']);
        expectSync(snapshot['subnetId'], subnetId(zone));
        expectSync(input['subnet_id'], subnetId(zone));
        expectSync(snapshot['template']['volcengine'], volcTemplateData());
        final expected = volcTemplateData();
        expected['runInstances']['ZoneId'] = zone;
        expectSync(input['template'], expected);
        if (zone == lostPurchaseZone || purchaseFailure != null) {
          throw UserError(purchaseFailure ?? 'private-purchase-response');
        }
        if (createResponse != null) return createResponse!;
        if (rejectedZones.contains(zone)) {
          if (failRefusalSave) {
            store.failWrite.add(CloudController.workspaceKey);
          }
          return {
            'state': 'unavailable',
            'instance_id': '',
            'request_id': 'fixture-refused',
          };
        }
      }
      return delegate(request, progress);
    };
  }

  Future<void> restart() async {
    c.dispose();
    c = controller(store);
    await c.initialize();
  }
}

void main() {
  final active = <ZoneHarness>[];
  void zoneTest(String name, Future<void> Function(WidgetTester) body) {
    testWidgets(name, (tester) async {
      try {
        await body(tester);
      } finally {
        for (final h in active) {
          h.c.dispose();
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

  zoneTest('preferred success does not query alternatives', (tester) async {
    final h = await harness();
    await h.create(tester, refresh: false);
    expect(h.purchasedZones, [preferred]);
    expect(h.calls('zones'), 0);
  });

  zoneTest(
    'explicit shortages change only zone and subnet with fresh durable tokens',
    (tester) async {
      final h = await harness();
      h.rejectedZones.addAll([preferred, alternative]);
      h.zones = [third, preferred, alternative, alternative, third];
      final id = await h.create(tester, refresh: false);
      expect(h.purchasedZones, [preferred, alternative, third]);
      expect(h.purchases.map((p) => p['client_token']).toSet(), hasLength(3));
      expect(h.calls('zones'), 1);
      expect(h.purchaseSnapshots.map((s) => s['unavailableZones']), [
        [],
        [preferred],
        [preferred, alternative],
      ]);
      expect(h.c.jobs.single.id, id);
      expect(h.c.jobs.single.effectiveZone, third);
      expect(h.c.jobs.single.template.volcengine, volcTemplateData());
      final token = h.c.jobs.single.clientToken;
      await h.restart();
      await h.c.refreshCloudMachine(id);
      expect(h.purchases, hasLength(3));
      expect(h.requests('volcengine_describe').last['client_token'], token);
      expect(h.c.jobs.single.unavailableZones, [preferred, alternative]);
    },
  );

  zoneTest(
    'all candidates rejected once remain exhausted across restart and retry',
    (tester) async {
      final h = await harness();
      h.rejectedZones.addAll([preferred, alternative, third]);
      final id = await h.create(tester, refresh: false);
      expect(h.purchasedZones, [preferred, alternative, third]);
      expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.c.jobs.single.createSubmitted, false);
      await h.restart();
      await h.c.retryCloudPreparation(id);
      await tester.pump();
      expect(h.purchases, hasLength(3));
      expect(h.c.jobs.single.canRemove, true);
    },
  );

  for (final value in <Object?>[
    [],
    [preferred],
    ['cn-shanghai-a'],
    ['cn-beijing-1'],
    ['cn-beijing-b\n'],
    [42],
    null,
    'cn-beijing-b',
    List.filled(101, alternative),
  ]) {
    zoneTest('empty or invalid candidates cannot buy: $value', (tester) async {
      final h = await harness();
      h.rejectedZones.add(preferred);
      h.zones = value;
      await h.create(tester, refresh: false);
      expect(h.purchasedZones, [preferred]);
      expect(h.c.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.c.jobs.single.createSubmitted, false);
    });
  }

  zoneTest(
    'inventory query failure retries reads without rebuying rejected zone',
    (tester) async {
      final h = await harness();
      h.rejectedZones.add(preferred);
      h.failQuery = true;
      final id = await h.create(tester, refresh: false);
      expect(h.c.jobs.single.error, contains('查询失败'));
      expect(h.c.jobs.single.error, isNot(contains('private-inventory')));
      h.failQuery = false;
      await h.c.retryCloudPreparation(id);
      await tester.pump();
      expect(h.purchasedZones, [preferred, alternative]);
    },
  );

  zoneTest(
    'lost alternate purchase response persists latest token and resumes read only',
    (tester) async {
      final h = await harness();
      h.rejectedZones.add(preferred);
      h.lostPurchaseZone = alternative;
      final id = await h.create(tester, refresh: false);
      expect(h.purchasedZones, [preferred, alternative]);
      expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
      final token = h.purchases.last['client_token'];
      await h.restart();
      h.exists = false;
      await h.c.refreshCloudMachine(id);
      expect(h.requests('volcengine_recover').last['client_token'], token);
      await expectLater(
        h.c.retryCloudPreparation(id),
        throwsA(isA<UserError>()),
      );
      await expectLater(h.c.removeMachine(id), throwsA(isA<UserError>()));
      h.exists = true;
      await h.c.refreshCloudMachine(id);
      expect(h.c.jobs.single.phase, CloudMachinePhase.created);
      expect(h.c.jobs.single.selectedZone, alternative);
      expect(h.purchases, hasLength(2));
      expect(h.calls('zones'), 1);
    },
  );

  for (final reason in [
    'timeout',
    'Insufficient.Balance',
    'QuotaExceeded',
    'AccessDenied',
    'InvalidParameter',
  ]) {
    zoneTest(
      'non-capacity error never queries zones or purchases again: $reason',
      (tester) async {
        final h = await harness();
        h.purchaseFailure = reason;
        await h.create(tester, refresh: false);
        expect(h.purchasedZones, [preferred]);
        expect(h.calls('zones'), 0);
        expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
        expect(h.c.jobs.single.createSubmitted, true);
      },
    );
  }

  for (final response in <Map<String, dynamic>>[
    {},
    {'state': 'unknown'},
    {'state': 'unavailable', 'instance_id': 'i-fixture'},
    {'state': 'unavailable', 'instance_id': 42},
    {'state': 'unavailable', 'eip_id': 'eip-fixture'},
  ]) {
    zoneTest('ambiguous response cannot authorize fallback: $response', (
      tester,
    ) async {
      final h = await harness();
      h.createResponse = response;
      await h.create(tester, refresh: false);
      expect(h.purchasedZones, [preferred]);
      expect(h.calls('zones'), 0);
      expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
      expect(h.c.jobs.single.createSubmitted, true);
    });
  }

  zoneTest(
    'refusal persistence failure retains durable purchase and prevents inventory query',
    (tester) async {
      final h = await harness();
      h.rejectedZones.add(preferred);
      h.failRefusalSave = true;
      final id = await h.create(tester, refresh: false);
      expect(h.purchasedZones, [preferred]);
      expect(h.calls('zones'), 0);
      expect(h.c.jobs.single.phase, CloudMachinePhase.unknown);
      expect(h.saved['jobs'].single['createSubmitted'], true);
      expect(h.saved['jobs'].single['unavailableZones'], isEmpty);
      h.store.failWrite.clear();
      await h.restart();
      await h.c.refreshCloudMachine(id);
      expect(h.purchases, hasLength(1));
    },
  );

  for (final stage in ['selection', 'purchase intent']) {
    zoneTest('save failure before $stage prevents alternate purchase', (
      tester,
    ) async {
      final h = await harness();
      h.rejectedZones.add(preferred);
      h.failSelectionSave = stage == 'selection';
      h.failPurchaseIntentSave = stage == 'purchase intent';
      await h.create(tester, refresh: false);
      expect(h.purchasedZones, [preferred]);
      expect(h.c.jobs.single.createSubmitted, false);
      h.store.failWrite.clear();
      await h.restart();
      expect(h.c.jobs.single.createSubmitted, false);
      expect(h.purchases, hasLength(1));
    });
  }

  zoneTest('unconfirmed alternate subnet halts before another purchase', (
    tester,
  ) async {
    final h = await harness();
    h.rejectedZones.add(preferred);
    h.failedSubnetZone = alternative;
    final id = await h.create(tester, refresh: false);
    expect(h.purchasedZones, [preferred]);
    expect(h.c.jobs.single.createSubmitted, false);
    await h.restart();
    await h.c.retryCloudPreparation(id);
    await tester.pump();
    expect(h.purchases, hasLength(1));
  });
}
