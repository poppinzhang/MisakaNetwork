import 'dart:convert';

import 'package:flutter/services.dart';

/// Packaged, administrator-authored CVM configurations. Credentials and
/// lifecycle-controlled RunInstances parameters never belong in these files.
abstract final class TencentTemplateCatalog {
  static const assetPath = 'assets/cloud_templates/tencent.json';

  static Future<List<Map<String, dynamic>>> load({AssetBundle? bundle}) async =>
      parse(await (bundle ?? rootBundle).loadString(assetPath));

  static List<Map<String, dynamic>> parse(String source) {
    if (utf8.encode(source).length > 1024 * 1024) {
      throw const FormatException('腾讯云模板文件不能超过 1 MiB。');
    }
    final catalog = _object(jsonDecode(source), '模板文件', {
      'schemaVersion',
      'templates',
    });
    if (catalog['schemaVersion'] is! int || catalog['schemaVersion'] != 4) {
      throw const FormatException('腾讯云模板版本必须为 4，请重新生成模板。');
    }
    final entries = catalog['templates'];
    if (entries is! List || entries.length > 100) {
      throw const FormatException('templates 必须是最多包含 100 个模板的数组。');
    }
    final ids = <String>{};
    return [
      for (final entry in entries)
        (() {
          if (entry is! Map<String, dynamic>) {
            throw const FormatException('腾讯云模板必须是对象。');
          }
          final result = validateTemplate(entry);
          if (!ids.add(result['id'] as String)) {
            throw const FormatException('腾讯云模板 id 不能重复。');
          }
          return result;
        })(),
    ];
  }

  static Map<String, dynamic> validateTemplate(Map<String, dynamic> value) {
    final t = _object(value, '模板', {
      'id',
      'name',
      'description',
      'cpu',
      'memoryGb',
      'diskGb',
      'architecture',
      'os',
      'sshUsername',
      'regionLabel',
      'region',
      'runInstances',
    });
    _string(t, 'id', pattern: r'^[a-z][a-z0-9-]{0,63}$');
    _string(t, 'name', max: 80);
    _string(t, 'description', max: 500);
    _string(t, 'regionLabel', max: 80);
    final region = _string(
      t,
      'region',
      pattern: r'^[a-z]{2}-[a-z]+(?:-[a-z]+)*$',
    );
    _integer(t, 'cpu', 1, 1024);
    _integer(t, 'memoryGb', 1, 1024);
    final diskSize = _integer(t, 'diskGb', 20, 4096);
    _choice(t, 'architecture', {'x64', 'arm64'});
    _string(t, 'os', max: 128);
    _string(t, 'sshUsername', pattern: r'^[a-z_][a-z0-9_-]{0,31}$');
    final run = _object(t['runInstances'], 'runInstances', {
      'Placement',
      'InstanceType',
      'ImageId',
      'SystemDisk',
      'InternetAccessible',
    });
    final placement = _object(run['Placement'], 'Placement', {'Zone'});
    _string(
      placement,
      'Zone',
      pattern: '^${RegExp.escape(region)}-[1-9][0-9]*\$',
    );
    _string(run, 'InstanceType', pattern: r'^[A-Z][A-Za-z0-9]*\.[A-Z0-9]+$');
    _string(run, 'ImageId', pattern: r'^img-[a-z0-9]+$');
    final disk = _object(run['SystemDisk'], 'SystemDisk', {
      'DiskType',
      'DiskSize',
    });
    _choice(disk, 'DiskType', {
      'CLOUD_PREMIUM',
      'CLOUD_SSD',
      'CLOUD_BSSD',
      'CLOUD_HSSD',
    });
    if (_integer(disk, 'DiskSize', 20, 4096) != diskSize) {
      throw const FormatException('diskGb 必须与 SystemDisk.DiskSize 相同。');
    }
    final internet = _object(run['InternetAccessible'], 'InternetAccessible', {
      'InternetChargeType',
      'InternetMaxBandwidthOut',
      'PublicIpAssigned',
    });
    _choice(internet, 'InternetChargeType', {'TRAFFIC_POSTPAID_BY_HOUR'});
    _integer(internet, 'InternetMaxBandwidthOut', 1, 100);
    if (internet['PublicIpAssigned'] != true) {
      throw const FormatException('PublicIpAssigned 必须为 true。');
    }
    return jsonDecode(jsonEncode(t)) as Map<String, dynamic>;
  }

  static Map<String, dynamic> _object(
    Object? value,
    String name,
    Set<String> keys,
  ) {
    if (value is! Map<String, dynamic> ||
        value.keys.toSet().difference(keys).isNotEmpty ||
        keys.difference(value.keys.toSet()).isNotEmpty) {
      throw FormatException('$name 字段不完整或包含不支持的字段。');
    }
    return value;
  }

  static String _string(
    Map<String, dynamic> value,
    String key, {
    int max = 128,
    String? pattern,
  }) {
    final text = value[key];
    if (text is! String ||
        text.isEmpty ||
        text.length > max ||
        text.trim() != text ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(text) ||
        (pattern != null && !RegExp(pattern).hasMatch(text))) {
      throw FormatException('$key 格式无效。');
    }
    return text;
  }

