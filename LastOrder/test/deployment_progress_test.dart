import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/services.dart';

Future<void> noProtection(String path, String mode) async {}

void main() {
  test('progress decoder accepts only known stages and their ranges', () {
    expect(
      DeploymentProgress.decode({'percent': 42, 'stage': '上传并解压安装包'})?.percent,
      42,
    );
    for (final value in [
      null,
      [],
      {'percent': 50.0, 'stage': '上传并解压安装包'},
      {'percent': 101, 'stage': '部署完成'},
      {'percent': 50, 'stage': 'synthetic-private-output'},
      {'percent': 100, 'stage': '上传并解压安装包'},
    ]) {
      expect(DeploymentProgress.decode(value), isNull);
    }
  });

  test(
    'progress is delivered while helper is running and cleaned on success',
    () async {
      final updates = <DeploymentProgress>[];
      final gate = Completer<Map<String, dynamic>>();
      final started = Completer<File>();
      final request = {'action': 'deploy', 'password': 'synthetic-secret'};
      final result = trackDeploymentProgress(request, updates.add, (fields) {
        expect(fields['password'], 'synthetic-secret');
        started.complete(File(fields['progress_path'] as String));
        return gate.future;
      }, protect: noProtection);
      final file = await started.future;
      await file.writeAsString(
        jsonEncode({'percent': 45, 'stage': '上传并解压安装包'}),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(updates.map((e) => e.percent), [45]);
      expect(gate.isCompleted, isFalse);
      await file.writeAsString(jsonEncode({'percent': 100, 'stage': '部署完成'}));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(updates.map((e) => e.percent), [45]);
      gate.complete({'reachable': true});
      expect(await result, {'reachable': true});
      expect(updates.map((e) => e.percent), [45, 100]);
      expect(await file.parent.exists(), isFalse);
      expect(request.containsKey('progress_path'), isFalse);
    },
  );

  test('partial invalid and regressing snapshots are ignored', () async {
    final updates = <DeploymentProgress>[];
    await trackDeploymentProgress({'action': 'deploy'}, updates.add, (
      request,
    ) async {
      final file = File(request['progress_path'] as String);
      for (final data in [
        '{',
        'x' * 2048,
        jsonEncode({'percent': 55, 'stage': 'synthetic-private-output'}),
        jsonEncode({'percent': 55, 'stage': '上传并解压安装包'}),
        jsonEncode({'percent': 40, 'stage': '上传并解压安装包'}),
      ]) {
        await file.writeAsString(data);
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return {'needs_confirmation': true, 'fingerprint': 'SHA256:synthetic'};
    }, protect: noProtection);
    expect(updates.map((e) => e.percent), [55]);
  });

  test('failed helper never reports completion and stops polling', () async {
    final updates = <DeploymentProgress>[];
    late File file;
    await expectLater(
      trackDeploymentProgress({'action': 'deploy'}, updates.add, (
        request,
      ) async {
        file = File(request['progress_path'] as String);
        await file.writeAsString(jsonEncode({'percent': 100, 'stage': '部署完成'}));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        throw const UserError('部署失败');
      }, protect: noProtection),
      throwsA(isA<UserError>()),
    );
    expect(updates, isEmpty);
    expect(await file.parent.exists(), isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(updates, isEmpty);
  });

  test('parallel deployments use independent progress directories', () async {
    final started = [Completer<File>(), Completer<File>()];
    final gates = [
      Completer<Map<String, dynamic>>(),
      Completer<Map<String, dynamic>>(),
    ];
    final updates = [<DeploymentProgress>[], <DeploymentProgress>[]];
    final operations = [
      for (var i = 0; i < 2; i++)
        trackDeploymentProgress({'action': 'deploy'}, updates[i].add, (
          request,
        ) {
          started[i].complete(File(request['progress_path'] as String));
          return gates[i].future;
        }, protect: noProtection),
    ];
    final files = await Future.wait(started.map((e) => e.future));
    expect(files[0].path, isNot(files[1].path));
    await files[0].writeAsString(
      jsonEncode({'percent': 30, 'stage': '上传并解压安装包'}),
    );
    await files[1].writeAsString(
      jsonEncode({'percent': 70, 'stage': '上传并解压安装包'}),
    );
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(updates[0].single.percent, 30);
    expect(updates[1].single.percent, 70);
    for (final gate in gates) {
      gate.complete({'reachable': true});
    }
    await Future.wait(operations);
    for (final file in files) {
      expect(await file.parent.exists(), isFalse);
    }
  });
}
