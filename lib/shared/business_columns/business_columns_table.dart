import '../../features/basic_data/widgets/master_data_table_view.dart';
import 'business_column.dart';

/// Uses the stored line snapshots, so catalog renames never rewrite old headers.
List<MasterColumnDef<T>> businessReadOnlyColumns<T>(
  Iterable<T> items, {
  required List<BusinessColumn> Function(T) columnsOf,
  bool priceMasked = false,
}) {
  final definitions = <String, BusinessColumn>{};
  for (final item in items) {
    for (final column in columnsOf(item)) {
      definitions.putIfAbsent(column.id, () => column);
    }
  }
  return [
    for (final column in definitions.values)
      MasterColumnDef<T>(
        key: column.key,
        exportDefinition: {...column.toSnapshot()}..remove('value'),
        label: column.label,
        width: column.numeric ? 130 : 170,
        type: column.numeric ? 'number' : 'text',
        sortable: !(priceMasked && column.financial),
        filterFromRows: !(priceMasked && column.financial),
        columnSearchEnabled: priceMasked && column.financial ? false : null,
        aiSensitive: column.financial,
        exactValueOf: column.numeric && !(priceMasked && column.financial)
            ? (item) {
                for (final value in columnsOf(item)) {
                  if (value.id == column.id) {
                    return businessExactDecimal(value.value);
                  }
                }
                return null;
              }
            : null,
        value: (item) {
          if (priceMasked && column.financial) return '***';
          for (final value in columnsOf(item)) {
            if (value.id == column.id) return value.value;
          }
          return null;
        },
      ),
  ];
}
