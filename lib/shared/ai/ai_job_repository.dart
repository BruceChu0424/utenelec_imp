import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import 'ai_job_models.dart';

/// 公共 AI 作业接口(ADR-133): 提交原始文件 → 轮询 → 取消。
abstract interface class AiJobRepository {
  /// `POST /ai/jobs?kind=..&<params>`, 请求体为原始字节(application/octet-stream)。
  Future<AiJobSnapshot> submit(AiJobRequest request);

  /// `GET /ai/jobs/{id}`。
  Future<AiJobSnapshot> get(String jobId);

  /// `POST /ai/jobs/{id}/cancel`。
  Future<void> cancel(String jobId);
}

final aiJobRepositoryProvider = Provider<AiJobRepository>(
  (ref) => DioAiJobRepository(ref.watch(apiClientProvider)),
);

class DioAiJobRepository implements AiJobRepository {
  DioAiJobRepository(this.api);

  final ApiClient api;

  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) {
    // fl-platform: 用扩展后的 ApiClient.postBytes(queryParameters/headers/receiveTimeout) 实现。
    throw UnimplementedError('AiJobRepository.submit');
  }

  @override
  Future<AiJobSnapshot> get(String jobId) {
    throw UnimplementedError('AiJobRepository.get');
  }

  @override
  Future<void> cancel(String jobId) {
    throw UnimplementedError('AiJobRepository.cancel');
  }
}
