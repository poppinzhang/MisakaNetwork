import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/cloud_ui.dart';
import 'package:material_ui/material_ui.dart';

import 'aliyun_controller_test.dart' as aliyun;
import 'cloud_templates_test.dart' show validTencentTemplate;
import 'fakes.dart';
import 'volcengine_controller_test.dart' as volcengine;

void main() {
  final providers = [
    (
      provider: CloudProvider.tencent,
      make: validTencentTemplate,
      model: CloudTemplate.tencent,
    ),
    (
      provider: CloudProvider.volcengine,
      make: volcengine.volcTemplateData,
      model: CloudTemplate.volcengine,
    ),
    (
      provider: CloudProvider.aliyun,
      make: aliyun.templateData,
      model: CloudTemplate.aliyun,
    ),
  ];
  for (final entry in providers) {
    testWidgets(
      '${entry.provider.name} shows the chosen Linux image and SSH account',
      (tester) async {
        final template = entry.model(
          entry.make()
            ..['os'] = 'Debian 13'
            ..['sshUsername'] = 'custom-user',
        );
        final controller = CloudController(
          store: MemoryStore(),
          helper: FakeHelper()..cloudSshReady = true,
          templateLoader: () async =>
              entry.provider == CloudProvider.tencent ? [template] : [],
          volcengineTemplateLoader: () async =>
              entry.provider == CloudProvider.volcengine ? [template] : [],
          aliyunTemplateLoader: () async =>
              entry.provider == CloudProvider.aliyun ? [template] : [],
        );
        addTearDown(controller.dispose);
        await controller.initialize();
        await controller.saveCredential(
          entry.provider,
          accessKeyId: 'FixtureID',
          accessKeySecret: 'FixtureSecret',
        );
        tester.view.physicalSize = const Size(390, 1000);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = 2;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: CloudCreateDialog(controller: controller)),
          ),
        );
        await tester.pumpAndSettle();
        for (final key in [
          'cloud-select-provider-${entry.provider.name}',
          'cloud-template-${template.id}',
        ]) {
          final finder = find.byKey(ValueKey(key));
          await tester.ensureVisible(finder);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }
        expect(find.textContaining('系统：Debian 13'), findsOneWidget);
        expect(find.textContaining('SSH 登录：custom-user（密钥）'), findsOneWidget);
        expect(
          find.textContaining('glibc 2.39+、GTK 3.24 与 systemd'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
