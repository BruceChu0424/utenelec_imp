import 'dart:convert';

import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/task_form_drafts.dart';
import 'warehouse_draw_task.dart';

bool _queryContains(FormDraft draft, String key, String id) =>
    id.isNotEmpty &&
    (Uri.tryParse(draft.route)?.queryParameters[key]?.split(',') ?? const [])
        .map((value) => value.trim())
        .contains(id);

Set<String>? _strictIds(Object? raw) {
  if (raw is! List ||
      raw.isEmpty ||
      raw.any((id) => id is! String || id.isEmpty || id.trim() != id)) {
    return null;
  }
  final ids = raw.cast<String>().toSet();
  return ids.length == raw.length ? ids : null;
}

/// These editor routes define an omitted scope as their legacy whole source.
/// A present empty/malformed scope, or a snapshot whose scope lost its route,
/// never inherits that compatibility meaning.
bool _physicalMember(
  FormDraft draft,
  Iterable<String>? currentIds, {
  String queryKey = 'itemIds',
  String dataKey = 'selectedItemIds',
}) {
  final query = Uri.tryParse(draft.route)?.queryParameters;
  if (query == null) return false;
  final rawSaved = draft.data[dataKey];
  if (query.containsKey(queryKey)) {
    final routed = _strictIds(query[queryKey]!.split(','));
    if (routed == null) return false;
    if (draft.data.containsKey(dataKey)) {
      final saved = _strictIds(rawSaved);
      if (saved == null ||
          saved.length != routed.length ||
          !saved.containsAll(routed)) {
        return false;
      }
    }
    return currentIds == null || currentIds.any(routed.contains);
  }
  if (rawSaved != null) return false;
  return currentIds == null || currentIds.isNotEmpty;
}

List<FormDraft> arrivalTaskDrafts(
  Iterable<FormDraft> drafts,
  String expectationId, {
  String? expectationItemId,
}) => taskDraftsFor(
  drafts,
  matches: (draft) =>
      FormDraftCatalog.arrival.groups(draft) &&
      _queryContains(draft, 'expectationIds', expectationId) &&
      _physicalMember(
        draft,
        expectationItemId == null ? null : [expectationItemId],
        queryKey: 'expectationItemIds',
        dataKey: 'expectationItemIds',
      ) &&
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
  String issueId, {
  String? itemId,
}) => taskDraftsFor(
  drafts,
  matches: (draft) =>
      _physicalMember(draft, itemId == null ? null : [itemId]) &&
      ((FormDraftCatalog.subcontractOutbound.groups(draft) &&
              Uri.tryParse(draft.route)?.path ==
                  '/warehouse/subcontract-outbound/$issueId') ||
          (FormDraftCatalog.subcontractOutboundBatch.groups(draft) &&
              _queryContains(draft, 'issueIds', issueId) &&
              !(draft.data['completed'] is List &&
                  (draft.data['completed'] as List).contains(issueId)))),
);

List<FormDraft> salesOutboundTaskDrafts(
  Iterable<FormDraft> drafts,
  String shipmentId, {
  String? itemId,
}) => taskDraftsFor(
  drafts,
  matches: (draft) {
    if (!_physicalMember(draft, itemId == null ? null : [itemId])) return false;
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
  String? lotId,
  String? documentId,
  String? itemId,
}) => taskDraftsFor(
  drafts,
  matches: (draft) =>
      (reportId != null &&
          FormDraftCatalog.finishedArrival.groups(draft) &&
          _queryContains(draft, 'reportIds', reportId) &&
          (lotId == null || _finishedArrivalDraftContainsLot(draft, lotId))) ||
      (documentId != null &&
          FormDraftCatalog.productionFinishedBatchStockIn.groups(draft) &&
          _physicalMember(draft, itemId == null ? null : [itemId]) &&
          _finishedItemOwner(draft, itemId, documentId) &&
          _queryContains(draft, 'documentIds', documentId) &&
          (draft.data['selectedDocumentIds'] is! List ||
              (draft.data['selectedDocumentIds'] as List).contains(
                documentId,
              ))),
);

bool _finishedItemOwner(FormDraft draft, String? itemId, String documentId) {
  final query =
      Uri.tryParse(draft.route)?.queryParameters ?? const <String, String>{};
  final selected = query.containsKey('itemIds')
      ? _strictIds(query['itemIds']!.split(','))
      : null;
  final documents = (query['documentIds'] ?? '').split(',').toSet();
  bool valid(Object? raw) {
    if (raw is! Map ||
        raw.entries.any(
          (entry) => entry.key is! String || entry.value is! String,
        )) {
      return false;
    }
    final mapping = raw.cast<String, String>();
    if (selected == null) return mapping.isEmpty;
    return mapping.length == selected.length &&
        mapping.keys.toSet().containsAll(selected) &&
        documents.containsAll(mapping.values) &&
        (itemId == null || mapping[itemId] == documentId);
  }

  if (query.containsKey('itemDocuments')) {
    try {
      if (!valid(jsonDecode(query['itemDocuments']!))) return false;
    } on FormatException {
      return false;
    }
  }
  return !draft.data.containsKey('selectedItemDocuments') ||
      valid(draft.data['selectedItemDocuments']);
}

bool _finishedArrivalDraftContainsLot(FormDraft draft, String lotId) {
  if (Uri.tryParse(draft.route)?.queryParameters.containsKey('lotIds') ==
      true) {
    return _queryContains(draft, 'lotIds', lotId);
  }
  // Before lot-scoped routes, the snapshot is the only recorded lot identity.
  final rows = draft.data['rows'];
  return rows is! List ||
      rows.whereType<Map<Object?, Object?>>().any(
        (row) => row['lotId'] == lotId,
      );
}

