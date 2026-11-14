import 'dart:async';
import 'dart:io';

import 'package:last_order/src/controller.dart';
import 'package:last_order/src/models.dart';
import 'package:last_order/src/services.dart';
import 'package:last_order/generated/misaka/v1/sisters.pbgrpc.dart';

// Synthetic one-pixel PNG for widget transport, not QR scan validity.
const testQrStart = {
  'qrcode_key': 'test-qr',
  'qr_png_base64': 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgYGAAAAAEAAH2FzhVAAAAAElFTkSuQmCC',
};

class MemoryStore implements StateStore {
  SavedState state = SavedState();
  final secrets = <String, String>{};
  bool failSave = false, failLoad = false;
  Future<void> Function(String)? beforeRead;
  Future<void> Function(SavedState)? beforeSave;
  final failRead = <String>{},
      failWrite = <String>{},
      failDelete = <String>{},
      silentDelete = <String>{};
  @override
  Future<SavedState> load() async {
    if (failLoad) throw const UserError('配置无法读取');
    return state;
  }

  @override
  Future<void> save(SavedState value) async {
    await beforeSave?.call(value);
    if (failSave) throw const UserError('写入失败');
    state = SavedState.decode(value.encode());
  }

  @override
  Future<String?> readSecret(String key) async {
    await beforeRead?.call(key);
    if (failRead.contains(key)) throw const UserError('读取失败');
    return secrets[key];
  }

  @override
  Future<void> writeSecret(String key, String value) async {
    if (failWrite.contains(key)) throw const UserError('写入失败');
    secrets[key] = value;
  }

  @override
  Future<void> deleteSecret(String key) async {
    if (failDelete.contains(key)) throw const UserError('删除失败');
    if (!silentDelete.contains(key)) secrets.remove(key);
  }

  @override
  Future<String> directory() async => '/tmp/misaka-test';

  final pruned = <Set<String>>[];
  bool failPrune = false;
  @override
  Future<void> pruneCredentials(Set<String> keep) async {
    if (failPrune) throw const FileSystemException('清理失败');
    pruned.add(keep);
  }
}

class FakeGateway implements AgentGateway {
  final fail = <String>{};
  final submitted = <String, TaskRequest>{};
  final cancelled = <String>[];
  final remoteTasks = <TaskStatus>[];
  TaskState submitState = TaskState.TASK_STATE_QUEUED;
  bool timeStartSupported = true;
  bool requestIntervalSupported = true;
  final statusRequests = <Machine>[];
  Future<AgentStatus> Function(Machine)? statusHandler;
  @override
  Future<AgentStatus> status(Machine m) async {
    statusRequests.add(m);
    if (statusHandler != null) return statusHandler!(m);
    if (fail.contains(m.id)) throw const UserError('连接失败');
    return AgentStatus(
      version: '0.4.0',
      runtimeReady: true,
      platform: 'linux/arm64',
      maxConcurrency: 2,
      tasks: remoteTasks,
      supportsTimeStart: timeStartSupported,
      supportsRequestInterval: requestIntervalSupported,
    );
  }

  @override
  Future<TaskStatus> submit(Machine m, TaskRequest t) async {
    if (fail.contains(m.id)) throw const UserError('提交失败');
    submitted[m.id] = t;
    return TaskStatus(id: t.id, state: submitState);
  }

  @override
  Future<TaskStatus> cancel(Machine m, String id) async {
    cancelled.add('${m.id}:$id');
    return TaskStatus(id: id, state: TaskState.TASK_STATE_CANCELLED);
  }
}

class FakeRuntime implements RuntimeBridge {
  bool valid = true;
  final responses = <String, Map<String, dynamic>>{};
  final calls = <String>[];
  final parameters = <Map<String, dynamic>>[];
  Future<Map<String, dynamic>> Function(String, Map<String, dynamic>)? handler;
  @override
  Future<Map<String, dynamic>> call(
    String op,
    Map<String, dynamic> params,
  ) async {
    calls.add(op);
    parameters.add(params);
    if (handler != null) return handler!(op, params);
    return responses[op] ??
        (op == 'login_state'
            ? {
                'status': 'valid',
                'logged_in': true,
                'username': '测试账号',
                'uid': '123',
              }
            : null) ??
        (op == 'validate'
            ? {
                'ok': valid,
                'errors': valid ? [] : ['票档无效'],
              }
            : {'logged_in': false});
  }
}

class FakeHelper implements DeploymentHelper {
  bool cloudSshReady = false;
  final requests = <Map<String, dynamic>>[];
  Future<void>? deployGate;
  bool failDeploy = false;
  bool? reachable;
  Future<Map<String, dynamic>> Function(
    Map<String, dynamic>,
    void Function(DeploymentProgress)?,
  )?
  handler;
  final progressCallbacks = <String, void Function(DeploymentProgress)>{};
  @override
  Future<Map<String, dynamic>> call(
    Map<String, dynamic> request, {
    void Function(DeploymentProgress)? onProgress,
  }) async {
    if (request['action'] == 'generate_cloud_ssh_key' && handler == null) {
      if (!cloudSshReady) return {};
      // Synthetic fixture only; deployment tests do not exercise cryptography.
      return {
        'private_key': '-----BEGIN RSA PRIVATE KEY-----\nTEST ONLY\n-----END RSA PRIVATE KEY-----',
        'public_key': 'ssh-rsa TEST-ONLY',
        'fingerprint': 'SHA256:TEST-ONLY',
      };
    }
    requests.add(request);
    if (onProgress != null && request['host'] is String) {
      progressCallbacks[request['host'] as String] = onProgress;
    }
    if (handler != null) return handler!(request, onProgress);
    if (request['action'] == 'verify_cloud_credential') {
      return {
        'verified': true,
        'provider': (request['cloud_credential'] as Map)['provider'],
      };
    }
    if (request['action'] == 'deploy') {
      await deployGate;
      if (failDeploy) throw const UserError('部署失败');
    }
    return {
      'ca_cert': 'ca',
      'client_cert': 'cert',
      'client_key': 'key',
      if (reachable != null) 'reachable': reachable,
    };
  }
}

Machine machine(String id) => Machine(
  id: id,
  name: '节点 $id',
  host: 'node.example',
  caCert: 'ca',
  clientCert: 'cert',
  clientKey: 'key',
);
AppController controller({
  MemoryStore? store,
  FakeGateway? gateway,
  FakeRuntime? runtime,
  FakeHelper? helper,
}) => AppController(
  store: store ?? MemoryStore(),
  gateway: gateway ?? FakeGateway(),
  runtime: runtime ?? FakeRuntime(),
  helper: helper ?? FakeHelper(),
  cloudTemplateLoader: () async => [],
);
