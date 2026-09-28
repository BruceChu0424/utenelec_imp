import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'ai_job_models.dart';
import 'ai_job_repository.dart';

typedef AiJobProgressCallback = void Function(AiJobSnapshot snapshot);

/// 提交并轮询一个 AI 作业直到结束(ADR-133)。
///
/// 轮询节奏: 前 10 秒每 1 秒, 之后每 2 秒, 最长 [maxDuration]。
/// 成功返回终态快照; 失败/取消/超时抛 [AiJobFailure](message 可直接展示)。
class AiJobRunner {
  AiJobRunner(
    this.repository, {
    this.fastInterval = const Duration(seconds: 1),
    this.slowInterval = const Duration(seconds: 2),
    this.fastPhase = const Duration(seconds: 10),
    this.maxDuration = const Duration(minutes: 5),
  });

  final AiJobRepository repository;
  final Duration fastInterval;
  final Duration slowInterval;
  final Duration fastPhase;
  final Duration maxDuration;

  Future<AiJobSnapshot> run(
    AiJobRequest request, {
    AiJobProgressCallback? onProgress,
    AiJobCancelToken? cancelToken,
  }) {
    // fl-platform: 实现提交、轮询、取消(调用 repository.cancel)与超时。
    throw UnimplementedError('AiJobRunner.run');
  }

  /// 已有作业(例如从订货单转到报价单时复用同一次识别)只轮询不再提交。
  Future<AiJobSnapshot> resume(
    String jobId, {
    AiJobProgressCallback? onProgress,
    AiJobCancelToken? cancelToken,
  }) {
    throw UnimplementedError('AiJobRunner.resume');
  }
}

final aiJobRunnerProvider = Provider<AiJobRunner>(
  (ref) => AiJobRunner(ref.watch(aiJobRepositoryProvider)),
);
