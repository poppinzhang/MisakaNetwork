import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/app.dart';
import 'package:last_order/src/cloud_controller.dart';
import 'package:last_order/src/cloud_models.dart';
import 'package:last_order/src/cloud_ui.dart';
import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:material_ui/material_ui.dart';

import 'fakes.dart';

Future<AppController> openCloudApp(
  WidgetTester tester, {
  double width = 1360,
  double textScale = 1,
  bool dark = false,
  List<CloudProvider> credentials = const [],
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final c = controller(
    helper: FakeHelper()..cloudSshReady = true,
    store: MemoryStore()
      ..state = SavedState(
        themeMode: dark ? AppThemeMode.dark : AppThemeMode.light,
      ),
  );
  await c.initialize(poll: false);
  await c.cloud.initialize();
  addTearDown(c.dispose);
  for (final provider in credentials) {
    await c.cloud.saveCredential(
      provider,
      alias: '${provider.displayName}测试凭证',
      accessKeyId: 'synthetic-id-${provider.name}',
      accessKeySecret: 'synthetic-secret-${provider.name}',
    );
  }
  await tester.pumpWidget(LastOrderApp(controller: c));
  await tester.pumpAndSettle();
  return c;
}

Future<void> tapVisible(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> goToPage(WidgetTester tester, String title) async {
  final desktop = tester.view.physicalSize.width >= 600;
  await tapVisible(
    tester,
    desktop ? find.byTooltip(title) : find.text(title).last,
  );
}

Future<void> openCloudCreation(WidgetTester tester) async {
  await goToPage(tester, '机器管理');
  await tapVisible(tester, find.text('添加机器'));
  await tapVisible(tester, find.byKey(const ValueKey('cloud-create-entry')));
  expect(find.byType(CloudCreateDialog), findsOneWidget);
}

Future<void> chooseTemplate(
  WidgetTester tester, {
  CloudProvider provider = CloudProvider.tencent,
  String template = 'balanced',
}) async {
  await tapVisible(tester, find.text('创建'));
  expect(find.text('轻量起步'), findsOneWidget);
  expect(find.text('均衡配置'), findsOneWidget);
  expect(find.text('充裕性能'), findsOneWidget);
  final create = find.byKey(const ValueKey('cloud-confirm-create'));
  expect(tester.widget<FilledButton>(create).onPressed, isNull);
  await tapVisible(
    tester,
    find.byKey(ValueKey('cloud-template-${provider.name}-$template')),
  );
  expect(tester.widget<FilledButton>(create).onPressed, isNotNull);
}

Future<void> advancePreview(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 3));
  await tester.pump();
}

