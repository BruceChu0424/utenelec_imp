import 'package:flutter/widgets.dart';

import 'ai_job_models.dart';
import 'ai_job_runner.dart';

/// 进度弹窗里的一步。[serverStages] 是这一步覆盖的服务端阶段键(见 [AiJobSnapshot.stage])。
class AiProgressStage {
  const AiProgressStage({
    required this.key,
    required this.label,
    this.serverStages = const [],
  });

  final String key;
  final String label;
  final List<String> serverStages;
}

/// 一次在弹窗里运行的作业: 弹窗把进度回调与取消令牌交给它。
typedef AiProgressTask = Future<AiJobSnapshot> Function(
  AiJobProgressCallback onProgress,
  AiJobCancelToken cancelToken,
);

/// 公共 AI 进度弹窗(组件文档: docs/02-组件库/AI任务进度弹窗.md)。
///
/// 模态卡片, 显示分步进度、已用时间与「取消」。返回终态快照;
/// 用户取消返回 null; 作业失败时关闭弹窗并把 [AiJobFailure] 抛给调用方。
Future<AiJobSnapshot?> showAiProgressDialog(
  BuildContext context, {
  required String title,
  String? subtitle,
  required List<AiProgressStage> stages,
  required AiProgressTask task,
}) {
  // fl-platform: 实现弹窗 UI(品牌色、性能分级动画、阶段列表、计时、取消)。
  throw UnimplementedError('showAiProgressDialog');
}
