import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'desktop notification channel rejects incomplete requests before delivery',
    (tester) async {
      const channel = MethodChannel('misaka/notifications');
      for (final field in ['id', 'title', 'body']) {
        final arguments = {'id': 'test', 'title': 'Test', 'body': 'Test'}
          ..remove(field);
        await expectLater(
          channel.invokeMethod<bool>('showSuccess', arguments),
          throwsA(
            isA<PlatformException>().having(
              (error) => error.code,
              'code',
              'invalid_arguments',
            ),
          ),
        );
      }
    },
    skip: !Platform.isMacOS && !Platform.isWindows,
  );
}
