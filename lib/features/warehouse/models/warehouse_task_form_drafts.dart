import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/task_form_drafts.dart';
import 'warehouse_draw_task.dart';

bool _queryContains(FormDraft draft, String key, String id) =>
    id.isNotEmpty &&
    (Uri.tryParse(draft.route)?.queryParameters[key]?.split(',') ?? const [])
        .map((value) => value.trim())
        .contains(id);

List<FormDraft> arrivalTaskDrafts(
  Iterable<FormDraft> drafts,
  String expectationId,
) => taskDraftsFor(
  drafts,
  matches: (draft) =>
      FormDraftCatalog.arrival.groups(draft) &&
      _queryContains(draft, 'expectationIds', expectationId) &&
      (draft.data['rows'] is! List ||
          (draft.data['rows'] as List).whereType<Map<Object?, Object?>>().any(
            (row) => row['expectationId'] == expectationId,
          )),
);

List<FormDraft> finishedArrivalTaskDrafts(
  Iterable<FormDraft> drafts,
  String? reportId,
) => reportId == null
    ? const []
    : taskDraftsFor(
        drafts,
        matches: (draft) =>
            FormDraftCatalog.finishedArrival.groups(draft) &&
            _queryContains(draft, 'reportIds', reportId),
      );

List<FormDraft> drawTaskDrafts(
  Iterable<FormDraft> drafts,
  WarehouseDrawTask task,
) {
  final members = task.members ?? [task];
  return taskDraftsFor(
    drafts,
    matches: (draft) {
      final path = Uri.tryParse(draft.route)?.path;
      return members.any((member) {
        final id = member.actionDocId;
        if (id == null || id.isEmpty) return false;
        if (member.isMaterialDiscovery) {
          return (FormDraftCatalog.warehouseDiscovery.groups(draft) &&
                  path == '/warehouse/material-discovery/$id') ||
              (FormDraftCatalog.warehouseDraw.groups(draft) &&
                  _queryContains(draft, 'discoveryRequestIds', id));
        }
        return FormDraftCatalog.warehouseDraw.groups(draft) &&
            _queryContains(draft, 'documentIds', id);
      });
    },
  );
}

List<FormDraft> subcontractOutboundTaskDrafts(
  Iterable<FormDraft> drafts,
  String issueId,
) => taskDraftsFor(
  drafts,
  matches: (draft) =>
      (FormDraftCatalog.subcontractOutbound.groups(draft) &&
          Uri.tryParse(draft.route)?.path ==
              '/warehouse/subcontract-outbound/$issueId') ||
      (FormDraftCatalog.subcontractOutboundBatch.groups(draft) &&
          _queryContains(draft, 'issueIds', issueId) &&
          !(draft.data['completed'] is List &&
              (draft.data['completed'] as List).contains(issueId))),
);

List<FormDraft> salesOutboundTaskDrafts(
  Iterable<FormDraft> drafts,
  String shipmentId,
) => taskDraftsFor(
  drafts,
  matches: (draft) {
    final uri = Uri.tryParse(draft.route);
    return (FormDraftCatalog.warehouseSalesOutbound.groups(draft) &&
            uri?.path == '/warehouse/sales-outbound/$shipmentId') ||
        (FormDraftCatalog.warehouseSalesOutboundBatch.groups(draft) &&
            _queryContains(draft, 'shipmentIds', shipmentId) &&
            !(draft.data['completed'] is List &&
                (draft.data['completed'] as List).contains(shipmentId)));
  },
);

List<FormDraft> finishedInboundTaskDrafts(
  Iterable<FormDraft> drafts, {
  String? reportId,
  String? documentId,
}) => taskDraftsFor(
  drafts,
  matches: (draft) =>
      (reportId != null &&
          FormDraftCatalog.finishedArrival.groups(draft) &&
          _queryContains(draft, 'reportIds', reportId)) ||
      (documentId != null &&
          FormDraftCatalog.productionFinishedBatchStockIn.groups(draft) &&
          _queryContains(draft, 'documentIds', documentId) &&
          (draft.data['selectedDocumentIds'] is! List ||
              (draft.data['selectedDocumentIds'] as List).contains(
                documentId,
              ))),
);

List<FormDraft> stockTaskDrafts(
  Iterable<FormDraft> drafts,
  String documentId,
) => taskDraftsFor(
  drafts,
  matches: (draft) =>
      (FormDraftCatalog.warehouseDraw.groups(draft) &&
          _queryContains(draft, 'documentIds', documentId)) ||
      (FormDraftCatalog.materialReturnBatchReceive.groups(draft) &&
          _queryContains(draft, 'documentIds', documentId) &&
          !(draft.data['rows'] is List &&
              (draft.data['rows'] as List)
                  .whereType<Map<Object?, Object?>>()
                  .any(
                    (row) =>
                        row['documentId'] == documentId && row['done'] == true,
                  ))),
);

List<FormDraft> qualityStockInTaskDrafts(
  Iterable<FormDraft> drafts,
  String receiptType,
  String receiptId,
) => taskDraftsFor(
  drafts,
  matches: (draft) {
    final uri = Uri.tryParse(draft.route);
    final segments = uri?.pathSegments ?? const <String>[];
    String? type(Object? value) {
      if (value is! String) return null;
      final normalized = value.trim().toUpperCase();
      return const {'PURCHASE', 'SUBCONTRACT'}.contains(normalized)
          ? normalized
          : null;
    }

    final expectedType = type(receiptType);
    bool sameReceipt() =>
        expectedType != null &&
        segments.length >= 2 &&
        type(segments[segments.length - 2]) == expectedType &&
        segments.last == receiptId;
    if (FormDraftCatalog.warehouseQualityStockIn.groups(draft) &&
        sameReceipt()) {
      return true;
    }
    if (FormDraftCatalog.warehouseQualityPreStockIn.groups(draft) &&
        sameReceipt()) {
      return true;
    }
    if (!FormDraftCatalog.warehouseQualityBatchStockIn.groups(draft)) {
      return false;
    }
    final receipts = draft.data['receipts'];
    return (receipts is List &&
            receipts.whereType<Map<Object?, Object?>>().any(
              (receipt) =>
                  expectedType != null &&
                  type(receipt['receiptType']) == expectedType &&
                  receipt['receiptId'] == receiptId,
            )) ||
        (uri?.queryParameters['receipts']?.split(',') ?? const <String>[]).any((
          value,
        ) {
          final separator = value.indexOf(':');
          return expectedType != null &&
              separator > 0 &&
              type(value.substring(0, separator)) == expectedType &&
              value.substring(separator + 1) == receiptId;
        });
  },
);
