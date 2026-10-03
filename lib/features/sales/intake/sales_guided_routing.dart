import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/ai/ai_job_models.dart';
import '../../../shared/ai/ai_job_runner.dart';
import '../../../shared/ai/ai_progress_dialog.dart';
import '../../../shared/ai/chat/ai_chat_l10n.dart';
import '../../../shared/ai/guided/ai_guided_file_plan.dart';
import '../../../shared/auth/permissions.dart';
import 'sales_intake_launcher.dart';

/// Reauthorize a user-requested workflow switch; never relabel an old plan or
/// discard its no-write restrictions by passing a plain file to another page.
Future<AiGuidedFilePlan?> prepareGuidedSalesRoute(
  BuildContext context,
  WidgetRef ref, {
  required AiGuidedFilePlan original,
  required PlatformFile file,
  required AiGuidedWorkflow workflow,
}) async {
  final current = await validateAiGuidedFilePlan(ref, original);
  if (!context.mounted || !current.matches(ref)) return null;
  if (!ref.read(currentPermissionsProvider).containsAll(workflow.permissions)) {
    throw ApiException('FORBIDDEN', aiChatText(context, 'permissionChanged'));
  }
  if (current.workflow == workflow && current.result.matchesSource(file)) {
    return current;
  }
  final contentType = aiGuidedContentTypes[file.extension?.toLowerCase()];
  if (file.bytes == null || contentType == null) {
    throw ApiException(
      'DOCUMENT_ROUTE_INVALID',
      aiChatText(context, 'documentSourceMismatch'),
    );
  }
  final runner = ref.read(aiJobRunnerProvider);
  final request = AiJobRequest(
    kind: aiGuidedRouteKind,
    params: {
      // This is a fixed user-clicked workflow command, not free-form chat.
      // Keep its protocol intent independent of the displayed UI language.
      'message': workflow == AiGuidedWorkflow.salesQuote
          ? 'Create sales quotation'
          : 'Fill sales order',
      'pageRoute': ?current.pageRoute,
    },
    bytes: file.bytes!,
    fileName: file.name,
    contentType: contentType,
  );
  final snapshot = await ref.read(salesIntakeProgressPresenterProvider)(
    context,
    title: aiChatText(context, 'documentClassifying'),
    subtitle:
        '${file.name}\n${aiChatText(context, workflow == AiGuidedWorkflow.salesQuote ? 'guidedQuoteRequest' : 'guidedOrderRequest')}',
    stages: [
      AiProgressStage(
        key: AiJobSnapshot.uploadingStage,
        label: aiChatText(context, 'uploading'),
      ),
      AiProgressStage(
        key: 'READING',
        label: aiChatText(context, 'documentReading'),
      ),
      AiProgressStage(
        key: 'CLASSIFYING',
        label: aiChatText(context, 'documentClassifying'),
        serverStages: const ['PARSING', 'READY_TO_FILL'],
      ),
    ],
    task: (progress, cancel) =>
        runner.run(request, onProgress: progress, cancelToken: cancel),
  );
  if (!context.mounted || snapshot == null || !current.matches(ref)) {
    return null;
  }
  final result = AiGuidedFileResult.fromJson(snapshot.result ?? const {});
  final offered =
      (!result.needsChoice && result.workflow == workflow) ||
      result.choices.any((choice) => choice.workflow == workflow);
  if (!offered || !result.matchesSource(file)) {
    throw ApiException(
      'DOCUMENT_ROUTE_INVALID',
      result.summary.isNotEmpty
          ? result.summary
          : aiChatText(context, 'documentUnsupported'),
    );
  }
  final proposed = AiGuidedFilePlan(
    jobId: snapshot.id,
    file: file,
    result: result,
    workflow: workflow,
    identity: current.identity,
    pageRoute: current.pageRoute,
  );
  return validateAiGuidedFilePlan(ref, proposed);
}
