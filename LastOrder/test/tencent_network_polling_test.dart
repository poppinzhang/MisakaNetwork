import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';

import 'tencent_network_controller_test.dart' show NetworkHarness;

class PollingHarness extends NetworkHarness {
  final hidden = <String, int>{};
  final lookupsAfterCreate = <String, int>{};
  bool loseResponse = false;
  bool conflictingId = false;
  bool transientReadFailure = false;

  @override
  CloudController makeController() => CloudController(
    store: store,
    helper: helper,
    templateLoader: () async => templates(),
    preparationPollAttempts: 4,
    preparationPollInterval: const Duration(seconds: 1),
  );

  @override
  Future<void> init() async {
    await super.init();
    final delegate = helper.handler!;
    helper.handler = (request, progress) async {
      final action = request['action'];
      if (action == 'tencent_network_create') {
        final result = await delegate(request, progress);
        final kind = (request['cloud'] as Map)['network_kind'] as String;
        lookupsAfterCreate[kind] = 0;
        if (loseResponse) throw StateError('synthetic lost response');
        return {...result, 'state': 'unknown'};
      }
      if (action == 'tencent_network_lookup') {
        final cloud = request['cloud'] as Map;
        final kind = cloud['network_kind'] as String;
        if (lookupsAfterCreate.containsKey(kind)) {
          final count = lookupsAfterCreate.update(kind, (n) => n + 1);
          if (transientReadFailure && count == 1) {
            throw StateError('synthetic eventual consistency error');
          }
          if (!loseResponse) {
            expectSync(
              cloud[kind == 'vpc' ? 'vpc_id' : 'subnet_id'],
              kind == 'vpc'
                  ? vpc
                  : subnetId(
                      cloud['template']['runInstances']['Placement']['Zone']
                          as String,
                    ),
            );
          }
          if (count <= (hidden[kind] ?? 0)) return {'found': false};
          if (conflictingId) {
            final result = await delegate(request, progress);
            return {...result, 'vpc_id': 'vpc-conflict'};
          }
        }
      }
      return delegate(request, progress);
    };
  }
}

void main() {
  testWidgets('transient visibility errors are retried without writes', (
    tester,
  ) async {
    final h = PollingHarness();
    await h.init();
    try {
      h.transientReadFailure = true;
      await h.start();
      await tester.pump();
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(h.instances, 1);
      expect(h.creates('vpc'), 1);
      expect(h.creates('subnet'), 1);
    } finally {
      h.dispose();
    }
  });
  testWidgets('waits for delayed VPC and subnet without another mutation', (
    tester,
  ) async {
    final h = PollingHarness();
    await h.init();
    try {
      h.hidden.addAll({'vpc': 1, 'subnet': 1});
      await h.start();
      await tester.pump();
      expect(h.controller.jobs.single.phase, CloudMachinePhase.creating);
      expect(h.instances, 0);
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(h.instances, 1);
      expect(h.creates('vpc'), 1);
      expect(h.creates('subnet'), 1);
      expect(h.networks.every((r) => r['pending'] == false), isTrue);
    } finally {
      h.dispose();
    }
  });

  testWidgets('lost mutation response recovers using read-only polling', (
    tester,
  ) async {
    final h = PollingHarness();
    await h.init();
    try {
      h.loseResponse = true;
      h.hidden['vpc'] = 1;
      await h.start();
      await tester.pump();
      for (var i = 0; i < 3; i++) {
        await tester.pump(const Duration(seconds: 1));
      }
      expect(h.instances, 1);
      expect(h.creates('vpc'), 1);
      expect(h.creates('subnet'), 1);
    } finally {
      h.dispose();
    }
  });

  testWidgets(
    'poll timeout retains intent and retry queries without creating',
    (tester) async {
      final h = PollingHarness();
      await h.init();
      try {
        h.hidden['vpc'] = 99;
        final job = await h.start();
        await tester.pump();
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(seconds: 1));
        }
        expect(h.controller.jobs.single.phase, CloudMachinePhase.createFailed);
        expect(h.networks.single['pending'], isTrue);
        expect(h.instances, 0);
        expect(h.creates('vpc'), 1);
        await h.restart();
        h.hidden['vpc'] = 0;
        await h.controller.retryTencentPreparation(job.id);
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(h.instances, 1);
        expect(h.creates('vpc'), 1);
        expect(h.creates('subnet'), 1);
      } finally {
        h.dispose();
      }
    },
  );

  testWidgets('poll refuses conflicting known ID before purchase', (
    tester,
  ) async {
    final h = PollingHarness();
    await h.init();
    try {
      h.conflictingId = true;
      await h.start();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(h.controller.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(h.networks.single['vpcId'], 'vpc-test');
      expect(h.networks.single['pending'], isTrue);
      expect(h.instances, 0);
      expect(h.creates('vpc'), 1);
    } finally {
      h.dispose();
    }
  });

  testWidgets('dispose stops polling without a later cloud call', (
    tester,
  ) async {
    final h = PollingHarness();
    await h.init();
    await h.start();
    await tester.pump();
    h.dispose();
    final calls = h.helper.requests.length;
    await tester.pump(const Duration(seconds: 1));
    expect(h.helper.requests.length, calls);
    expect(h.instances, 0);
    expect(h.networks.single['pending'], isTrue);
  });
}
