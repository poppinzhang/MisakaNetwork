// This is a generated file - do not edit.
//
// Generated from misaka/v1/sisters.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:async' as $async;
import 'dart:core' as $core;

import 'package:grpc/service_api.dart' as $grpc;
import 'package:protobuf/protobuf.dart' as $pb;

import 'sisters.pb.dart' as $0;

export 'sisters.pb.dart';

/// All calls require mutual TLS. Cookie and configuration fields are write-only.
@$pb.GrpcServiceName('misaka.v1.Sisters')
class SistersClient extends $grpc.Client {
  /// The hostname for this service.
  static const $core.String defaultHost = '';

  /// OAuth scopes needed for the client.
  static const $core.List<$core.String> oauthScopes = [
    '',
  ];

  SistersClient(super.channel, {super.options, super.interceptors});

  $grpc.ResponseFuture<$0.AgentStatus> getStatus(
    $0.Empty request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$getStatus, request, options: options);
  }

  $grpc.ResponseFuture<$0.TaskStatus> submitTask(
    $0.TaskRequest request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$submitTask, request, options: options);
  }

  $grpc.ResponseFuture<$0.TaskStatus> cancelTask(
    $0.TaskId request, {
    $grpc.CallOptions? options,
  }) {
    return $createUnaryCall(_$cancelTask, request, options: options);
  }

  // method descriptors

  static final _$getStatus = $grpc.ClientMethod<$0.Empty, $0.AgentStatus>(
      '/misaka.v1.Sisters/GetStatus',
      ($0.Empty value) => value.writeToBuffer(),
      $0.AgentStatus.fromBuffer);
  static final _$submitTask = $grpc.ClientMethod<$0.TaskRequest, $0.TaskStatus>(
      '/misaka.v1.Sisters/SubmitTask',
      ($0.TaskRequest value) => value.writeToBuffer(),
      $0.TaskStatus.fromBuffer);
  static final _$cancelTask = $grpc.ClientMethod<$0.TaskId, $0.TaskStatus>(
      '/misaka.v1.Sisters/CancelTask',
      ($0.TaskId value) => value.writeToBuffer(),
      $0.TaskStatus.fromBuffer);
}

@$pb.GrpcServiceName('misaka.v1.Sisters')
abstract class SistersServiceBase extends $grpc.Service {
  $core.String get $name => 'misaka.v1.Sisters';

  SistersServiceBase() {
    $addMethod($grpc.ServiceMethod<$0.Empty, $0.AgentStatus>(
        'GetStatus',
        getStatus_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.Empty.fromBuffer(value),
        ($0.AgentStatus value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.TaskRequest, $0.TaskStatus>(
        'SubmitTask',
        submitTask_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.TaskRequest.fromBuffer(value),
        ($0.TaskStatus value) => value.writeToBuffer()));
    $addMethod($grpc.ServiceMethod<$0.TaskId, $0.TaskStatus>(
        'CancelTask',
        cancelTask_Pre,
        false,
        false,
        ($core.List<$core.int> value) => $0.TaskId.fromBuffer(value),
        ($0.TaskStatus value) => value.writeToBuffer()));
  }

  $async.Future<$0.AgentStatus> getStatus_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.Empty> $request) async {
    return getStatus($call, await $request);
  }

  $async.Future<$0.AgentStatus> getStatus(
      $grpc.ServiceCall call, $0.Empty request);

  $async.Future<$0.TaskStatus> submitTask_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.TaskRequest> $request) async {
    return submitTask($call, await $request);
  }

  $async.Future<$0.TaskStatus> submitTask(
      $grpc.ServiceCall call, $0.TaskRequest request);

  $async.Future<$0.TaskStatus> cancelTask_Pre(
      $grpc.ServiceCall $call, $async.Future<$0.TaskId> $request) async {
    return cancelTask($call, await $request);
  }

  $async.Future<$0.TaskStatus> cancelTask(
      $grpc.ServiceCall call, $0.TaskId request);
}
