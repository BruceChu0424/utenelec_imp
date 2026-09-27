import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/utils/china_datetime.dart';
import 'form_draft.dart';
import 'form_draft_store.dart';
import '../providers/draft_counts_provider.dart' show DraftDocKind;

export 'form_draft.dart';
export 'form_draft_category_table.dart'
    show
        FormDraftCategoryTable,
        FormDraftCategoryList,
        FormDraftCategoryHost,
        FormDraftCategoryRow,
        deleteFormDrafts;

/// A business draft category. Module-only scopes are for categories without a
/// pre-existing document list; document lists use kind and/or exact route.
class FormDraftCategoryScope {
  const FormDraftCategoryScope({
    this.kind,
    this.module,
    this.routePrefix,
    this.routePath,
    this.routePrefixes = const {},
    this.query = const {},
    this.excludeKinds = const {},
    this.excludeRoutes = const {},
  });
  final String? kind;
  final BadgeModule? module;
  final String? routePrefix;
  final String? routePath;
  final Set<String> routePrefixes;
  final Map<String, String> query;
  final Set<String> excludeKinds;
  final Set<String> excludeRoutes;

  bool matches(FormDraft draft) {
    final uri = Uri.parse(draft.route);
    return (kind == null || formDraftBusinessKind(draft) == kind) &&
        (module == null || draft.module == module) &&
        (routePrefix == null || uri.path.startsWith(routePrefix!)) &&
        (routePath == null || uri.path == routePath) &&
        (routePrefixes.isEmpty || routePrefixes.any(uri.path.startsWith)) &&
        !excludeKinds.contains(formDraftBusinessKind(draft)) &&
        !excludeRoutes.contains(uri.path) &&
        query.entries.every(
          (item) => uri.queryParameters[item.key] == item.value,
        );
  }

  @override
  bool operator ==(Object other) =>
      other is FormDraftCategoryScope &&
      other.kind == kind &&
      other.module == module &&
      other.routePrefix == routePrefix &&
      other.routePath == routePath &&
      setEquals(other.routePrefixes, routePrefixes) &&
      mapEquals(other.query, query) &&
      setEquals(other.excludeKinds, excludeKinds) &&
      setEquals(other.excludeRoutes, excludeRoutes);
  @override
  int get hashCode => Object.hash(
    kind,
    module,
    routePrefix,
    routePath,
    Object.hashAllUnordered(routePrefixes),
    Object.hashAllUnordered(
      query.entries.map((e) => Object.hash(e.key, e.value)),
    ),
    Object.hashAllUnordered(excludeKinds),
    Object.hashAllUnordered(excludeRoutes),
  );
}

final formDraftCategoryProvider =
    Provider.family<List<FormDraft>, FormDraftCategoryScope>((ref, scope) {
      final result = ref
          .watch(formDraftsProvider)
          .where(scope.matches)
          .toList();
      result.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return result;
    });

final formDraftCategoryCountProvider =
    Provider.family<int, FormDraftCategoryScope>(
      (ref, scope) => ref
          .watch(formDraftCategoryProvider(scope))
          .where(
            (draft) =>
                !formDraftHasFormalDraftCounter(draft) ||
                formDraftConfirmedIds(draft).isEmpty,
          )
          .length,
    );

String? formDraftBusinessKind(FormDraft draft) =>
    draft.draftKind ??
    (Uri.parse(draft.route).path == '/sales/customer-shipments/new'
        ? 'salesShipment'
        : null);

bool formDraftHasFormalDraftCounter(FormDraft draft) =>
    formDraftBusinessKind(draft) == 'expense' ||
    DraftDocKind.values.any(
      (kind) => kind.name == formDraftBusinessKind(draft),
    );

/// Categories with no server list count every locally resumable workflow,
/// including a confirmed creation still waiting for its attachments.
final formDraftCategoryVisibleCountProvider =
    Provider.family<int, FormDraftCategoryScope>(
      (ref, scope) => ref.watch(formDraftCategoryProvider(scope)).length,
    );

