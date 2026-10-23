import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/utils/china_datetime.dart';
import '../../core/network/server_config.dart';
import '../../core/ui/app_notification.dart';
import '../providers/authenticated_scope_provider.dart';
import 'form_draft_catalog.dart';
import 'form_draft_store.dart';
import '../../core/router/route_names.dart';

/// Task editors keep their local input on the authoritative task row. A new
/// document with a source reference remains a new-document draft.
bool isTaskFormDraft(FormDraft draft) {
  final uri = Uri.tryParse(draft.route);
  if (uri == null) return false;
  final path = uri.path;
  bool hasQuery(String key) =>
      (uri.queryParameters[key]?.trim().isNotEmpty ?? false);
  bool hasList(Object? value) => value is List && value.isNotEmpty;
  bool hasSourceRows(Object? value, String key) =>
      value is List &&
      value.any(
        (row) =>
            row is Map &&
            row[key] is String &&
            (row[key] as String).trim().isNotEmpty,
      );
  if (FormDraftCatalog.iqcReport.matchesDestination(draft) ||
      FormDraftCatalog.fqcSheet.matchesDestination(draft) ||
      FormDraftCatalog.fqcInspection.matchesDestination(draft) ||
      FormDraftCatalog.warehouseDiscovery.matchesDestination(draft) ||
      FormDraftCatalog.subcontractOutbound.matchesDestination(draft) ||
      FormDraftCatalog.subcontractOutboundBatch.matchesDestination(draft) ||
      FormDraftCatalog.warehouseSalesOutbound.matchesDestination(draft) ||
      FormDraftCatalog.warehouseSalesOutboundBatch.matchesDestination(draft) ||
      FormDraftCatalog.warehouseQualityStockIn.matchesDestination(draft) ||
      FormDraftCatalog.warehouseQualityBatchStockIn.matchesDestination(draft) ||
      FormDraftCatalog.warehouseQualityPreStockIn.matchesDestination(draft) ||
      FormDraftCatalog.productionFinishedBatchStockIn.matchesDestination(
        draft,
      ) ||
      FormDraftCatalog.materialReturnBatchReceive.matchesDestination(draft) ||
      FormDraftCatalog.financeSalesOrderReview.matchesDestination(draft) ||
      FormDraftCatalog.financeProcurementReview.matchesDestination(draft) ||
      FormDraftCatalog.financeQuoteReview.matchesDestination(draft) ||
      FormDraftCatalog.financeShipmentReview.matchesDestination(draft) ||
      (FormDraftCatalog.employeeReconcile.matchesDestination(draft) &&
          hasQuery('planId')) ||
      FormDraftCatalog.employeeOffboarding.matchesDestination(draft)) {
    return true;
  }
  if (path == '/production/daily-reports/new') {
    return hasQuery('executionSegmentIds') ||
        hasQuery('executionSegmentId') ||
        (uri.queryParameters['from'] == 'workshop-tasks' &&
            hasSourceRows(draft.data['rows'], 'executionSegmentId'));
  }
  if (path == RouteName.productionDrawRequest) {
    final preview = draft.data['preview'];
    return hasQuery('segmentIds') ||
        (preview is Map && hasSourceRows(preview['tasks'], 'segmentId'));
  }
  if (path == '/production/material-discovery-request') {
    return hasQuery('segmentIds') ||
        hasSourceRows(draft.data['tasks'], 'segmentId');
  }
  if (path == '/production/material-return/new') {
    return hasQuery('executionSegmentId');
  }
  if (path == '/production/overproduction-rate-requests/new' ||
      path == '/production/material-increment-requests/new') {
    return hasQuery('segmentId');
  }
  if (FormDraftCatalog.arrival.matchesDestination(draft)) {
    return hasQuery('expectationIds');
  }
  if (FormDraftCatalog.finishedArrival.matchesDestination(draft)) {
    return hasQuery('reportIds');
  }
  if (FormDraftCatalog.warehouseDraw.matchesDestination(draft)) {
    return hasQuery('documentIds') || hasQuery('discoveryRequestIds');
  }
  if (FormDraftCatalog.workshopMaterialBatchIssue.matchesDestination(draft)) {
    return true;
  }
  if (FormDraftCatalog.workshopMaterialIssue.matchesDestination(draft)) {
    return hasQuery('requisitionId') ||
        (draft.data['requisitionId'] is String &&
            (draft.data['requisitionId'] as String).trim().isNotEmpty);
  }
  final selection = draft.data['selection'];
  if ((FormDraftCatalog.iqcBatchReport.matchesDestination(draft) ||
          FormDraftCatalog.fqcBatchReport.matchesDestination(draft)) &&
      selection is Map) {
    return hasList(selection['receipts']) ||
        hasList(selection['sheetIds']) ||
        hasList(selection['inspectionIds']);
  }
  return false;
}

