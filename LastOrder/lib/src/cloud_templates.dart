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
    if (catalog['schemaVersion'] is! int || catalog['schemaVersion'] != 1) {
      throw const FormatException('腾讯云模板版本必须为 1。');
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
      'regionLabel',
      'region',
      'sshUsername',
      'sshCidr',
      'grpcCidr',
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
    _string(t, 'sshUsername', pattern: r'^[a-z_][a-z0-9_-]{0,31}$');
    _integer(t, 'cpu', 1, 1024);
    _integer(t, 'memoryGb', 1, 1024);
    final diskSize = _integer(t, 'diskGb', 20, 4096);
    _choice(t, 'architecture', {'x64', 'arm64'});
    _choice(t, 'os', {'Ubuntu 24.04 LTS'});
    for (final field in ['sshCidr', 'grpcCidr']) {
      if (!_isCidr(_string(t, field))) {
        throw FormatException('$field 必须是规范的 IPv4 CIDR，例如 203.0.113.8/32。');
      }
    }
    final run = _object(t['runInstances'], 'runInstances', {
      'Placement',
      'InstanceType',
      'ImageId',
      'SystemDisk',
      'VirtualPrivateCloud',
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
    final vpc = _object(run['VirtualPrivateCloud'], 'VirtualPrivateCloud', {
      'VpcId',
      'SubnetId',
    });
    _string(vpc, 'VpcId', pattern: r'^vpc-[a-z0-9]+$');
    _string(vpc, 'SubnetId', pattern: r'^subnet-[a-z0-9]+$');
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

  static bool _isCidr(String value) {
    final parts = value.split('/');
    if (parts.length != 2) return false;
    final octets = parts[0].split('.');
    final prefix = int.tryParse(parts[1]);
    if (octets.length != 4 ||
        prefix == null ||
        prefix < 0 ||
        prefix > 32 ||
        '$prefix' != parts[1]) {
      return false;
    }
    var ip = 0;
    for (final octet in octets) {
      final n = int.tryParse(octet);
      if (n == null || n < 0 || n > 255 || '$n' != octet) return false;
      ip = (ip << 8) | n;
    }
    final hostMask = (1 << (32 - prefix)) - 1;
    // Tencent VPC normalizes 0.0.0.0/n to 0.0.0.0/0. Accept only the
    // administrator's explicit /0 choice, never silently broaden access.
    return !(ip == 0 && prefix != 0) && ip & hostMask == 0;
  }
}