  static int _integer(
    Map<String, dynamic> value,
    String key,
    int min,
    int max,
  ) {
    final n = value[key];
    if (n is! int || n < min || n > max) {
      throw FormatException('$key 必须为 $min–$max 的整数。');
    }
    return n;
  }

  static void _choice(
    Map<String, dynamic> value,
    String key,
    Set<String> choices,
  ) {
    if (!choices.contains(value[key])) throw FormatException('$key 不在支持范围内。');
  }
}

/// Administrator-authored Volcengine ECS templates. Lifecycle policy remains
/// fixed in the helper and cannot be overridden by arbitrary API fields.
abstract final class VolcengineTemplateCatalog {
  static const assetPath = 'assets/cloud_templates/volcengine.json';
  static Future<List<Map<String, dynamic>>> load({AssetBundle? bundle}) async =>
      parse(await (bundle ?? rootBundle).loadString(assetPath));

  static List<Map<String, dynamic>> parse(String source) {
    if (utf8.encode(source).length > 1024 * 1024) {
      throw const FormatException('火山引擎模板文件不能超过 1 MiB。');
    }
    final catalog = TencentTemplateCatalog._object(jsonDecode(source), '模板文件', {
      'schemaVersion',
      'templates',
    });
    if (catalog['schemaVersion'] is! int || catalog['schemaVersion'] != 2) {
      throw const FormatException('火山引擎模板版本必须为 2。');
    }
    final entries = catalog['templates'];
    if (entries is! List || entries.length > 100) {
      throw const FormatException('templates 必须是最多包含 100 个模板的数组。');
    }
    final ids = <String>{};
    return [
      for (final entry in entries)
        (() {
          if (entry is! Map<String, dynamic>) {
            throw const FormatException('模板必须是对象。');
          }
          final result = validateTemplate(entry);
          if (!ids.add(result['id'] as String)) {
            throw const FormatException('模板 id 不能重复。');
          }
          return result;
        })(),
    ];
  }

  static Map<String, dynamic> validateTemplate(Map<String, dynamic> value) {
    final t = TencentTemplateCatalog._object(value, '模板', {
      'id',
      'name',
      'description',
      'cpu',
      'memoryGb',
      'diskGb',
      'architecture',
      'os',
      'sshUsername',
      'regionLabel',
      'region',
      'runInstances',
    });
    TencentTemplateCatalog._string(t, 'id', pattern: r'^[a-z][a-z0-9-]{0,63}$');
    TencentTemplateCatalog._string(t, 'name', max: 80);
    TencentTemplateCatalog._string(t, 'description', max: 500);
    TencentTemplateCatalog._string(t, 'regionLabel', max: 80);
    final region = TencentTemplateCatalog._string(
      t,
      'region',
      pattern: r'^[a-z]{2}-[a-z]+(?:-[a-z0-9]+)*$',
    );
    TencentTemplateCatalog._integer(t, 'cpu', 1, 1024);
    TencentTemplateCatalog._integer(t, 'memoryGb', 1, 1024);
    final diskSize = TencentTemplateCatalog._integer(t, 'diskGb', 20, 2048);
    TencentTemplateCatalog._choice(t, 'architecture', {'x64', 'arm64'});
    TencentTemplateCatalog._string(t, 'os', max: 128);
    TencentTemplateCatalog._string(
      t,
      'sshUsername',
      pattern: r'^[a-z_][a-z0-9_-]{0,31}$',
    );
    final run = TencentTemplateCatalog._object(
      t['runInstances'],
      'runInstances',
      {'ZoneId', 'InstanceTypeId', 'ImageId', 'Volumes', 'EipAddress'},
    );
    TencentTemplateCatalog._string(
      run,
      'ZoneId',
      pattern:
          '^${RegExp.escape(region)}${RegExp(r'[0-9]$').hasMatch(region) ? '' : '-'}[a-z]\$',
    );
    TencentTemplateCatalog._string(
      run,
      'InstanceTypeId',
      pattern: r'^ecs\.[a-zA-Z0-9-]+\.[a-zA-Z0-9]+$',
    );
    TencentTemplateCatalog._string(
      run,
      'ImageId',
      pattern: r'^image-[a-z0-9]+$',
    );
    final volumes = run['Volumes'];
    if (volumes is! List || volumes.length != 1) {
      throw const FormatException('只允许一块随实例释放的系统盘。');
    }
    final disk = TencentTemplateCatalog._object(volumes.single, 'Volumes', {
      'VolumeType',
      'Size',
    });
    TencentTemplateCatalog._choice(disk, 'VolumeType', {
      'ESSD_PL0',
      'ESSD_FlexPL',
    });
    if (TencentTemplateCatalog._integer(disk, 'Size', 20, 2048) != diskSize) {
      throw const FormatException('diskGb 必须与系统盘 Size 相同。');
    }
    final eip = TencentTemplateCatalog._object(
      run['EipAddress'],
      'EipAddress',
      {'BandwidthMbps', 'ISP', 'ChargeType', 'ReleaseWithInstance'},
    );
    TencentTemplateCatalog._integer(eip, 'BandwidthMbps', 1, 200);
    TencentTemplateCatalog._choice(eip, 'ISP', {'BGP'});
    TencentTemplateCatalog._choice(eip, 'ChargeType', {'PayByTraffic'});
    if (eip['ReleaseWithInstance'] != true) {
      throw const FormatException('公网 IP 必须随实例一同释放。');
    }
    return jsonDecode(jsonEncode(t)) as Map<String, dynamic>;
  }
}

