import '../../components/layout/uten_editable_grid.dart';

/// Spread into a business line request. The transaction bridge authorizes and
/// writes these values only when the enclosing business save commits.
Map<String, dynamic> platformRowPayload(EditableGridRow row) {
  final payload = row.platformFields.savePayload();
  return payload == null ? const {} : {'platformFields': payload};
}
