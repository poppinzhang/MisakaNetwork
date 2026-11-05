// This is a generated file - do not edit.
//
// Generated from misaka/v1/sisters.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports
// ignore_for_file: unused_import

import 'dart:convert' as $convert;
import 'dart:core' as $core;
import 'dart:typed_data' as $typed_data;

@$core.Deprecated('Use taskStateDescriptor instead')
const TaskState$json = {
  '1': 'TaskState',
  '2': [
    {'1': 'TASK_STATE_UNSPECIFIED', '2': 0},
    {'1': 'TASK_STATE_QUEUED', '2': 1},
    {'1': 'TASK_STATE_RUNNING', '2': 2},
    {'1': 'TASK_STATE_SUCCEEDED', '2': 3},
    {'1': 'TASK_STATE_FAILED', '2': 4},
    {'1': 'TASK_STATE_CANCELLED', '2': 5},
  ],
};

/// Descriptor for `TaskState`. Decode as a `google.protobuf.EnumDescriptorProto`.
final $typed_data.Uint8List taskStateDescriptor = $convert.base64Decode(
    'CglUYXNrU3RhdGUSGgoWVEFTS19TVEFURV9VTlNQRUNJRklFRBAAEhUKEVRBU0tfU1RBVEVfUV'
    'VFVUVEEAESFgoSVEFTS19TVEFURV9SVU5OSU5HEAISGAoUVEFTS19TVEFURV9TVUNDRUVERUQQ'
    'AxIVChFUQVNLX1NUQVRFX0ZBSUxFRBAEEhgKFFRBU0tfU1RBVEVfQ0FOQ0VMTEVEEAU=');

@$core.Deprecated('Use emptyDescriptor instead')
const Empty$json = {
  '1': 'Empty',
};

/// Descriptor for `Empty`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List emptyDescriptor =
    $convert.base64Decode('CgVFbXB0eQ==');

@$core.Deprecated('Use taskIdDescriptor instead')
const TaskId$json = {
  '1': 'TaskId',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
  ],
};

/// Descriptor for `TaskId`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taskIdDescriptor =
    $convert.base64Decode('CgZUYXNrSWQSDgoCaWQYASABKAlSAmlk');

@$core.Deprecated('Use taskRequestDescriptor instead')
const TaskRequest$json = {
  '1': 'TaskRequest',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {'1': 'cookie_json', '3': 3, '4': 1, '5': 9, '10': 'cookieJson'},
    {'1': 'config_json', '3': 4, '4': 1, '5': 9, '10': 'configJson'},
    {'1': 'time_start', '3': 5, '4': 1, '5': 9, '10': 'timeStart'},
  ],
};

/// Descriptor for `TaskRequest`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taskRequestDescriptor = $convert.base64Decode(
    'CgtUYXNrUmVxdWVzdBIOCgJpZBgBIAEoCVICaWQSEgoEbmFtZRgCIAEoCVIEbmFtZRIfCgtjb2'
    '9raWVfanNvbhgDIAEoCVIKY29va2llSnNvbhIfCgtjb25maWdfanNvbhgEIAEoCVIKY29uZmln'
    'SnNvbhIdCgp0aW1lX3N0YXJ0GAUgASgJUgl0aW1lU3RhcnQ=');

@$core.Deprecated('Use taskEventDescriptor instead')
const TaskEvent$json = {
  '1': 'TaskEvent',
  '2': [
    {'1': 'timestamp_unix_ms', '3': 1, '4': 1, '5': 3, '10': 'timestampUnixMs'},
    {'1': 'level', '3': 2, '4': 1, '5': 9, '10': 'level'},
    {'1': 'message', '3': 3, '4': 1, '5': 9, '10': 'message'},
  ],
};

/// Descriptor for `TaskEvent`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taskEventDescriptor = $convert.base64Decode(
    'CglUYXNrRXZlbnQSKgoRdGltZXN0YW1wX3VuaXhfbXMYASABKANSD3RpbWVzdGFtcFVuaXhNcx'
    'IUCgVsZXZlbBgCIAEoCVIFbGV2ZWwSGAoHbWVzc2FnZRgDIAEoCVIHbWVzc2FnZQ==');