/// Aliyun ECS templates use only administrator-authored machine specifications.
/// VPC, vSwitch, key, purchase token and lifecycle settings are runtime policy.
abstract final class AliyunTemplateCatalog {
  static const assetPath = 'assets/cloud_templates/aliyun.json';
  static Future<List<Map<String, dynamic>>> load({AssetBundle? bundle}) async =>
      parse(await (bundle ?? rootBundle).loadString(assetPath));

  static List<Map<String, dynamic>> parse(String source) {
    if (utf8.encode(source).length > 1024 * 1024) {
      throw const FormatException('阿里云模板文件不能超过 1 MiB。');
    }
    final catalog = TencentTemplateCatalog._object(jsonDecode(source), '模板文件', {
      'schemaVersion',
      'templates',
    });
    if (catalog['schemaVersion'] is! int || catalog['schemaVersion'] != 2) {
      throw const FormatException('阿里云模板版本必须为 2。');
    }
    final entries = catalog['templates'];
    if (entries is! List || entries.length > 100) {
      throw const FormatException('templates 必须是最多包含 100 个模板的数组。');
    }
    final ids = <String>{};
    return [
      for (final entry in entries)
        (() {
          if (entry is! Map<String, dynamic>) {
            throw const FormatException('模板必须是对象。');
          }
          final result = validateTemplate(entry);
          if (!ids.add(result['id'] as String)) {
            throw const FormatException('模板 id 不能重复。');
          }
          return result;
        })(),
    ];
  }

  static Map<String, dynamic> validateTemplate(Map<String, dynamic> value) {
    final t = TencentTemplateCatalog._object(value, '模板', {
      'id',
      'name',
      'description',
      'cpu',
      'memoryGb',
      'diskGb',
      'architecture',
      'os',
      'sshUsername',
      'regionLabel',
      'region',
      'runInstances',
    });
    TencentTemplateCatalog._string(t, 'id', pattern: r'^[a-z][a-z0-9-]{0,63}$');
    TencentTemplateCatalog._string(t, 'name', max: 80);
    TencentTemplateCatalog._string(t, 'description', max: 500);
    TencentTemplateCatalog._string(t, 'regionLabel', max: 80);
    final region = TencentTemplateCatalog._string(
      t,
      'region',
      pattern: r'^[a-z]{2}-[a-z]+(?:-[a-z0-9]+)*$',
    );
    TencentTemplateCatalog._integer(t, 'cpu', 1, 1024);
    TencentTemplateCatalog._integer(t, 'memoryGb', 1, 1024);
    final diskSize = TencentTemplateCatalog._integer(t, 'diskGb', 20, 2048);
    TencentTemplateCatalog._choice(t, 'architecture', {'x64', 'arm64'});
    TencentTemplateCatalog._string(t, 'os', max: 128);
    TencentTemplateCatalog._string(
      t,
      'sshUsername',
      pattern: r'^[a-z_][a-z0-9_-]{0,31}$',
    );
    final run = TencentTemplateCatalog._object(
      t['runInstances'],
      'runInstances',
      {
        'ZoneId',
        'InstanceType',
        'ImageId',
        'SystemDisk',
        'InternetChargeType',
        'InternetMaxBandwidthOut',
      },
    );
    TencentTemplateCatalog._string(
      run,
      'ZoneId',
      pattern:
          '^${RegExp.escape(region)}${RegExp(r'[0-9]$').hasMatch(region) ? '' : '-'}[a-z]\$',
    );
    TencentTemplateCatalog._string(
      run,
      'InstanceType',
      pattern: r'^ecs\.[a-zA-Z0-9-]+\.[a-zA-Z0-9]+$',
    );
    TencentTemplateCatalog._string(
      run,
      'ImageId',
      pattern: r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$',
    );
    final disk = TencentTemplateCatalog._object(
      run['SystemDisk'],
      'SystemDisk',
      {'Category', 'Size'},
    );
    TencentTemplateCatalog._choice(disk, 'Category', {
      'cloud_efficiency',
      'cloud_ssd',
      'cloud_essd',
      'cloud_essd_entry',
      'cloud_auto',
    });
    if (TencentTemplateCatalog._integer(disk, 'Size', 20, 2048) != diskSize) {
      throw const FormatException('diskGb 必须与 SystemDisk.Size 相同。');
    }
    TencentTemplateCatalog._choice(run, 'InternetChargeType', {'PayByTraffic'});
    TencentTemplateCatalog._integer(run, 'InternetMaxBandwidthOut', 1, 100);
    return jsonDecode(jsonEncode(t)) as Map<String, dynamic>;
  }
}
