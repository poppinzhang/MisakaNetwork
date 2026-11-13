import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_templates.dart';

Map<String, dynamic> validTencentTemplate() => {
  'id': 'test-ubuntu-x64',
  'name': '模拟配置',
  'description': '仅用于离线测试',
  'cpu': 2,
  'memoryGb': 4,
  'diskGb': 40,
  'architecture': 'x64',
  'os': 'Ubuntu 24.04 LTS',
  'regionLabel': '模拟地域',
  'region': 'ap-guangzhou',
  'sshUsername': 'ubuntu',
  'sshCidr': '203.0.113.8/32',
  'grpcCidr': '203.0.113.0/24',
  'runInstances': {
    'Placement': {'Zone': 'ap-guangzhou-6'},
    'InstanceType': 'S5.MEDIUM4',
    'ImageId': 'img-test0001',
    'SystemDisk': {'DiskType': 'CLOUD_SSD', 'DiskSize': 40},
    'VirtualPrivateCloud': {
      'VpcId': 'vpc-test0001',
      'SubnetId': 'subnet-test0001',
    },
    'InternetAccessible': {
      'InternetChargeType': 'TRAFFIC_POSTPAID_BY_HOUR',
      'InternetMaxBandwidthOut': 5,
      'PublicIpAssigned': true,
    },
  },
};