List<FormDraft> stockTaskDrafts(
  Iterable<FormDraft> drafts,
  String documentId, {
  String? itemId,
}) => taskDraftsFor(
  drafts,
  matches: (draft) =>
      _physicalMember(draft, itemId == null ? null : [itemId]) &&
      ((FormDraftCatalog.warehouseDraw.groups(draft) &&
              _queryContains(draft, 'documentIds', documentId)) ||
          (FormDraftCatalog.materialReturnBatchReceive.groups(draft) &&
              _queryContains(draft, 'documentIds', documentId) &&
              !(draft.data['rows'] is List &&
                  (draft.data['rows'] as List)
                      .whereType<Map<Object?, Object?>>()
                      .any(
                        (row) =>
                            row['documentId'] == documentId &&
                            row['done'] == true,
                      )))),
);

List<FormDraft> workshopMaterialTaskDrafts(
  Iterable<FormDraft> drafts,
  String requisitionId, {
  String? lineId,
}) => taskDraftsFor(
  drafts,
  matches: (draft) {
    if (FormDraftCatalog.workshopMaterialBatchIssue.groups(draft)) {
      final uri = Uri.tryParse(draft.route);
      final raw = uri?.queryParameters['selections'];
      if (raw == null) return false;
      try {
        final routed = _workshopSelections(jsonDecode(raw));
        final saved = _workshopSelections(draft.data['selections']);
        if (routed == null ||
            saved == null ||
            jsonEncode(routed) != jsonEncode(saved)) {
          return false;
        }
        final lines = routed[requisitionId];
        return lines != null && (lineId == null || lines.contains(lineId));
      } on FormatException {
        return false;
      }
    }
    return FormDraftCatalog.workshopMaterialIssue.groups(draft) &&
        _queryContains(draft, 'requisitionId', requisitionId) &&
        _physicalMember(
          draft,
          lineId == null ? null : [lineId],
          queryKey: 'lineIds',
          dataKey: 'selectedLineIds',
        ) &&
        (!draft.data.containsKey('requisitionId') ||
            draft.data['requisitionId'] == requisitionId);
  },
);

Map<String, List<String>>? _workshopSelections(Object? raw) {
  if (raw is! Map || raw.isEmpty) return null;
  if (raw.keys.any(
    (key) => key is! String || key.isEmpty || key.trim() != key,
  )) {
    return null;
  }
  final result = <String, List<String>>{};
  for (final key in raw.keys.cast<String>().toList()..sort()) {
    final ids = _strictIds(raw[key]);
    if (ids == null) return null;
    result[key] = ids.toList()..sort();
  }
  return result;
}

Map<String, Object>? _discoveryScope(Object? raw) {
  if (raw is! String) return null;
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> || decoded.isEmpty) return null;
    final result = <String, Object>{};
    for (final key in decoded.keys.toList()..sort()) {
      final value = decoded[key];
      if (key.isEmpty ||
          value is! Map ||
          value['expectedVersion'] is! int ||
          (value['expectedVersion'] as int) < 0) {
        return null;
      }
      final keys = _strictIds(value['keys']);
      if (keys == null ||
          keys.any(
            (key) => !RegExp(r'^suggestion-[1-9][0-9]*$').hasMatch(key),
          )) {
        return null;
      }
      result[key] = {
        'expectedVersion': value['expectedVersion'],
        'keys': keys.toList()..sort(),
      };
    }
    return result;
  } on FormatException {
    return null;
  }
}

List<FormDraft> materialDiscoveryTaskDrafts(
  Iterable<FormDraft> drafts,
  String requestId, {
  String? suggestionKey,
  int? expectedVersion,
}) => taskDraftsFor(
  drafts,
  matches: (draft) {
    final uri = Uri.tryParse(draft.route);
    if (FormDraftCatalog.warehouseDiscovery.groups(draft) &&
        uri?.path == '/warehouse/material-discovery/$requestId') {
      return true;
    }
    if (!FormDraftCatalog.warehouseDraw.groups(draft) ||
        !_queryContains(draft, 'discoveryRequestIds', requestId)) {
      return false;
    }
    if (uri?.queryParameters.containsKey('discoverySelection') != true) {
      return draft.data['discoverySelection'] == null;
    }
    final scope = _discoveryScope(uri!.queryParameters['discoverySelection']);
    if (scope == null || !scope.containsKey(requestId)) return false;
    if (draft.data.containsKey('discoverySelection') &&
        jsonEncode(_discoveryScope(draft.data['discoverySelection'])) !=
            jsonEncode(scope)) {
      return false;
    }
    final member = scope[requestId] as Map<String, dynamic>;
    return (expectedVersion == null ||
            expectedVersion == member['expectedVersion']) &&
        (suggestionKey == null ||
            (member['keys'] as List<String>).contains(suggestionKey));
  },
);

List<FormDraft> qualityStockInTaskDrafts(
  Iterable<FormDraft> drafts,
  String receiptType,
  String receiptId, {
  String? inspectionItemId,
  Iterable<String>? inspectionItemIds,
}) => taskDraftsFor(
  drafts,
  matches: (draft) {
    final uri = Uri.tryParse(draft.route);
    final current =
        inspectionItemIds ??
        (inspectionItemId == null ? null : [inspectionItemId]);
    if (!_physicalMember(
      draft,
      current,
      queryKey: 'inspectionItemIds',
      dataKey: 'inspectionItemIds',
    )) {
      return false;
    }
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
