/// 公共 AI 作业(ADR-133)的客户端模型: 与服务端 `GET /api/ai/jobs/{id}` 一一对应。
///
/// 任何接入 AI 作业的功能(目前是销售客户文件识别)都只依赖这里的类型,
/// 不直接解析作业 JSON。
library;

import 'dart:async';

/// 服务端作业状态。
enum AiJobStatus {
  pending,
  running,
  succeeded,
  failed,
  cancelled;

  static AiJobStatus parse(Object? raw) {
    switch ('$raw'.toUpperCase()) {
      case 'RUNNING':
        return AiJobStatus.running;
      case 'SUCCEEDED':
        return AiJobStatus.succeeded;
      case 'FAILED':
        return AiJobStatus.failed;
      case 'CANCELLED':
        return AiJobStatus.cancelled;
      default:
        return AiJobStatus.pending;
    }
  }

  bool get isTerminal =>
      this == AiJobStatus.succeeded ||
      this == AiJobStatus.failed ||
      this == AiJobStatus.cancelled;
}

/// 一次轮询看到的作业快照。
class AiJobSnapshot {
  const AiJobSnapshot({
    required this.id,
    required this.kind,
    required this.status,
    this.stage,
    this.progress = 0,
    this.result,
    this.errorCode,
    this.errorMessage,
    this.createdAt,
    this.startedAt,
    this.finishedAt,
  });

  factory AiJobSnapshot.fromJson(Map<String, dynamic> json) {
    final result = json['result'];
    return AiJobSnapshot(
      id: '${json['id'] ?? json['jobId'] ?? ''}',
      kind: '${json['kind'] ?? ''}',
      status: AiJobStatus.parse(json['status']),
      stage: json['stage'] as String?,
      progress: (json['progress'] as num?)?.toInt() ?? 0,
      result: result is Map<String, dynamic> ? result : null,
      errorCode: json['errorCode'] as String?,
      errorMessage: json['errorMessage'] as String?,
      createdAt: DateTime.tryParse('${json['createdAt'] ?? ''}'),
      startedAt: DateTime.tryParse('${json['startedAt'] ?? ''}'),
      finishedAt: DateTime.tryParse('${json['finishedAt'] ?? ''}'),
    );
  }

  final String id;
  final String kind;
  final AiJobStatus status;

  /// 服务端阶段键(例如 READING / LAYOUT / MATCHING_GOODS), 客户端上传阶段为 [uploadingStage]。
  final String? stage;

  /// 0-100。
  final int progress;

  /// 仅在 [AiJobStatus.succeeded] 时有值。
  final Map<String, dynamic>? result;
  final String? errorCode;

  /// 服务端给出的大白话原因, 可直接展示。
  final String? errorMessage;
  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  /// 客户端「上传文件」阶段的约定键。
  static const uploadingStage = 'UPLOADING';

  bool get isTerminal => status.isTerminal;

  AiJobSnapshot copyWith({AiJobStatus? status, String? stage, int? progress}) =>
      AiJobSnapshot(
        id: id,
        kind: kind,
        status: status ?? this.status,
        stage: stage ?? this.stage,
        progress: progress ?? this.progress,
        result: result,
        errorCode: errorCode,
        errorMessage: errorMessage,
        createdAt: createdAt,
        startedAt: startedAt,
        finishedAt: finishedAt,
      );
}

/// 提交一次 AI 作业所需的全部输入(原始文件字节直接上传, 不走附件通道)。
class AiJobRequest {
  const AiJobRequest({
    required this.kind,
    required this.params,
    required this.bytes,
    required this.fileName,
    required this.contentType,
  });

  /// 服务端作业种类, 例如 `SALES_DOCUMENT_INTAKE`。
  final String kind;

  /// 作业参数(作为查询参数发送), 例如 `{docType: order, clientId: ...}`。
  final Map<String, String> params;
  final List<int> bytes;
  final String fileName;
  final String contentType;
}

/// 取消令牌: 用户在进度弹窗里点「取消」。
///
/// 轮询等待期间通过 [whenCancelled] 立即醒来, 不必等到下一次轮询。
class AiJobCancelToken {
  bool _cancelled = false;
  final Completer<void> _signal = Completer<void>();

  bool get isCancelled => _cancelled;

  /// 取消后完成(只完成一次); 未取消时永不完成。
  Future<void> get whenCancelled => _signal.future;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    _signal.complete();
  }
}

/// 作业结束但不是成功时抛出, [message] 可直接展示。
///
/// [code] 为服务端 errorCode(如 `FILE_UNREADABLE`), 或下列客户端代码之一。
/// 进度弹窗会把客户端自己写的文案([clientMessage])换成当前语言再抛给调用方。
class AiJobFailure implements Exception {
  const AiJobFailure({
    required this.message,
    this.code,
    this.snapshot,
    this.clientMessage = false,
  });

  /// 用户取消(进度弹窗把它当作「返回 null」, 不提示错误)。
  static const codeCancelled = 'CANCELLED';

  /// 超过 [AiJobRunner.maxDuration] 仍未结束, 客户端已停止等待并请求服务端取消。
  static const codeClientTimeout = 'CLIENT_TIMEOUT';

  /// 作业已不存在(被清理或系统重置数据), 需要重新识别。
  static const codeJobGone = 'JOB_GONE';

  /// 服务端判定失败但没有给出错误码。
  static const codeFailed = 'FAILED';

  final String message;
  final String? code;
  final AiJobSnapshot? snapshot;

  /// [message] 是客户端兜底文案(服务端没给原因), 不是服务端的原话。
  final bool clientMessage;

  bool get isCancelled => code == codeCancelled;

  @override
  String toString() => message;
}