/// A persisted editor checkpoint may be finishing attachments for a business
/// document that already exists. It overlays that row, never adds a second one.
Set<String> formDraftConfirmedIds(FormDraft draft) {
  final result = <String>{};
  void add(Object? value) {
    if (value is String && value.trim().isNotEmpty) result.add(value);
  }

  for (final key in [
    'createdDocId',
    'createdReportId',
    'createdId',
    'batchId',
  ]) {
    add(draft.data[key]);
  }
  for (final key in ['createdOrders', 'createdShipments']) {
    final list = draft.data[key];
    if (list is List) {
      for (final item in list) {
        if (item is Map) add(item['id']);
      }
    }
  }
  return result;
}

Map<String, dynamic> formDraftHeader(FormDraft draft) => {
  for (final key in ['text', 'fields', 'header'])
    if (draft.data[key] is Map<String, dynamic>)
      ...draft.data[key] as Map<String, dynamic>,
  ...draft.data,
};

String formDraftFieldKey(String key) =>
    const {
      'client': 'clientId',
      'clientName': 'clientId',
      'customer': 'clientId',
      'customerName': 'clientId',
      'supplier': 'supplierId',
      'supplierName': 'supplierId',
      'currency': 'currencyId',
      'currencyName': 'currencyId',
      'warehouse': 'warehouseId',
      'warehouseName': 'warehouseId',
      'department': 'departmentId',
      'departmentName': 'departmentId',
      'account': 'accountId',
      'accountName': 'accountId',
      'seller': 'sellerId',
      'sellerName': 'sellerId',
      'sender': 'senderId',
      'senderName': 'senderId',
      'goods': 'goodsId',
      'goodsName': 'goodsId',
    }[key] ??
    key;

/// Match UUID identities, including row-level suppliers in multi-order drafts.
Set<String> formDraftColumnRawValues(FormDraft draft, String key) {
  final canonical = formDraftFieldKey(key);
  final values = <String>{};
  void collect(Object? node, int depth) {
    if (depth > 5) return;
    if (node is Map) {
      final raw = node[canonical];
      if (raw is String && raw.isNotEmpty) values.add(raw);
      if (raw is num) values.add(raw.toString());
      if (canonical == 'goodsId' && node['goods'] is Map) {
        final id = (node['goods'] as Map)['id'];
        if (id is String) values.add(id);
      }
      for (final entry in node.entries) {
        if (const {
          'attachments',
          'pendingFiles',
          'bytes',
          'createdOrders',
          'createdShipments',
          'priceContext',
          'sourceRefs',
          'autofillValues',
        }.contains(entry.key)) {
          continue;
        }
        if (entry.value is Map || entry.value is List) {
          collect(entry.value, depth + 1);
        }
      }
    } else if (node is List) {
      for (final row in node) {
        collect(row, depth + 1);
      }
    }
  }

  collect(draft.data, 0);
  return values;
}

/// Values are editor facts only. Missing amounts/parties stay empty, never
/// fabricated zeroes, invoice numbers, approval states or inventory quantities.
String? formDraftColumnValue(FormDraft draft, String key) {
  final values = formDraftHeader(draft);
  if (key == 'billNo' || key == 'number' || key == 'no') {
    return '未提交草稿';
  }
  if ((key == 'title' || key == 'name' || key == 'code') &&
      values[key] is String &&
      (values[key] as String).isNotEmpty) {
    return values[key] as String;
  }
  if (key == 'title' &&
      values['name'] is String &&
      (values['name'] as String).isNotEmpty) {
    return '${draft.title} · ${values['name']}';
  }
  if (key == 'title' && values['year'] is num && values['month'] is num) {
    return '${draft.title} · ${values['year']}-${values['month'].toString().padLeft(2, '0')}';
  }
  if (key == 'code') return '未提交草稿';
  if (key == 'title' ||
      key == 'name' ||
      key == 'documentType' ||
      key == 'docType') {
    return draft.title;
  }
  if (key == 'status' ||
      key == 'statusLabel' ||
      key == 'stage' ||
      key == 'progress') {
    return '草稿';
  }
  if (key == 'updatedAt' || key == 'createdAt' || key == 'savedAt') {
    return ChinaDateTime.formatInstant(draft.updatedAt);
  }
  final aliases = <String, String>{
    'date': 'billDate',
    'notes': 'remark',
    'description': 'remark',
  };
  final value = values[aliases[key] ?? key];
  if (value is! String && value is! num) return null;
  final text = value.toString();
  if (key.toLowerCase().contains('date')) return text.split('T').first;
  return text.isEmpty ? null : text;
}
