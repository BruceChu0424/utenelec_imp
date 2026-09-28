import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_exception.dart';
import 'ai_job_models.dart';
import 'ai_job_repository.dart';

typedef AiJobProgressCallback = void Function(AiJobSnapshot snapshot);

/// 等待一段时间(测试注入假时钟用)。
typedef AiJobSleep = Future<void> Function(Duration duration);

/// 提交并轮询一个 AI 作业直到结束(ADR-133)。
///
/// 轮询节奏: 前 10 秒每 1 秒, 之后每 2 秒, 最长 [maxDuration]。
/// 成功返回终态快照; 失败/取消/超时抛 [AiJobFailure](message 可直接展示);
/// 提交被拒(没权限、文件太大、同时识别太多)抛服务端的 [ApiException], 交给
/// `context.appApiError` 展示。
///
/// 进度回调的第一条是客户端「上传文件」快照(stage = [AiJobSnapshot.uploadingStage],
/// id 为空), 之后每条都带服务端作业 id。
class AiJobRunner {
  AiJobRunner(
    this.repository, {
    this.fastInterval = const Duration(seconds: 1),
    this.slowInterval = const Duration(seconds: 2),
    this.fastPhase = const Duration(seconds: 10),
    this.maxDuration = const Duration(minutes: 5),
    this.maxConsecutivePollErrors = 3,
    AiJobSleep? sleep,
    DateTime Function()? now,
  }) : _sleep = sleep ?? _defaultSleep,
       _now = now ?? clock.now;

  final AiJobRepository repository;
  final Duration fastInterval;
  final Duration slowInterval;
  final Duration fastPhase;
  final Duration maxDuration;

  /// 连续几次轮询失败(断网等)才放弃; 中间偶发一次失败只是跳过这一拍。
  final int maxConsecutivePollErrors;

  final AiJobSleep _sleep;
  final DateTime Function() _now;

  static Future<void> _defaultSleep(Duration duration) =>
      Future<void>.delayed(duration);

  Future<AiJobSnapshot> run(
    AiJobRequest request, {
    AiJobProgressCallback? onProgress,
    AiJobCancelToken? cancelToken,
  }) async {
    final token = cancelToken ?? AiJobCancelToken();
    if (token.isCancelled) throw _cancelled(null);
    onProgress?.call(
      AiJobSnapshot(
        id: '',
        kind: request.kind,
        status: AiJobStatus.pending,
        stage: AiJobSnapshot.uploadingStage,
      ),
    );
    final submitted = await repository.submit(request);
    if (token.isCancelled) {
      await _requestCancel(submitted.id);
      throw _cancelled(submitted);
    }
    return _poll(
      submitted.id,
      initial: submitted,
      onProgress: onProgress,
      token: token,
    );
  }

  /// 已有作业(例如从订货单转到报价单时复用同一次识别)只轮询不再提交。
  Future<AiJobSnapshot> resume(
    String jobId, {
    AiJobProgressCallback? onProgress,
    AiJobCancelToken? cancelToken,
  }) {
    final token = cancelToken ?? AiJobCancelToken();
    if (token.isCancelled) return Future.error(_cancelled(null));
    return _poll(jobId, onProgress: onProgress, token: token, pollFirst: true);
  }

  Future<AiJobSnapshot> _poll(
    String jobId, {
    AiJobSnapshot? initial,
    required AiJobProgressCallback? onProgress,
    required AiJobCancelToken token,
    bool pollFirst = false,
  }) async {
    final startedAt = _now();
    var current = initial;
    var consecutiveErrors = 0;
    if (current != null) {
      onProgress?.call(current);
      // 重复提交可能直接拿回已结束的原作业; 成功态要再取一次才有结果。
      if (current.isTerminal) {
        if (current.status != AiJobStatus.succeeded || current.result != null) {
          return _finish(current);
        }
        pollFirst = true;
      }
    }
    while (true) {
      if (!pollFirst) {
        final elapsed = _now().difference(startedAt);
        if (elapsed >= maxDuration) {
          await _requestCancel(jobId);
          throw AiJobFailure(
            code: AiJobFailure.codeClientTimeout,
            message: _timeoutMessage,
            snapshot: current,
            clientMessage: true,
          );
        }
        final interval = elapsed < fastPhase ? fastInterval : slowInterval;
        final remaining = maxDuration - elapsed;
        await Future.any<void>([
          _sleep(interval < remaining ? interval : remaining),
          token.whenCancelled,
        ]);
      }
      pollFirst = false;
      if (token.isCancelled) {
        await _requestCancel(jobId);
        throw _cancelled(current);
      }
      try {
        current = await repository.get(jobId);
        consecutiveErrors = 0;
      } on ApiException catch (error) {
        if (error.httpStatus == 404 || error.code == 'NOT_FOUND') {
          throw AiJobFailure(
            code: AiJobFailure.codeJobGone,
            message: _goneMessage,
            snapshot: current,
            clientMessage: true,
          );
        }
        consecutiveErrors++;
        if (consecutiveErrors >= maxConsecutivePollErrors) rethrow;
        continue;
      }
      if (token.isCancelled) {
        if (current.isTerminal) return _finish(current, cancelled: true);
        await _requestCancel(jobId);
        throw _cancelled(current);
      }
      onProgress?.call(current);
      if (current.isTerminal) return _finish(current);
    }
  }

  AiJobSnapshot _finish(AiJobSnapshot snapshot, {bool cancelled = false}) {
    if (cancelled) throw _cancelled(snapshot);
    switch (snapshot.status) {
      case AiJobStatus.succeeded:
        return snapshot;
      case AiJobStatus.cancelled:
        throw _cancelled(snapshot);
      case AiJobStatus.failed:
      case AiJobStatus.pending:
      case AiJobStatus.running:
        final message = snapshot.errorMessage?.trim();
        final noReason = message == null || message.isEmpty;
        throw AiJobFailure(
          code: snapshot.errorCode ?? AiJobFailure.codeFailed,
          message: noReason ? _failedMessage : message,
          snapshot: snapshot,
          clientMessage: noReason,
        );
    }
  }

  AiJobFailure _cancelled(AiJobSnapshot? snapshot) => AiJobFailure(
    code: AiJobFailure.codeCancelled,
    message: _cancelledMessage,
    snapshot: snapshot,
    clientMessage: true,
  );

  // 公共组件不绑定某个业务(不写「识别」), 且都标记为客户端文案:
  // 经进度弹窗抛出时换成当前语言(aiJobTimeout / aiJobGone / aiJobFailedGeneric)。
  // 直接调用 run 而不经弹窗的调用方看到的是下面的中文兜底。
  static const _timeoutMessage = '处理时间太长, 已停止等待。请稍后再试, 或把文件拆小一些';
  static const _goneMessage = '这次处理的任务已不存在(可能已被清理), 请重新开始';
  static const _failedMessage = '处理没有成功, 请稍后重试';
  static const _cancelledMessage = '已取消';

  /// 尽力通知服务端停止; 失败不影响本地结束(服务端还有租约与清理兜底)。
  Future<void> _requestCancel(String jobId) async {
    if (jobId.isEmpty) return;
    try {
      await repository.cancel(jobId);
    } catch (_) {
      // 取消只是省资源, 网络失败时服务端作业自然结束后也会被清理。
    }
  }
}

final aiJobRunnerProvider = Provider<AiJobRunner>(
  (ref) => AiJobRunner(ref.watch(aiJobRepositoryProvider)),
);
