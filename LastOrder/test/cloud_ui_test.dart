import 'dart:async';
import 'dart:convert';

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
  FakeHelper? helper,
  MemoryStore? store,
}) async {
  tester.view.physicalSize = Size(width, 1100);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final c = controller(
    helper: helper ?? (FakeHelper()..cloudSshReady = true),
    store: (store ?? MemoryStore())
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
  CloudProvider provider = CloudProvider.aliyun,
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

MemoryStore oldCredentialStore() =>
    MemoryStore()
      ..secrets[CloudController.workspaceKey] = jsonEncode({
        'version': 1,
        'credentials': [
          {
            'provider': 'tencent',
            'alias': '旧备注不再展示',
            'accessKeyId': 'synthetic-old-id',
            'accessKeySecret': 'synthetic-old-secret',
            'checkedAt': '2026-11-01T00:00:00Z',
          },
        ],
        'jobs': [],
      });

class CredentialWriteStore extends MemoryStore {
  Completer<void>? writeGate;
  @override
  Future<void> writeSecret(String key, String value) async {
    if (key == CloudController.workspaceKey) await writeGate?.future;
    await super.writeSecret(key, value);
  }
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
        expect(find.text('账号备注'), findsNothing);
        expect(find.byType(TextFormField), findsNWidgets(2));
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
        expect(find.textContaining('提交后联网验证，通过后才保存'), findsOneWidget);
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
    'credentials validate empty values and hide inputs after verified saving',
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
      expect(
        c.cloud.credentialFor(CloudProvider.tencent)!.onlineVerified,
        isTrue,
      );
      expect(find.text('联网验证通过，已安全保存。'), findsOneWidget);
      expect(find.byKey(const ValueKey('cloud-save-credential')), findsNothing);
      expect(find.byKey(const ValueKey('cloud-alias')), findsNothing);
      for (final key in ['cloud-key-id', 'cloud-key-secret']) {
        expect(find.byKey(ValueKey(key)), findsNothing);
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
    'failed credential save leaves input available without echoing secrets',
    (tester) async {
      final c = await openCloudApp(tester);
      final store = c.store as MemoryStore;
      final original = store.secrets[CloudController.workspaceKey];
      store.failWrite.add(CloudController.workspaceKey);
      await goToPage(tester, '公有云部署');
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

      expect(find.textContaining('公有云信息无法保存'), findsOneWidget);
      expect(find.text('联网验证通过，已安全保存。'), findsNothing);
      expect(store.secrets[CloudController.workspaceKey], original);
      expect(c.cloud.credentialFor(CloudProvider.tencent), isNull);
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
    'online verification disables repeated edits and hides inputs only after saving',
    (tester) async {
      final helper = FakeHelper()..cloudSshReady = true;
      final c = await openCloudApp(tester, helper: helper);
      final store = c.store as MemoryStore;
      final original = store.secrets[CloudController.workspaceKey];
      final verification = Completer<Map<String, dynamic>>();
      helper.handler = (request, _) {
        expect(request['action'], 'verify_cloud_credential');
        expect((request['cloud_credential'] as Map)['provider'], 'tencent');
        return verification.future;
      };
      final priorRequests = helper.requests.length;
      await goToPage(tester, '公有云部署');
      await tester.enterText(
        find.byKey(const ValueKey('cloud-key-id')),
        'synthetic-new-id',
      );
      await tester.enterText(
        find.byKey(const ValueKey('cloud-key-secret')),
        'synthetic-new-secret',
      );
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-save-credential')),
      );
      expect(find.text('正在验证并保存'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('cloud-save-credential')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextFormField>(find.byKey(const ValueKey('cloud-key-id')))
            .enabled,
        isFalse,
      );
      expect(find.text('移除凭证'), findsNothing);
      expect(find.text('去创建云服务器'), findsNothing);
      expect(store.secrets[CloudController.workspaceKey], original);
      expect(c.cloud.credentials, isEmpty);
      expect(helper.requests, hasLength(priorRequests + 1));
      verification.complete({'verified': true, 'provider': 'tencent'});
      await tester.pumpAndSettle();
      expect(find.text('联网验证通过，已安全保存。'), findsOneWidget);
      expect(
        c.cloud.credentialFor(CloudProvider.tencent)!.onlineVerified,
        isTrue,
      );
      expect(find.byType(TextFormField), findsNothing);
      expect(find.byKey(const ValueKey('cloud-save-credential')), findsNothing);
      expect(c.cloud.credentials, hasLength(1));
      expect(store.secrets[CloudController.workspaceKey], isNot(original));
      expect(tester.takeException(), isNull);
    },
  );

  for (final initiallySaved in [false, true]) {
    testWidgets(
      'failed online verification never saves a submitted credential (old unverified record: $initiallySaved)',
      (tester) async {
        final helper = FakeHelper()..cloudSshReady = true;
        final c = await openCloudApp(
          tester,
          helper: helper,
          store: initiallySaved ? oldCredentialStore() : null,
        );
        final store = c.store as MemoryStore;
        final original = store.secrets[CloudController.workspaceKey];
        helper.handler = (_, _) async =>
            throw StateError('synthetic-secret-do-not-display');
        await goToPage(tester, '公有云部署');
        await tester.enterText(
          find.byKey(const ValueKey('cloud-key-id')),
          'synthetic-new-id',
        );
        await tester.enterText(
          find.byKey(const ValueKey('cloud-key-secret')),
          'synthetic-secret-do-not-display',
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('cloud-save-credential')),
        );
        expect(find.textContaining('凭证联网验证未通过，未保存新凭证'), findsOneWidget);
        expect(find.text('联网验证通过，已安全保存。'), findsNothing);
        expect(store.secrets[CloudController.workspaceKey], original);
        expect(c.cloud.credentials, hasLength(initiallySaved ? 1 : 0));
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                (widget.data?.contains('synthetic-secret-do-not-display') ??
                    false),
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final provider in CloudProvider.values) {
    testWidgets(
      '${provider.name} maintains one credential and permits confirmed removal',
      (tester) async {
        final c = await openCloudApp(tester, credentials: CloudProvider.values);
        await goToPage(tester, '公有云部署');
        await tapVisible(
          tester,
          find.byKey(ValueKey('cloud-provider-${provider.name}')),
        );
        expect(find.textContaining('如需更换凭证，请先移除当前凭证'), findsOneWidget);
        expect(find.byType(TextFormField), findsNothing);
        expect(
          find.byKey(const ValueKey('cloud-save-credential')),
          findsNothing,
        );
        expect(find.text('账号备注'), findsNothing);
        expect(c.cloud.credentials, hasLength(3));
        await tapVisible(tester, find.text('移除凭证'));
        await tapVisible(tester, find.text('返回'));
        expect(c.cloud.credentialFor(provider), isNotNull);
        expect(find.byType(TextFormField), findsNothing);
        await tapVisible(tester, find.text('移除凭证'));
        await tapVisible(tester, find.text('移除'));
        expect(c.cloud.credentialFor(provider), isNull);
        expect(c.cloud.credentials, hasLength(2));
        expect(find.text('已从本机移除凭证。'), findsOneWidget);
        expect(find.text('移除凭证'), findsNothing);
        expect(find.text('联网验证并保存'), findsOneWidget);
        expect(find.byType(TextFormField), findsNWidgets(2));
        for (final key in ['cloud-key-id', 'cloud-key-secret']) {
          expect(
            tester
                .widget<TextFormField>(find.byKey(ValueKey(key)))
                .controller!
                .text,
            isEmpty,
          );
        }
        expect(find.text('账号备注'), findsNothing);
        final remaining = jsonDecode(
          (c.store as MemoryStore).secrets[CloudController.workspaceKey]!,
        ) as Map;
        expect(
          (remaining['credentials'] as List).where(
            (item) => item['provider'] == provider.name,
          ),
          isEmpty,
        );
        await tester.enterText(
          find.byKey(const ValueKey('cloud-key-id')),
          'synthetic-new-id',
        );
        await tester.enterText(
          find.byKey(const ValueKey('cloud-key-secret')),
          'synthetic-new-secret',
        );
        await tapVisible(
          tester,
          find.byKey(const ValueKey('cloud-save-credential')),
        );
        expect(c.cloud.credentials, hasLength(3));
        expect(c.cloud.credentialFor(provider)!.onlineVerified, isTrue);
        expect(find.byType(TextFormField), findsNothing);
        expect(
          find.byKey(const ValueKey('cloud-save-credential')),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('failed removal keeps verified credential and inputs hidden', (
    tester,
  ) async {
    final c = await openCloudApp(tester, credentials: [CloudProvider.tencent]);
    final store = c.store as MemoryStore;
    final original = store.secrets[CloudController.workspaceKey];
    store.failWrite.add(CloudController.workspaceKey);
    await goToPage(tester, '公有云部署');
    await tapVisible(tester, find.text('移除凭证'));
    await tapVisible(tester, find.text('移除'));
    expect(find.textContaining('公有云信息无法保存'), findsOneWidget);
    expect(
      c.cloud.credentialFor(CloudProvider.tencent)!.onlineVerified,
      isTrue,
    );
    expect(store.secrets[CloudController.workspaceKey], original);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.byKey(const ValueKey('cloud-save-credential')), findsNothing);
    expect(find.text('移除凭证'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending removal shows inputs only after the deletion is saved', (
    tester,
  ) async {
    final store = CredentialWriteStore();
    final c = await openCloudApp(
      tester,
      store: store,
      credentials: [CloudProvider.tencent],
    );
    final original = store.secrets[CloudController.workspaceKey];
    final gate = Completer<void>();
    store.writeGate = gate;
    await goToPage(tester, '公有云部署');
    await tapVisible(tester, find.text('移除凭证'));
    await tapVisible(tester, find.text('移除'));
    expect(find.text('正在移除凭证'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.byKey(const ValueKey('cloud-save-credential')), findsNothing);
    expect(c.cloud.credentialFor(CloudProvider.tencent), isNotNull);
    expect(store.secrets[CloudController.workspaceKey], original);
    gate.complete();
    await tester.pumpAndSettle();
    expect(c.cloud.credentialFor(CloudProvider.tencent), isNull);
    expect(find.byType(TextFormField), findsNWidgets(2));
    expect(find.text('联网验证并保存'), findsOneWidget);
    expect(find.text('账号备注'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'previous locally checked credentials require verification before new creation',
    (tester) async {
      final store = MemoryStore();
      store.secrets[CloudController.workspaceKey] = jsonEncode({
        'version': 1,
        'credentials': [
          {
            'provider': 'tencent',
            'alias': '之前保存的凭证',
            'accessKeyId': 'synthetic-old-id',
            'accessKeySecret': 'synthetic-old-secret',
            'checkedAt': '2026-11-01T00:00:00Z',
          },
        ],
        'jobs': [],
      });
      final c = await openCloudApp(tester, store: store);
      expect(
        c.cloud.credentialFor(CloudProvider.tencent)!.onlineVerified,
        isFalse,
      );
      await goToPage(tester, '公有云部署');
      expect(find.textContaining('待联网验证，请重新提交验证'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, '去创建云服务器'),
            )
            .onPressed,
        isNull,
      );
      await openCloudCreation(tester);
      expect(find.text('验证凭证'), findsOneWidget);
      await tapVisible(tester, find.text('验证凭证'));
      expect(find.text('腾讯云凭证'), findsOneWidget);
      await tapVisible(tester, find.text('移除凭证'));
      await tapVisible(tester, find.text('移除'));
      expect(c.cloud.credentials, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Aliyun creation requires an administrator template and offers no preview',
    (tester) async {
      final c = await openCloudApp(tester, credentials: [CloudProvider.aliyun]);
      await openCloudCreation(tester);
      await tapVisible(
        tester,
        find.byKey(const ValueKey('cloud-select-provider-aliyun')),
      );
      expect(find.textContaining('管理员尚未配置阿里云模板'), findsOneWidget);
      expect(find.byKey(const ValueKey('cloud-preview-outcome')), findsNothing);
      expect(find.text('轻量起步'), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const ValueKey('cloud-confirm-create')),
            )
            .onPressed,
        isNull,
      );
      expect(c.cloud.jobs, isEmpty);
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
          credentials: [CloudProvider.aliyun],
        );
        await goToPage(tester, '公有云部署');
        await tapVisible(
          tester,
          find.byKey(const ValueKey('cloud-provider-aliyun')),
        );
        expect(find.byType(CloudCredentialsPage), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tapVisible(tester, find.text('去创建云服务器'));
        expect(find.byType(CloudCreateDialog), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tapVisible(
          tester,
          find.byKey(const ValueKey('cloud-select-provider-aliyun')),
        );
        expect(find.textContaining('管理员尚未配置阿里云模板'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const ValueKey('cloud-confirm-create')),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
