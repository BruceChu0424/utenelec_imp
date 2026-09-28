import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_endpoints.dart';
import 'ai_job_models.dart';

/// 公共 AI 作业接口(ADR-133): 提交原始文件 → 轮询 → 取消。
///
/// 只有传输, 不含轮询节奏与界面; 轮询见 [AiJobRunner], 界面见 `showAiProgressDialog`。
abstract interface class AiJobRepository {
  /// `POST /ai/jobs?kind=..&<params>`, 请求体为原始字节(application/octet-stream)。
  ///
  /// 服务端 202 返回 `{jobId, status}`; 同一个人 10 分钟内重复提交同一份文件会拿回原作业。
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

  /// 原文件名请求头(百分号编码的 UTF-8, 与服务端约定一致)。
  static const fileNameHeader = 'X-Uten-File-Name';

  /// 原文件类型请求头(请求体本身固定为 application/octet-stream)。
  static const fileTypeHeader = 'X-Uten-File-Type';

  /// 查询参数里保留给作业种类的键; 业务参数不能占用。
  static const kindParam = 'kind';

  /// 上传总时限: 服务端上限 15 MiB, 慢速网络(约 1 Mbps)也要能传完。
  static const uploadTimeout = Duration(minutes: 3);

  /// 提交后服务端只做读取与校验就返回 202, 不等识别本身。
  static const submitReceiveTimeout = Duration(seconds: 60);

  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) async {
    if (request.params.containsKey(kindParam)) {
      throw ArgumentError.value(
        request.params,
        'params',
        '"$kindParam" is reserved for the job kind',
      );
    }
    final json = await api.postBytes(
      ApiEndpoints.aiJobs,
      request.bytes is Uint8List
          ? request.bytes as Uint8List
          : Uint8List.fromList(request.bytes),
      query: {kindParam: request.kind, ...request.params},
      headers: {
        fileNameHeader: Uri.encodeComponent(request.fileName),
        fileTypeHeader: request.contentType,
      },
      sendTimeout: uploadTimeout,
      receiveTimeout: submitReceiveTimeout,
    );
    final snapshot = AiJobSnapshot.fromJson(json);
    if (snapshot.id.isEmpty) {
      throw const FormatException('AI job submit response has no jobId');
    }
    return snapshot.kind.isEmpty
        ? AiJobSnapshot(
            id: snapshot.id,
            kind: request.kind,
            status: snapshot.status,
            stage: snapshot.stage,
            progress: snapshot.progress,
            result: snapshot.result,
            errorCode: snapshot.errorCode,
            errorMessage: snapshot.errorMessage,
            createdAt: snapshot.createdAt,
            startedAt: snapshot.startedAt,
            finishedAt: snapshot.finishedAt,
          )
        : snapshot;
  }

  @override
  Future<AiJobSnapshot> get(String jobId) async {
    final json = await api.get(ApiEndpoints.aiJob(_checkedId(jobId)));
    final snapshot = AiJobSnapshot.fromJson(json);
    if (snapshot.id.isEmpty) {
      throw const FormatException('AI job response has no id');
    }
    return snapshot;
  }

  @override
  Future<void> cancel(String jobId) async {
    await api.post(ApiEndpoints.aiJobCancel(_checkedId(jobId)));
  }

  /// 作业 id 直接拼进路径: 只接受服务端发的 UUID 形态, 拒绝斜杠等路径字符。
  static String _checkedId(String jobId) {
    if (!RegExp(r'^[0-9A-Za-z-]{1,64}$').hasMatch(jobId)) {
      throw ArgumentError.value(jobId, 'jobId', 'not a job id');
    }
    return jobId;
  }
}
