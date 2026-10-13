import '../../../core/router/route_names.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/task_form_drafts.dart';

/// Match only inspection identities in the documented selection contract.
/// A batch is kept intact and can be resumed from any of its source rows.
List<FormDraft> qualityTaskDrafts(
  Iterable<FormDraft> drafts, {
  String? receiptType,
  String? receiptId,
  String? sheetId,
  String? inspectionId,
}) => taskDraftsFor(
  drafts,
  matches: (draft) {
    final uri = Uri.tryParse(draft.route);
    final path = uri?.path;
    final segments = uri?.pathSegments ?? const <String>[];
    String? type(Object? value) {
      if (value is! String) return null;
      final normalized = value.trim().toUpperCase();
      return const {'PURCHASE', 'SUBCONTRACT'}.contains(normalized)
          ? normalized
          : null;
    }

    final expectedType = type(receiptType);
    if (receiptId != null &&
        receiptType != null &&
        FormDraftCatalog.iqcReport.groups(draft) &&
        expectedType != null &&
        segments.length >= 2 &&
        type(segments[segments.length - 2]) == expectedType &&
        segments.last == receiptId) {
      return true;
    }
    if (sheetId != null &&
        FormDraftCatalog.fqcSheet.groups(draft) &&
        path == RouteName.productionFqcSheetHandling(sheetId)) {
      return true;
    }
    if (inspectionId != null &&
        FormDraftCatalog.fqcInspection.groups(draft) &&
        path == RouteName.productionFqcInspectionHandling(inspectionId)) {
      return true;
    }
    if (!(FormDraftCatalog.iqcBatchReport.groups(draft) ||
        FormDraftCatalog.fqcBatchReport.groups(draft))) {
      return false;
    }
    final selection = draft.data['selection'];
    if (selection is! Map) return false;
    bool contains(String key, String? id) =>
        id != null &&
        selection[key] is List &&
        (selection[key] as List).contains(id);
    if (contains('sheetIds', sheetId) ||
        contains('inspectionIds', inspectionId)) {
      return true;
    }
    final receipts = selection['receipts'];
    return receiptId != null &&
        receiptType != null &&
        receipts is List &&
        receipts.whereType<Map<Object?, Object?>>().any(
          (receipt) =>
              expectedType != null &&
              type(receipt['receiptType']) == expectedType &&
              receipt['receiptId'] == receiptId,
        );
  },
);
