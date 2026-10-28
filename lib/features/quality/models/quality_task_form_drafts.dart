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
  matches: (draft) => qualityTaskDraftIdentities(draft).any(
    (identity) =>
        identity ==
            (receiptType == null || receiptId == null
                ? null
                : 'iqc:${receiptType.trim().toUpperCase()}:$receiptId') ||
        identity == (sheetId == null ? null : 'sheet:$sheetId') ||
        identity == (inspectionId == null ? null : 'fqc:$inspectionId'),
  ),
);

/// One parser for the source identities documented by the task draft contract.
Set<String> qualityTaskDraftIdentities(FormDraft draft) {
  final result = <String>{};
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

  if (FormDraftCatalog.iqcReport.groups(draft) &&
      segments.length >= 2 &&
      type(segments[segments.length - 2]) != null) {
    result.add('iqc:${type(segments[segments.length - 2])}:${segments.last}');
  }
  if (segments.isNotEmpty &&
      FormDraftCatalog.fqcSheet.groups(draft) &&
      path == RouteName.productionFqcSheetHandling(segments.last)) {
    result.add('sheet:${segments.last}');
  }
  if (segments.isNotEmpty &&
      FormDraftCatalog.fqcInspection.groups(draft) &&
      path == RouteName.productionFqcInspectionHandling(segments.last)) {
    result.add('fqc:${segments.last}');
  }
  if (!(FormDraftCatalog.iqcBatchReport.groups(draft) ||
      FormDraftCatalog.fqcBatchReport.groups(draft))) {
    return result;
  }
  final selection = draft.data['selection'];
  if (selection is! Map) return result;
  Iterable<String> ids(Object? value) => value is List
      ? value.whereType<String>().where((id) => id.isNotEmpty)
      : const [];
  for (final id in ids(selection['sheetIds'])) {
    result.add('sheet:$id');
  }
  for (final id in ids(selection['inspectionIds'])) {
    result.add('fqc:$id');
  }
  final receipts = selection['receipts'];
  if (receipts is List) {
    for (final receipt in receipts.whereType<Map<Object?, Object?>>()) {
      final kind = type(receipt['receiptType']), id = receipt['receiptId'];
      if (kind != null && id is String) result.add('iqc:$kind:$id');
    }
  }
  return result;
}

/// Client-owned draft badges only narrow an already-authorized server read.
Map<String, String> qualityDraftStatuses(Iterable<FormDraft> drafts) {
  final members = <String, Map<String, FormDraft>>{};
  for (final draft in drafts) {
    for (final identity in qualityTaskDraftIdentities(draft)) {
      members.putIfAbsent(identity, () => {})[draft.id] = draft;
    }
  }
  return {
    for (final entry in members.entries)
      entry.key: taskDraftStatus(entry.value.values),
  };
}
