// This is a generated file - do not edit.
//
// Generated from misaka/v1/sisters.proto.

// @dart = 3.3

// ignore_for_file: annotate_overrides, camel_case_types, comment_references
// ignore_for_file: constant_identifier_names
// ignore_for_file: curly_braces_in_flow_control_structures
// ignore_for_file: deprecated_member_use_from_same_package, library_prefixes
// ignore_for_file: non_constant_identifier_names, prefer_relative_imports

import 'dart:core' as $core;

import 'package:protobuf/protobuf.dart' as $pb;

class TaskState extends $pb.ProtobufEnum {
  static const TaskState TASK_STATE_UNSPECIFIED =
      TaskState._(0, _omitEnumNames ? '' : 'TASK_STATE_UNSPECIFIED');
  static const TaskState TASK_STATE_QUEUED =
      TaskState._(1, _omitEnumNames ? '' : 'TASK_STATE_QUEUED');
  static const TaskState TASK_STATE_RUNNING =
      TaskState._(2, _omitEnumNames ? '' : 'TASK_STATE_RUNNING');
  static const TaskState TASK_STATE_SUCCEEDED =
      TaskState._(3, _omitEnumNames ? '' : 'TASK_STATE_SUCCEEDED');
  static const TaskState TASK_STATE_FAILED =
      TaskState._(4, _omitEnumNames ? '' : 'TASK_STATE_FAILED');
  static const TaskState TASK_STATE_CANCELLED =
      TaskState._(5, _omitEnumNames ? '' : 'TASK_STATE_CANCELLED');

  static const $core.List<TaskState> values = <TaskState>[
    TASK_STATE_UNSPECIFIED,
    TASK_STATE_QUEUED,
    TASK_STATE_RUNNING,
    TASK_STATE_SUCCEEDED,
    TASK_STATE_FAILED,
    TASK_STATE_CANCELLED,
  ];

  static final $core.List<TaskState?> _byValue =
      $pb.ProtobufEnum.$_initByValueList(values, 5);
  static TaskState? valueOf($core.int value) =>
      value < 0 || value >= _byValue.length ? null : _byValue[value];

  const TaskState._(super.value, super.name);
}

const $core.bool _omitEnumNames =
    $core.bool.fromEnvironment('protobuf.omit_enum_names');
