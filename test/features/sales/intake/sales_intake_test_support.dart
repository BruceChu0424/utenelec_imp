// 识别客户文件测试替身: 文件选择器、AI 作业执行器(不走网络)、进度弹窗(直接执行任务)。
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_launcher.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_models.dart';
import 'package:uten_imp/features/sales/intake/sales_intake_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';
import 'package:uten_imp/shared/ai/ai_progress_dialog.dart';

class FakeFilePicker extends FilePicker {
  FakeFilePicker(this.file);

  final PlatformFile? file;
  int calls = 0;
  List<String>? allowedExtensions;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    this.allowedExtensions = allowedExtensions;
    expect(withData, isTrue, reason: '识别需要原始字节');
    expect(allowMultiple, isFalse);
    final f = file;
    return f == null ? null : FilePickerResult([f]);
  }
}

PlatformFile fakeFile(String name, {int size = 64}) => PlatformFile(
  name: name,
  size: size,
  bytes: Uint8List.fromList(List<int>.filled(size, 7)),
);

class _NoRepository implements AiJobRepository {
  @override
  Future<void> cancel(String jobId) async {}

  @override
  Future<AiJobSnapshot> get(String jobId) => throw UnimplementedError();

  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) =>
      throw UnimplementedError();
}

/// 不走网络的作业执行器: 记录请求, 回放给定终态(或抛失败)。
class FakeAiJobRunner extends AiJobRunner {
  FakeAiJobRunner({
    this.result,
    this.failure,
    this.terminal,
    this.jobId = 'job-42',
    this.sheetResults = const {},
  }) : super(_NoRepository());

  final Map<String, dynamic>? result;
  final AiJobFailure? failure;

  /// 直接回放的终态(例如 FAILED 快照, 不抛异常)。
  final AiJobSnapshot? terminal;
  final String jobId;

  /// 带参数 `sheet`(改为识别别的工作表)的提交按序号回放的结果, 作业 id 为 `$jobId-sheet-<序号>`。
  final Map<String, Map<String, dynamic>> sheetResults;
  AiJobRequest? lastRequest;
  final requests = <AiJobRequest>[];
  String? resumedJobId;
  final stagesSeen = <String>[];

  Future<AiJobSnapshot> _finish(
    AiJobProgressCallback? onProgress, {
    String? sheet,
  }) async {
    final id = sheet == null ? jobId : '$jobId-sheet-$sheet';
    for (final stage in const ['UPLOADING', 'READING', 'MATCHING_GOODS']) {
      stagesSeen.add(stage);
      onProgress?.call(
        AiJobSnapshot(
          id: id,
          kind: kSalesIntakeJobKind,
          status: AiJobStatus.running,
          stage: stage,
        ),
      );
    }
    final f = failure;
    if (f != null) throw f;
    final t = terminal;
    if (t != null) return t;
    return AiJobSnapshot(
      id: id,
      kind: kSalesIntakeJobKind,
      status: AiJobStatus.succeeded,
      progress: 100,
      result: sheet == null ? result : sheetResults[sheet],
    );
  }

  @override
  Future<AiJobSnapshot> run(
    AiJobRequest request, {
    AiJobProgressCallback? onProgress,
    AiJobCancelToken? cancelToken,
  }) {
    lastRequest = request;
    requests.add(request);
    return _finish(onProgress, sheet: request.params['sheet']);
  }

  @override
  Future<AiJobSnapshot> resume(
    String jobId, {
    AiJobProgressCallback? onProgress,
    AiJobCancelToken? cancelToken,
  }) {
    resumedJobId = jobId;
    return _finish(onProgress);
  }
}

/// 进度弹窗替身: 不画界面, 直接执行任务(公共弹窗由平台包实现并单独测试)。
class FakeProgressPresenter {
  int calls = 0;
  List<AiProgressStage>? stages;
  String? title;
  String? subtitle;

  Future<AiJobSnapshot?> call(
    BuildContext context, {
    required String title,
    String? subtitle,
    required List<AiProgressStage> stages,
    required AiProgressTask task,
  }) {
    calls++;
    this.stages = stages;
    this.title = title;
    this.subtitle = subtitle;
    return task((_) {}, AiJobCancelToken());
  }
}

class FakeSalesIntakeRepository implements SalesIntakeRepository {
  @override
  Future<String> createClientFromDocument(
    SalesIntakeNewClientProposal proposal,
  ) async => 'client-new';
}

SalesIntakeProgressPresenter presenterOf(FakeProgressPresenter fake) =>
    fake.call;
