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

import 'package:fixnum/fixnum.dart' as $fixnum;
import 'package:protobuf/protobuf.dart' as $pb;

import 'sisters.pbenum.dart';

export 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

export 'sisters.pbenum.dart';

class Empty extends $pb.GeneratedMessage {
  factory Empty() => Empty._();

  Empty._();

  factory Empty.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Empty()..mergeFromBuffer(data, registry);
  factory Empty.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      Empty()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'Empty',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'misaka.v1'),
      createEmptyInstance: Empty.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Empty clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  Empty copyWith(void Function(Empty) updates) =>
      super.copyWith((message) => updates(message as Empty)) as Empty;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use Empty() / Empty.new instead')
  static Empty create() => Empty._();
  static $pb.GeneratedMessage $_createMessage() => Empty._();
  @$core.override
  Empty createEmptyInstance() => Empty._();
  @$core.pragma('dart2js:noInline')
  static Empty getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<Empty>(Empty.$_createMessage);
  static Empty? _defaultInstance;
}

class TaskId extends $pb.GeneratedMessage {
  factory TaskId({
    $core.String? id,
  }) {
    final result = TaskId._();
    if (id != null) result.id = id;
    return result;
  }

  TaskId._();

  factory TaskId.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TaskId()..mergeFromBuffer(data, registry);
  factory TaskId.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TaskId()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TaskId',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'misaka.v1'),
      createEmptyInstance: TaskId.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TaskId clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TaskId copyWith(void Function(TaskId) updates) =>
      super.copyWith((message) => updates(message as TaskId)) as TaskId;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use TaskId() / TaskId.new instead')
  static TaskId create() => TaskId._();
  static $pb.GeneratedMessage $_createMessage() => TaskId._();
  @$core.override
  TaskId createEmptyInstance() => TaskId._();
  @$core.pragma('dart2js:noInline')
  static TaskId getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TaskId>(TaskId.$_createMessage);
  static TaskId? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);
}

class TaskRequest extends $pb.GeneratedMessage {
  factory TaskRequest({
    $core.String? id,
    $core.String? name,
    $core.String? cookieJson,
    $core.String? configJson,
    $core.String? timeStart,
  }) {
    final result = TaskRequest._();
    if (id != null) result.id = id;
    if (name != null) result.name = name;
    if (cookieJson != null) result.cookieJson = cookieJson;
    if (configJson != null) result.configJson = configJson;
    if (timeStart != null) result.timeStart = timeStart;
    return result;
  }

  TaskRequest._();