/// Each feature supplies an explicit source identity match. Never match a task
/// against arbitrary UUIDs elsewhere in a snapshot (warehouse, goods, etc.).
List<FormDraft> taskDraftsFor(
  Iterable<FormDraft> drafts, {
  required bool Function(FormDraft draft) matches,
}) {
  final result = {
    for (final draft in drafts)
      if (matches(draft)) draft.id: draft,
  }.values.toList();
  result.sort((a, b) {
    final time = b.updatedAt.compareTo(a.updatedAt);
    return time == 0 ? a.id.compareTo(b.id) : time;
  });
  return result;
}

String taskDraftStatus(Iterable<FormDraft> drafts) =>
    drafts.any((draft) => draft.hasUnknownSubmission) ? '提交待核对' : '草稿';

/// A batch snapshot is resumed as one editor even when opened from one member.
/// With several unfinished operations, the user chooses which input to resume.
Future<void> resumeTaskFormDraft(
  BuildContext context,
  WidgetRef ref,
  List<FormDraft> drafts, {
  bool choose = false,
}) async {
  if (drafts.isEmpty) return;
  final owner = ref.read(authenticatedScopeProvider);
  final server = ref.read(apiBaseUrlProvider);
  final selected = drafts.length == 1 && !choose
      ? drafts.single
      : await showDialog<FormDraft>(
          context: context,
          builder: (dialogContext) => UtenAlertDialog(
            scrollable: false,
            title: const Text('继续填写'),
            content: SizedBox(
              width: 460,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final draft in drafts)
                      ListTile(
                        leading: const Icon(Icons.drafts_outlined),
                        title: Text(draft.title),
                        subtitle: Text(
                          '${taskDraftStatus([draft])} · ${ChinaDateTime.formatInstant(draft.updatedAt)}',
                        ),
                        trailing: draft.hasUnknownSubmission
                            ? null
                            : IconButton(
                                tooltip: '丢弃本机填写',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: () async {
                                  final confirmed = await UtenDialog.show(
                                    dialogContext,
                                    title: '丢弃这份本机填写？',
                                    content: const Text(
                                      '只丢弃这份本机填写及待处理附件，原任务与已经保存的业务单据保留。',
                                    ),
                                    confirmLabel: '丢弃本机填写',
                                    danger: true,
                                  );
                                  if (confirmed != true ||
                                      !context.mounted ||
                                      !dialogContext.mounted ||
                                      owner !=
                                          ref.read(
                                            authenticatedScopeProvider,
                                          ) ||
                                      server != ref.read(apiBaseUrlProvider)) {
                                    return;
                                  }
                                  try {
                                    await ref
                                        .read(formDraftsProvider.notifier)
                                        .delete(
                                          draft.id,
                                          expectedRevision: draft.revision,
                                        );
                                    if (dialogContext.mounted) {
                                      Navigator.pop(dialogContext);
                                    }
                                  } catch (error) {
                                    if (context.mounted) {
                                      context.appError(
                                        describeSubmitError(
                                          error,
                                          fallback: '本机填写已变化，请刷新后重试',
                                        ),
                                      );
                                    }
                                  }
                                },
                              ),
                        onTap: () => Navigator.pop(dialogContext, draft),
                      ),
                  ],
                ),
              ),
            ),
            actions: [
              UtenButton(
                type: UtenButtonType.ghost,
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
            ],
          ),
        );
  if (selected == null ||
      !context.mounted ||
      owner != ref.read(authenticatedScopeProvider) ||
      server != ref.read(apiBaseUrlProvider)) {
    return;
  }
  final current = ref
      .read(formDraftsProvider)
      .where((draft) => draft.id == selected.id)
      .firstOrNull;
  if (current == null) return;
  if (current.revision != selected.revision) {
    context.appWarning('这份草稿已在其它页面更新，请从原任务重新打开');
    return;
  }
  await context.push(current.resumeLocation);
}
