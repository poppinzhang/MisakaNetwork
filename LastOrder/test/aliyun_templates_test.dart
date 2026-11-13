import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/cloud_templates.dart';

import 'aliyun_controller_test.dart' show templateData;
import 'fakes.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('packaged Aliyun catalog permits administrator configuration', () async {
    expect(
      AliyunTemplateCatalog.parse(
        await rootBundle.loadString(AliyunTemplateCatalog.assetPath),
      ),
      isA<List<Map<String, dynamic>>>(),
    );
  });
  test('Aliyun template validates native fields, foreign regions and immutable snapshot', () {
    final original = templateData();
    final parsed = AliyunTemplateCatalog.parse(
      jsonEncode({
        'schemaVersion': 2,
        'templates': [original],
      }),
    );
    expect(parsed.single, original);
    final snapshot = CloudTemplate.fromJson(
      CloudTemplate.aliyun(parsed.single).toJson(),
    );
    expect(snapshot.belongsTo(CloudProvider.aliyun), isTrue);
    expect(snapshot.belongsTo(CloudProvider.tencent), isFalse);
    expect(snapshot.zone, 'cn-hangzhou-a');
    expect(snapshot.tencent, isNull);
    expect(snapshot.volcengine, isNull);
    original['runInstances']['ZoneId'] = 'cn-hangzhou-b';
    expect(snapshot.zone, 'cn-hangzhou-a');
    for (final region in ['ap-southeast-1', 'cn-hangzhou', 'eu-central-1']) {
      final t = templateData()..['region'] = region;
      final zone = '$region${RegExp(r'[0-9]$').hasMatch(region) ? '' : '-'}a';
      t['runInstances']['ZoneId'] = zone;
      expect(AliyunTemplateCatalog.validateTemplate(t), t);
      expect(CloudProvider.aliyun.zonePattern(region).hasMatch(zone), true);
    }
  });
  test(
    'Aliyun template rejects policy overrides and malformed specifications',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (t) => t['secret_id'] = 'private',
        (t) => t['endpoint'] = 'https://example.invalid',
        (t) => t['sshUsername'] = 'user;command',
        (t) => t['runInstances']['UserData'] = 'script',
        (t) => t['runInstances']['Amount'] = 2,
        (t) => t['runInstances']['InstanceChargeType'] = 'PrePaid',
        (t) => t['runInstances']['ImageOptions'] = {'LoginAsNonRoot': true},
        (t) => t['runInstances']['VSwitchId'] = 'vsw-external',
        (t) => t['runInstances']['SecurityGroupId'] = 'sg-external',
        (t) => t['runInstances']['DataDisk'] = [],
        (t) => t['runInstances']['Password'] = 'private',
        (t) => t['runInstances']['InternetChargeType'] = 'PayByBandwidth',
        (t) => t['runInstances']['InternetMaxBandwidthOut'] = 0,
        (t) => t['runInstances']['InternetMaxBandwidthOut'] = 101,
        (t) => t['runInstances']['InternetMaxBandwidthOut'] = 5.0,
        (t) => t['runInstances']['SystemDisk']['Size'] = 51,
        (t) => t['runInstances']['SystemDisk']['Category'] = 'unknown',
        (t) => t['runInstances']['SystemDisk']['DeleteWithInstance'] = false,
        (t) => t['runInstances']['ZoneId'] = 'cn-shanghai-a',
        (t) => t['runInstances']['ZoneId'] = 'cn-hangzhoua',
        (t) => t['runInstances']['InstanceType'] = 'S5.MEDIUM4',
        (t) => t['runInstances']['ImageId'] = 'bad image',
        (t) => t['architecture'] = 'amd64',
        (t) => t['os'] = '',
      ]) {
        final value = templateData();
        mutate(value);
        expect(
          () => AliyunTemplateCatalog.validateTemplate(value),
          throwsFormatException,
          reason: value.toString(),
        );
      }
      for (final catalog in [
        {'schemaVersion': 1, 'templates': []},
        {
          'schemaVersion': 2,
          'templates': [templateData(), templateData()],
        },
        {'schemaVersion': 2, 'templates': [], 'endpoint': 'invalid'},
      ]) {
        expect(
          () => AliyunTemplateCatalog.parse(jsonEncode(catalog)),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'invalid Aliyun catalog is isolated from other provider catalog loaders',
    () async {
      final c = CloudController(
        store: MemoryStore(),
        helper: FakeHelper()..cloudSshReady = true,
        templateLoader: () async => [],
        aliyunTemplateLoader: () async => [
          CloudTemplate.aliyun(templateData()..['endpoint'] = 'invalid'),
        ],
      );
      addTearDown(c.dispose);
      await c.initialize();
      expect(c.initialized, isTrue);
      expect(c.templatesFor(CloudProvider.aliyun), isEmpty);
      expect(c.templateErrorFor(CloudProvider.aliyun), contains('阿里云'));
      expect(c.templateErrorFor(CloudProvider.tencent), isNull);
      expect(c.templateErrorFor(CloudProvider.volcengine), isNull);
    },
  );
}
