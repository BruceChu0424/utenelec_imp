import 'form_draft_category.dart';

/// Resolve editor selections with the domain dictionaries already held by the
/// page. This projection never loads data or constructs a business record.
String? formDraftMasterColumnValue(
  FormDraft draft,
  String key, {
  Map<String, String> clients = const {},
  Map<String, String> suppliers = const {},
  Map<String, String> currencies = const {},
  Map<String, String> warehouses = const {},
}) {
  final entries = switch (formDraftFieldKey(key)) {
    'clientId' => clients,
    'supplierId' => suppliers,
    'currencyId' => currencies,
    'warehouseId' => warehouses,
    _ => null,
  };
  if (entries == null) return null;
  final ids = formDraftColumnRawValues(draft, key);
  if (ids.isEmpty) return null;
  final labels = <String>{};
  var unresolved = 0;
  for (final id in ids) {
    final name = entries[id]?.trim();
    if (name == null || name.isEmpty) {
      unresolved++;
    } else {
      labels.add(name);
    }
  }
  if (labels.isEmpty) return null; // Keep the shared offline fallback.
  if (unresolved > 0) labels.add('另 $unresolved 项已选择');
  return labels.join('、');
}