void main() {
  testWidgets(
    'provider credentials use distinct official fields and an empty future-provider view',
    (tester) async {
      await openCloudApp(tester);
      await goToPage(tester, '公有云部署');
      for (final provider in CloudProvider.values) {
        await tapVisible(
          tester,
          find.byKey(ValueKey('cloud-provider-${provider.name}')),
        );
        expect(find.text('${provider.displayName}凭证'), findsOneWidget);
        final id = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(const ValueKey('cloud-key-id')),
            matching: find.byType(TextField),
          ),
        );
        final secret = tester.widget<TextField>(
          find.descendant(
            of: find.byKey(const ValueKey('cloud-key-secret')),
            matching: find.byType(TextField),
          ),
        );
        expect(id.decoration!.labelText, provider.credentialIdLabel);
        expect(secret.decoration!.labelText, provider.credentialSecretLabel);
        expect(find.textContaining('本机检查格式'), findsOneWidget);
      }
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-provider-upcoming')),
      );
      expect(find.text('更多云厂商，等待接入'), findsOneWidget);
      expect(find.byKey(const ValueKey('cloud-key-id')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'credentials validate empty values, save securely, and clear editable secrets',
    (tester) async {
      final c = await openCloudApp(tester);
      await goToPage(tester, '公有云部署');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-save-credential')),
      );
      expect(find.text('请填写 SecretId。'), findsOneWidget);
      expect(find.text('请填写 SecretKey。'), findsOneWidget);
      expect(c.cloud.credentials, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('cloud-key-id')),
        'synthetic-ui-id',
      );
      await tester.enterText(
        find.byKey(const ValueKey('cloud-key-secret')),
        'synthetic-ui-secret',
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-save-credential')),
      );
      expect(c.cloud.credentialFor(CloudProvider.tencent), isNotNull);
      expect(find.text('格式检查通过，已安全保存。云端身份与权限尚未验证。'), findsOneWidget);
      for (final key in ['cloud-key-id', 'cloud-key-secret']) {
        expect(
          tester
              .widget<TextFormField>(find.byKey(ValueKey(key)))
              .controller!
              .text,
          isEmpty,
        );
      }
      await tapVisible(tester, find.text('去创建云服务器'));
      expect(find.byType(CloudCreateDialog), findsOneWidget);
      expect(find.text('创建'), findsOneWidget);
      expect(find.text('录入凭证'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  for (var index = 0; index < CloudProvider.values.length; index++) {
    final provider = CloudProvider.values[index];
    testWidgets(
      'missing ${provider.name} credentials route from machine creation to its form',
      (tester) async {
        await openCloudApp(tester);
        await openCloudCreation(tester);
        expect(find.text('创建'), findsNothing);
        await tapVisible(tester, find.text('录入凭证').at(index));
        expect(find.byType(CloudCreateDialog), findsNothing);
        expect(find.text('${provider.displayName}凭证'), findsOneWidget);
        expect(find.byType(CloudCredentialsPage), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'repeated provider deep link overrides a manually selected credential tab',
    (tester) async {
      await openCloudApp(tester, credentials: [CloudProvider.aliyun]);
      await openCloudCreation(tester);
      await tapVisible(tester, find.text('录入凭证').first);
      expect(find.text('腾讯云凭证'), findsOneWidget);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-provider-aliyun')),
      );
      expect(find.text('阿里云凭证'), findsOneWidget);

      // Open directly from the credential page, so the existing page and its
      // manually selected tab remain mounted underneath this dialog.
      await tapVisible(tester, find.text('去创建云服务器'));
      await tapVisible(tester, find.text('录入凭证').first);
      expect(find.byType(CloudCreateDialog), findsNothing);
      expect(find.text('腾讯云凭证'), findsOneWidget);
      expect(find.text('阿里云凭证'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed credential save preserves the previous credential without echoing secrets',
    (tester) async {
      final c = await openCloudApp(
        tester,
        credentials: [CloudProvider.tencent],
      );
      final store = c.store as MemoryStore;
      final original = store.secrets[CloudController.workspaceKey];
      final previous = c.cloud.credentialFor(CloudProvider.tencent)!;
      store.failWrite.add(CloudController.workspaceKey);
      await goToPage(tester, '公有云部署');
      await tester.enterText(
        find.byKey(const ValueKey('cloud-alias')),
        '替换失败的测试凭证',
      );
      await tester.enterText(
        find.byKey(const ValueKey('cloud-key-id')),
        'synthetic-replacement-id',
      );
      const replacementSecret = 'synthetic-replacement-secret';
      await tester.enterText(
        find.byKey(const ValueKey('cloud-key-secret')),
        replacementSecret,
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-save-credential')),
      );

      expect(find.text('凭证未能保存，请检查填写内容或系统安全存储后重试。'), findsOneWidget);
      expect(find.text('格式检查通过，已安全保存。云端身份与权限尚未验证。'), findsNothing);
      expect(store.secrets[CloudController.workspaceKey], original);
      final retained = c.cloud.credentialFor(CloudProvider.tencent)!;
      expect(retained.alias, previous.alias);
      expect(retained.maskedId, previous.maskedId);
      final secretField = tester.widget<TextField>(
        find.descendant(
          of: find.byKey(const ValueKey('cloud-key-secret')),
          matching: find.byType(TextField),
        ),
      );
      expect(secretField.obscureText, isTrue);
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is Text &&
              (widget.data?.contains(replacementSecret) ?? false),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'template confirmation immediately adds independent creating machines',
    (tester) async {
      final c = await openCloudApp(
        tester,
        credentials: [CloudProvider.tencent],
      );
      await openCloudCreation(tester);
      await chooseTemplate(tester);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-confirm-create')),
      );
      expect(find.byType(CloudCreateDialog), findsNothing);
      expect(c.cloud.jobs, hasLength(1));
      expect(c.cloud.jobs.single.phase, CloudMachinePhase.creating);
      expect(find.text('创建云服务器'), findsOneWidget);
      expect(find.byType(CloudMachineCard), findsOneWidget);
      expect(c.state.machines, isEmpty);

      await openCloudCreation(tester);
      await chooseTemplate(tester, template: 'starter');
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-confirm-create')),
      );
      expect(c.cloud.jobs, hasLength(2));
      expect(c.cloud.jobs.last.phase, CloudMachinePhase.creating);
      expect(c.cloud.jobs.map((job) => job.id).toSet(), hasLength(2));
      expect(find.byType(CloudMachineCard), findsNWidgets(2));
      expect((c.gateway as FakeGateway).statusRequests, isEmpty);
      expect((c.helper as FakeHelper).requests, isEmpty);
      expect(tester.takeException(), isNull);
      await advancePreview(tester);
      await advancePreview(tester);
      expect(c.cloud.jobs.every((job) => !job.active), isTrue);
    },
  );

  testWidgets(
    'creation failure is visible and its failed machine can be deleted',
    (tester) async {
      final c = await openCloudApp(
        tester,
        credentials: [CloudProvider.tencent],
      );
      await openCloudCreation(tester);
      await chooseTemplate(tester);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-preview-outcome')),
      );
      await tapVisible(tester, find.text('创建失败').last);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-confirm-create')),
      );
      await advancePreview(tester);
      expect(c.cloud.jobs.single.phase, CloudMachinePhase.createFailed);
      expect(find.textContaining('当前配置暂时无可用库存'), findsOneWidget);
      expect(find.text('释放云服务器'), findsNothing);
      await tapVisible(tester, find.text('删除失败机器'));
      expect(c.cloud.jobs, isEmpty);
      expect(find.byType(CloudMachineCard), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'release requires confirmation and can be cancelled before previewing release',
    (tester) async {
      final c = await openCloudApp(
        tester,
        credentials: [CloudProvider.tencent],
      );
      await c.cloud.startPreviewCreation(
        CloudProvider.tencent,
        CloudTemplate.forProvider(CloudProvider.tencent).first,
      );
      await goToPage(tester, '机器管理');
      await advancePreview(tester);
      await advancePreview(tester);
      expect(c.cloud.jobs.single.phase, CloudMachinePhase.ready);
      await tapVisible(tester, find.text('释放云服务器'));
      expect(find.text('确认释放（预览）'), findsOneWidget);
      await tapVisible(tester, find.text('保留服务器'));
      expect(c.cloud.jobs.single.phase, CloudMachinePhase.ready);
      await tapVisible(tester, find.text('释放云服务器'));
      await tapVisible(tester, find.text('确认释放（预览）'));
      expect(c.cloud.jobs.single.phase, CloudMachinePhase.releasing);
      expect(find.text('正在演示释放，请稍候。'), findsOneWidget);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(c.cloud.jobs.single.phase, CloudMachinePhase.released);
      expect(find.text('已释放'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  for (final textScale in [1.0, 2.0]) {
    testWidgets(
      'dark mobile cloud credentials and creation fit at text scale $textScale',
      (tester) async {
        await openCloudApp(
          tester,
          width: 390,
          textScale: textScale,
          dark: true,
          credentials: [CloudProvider.tencent],
        );
        await goToPage(tester, '公有云部署');
        expect(find.byType(CloudCredentialsPage), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.text('去创建云服务器'));
        expect(find.byType(CloudCreateDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await chooseTemplate(tester);
        expect(tester.takeException(), isNull);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('cloud-confirm-create')),
        );
        expect(find.byType(CloudMachineCard), findsOneWidget);
        expect(tester.takeException(), isNull);
        await advancePreview(tester);
        await advancePreview(tester);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