@$core.Deprecated('Use taskStatusDescriptor instead')
const TaskStatus$json = {
  '1': 'TaskStatus',
  '2': [
    {'1': 'id', '3': 1, '4': 1, '5': 9, '10': 'id'},
    {'1': 'name', '3': 2, '4': 1, '5': 9, '10': 'name'},
    {
      '1': 'state',
      '3': 3,
      '4': 1,
      '5': 14,
      '6': '.misaka.v1.TaskState',
      '10': 'state'
    },
    {'1': 'message', '3': 4, '4': 1, '5': 9, '10': 'message'},
    {'1': 'updated_unix_ms', '3': 5, '4': 1, '5': 3, '10': 'updatedUnixMs'},
    {
      '1': 'events',
      '3': 6,
      '4': 3,
      '5': 11,
      '6': '.misaka.v1.TaskEvent',
      '10': 'events'
    },
  ],
};

/// Descriptor for `TaskStatus`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List taskStatusDescriptor = $convert.base64Decode(
    'CgpUYXNrU3RhdHVzEg4KAmlkGAEgASgJUgJpZBISCgRuYW1lGAIgASgJUgRuYW1lEioKBXN0YX'
    'RlGAMgASgOMhQubWlzYWthLnYxLlRhc2tTdGF0ZVIFc3RhdGUSGAoHbWVzc2FnZRgEIAEoCVIH'
    'bWVzc2FnZRImCg91cGRhdGVkX3VuaXhfbXMYBSABKANSDXVwZGF0ZWRVbml4TXMSLAoGZXZlbn'
    'RzGAYgAygLMhQubWlzYWthLnYxLlRhc2tFdmVudFIGZXZlbnRz');

@$core.Deprecated('Use agentStatusDescriptor instead')
const AgentStatus$json = {
  '1': 'AgentStatus',
  '2': [
    {'1': 'version', '3': 1, '4': 1, '5': 9, '10': 'version'},
    {'1': 'bili_version', '3': 2, '4': 1, '5': 9, '10': 'biliVersion'},
    {'1': 'platform', '3': 3, '4': 1, '5': 9, '10': 'platform'},
    {'1': 'started_unix_ms', '3': 4, '4': 1, '5': 3, '10': 'startedUnixMs'},
    {
      '1': 'tasks',
      '3': 5,
      '4': 3,
      '5': 11,
      '6': '.misaka.v1.TaskStatus',
      '10': 'tasks'
    },
    {'1': 'max_concurrency', '3': 6, '4': 1, '5': 5, '10': 'maxConcurrency'},
    {'1': 'runtime_ready', '3': 7, '4': 1, '5': 8, '10': 'runtimeReady'},
    {
      '1': 'supports_time_start',
      '3': 8,
      '4': 1,
      '5': 8,
      '10': 'supportsTimeStart'
    },
  ],
};

/// Descriptor for `AgentStatus`. Decode as a `google.protobuf.DescriptorProto`.
final $typed_data.Uint8List agentStatusDescriptor = $convert.base64Decode(
    'CgtBZ2VudFN0YXR1cxIYCgd2ZXJzaW9uGAEgASgJUgd2ZXJzaW9uEiEKDGJpbGlfdmVyc2lvbh'
    'gCIAEoCVILYmlsaVZlcnNpb24SGgoIcGxhdGZvcm0YAyABKAlSCHBsYXRmb3JtEiYKD3N0YXJ0'
    'ZWRfdW5peF9tcxgEIAEoA1INc3RhcnRlZFVuaXhNcxIrCgV0YXNrcxgFIAMoCzIVLm1pc2FrYS'
    '52MS5UYXNrU3RhdHVzUgV0YXNrcxInCg9tYXhfY29uY3VycmVuY3kYBiABKAVSDm1heENvbmN1'
    'cnJlbmN5EiMKDXJ1bnRpbWVfcmVhZHkYByABKAhSDHJ1bnRpbWVSZWFkeRIuChNzdXBwb3J0c1'
    '90aW1lX3N0YXJ0GAggASgIUhFzdXBwb3J0c1RpbWVTdGFydA==');