  factory TaskRequest.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TaskRequest()..mergeFromBuffer(data, registry);
  factory TaskRequest.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TaskRequest()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TaskRequest',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'misaka.v1'),
      createEmptyInstance: TaskRequest.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aOS(3, _omitFieldNames ? '' : 'cookieJson')
    ..aOS(4, _omitFieldNames ? '' : 'configJson')
    ..aOS(5, _omitFieldNames ? '' : 'timeStart')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TaskRequest clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TaskRequest copyWith(void Function(TaskRequest) updates) =>
      super.copyWith((message) => updates(message as TaskRequest))
          as TaskRequest;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use TaskRequest() / TaskRequest.new instead')
  static TaskRequest create() => TaskRequest._();
  static $pb.GeneratedMessage $_createMessage() => TaskRequest._();
  @$core.override
  TaskRequest createEmptyInstance() => TaskRequest._();
  @$core.pragma('dart2js:noInline')
  static TaskRequest getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<TaskRequest>(
          TaskRequest.$_createMessage);
  static TaskRequest? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get cookieJson => $_getSZ(2);
  @$pb.TagNumber(3)
  set cookieJson($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasCookieJson() => $_has(2);
  @$pb.TagNumber(3)
  void clearCookieJson() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get configJson => $_getSZ(3);
  @$pb.TagNumber(4)
  set configJson($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasConfigJson() => $_has(3);
  @$pb.TagNumber(4)
  void clearConfigJson() => $_clearField(4);

  /// Purchase start in Beijing time (UTC+8) as YYYY-MM-DDTHH:MM:SS, whatever
  /// the agent's own time zone. Empty starts immediately after submission.
  @$pb.TagNumber(5)
  $core.String get timeStart => $_getSZ(4);
  @$pb.TagNumber(5)
  set timeStart($core.String value) => $_setString(4, value);
  @$pb.TagNumber(5)
  $core.bool hasTimeStart() => $_has(4);
  @$pb.TagNumber(5)
  void clearTimeStart() => $_clearField(5);
}

class TaskEvent extends $pb.GeneratedMessage {
  factory TaskEvent({
    $fixnum.Int64? timestampUnixMs,
    $core.String? level,
    $core.String? message,
  }) {
    final result = TaskEvent._();
    if (timestampUnixMs != null) result.timestampUnixMs = timestampUnixMs;
    if (level != null) result.level = level;
    if (message != null) result.message = message;
    return result;
  }

  TaskEvent._();

  factory TaskEvent.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TaskEvent()..mergeFromBuffer(data, registry);
  factory TaskEvent.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TaskEvent()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TaskEvent',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'misaka.v1'),
      createEmptyInstance: TaskEvent.$_createMessage)
    ..aInt64(1, _omitFieldNames ? '' : 'timestampUnixMs')
    ..aOS(2, _omitFieldNames ? '' : 'level')
    ..aOS(3, _omitFieldNames ? '' : 'message')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TaskEvent clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TaskEvent copyWith(void Function(TaskEvent) updates) =>
      super.copyWith((message) => updates(message as TaskEvent)) as TaskEvent;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use TaskEvent() / TaskEvent.new instead')
  static TaskEvent create() => TaskEvent._();
  static $pb.GeneratedMessage $_createMessage() => TaskEvent._();
  @$core.override
  TaskEvent createEmptyInstance() => TaskEvent._();
  @$core.pragma('dart2js:noInline')
  static TaskEvent getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TaskEvent>(TaskEvent.$_createMessage);
  static TaskEvent? _defaultInstance;

  @$pb.TagNumber(1)
  $fixnum.Int64 get timestampUnixMs => $_getI64(0);
  @$pb.TagNumber(1)
  set timestampUnixMs($fixnum.Int64 value) => $_setInt64(0, value);
  @$pb.TagNumber(1)
  $core.bool hasTimestampUnixMs() => $_has(0);
  @$pb.TagNumber(1)
  void clearTimestampUnixMs() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get level => $_getSZ(1);
  @$pb.TagNumber(2)
  set level($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasLevel() => $_has(1);
  @$pb.TagNumber(2)
  void clearLevel() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get message => $_getSZ(2);
  @$pb.TagNumber(3)
  set message($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasMessage() => $_has(2);
  @$pb.TagNumber(3)
  void clearMessage() => $_clearField(3);
}

/// Sensitive, in-memory payment information for a confirmed order. Never copy
/// payment URLs into task messages or events. Presence does not mean paid.
class OrderPayment extends $pb.GeneratedMessage {
  factory OrderPayment({
    $core.String? orderId,
    $core.String? orderDetailUrl,
    $core.String? paymentCodeUrl,
    $fixnum.Int64? capturedUnixMs,
  }) {
    final result = OrderPayment._();
    if (orderId != null) result.orderId = orderId;
    if (orderDetailUrl != null) result.orderDetailUrl = orderDetailUrl;
    if (paymentCodeUrl != null) result.paymentCodeUrl = paymentCodeUrl;
    if (capturedUnixMs != null) result.capturedUnixMs = capturedUnixMs;
    return result;
  }

  OrderPayment._();

  factory OrderPayment.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OrderPayment()..mergeFromBuffer(data, registry);
  factory OrderPayment.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      OrderPayment()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'OrderPayment',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'misaka.v1'),
      createEmptyInstance: OrderPayment.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'orderId')
    ..aOS(2, _omitFieldNames ? '' : 'orderDetailUrl')
    ..aOS(3, _omitFieldNames ? '' : 'paymentCodeUrl')
    ..aInt64(4, _omitFieldNames ? '' : 'capturedUnixMs')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OrderPayment clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  OrderPayment copyWith(void Function(OrderPayment) updates) =>
      super.copyWith((message) => updates(message as OrderPayment))
          as OrderPayment;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use OrderPayment() / OrderPayment.new instead')
  static OrderPayment create() => OrderPayment._();
  static $pb.GeneratedMessage $_createMessage() => OrderPayment._();
  @$core.override
  OrderPayment createEmptyInstance() => OrderPayment._();
  @$core.pragma('dart2js:noInline')
  static OrderPayment getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<OrderPayment>(
          OrderPayment.$_createMessage);
  static OrderPayment? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get orderId => $_getSZ(0);
  @$pb.TagNumber(1)
  set orderId($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasOrderId() => $_has(0);
  @$pb.TagNumber(1)
  void clearOrderId() => $_clearField(1);

  /// Canonical Bilibili order page, derived from the validated order ID.
  @$pb.TagNumber(2)
  $core.String get orderDetailUrl => $_getSZ(1);
  @$pb.TagNumber(2)
  set orderDetailUrl($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasOrderDetailUrl() => $_has(1);
  @$pb.TagNumber(2)
  void clearOrderDetailUrl() => $_clearField(2);

  /// Validated QR content, not an image URL. Empty falls back to the order page.
  @$pb.TagNumber(3)
  $core.String get paymentCodeUrl => $_getSZ(2);
  @$pb.TagNumber(3)
  set paymentCodeUrl($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPaymentCodeUrl() => $_has(2);
  @$pb.TagNumber(3)
  void clearPaymentCodeUrl() => $_clearField(3);

  /// Time Sisters received the final result; not a payment expiry timestamp.
  @$pb.TagNumber(4)
  $fixnum.Int64 get capturedUnixMs => $_getI64(3);
  @$pb.TagNumber(4)
  set capturedUnixMs($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasCapturedUnixMs() => $_has(3);
  @$pb.TagNumber(4)
  void clearCapturedUnixMs() => $_clearField(4);
}

class TaskStatus extends $pb.GeneratedMessage {
  factory TaskStatus({
    $core.String? id,
    $core.String? name,
    TaskState? state,
    $core.String? message,
    $fixnum.Int64? updatedUnixMs,
    $core.Iterable<TaskEvent>? events,
    OrderPayment? payment,
  }) {
    final result = TaskStatus._();
    if (id != null) result.id = id;
    if (name != null) result.name = name;
    if (state != null) result.state = state;
    if (message != null) result.message = message;
    if (updatedUnixMs != null) result.updatedUnixMs = updatedUnixMs;
    if (events != null) result.events.addAll(events);
    if (payment != null) result.payment = payment;
    return result;
  }

  TaskStatus._();

  factory TaskStatus.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TaskStatus()..mergeFromBuffer(data, registry);
  factory TaskStatus.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      TaskStatus()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'TaskStatus',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'misaka.v1'),
      createEmptyInstance: TaskStatus.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'id')
    ..aOS(2, _omitFieldNames ? '' : 'name')
    ..aE<TaskState>(3, _omitFieldNames ? '' : 'state',
        enumValues: TaskState.values)
    ..aOS(4, _omitFieldNames ? '' : 'message')
    ..aInt64(5, _omitFieldNames ? '' : 'updatedUnixMs')
    ..pPM<TaskEvent>(6, _omitFieldNames ? '' : 'events',
        subBuilder: TaskEvent.$_createMessage)
    ..aOM<OrderPayment>(7, _omitFieldNames ? '' : 'payment',
        subBuilder: OrderPayment.$_createMessage)
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TaskStatus clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  TaskStatus copyWith(void Function(TaskStatus) updates) =>
      super.copyWith((message) => updates(message as TaskStatus)) as TaskStatus;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use TaskStatus() / TaskStatus.new instead')
  static TaskStatus create() => TaskStatus._();
  static $pb.GeneratedMessage $_createMessage() => TaskStatus._();
  @$core.override
  TaskStatus createEmptyInstance() => TaskStatus._();
  @$core.pragma('dart2js:noInline')
  static TaskStatus getDefault() => _defaultInstance ??=
      $pb.GeneratedMessage.$_defaultFor<TaskStatus>(TaskStatus.$_createMessage);
  static TaskStatus? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get id => $_getSZ(0);
  @$pb.TagNumber(1)
  set id($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasId() => $_has(0);
  @$pb.TagNumber(1)
  void clearId() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get name => $_getSZ(1);
  @$pb.TagNumber(2)
  set name($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasName() => $_has(1);
  @$pb.TagNumber(2)
  void clearName() => $_clearField(2);

  @$pb.TagNumber(3)
  TaskState get state => $_getN(2);
  @$pb.TagNumber(3)
  set state(TaskState value) => $_setField(3, value);
  @$pb.TagNumber(3)
  $core.bool hasState() => $_has(2);
  @$pb.TagNumber(3)
  void clearState() => $_clearField(3);

  @$pb.TagNumber(4)
  $core.String get message => $_getSZ(3);
  @$pb.TagNumber(4)
  set message($core.String value) => $_setString(3, value);
  @$pb.TagNumber(4)
  $core.bool hasMessage() => $_has(3);
  @$pb.TagNumber(4)
  void clearMessage() => $_clearField(4);

  @$pb.TagNumber(5)
  $fixnum.Int64 get updatedUnixMs => $_getI64(4);
  @$pb.TagNumber(5)
  set updatedUnixMs($fixnum.Int64 value) => $_setInt64(4, value);
  @$pb.TagNumber(5)
  $core.bool hasUpdatedUnixMs() => $_has(4);
  @$pb.TagNumber(5)
  void clearUpdatedUnixMs() => $_clearField(5);

  @$pb.TagNumber(6)
  $pb.PbList<TaskEvent> get events => $_getList(5);

  @$pb.TagNumber(7)
  OrderPayment get payment => $_getN(6);
  @$pb.TagNumber(7)
  set payment(OrderPayment value) => $_setField(7, value);
  @$pb.TagNumber(7)
  $core.bool hasPayment() => $_has(6);
  @$pb.TagNumber(7)
  void clearPayment() => $_clearField(7);
  @$pb.TagNumber(7)
  OrderPayment ensurePayment() => $_ensure(6);
}

class AgentStatus extends $pb.GeneratedMessage {
  factory AgentStatus({
    $core.String? version,
    $core.String? biliVersion,
    $core.String? platform,
    $fixnum.Int64? startedUnixMs,
    $core.Iterable<TaskStatus>? tasks,
    $core.int? maxConcurrency,
    $core.bool? runtimeReady,
    $core.bool? supportsTimeStart,
  }) {
    final result = AgentStatus._();
    if (version != null) result.version = version;
    if (biliVersion != null) result.biliVersion = biliVersion;
    if (platform != null) result.platform = platform;
    if (startedUnixMs != null) result.startedUnixMs = startedUnixMs;
    if (tasks != null) result.tasks.addAll(tasks);
    if (maxConcurrency != null) result.maxConcurrency = maxConcurrency;
    if (runtimeReady != null) result.runtimeReady = runtimeReady;
    if (supportsTimeStart != null) result.supportsTimeStart = supportsTimeStart;
    return result;
  }

  AgentStatus._();

  factory AgentStatus.fromBuffer($core.List<$core.int> data,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AgentStatus()..mergeFromBuffer(data, registry);
  factory AgentStatus.fromJson($core.String json,
          [$pb.ExtensionRegistry registry = $pb.ExtensionRegistry.EMPTY]) =>
      AgentStatus()..mergeFromJson(json, registry);

  static final $pb.BuilderInfo _i = $pb.BuilderInfo(
      _omitMessageNames ? '' : 'AgentStatus',
      package: const $pb.PackageName(_omitMessageNames ? '' : 'misaka.v1'),
      createEmptyInstance: AgentStatus.$_createMessage)
    ..aOS(1, _omitFieldNames ? '' : 'version')
    ..aOS(2, _omitFieldNames ? '' : 'biliVersion')
    ..aOS(3, _omitFieldNames ? '' : 'platform')
    ..aInt64(4, _omitFieldNames ? '' : 'startedUnixMs')
    ..pPM<TaskStatus>(5, _omitFieldNames ? '' : 'tasks',
        subBuilder: TaskStatus.$_createMessage)
    ..aI(6, _omitFieldNames ? '' : 'maxConcurrency')
    ..aOB(7, _omitFieldNames ? '' : 'runtimeReady')
    ..aOB(8, _omitFieldNames ? '' : 'supportsTimeStart')
    ..hasRequiredFields = false;

  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AgentStatus clone() => deepCopy();
  @$core.Deprecated('See https://github.com/google/protobuf.dart/issues/998.')
  AgentStatus copyWith(void Function(AgentStatus) updates) =>
      super.copyWith((message) => updates(message as AgentStatus))
          as AgentStatus;

  @$core.override
  $pb.BuilderInfo get info_ => _i;

  @$core.pragma('dart2js:noInline')
  @$core.Deprecated('Use AgentStatus() / AgentStatus.new instead')
  static AgentStatus create() => AgentStatus._();
  static $pb.GeneratedMessage $_createMessage() => AgentStatus._();
  @$core.override
  AgentStatus createEmptyInstance() => AgentStatus._();
  @$core.pragma('dart2js:noInline')
  static AgentStatus getDefault() =>
      _defaultInstance ??= $pb.GeneratedMessage.$_defaultFor<AgentStatus>(
          AgentStatus.$_createMessage);
  static AgentStatus? _defaultInstance;

  @$pb.TagNumber(1)
  $core.String get version => $_getSZ(0);
  @$pb.TagNumber(1)
  set version($core.String value) => $_setString(0, value);
  @$pb.TagNumber(1)
  $core.bool hasVersion() => $_has(0);
  @$pb.TagNumber(1)
  void clearVersion() => $_clearField(1);

  @$pb.TagNumber(2)
  $core.String get biliVersion => $_getSZ(1);
  @$pb.TagNumber(2)
  set biliVersion($core.String value) => $_setString(1, value);
  @$pb.TagNumber(2)
  $core.bool hasBiliVersion() => $_has(1);
  @$pb.TagNumber(2)
  void clearBiliVersion() => $_clearField(2);

  @$pb.TagNumber(3)
  $core.String get platform => $_getSZ(2);
  @$pb.TagNumber(3)
  set platform($core.String value) => $_setString(2, value);
  @$pb.TagNumber(3)
  $core.bool hasPlatform() => $_has(2);
  @$pb.TagNumber(3)
  void clearPlatform() => $_clearField(3);

  @$pb.TagNumber(4)
  $fixnum.Int64 get startedUnixMs => $_getI64(3);
  @$pb.TagNumber(4)
  set startedUnixMs($fixnum.Int64 value) => $_setInt64(3, value);
  @$pb.TagNumber(4)
  $core.bool hasStartedUnixMs() => $_has(3);
  @$pb.TagNumber(4)
  void clearStartedUnixMs() => $_clearField(4);

  @$pb.TagNumber(5)
  $pb.PbList<TaskStatus> get tasks => $_getList(4);

  @$pb.TagNumber(6)
  $core.int get maxConcurrency => $_getIZ(5);
  @$pb.TagNumber(6)
  set maxConcurrency($core.int value) => $_setSignedInt32(5, value);
  @$pb.TagNumber(6)
  $core.bool hasMaxConcurrency() => $_has(5);
  @$pb.TagNumber(6)
  void clearMaxConcurrency() => $_clearField(6);

  @$pb.TagNumber(7)
  $core.bool get runtimeReady => $_getBF(6);
  @$pb.TagNumber(7)
  set runtimeReady($core.bool value) => $_setBool(6, value);
  @$pb.TagNumber(7)
  $core.bool hasRuntimeReady() => $_has(6);
  @$pb.TagNumber(7)
  void clearRuntimeReady() => $_clearField(7);

  /// Agents without this flag ignore TaskRequest.time_start and would start a
  /// timed task immediately, so clients must not send timed tasks to them.
  @$pb.TagNumber(8)
  $core.bool get supportsTimeStart => $_getBF(7);
  @$pb.TagNumber(8)
  set supportsTimeStart($core.bool value) => $_setBool(7, value);
  @$pb.TagNumber(8)
  $core.bool hasSupportsTimeStart() => $_has(7);
  @$pb.TagNumber(8)
  void clearSupportsTimeStart() => $_clearField(8);
}

const $core.bool _omitFieldNames =
    $core.bool.fromEnvironment('protobuf.omit_field_names');
const $core.bool _omitMessageNames =
    $core.bool.fromEnvironment('protobuf.omit_message_names');