class _TemplateBundle extends CachingAssetBundle {
  _TemplateBundle(this.data);
  final String data;
  String? requestedKey;
  @override
  Future<ByteData> load(String key) async {
    requestedKey = key;
    return ByteData.sublistView(Uint8List.fromList(utf8.encode(data)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'loads exact packaged asset and permits an empty unconfigured catalog',
    () async {
      final bundle = _TemplateBundle('{"schemaVersion":1,"templates":[]}');
      expect(await TencentTemplateCatalog.load(bundle: bundle), isEmpty);
      expect(bundle.requestedKey, TencentTemplateCatalog.assetPath);
      // Administrators may fill the real asset before packaging; loading it
      // must remain valid without coupling the test to an empty configuration.
      expect(
        await TencentTemplateCatalog.load(),
        isA<List<Map<String, dynamic>>>(),
      );
    },
  );

  test('valid template returns independent deep copy', () {
    final original = validTencentTemplate();
    final parsed = TencentTemplateCatalog.validateTemplate(original);
    original['runInstances']['ImageId'] = 'changed';
    expect(parsed['runInstances']['ImageId'], 'img-test0001');
  });

  test('catalog parsing preserves mixed-case instance family names', () {
    for (final instanceType in [
      'S5.MEDIUM4',
      'S5t.MEDIUM4',
      'S5ne.19XLARGE298',
      'S5se.LARGE16',
      'S9pro.MEDIUM4',
      'GN10Xp.10XLARGE160',
    ]) {
      final value = validTencentTemplate();
      value['runInstances']['InstanceType'] = instanceType;
      final parsed = TencentTemplateCatalog.parse(
        jsonEncode({'schemaVersion': 1, 'templates': [value]}),
      );
      expect(parsed.single['runInstances']['InstanceType'], instanceType);
    }
  });

  test('catalog parsing rejects malformed instance type identifiers', () {
    for (final instanceType in [
      '',
      's5t.MEDIUM4',
      'S5t.medium4',
      'S5t',
      'S5t..MEDIUM4',
      'S5t.MEDIUM4/extra',
      'S5t.MEDIUM4;command',
      'S5t.MEDIUM4\n',
      ' S5t.MEDIUM4',
      'S5t.MEDIUM4 ',
      'S5-t.MEDIUM4',
      'S5_t.MEDIUM4',
      'S5t.ＭＥＤＩＵＭ4',
      '<script>.MEDIUM4',
    ]) {
      final value = validTencentTemplate();
      value['runInstances']['InstanceType'] = instanceType;
      expect(
        () => TencentTemplateCatalog.parse(
          jsonEncode({'schemaVersion': 1, 'templates': [value]}),
        ),
        throwsFormatException,
        reason: instanceType,
      );
    }
  });

  test('rejects unsupported catalog version, unknown keys, invalid lists and duplicates', () {
    for (final catalog in [
      {'schemaVersion': 2, 'templates': []},
      {'schemaVersion': 1, 'templates': [], 'secret': 'no'},
      {'schemaVersion': 1, 'templates': {}},
      {
        'schemaVersion': 1,
        'templates': List.filled(101, validTencentTemplate()),
      },
      {
        'schemaVersion': 1,
        'templates': [validTencentTemplate(), validTencentTemplate()],
      },
    ]) {
      expect(
        () => TencentTemplateCatalog.parse(jsonEncode(catalog)),
        throwsFormatException,
      );
    }
  });

  test(
    'rejects keys that can inject secrets or change lifecycle semantics',
    () {
      for (final key in [
        'SecretId',
        'SecretKey',
        'UserData',
        'DataDisks',
        'InstanceChargeType',
        'LoginSettings',
        'SecurityGroupIds',
        'ClientToken',
        'InstanceCount',
        'ActionTimer',
      ]) {
        final value = validTencentTemplate();
        value['runInstances'][key] = 'forbidden';
        expect(
          () => TencentTemplateCatalog.validateTemplate(value),
          throwsFormatException,
          reason: key,
        );
      }
      final value = validTencentTemplate()..['secretKey'] = 'forbidden';
      expect(
        () => TencentTemplateCatalog.validateTemplate(value),
        throwsFormatException,
      );
    },
  );

  test('rejects invalid source networks and noncanonical CIDR', () {
    for (final cidr in [
      '::/0',
      '0.0.0.0',
      '203.0.113.8/24',
      '256.0.0.1/32',
      '203.0.113.1/33',
      '203.0.113.1/-1',
      '203.0.113.001/32',
      '203.0.113.1/032',
      '0.0.0.0/1',
      '0.0.0.0/24',
      '0.0.0.0/32',
    ]) {
      final value = validTencentTemplate()..['grpcCidr'] = cidr;
      expect(
        () => TencentTemplateCatalog.validateTemplate(value),
        throwsFormatException,
        reason: cidr,
      );
    }
    expect(
      TencentTemplateCatalog.validateTemplate(
        validTencentTemplate()..['grpcCidr'] = '0.0.0.0/0',
      ),
      isNotEmpty,
    );
  });

  test('rejects malformed display metadata, architecture, disk, networking and region', () {
    final mutations = <void Function(Map<String, dynamic>)>[
      (t) => t['id'] = '../unsafe',
      (t) => t['name'] = 'bad\nname',
      (t) => t['cpu'] = 2.5,
      (t) => t['memoryGb'] = 0,
      (t) => t['architecture'] = 'riscv',
      (t) => t['os'] = 'Ubuntu 22.04 LTS',
      (t) => t['sshUsername'] = 'user;command',
      (t) => t['runInstances']['Placement']['Zone'] = 'ap-beijing-1',
      (t) => t['runInstances']['SystemDisk']['DiskSize'] = 60,
      (t) =>
          t['runInstances']['InternetAccessible']['PublicIpAssigned'] = false,
      (t) => t['runInstances']['InternetAccessible']['InternetChargeType'] =
          'BANDWIDTH_PREPAID',
      (t) =>
          t['runInstances']['InternetAccessible']['InternetMaxBandwidthOut'] =
              0,
      (t) => t['runInstances']['VirtualPrivateCloud']['VpcId'] =
          'https://example.test',
      (t) => t['runInstances']['SystemDisk']['DiskType'] = 'LOCAL_SSD',
    ];
    for (final mutate in mutations) {
      final value = validTencentTemplate();
      mutate(value);
      expect(
        () => TencentTemplateCatalog.validateTemplate(value),
        throwsFormatException,
      );
    }
  });

  test('oversized catalog is rejected before parsing', () {
    expect(
      () => TencentTemplateCatalog.parse(' ' * (1024 * 1024 + 1)),
      throwsFormatException,
    );
  });
}
