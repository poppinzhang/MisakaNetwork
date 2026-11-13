import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/cloud_templates.dart';
import 'package:last_order/src/models.dart';

import 'cloud_templates_test.dart' show validTencentTemplate;
import 'aliyun_controller_test.dart' as aliyun;
import 'fakes.dart';
import 'volcengine_controller_test.dart' as volcengine;

void main() {
  final catalogs = [
    (
      name: 'Tencent',
      provider: CloudProvider.tencent,
      version: 4,
      make: validTencentTemplate,
      parse: TencentTemplateCatalog.parse,
      validate: TencentTemplateCatalog.validateTemplate,
      model: CloudTemplate.tencent,
    ),
    (
      name: 'Volcengine',
      provider: CloudProvider.volcengine,
      version: 2,
      make: volcengine.volcTemplateData,
      parse: VolcengineTemplateCatalog.parse,
      validate: VolcengineTemplateCatalog.validateTemplate,
      model: CloudTemplate.volcengine,
    ),
    (
      name: 'Aliyun',
      provider: CloudProvider.aliyun,
      version: 2,
      make: aliyun.templateData,
      parse: AliyunTemplateCatalog.parse,
      validate: AliyunTemplateCatalog.validateTemplate,
      model: CloudTemplate.aliyun,
    ),
  ];
  for (final catalog in catalogs) {
    test(
      '${catalog.name} permits administrator chosen Linux display names and login accounts',
      () {
        for (final os in [
          'Debian 13',
          'Ubuntu 26.04 LTS',
          'Rocky Linux 10',
          '自定义 Linux',
        ]) {
          final value = catalog.make()
            ..['os'] = os
            ..['sshUsername'] = 'custom-user';
          final parsed = catalog
              .parse(
                jsonEncode({
                  'schemaVersion': catalog.version,
                  'templates': [value],
                }),
              )
              .single;
          expect(parsed['os'], os);
          expect(parsed['sshUsername'], 'custom-user');
          final snapshot = CloudTemplate.fromJson(
            catalog.model(parsed).toJson(),
          );
          expect(snapshot.os, os);
          expect(snapshot.sshUsername, 'custom-user');
          value['sshUsername'] = 'changed';
          expect(snapshot.sshUsername, 'custom-user');
        }
      },
    );
    test(
      '${catalog.name} requires a safe explicit SSH user and OS display name',
      () {
        for (final user in [
          '',
          ' root',
          'root ',
          'user;command',
          'user\nname',
          '-root',
          'Root',
          '用户',
          'a' * 33,
        ]) {
          expect(
            () => catalog.validate(catalog.make()..['sshUsername'] = user),
            throwsFormatException,
          );
        }
        expect(
          () => catalog.validate(catalog.make()..remove('sshUsername')),
          throwsFormatException,
        );
        for (final os in ['', ' Linux', 'Linux ', 'Linux\ncustom', 'a' * 129]) {
          expect(
            () => catalog.validate(catalog.make()..['os'] = os),
            throwsFormatException,
          );
        }
        for (final user in [
          'root',
          'ubuntu',
          'ecs-user',
          '_service',
          'user_123',
        ]) {
          expect(
            catalog.validate(
              catalog.make()..['sshUsername'] = user,
            )['sshUsername'],
            user,
          );
        }
      },
    );
    test('${catalog.name} rejects the prior catalog schema', () {
      expect(
        () => catalog.parse(
          jsonEncode({'schemaVersion': catalog.version - 1, 'templates': []}),
        ),
        throwsFormatException,
      );
    });
    test(
      '${catalog.name} preserves an old workspace whose template lacks an SSH user',
      () async {
        final template = catalog.model(catalog.make());
        final job = CloudMachine(
          id: 'persisted-operation',
          name: '已保存的云服务器',
          provider: catalog.provider,
          template: template,
          phase: CloudMachinePhase.creating,
          isReal: true,
          createSubmitted: true,
          region: template.configuration!['region'] as String,
          clientToken: 'persisted-client-token',
        ).toJson();
        (job['template'][catalog.provider.name] as Map).remove('sshUsername');
        final legacy = jsonEncode({
          'version': 1,
          'credentials': [],
          'jobs': [job],
          'networks': [],
        });
        final store = MemoryStore();
        store.secrets[CloudController.workspaceKey] = legacy;
        store.secrets[CloudController.sshIdentityKey] = jsonEncode({
          'private_key': '-----BEGIN RSA PRIVATE KEY-----TEST',
          'public_key': 'ssh-rsa TEST',
          'fingerprint': 'SHA256:TEST',
        });
        final helper = FakeHelper();
        final controller = CloudController(
          store: store,
          helper: helper,
          templateLoader: () async => [],
          volcengineTemplateLoader: () async => [],
          aliyunTemplateLoader: () async => [],
        );
        addTearDown(controller.dispose);
        for (var attempt = 0; attempt < 2; attempt++) {
          await controller.initialize();
          expect(controller.initialized, isFalse);
          expect(controller.startupError, isNotNull);
          expect(controller.jobs, isEmpty);
          expect(store.secrets[CloudController.workspaceKey], legacy);
          expect(helper.requests, isEmpty);
        }
        await expectLater(
          controller.saveCredential(
            catalog.provider,
            accessKeyId: 'FixtureID',
            accessKeySecret: 'FixtureSecret',
          ),
          throwsA(isA<UserError>()),
        );
        expect(store.secrets[CloudController.workspaceKey], legacy);
        expect(helper.requests, isEmpty);
      },
    );
  }
}
