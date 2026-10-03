import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../components/inputs/uten_field_message.dart';
import '../../components/inputs/uten_input_decoration.dart';
import '../../components/layout/uten_editable_grid.dart';
import '../../core/ui/app_notification.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/l10n/gen/app_localizations_zh.dart';
import 'business_column.dart';
import 'business_column_picker.dart';

mixin BusinessColumnsRow on EditableGridRow {
  final extraColumnsChanged = _BusinessColumnSignal();
  final _extraDefinitions = <BusinessColumn>[];
  final _extraControllers = <String, TextEditingController>{};

  List<BusinessColumn> get extraColumnDefinitions =>
      List.unmodifiable(_extraDefinitions);
  Iterable<Listenable> get extraColumnListenables => [
    extraColumnsChanged,
    ..._extraControllers.values,
  ];

  TextEditingController extraColumnController(BusinessColumn column) {
    if (!_extraDefinitions.any((c) => c.id == column.id)) {
      // New or imported rows inherit the header, never another row's operand.
      _extraDefinitions.add(
        BusinessColumn(
          id: column.id,
          name: column.name,
          scope: column.scope,
          type: column.type,
          operation: column.operation,
        ),
      );
      final controller = TextEditingController();
      controller.addListener(extraColumnsChanged.changed);
      return _extraControllers.putIfAbsent(column.id, () => controller);
    }
    return _extraControllers.putIfAbsent(column.id, () {
      final controller = TextEditingController(text: column.value ?? '');
      controller.addListener(extraColumnsChanged.changed);
      return controller;
    });
  }

  void addExtraColumn(BusinessColumn column) {
    if (_extraDefinitions.any((c) => c.id == column.id)) return;
    _extraDefinitions.add(column);
    extraColumnController(column);
    extraColumnsChanged.changed();
  }

  /// Removing a document column also removes its operand. Hiding a header is
  /// a separate layout action and must never change the agreed amount.
  bool removeExtraColumn(String columnId) {
    final index = _extraDefinitions.indexWhere((c) => c.id == columnId);
    if (index < 0) return false;
    _extraDefinitions.removeAt(index);
    final controller = _extraControllers.remove(columnId);
    controller?.removeListener(extraColumnsChanged.changed);
    controller?.dispose();
    extraColumnsChanged.changed();
    return true;
  }

  void restoreExtraColumns(Object? raw) {
    for (final column in BusinessColumn.read(raw)) {
      addExtraColumn(column);
      extraColumnController(column).text = column.value ?? '';
    }
  }

  List<BusinessColumn> get extraColumnSnapshots => [
    for (final column in _extraDefinitions)
      BusinessColumn.fromJson(
        column.toSnapshot(extraColumnController(column).text.trim()),
      ),
  ];

  List<Map<String, dynamic>> extraColumnsPayload({bool priceMasked = false}) =>
      [
        for (final column in _extraDefinitions)
          {
            'columnId': column.id,
            'value': priceMasked && column.financial
                ? null
                : extraColumnController(column).text.trim(),
          },
      ];

  List<Map<String, dynamic>> exportExtraColumns() => [
    for (final column in extraColumnSnapshots) column.toSnapshot(),
  ];

  void copyExtraColumnsTo(BusinessColumnsRow target) =>
      target.restoreExtraColumns(exportExtraColumns());

  String get extraColumnsSignature => jsonEncode(exportExtraColumns());

  /// Merging two lines would charge a fixed fee only once. Keep those lines
  /// separate even when the fee and product happen to be identical.
  bool get extraColumnsPreventMerge => extraColumnSnapshots.any(
    (column) =>
        (column.operation == 'ADD' || column.operation == 'SUBTRACT') &&
        (column.value?.trim().isNotEmpty ?? false) &&
        businessExactDecimal(column.value) != '0',
  );

  String? applyExtraColumnAmount(String? base) =>
      businessColumnAmount(base, extraColumnSnapshots);

  bool extraColumnsValid(String? base) {
    for (final column in extraColumnSnapshots) {
      final raw = column.value?.trim() ?? '';
      if (!_businessColumnValueValid(column, raw)) return false;
    }
    return base == null || applyExtraColumnAmount(base) != null;
  }

  @override
  void dispose() {
    for (final controller in _extraControllers.values) {
      controller.dispose();
    }
    extraColumnsChanged.dispose();
    super.dispose();
  }
}

List<EditableGridColumn<T>> businessEditableColumns<T extends EditableGridRow>(
  Iterable<BusinessColumn> definitions, {
  required BusinessColumnsRow Function(T) rowOf,
  bool priceMasked = false,
  String? amountHint,
}) => [
  for (final column in definitions)
    EditableGridColumn<T>(
      key: column.key,
      exportDefinition: {...column.toSnapshot()}..remove('value'),
      label: column.label,
      width: column.numeric ? 130 : 170,
      numeric: column.numeric,
      headerInfo: column.affectsAmount ? amountHint : null,
      textOf: (row) => priceMasked && column.financial
          ? '***'
          : rowOf(row).extraColumnController(column).text,
      listenableOf: (row) => rowOf(row).extraColumnController(column),
      cellBuilder: (context, row) => priceMasked && column.financial
          ? const Text('***')
          : _BusinessColumnInput(
              column: column,
              controller: rowOf(row).extraColumnController(column),
            ),
    ),
];

int _businessColumnMaxLength(BusinessColumn column) =>
    column.numeric ? 120 : 2000;

bool _businessColumnValueValid(BusinessColumn column, String raw) {
  if (raw.length > _businessColumnMaxLength(column)) return false;
  if (raw.isEmpty || !column.numeric) return true;
  final value = businessExactDecimal(raw);
  return value != null && !(column.operation == 'DIVIDE' && value == '0');
}

class _BusinessColumnInput extends StatelessWidget {
  const _BusinessColumnInput({required this.column, required this.controller});

  final BusinessColumn column;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (context, value, _) {
          final text =
              Localizations.of<AppLocalizations>(context, AppLocalizations) ??
              AppLocalizationsZh();
          final raw = value.text.trim();
          final limit = _businessColumnMaxLength(column);
          final error = raw.length > limit
              ? text.aiSettingsTooLong(limit)
              : !_businessColumnValueValid(column, raw)
              ? text.businessColumnInvalid
              : null;
          return TextField(
            controller: controller,
            textAlign: column.numeric ? TextAlign.right : TextAlign.left,
            keyboardType: column.numeric
                ? const TextInputType.numberWithOptions(
                    decimal: true,
                    signed: true,
                  )
                : TextInputType.text,
            maxLength: limit,
            // Preserve pasted/imported input for correction instead of silently
            // truncating a numeric operand or a customer's reference code.
            maxLengthEnforcement: MaxLengthEnforcement.none,
            decoration: UtenInputDecoration(
              InputDecoration(
                border: InputBorder.none,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                hintText: column.name,
                counterText: '',
                error: utenFieldError(error),
              ),
            ),
          );
        },
      );
}

List<BusinessColumn> businessColumnsOf(Iterable<BusinessColumnsRow> rows) {
  final columns = <String, BusinessColumn>{};
  for (final row in rows) {
    for (final column in row.extraColumnDefinitions) {
      columns.putIfAbsent(column.id, () => column);
    }
  }
  return columns.values.toList(growable: false);
}

T inheritBusinessColumns<T extends BusinessColumnsRow>(
  T row,
  Iterable<BusinessColumnsRow> existing,
) {
  for (final column in businessColumnsOf(existing)) {
    row.addExtraColumn(
      BusinessColumn.fromJson({...column.toSnapshot(), 'value': null}),
    );
  }
  return row;
}

void synchronizeBusinessColumns(Iterable<BusinessColumnsRow> rows) {
  final list = rows.toList(growable: false);
  final columns = businessColumnsOf(list);
  for (final row in list) {
    for (final column in columns) {
      row.addExtraColumn(
        BusinessColumn.fromJson({...column.toSnapshot(), 'value': null}),
      );
    }
  }
}

/// Adds an explicit choice to the current document. Catalog history only ranks
/// suggestions; it never inserts a saved fee into another document automatically.
Future<String?> addBusinessGridColumn<T extends EditableGridRow>(
  BuildContext context, {
  required String scope,
  required List<EditableGridColumn<T>> hiddenColumns,
  required Iterable<BusinessColumnsRow> rows,
  required VoidCallback onChanged,
  Iterable<BusinessColumnsRow> Function()? currentRows,
  BusinessColumnsRow Function()? createRow,
  bool priceMasked = false,
  bool Function()? isEditingEnabled,
}) async {
  if (!(isEditingEnabled?.call() ?? true)) return null;
  final initial = (currentRows?.call() ?? rows).toList();
  final choice = await showBusinessColumnPicker(
    context,
    scope: scope,
    systemColumns: hiddenColumns.map(
      (c) => BusinessSystemColumn(c.key, c.label),
    ),
    existingIds: businessColumnsOf(initial).map((c) => c.id).toSet(),
    existingColumns: businessColumnsOf(initial),
    priceMasked: priceMasked,
    isEditingEnabled: isEditingEnabled,
  );
  if (choice == null ||
      !context.mounted ||
      !(isEditingEnabled?.call() ?? true)) {
    return null;
  }
  // The document can refresh while the picker is open. Apply to its current
  // rows, never the previous snapshot's potentially disposed controllers.
  final current = (currentRows?.call() ?? rows).toList();
  final removeId = choice.removeColumnId;
  if (removeId != null) {
    final existing = [
      for (final row in current)
        ...row.extraColumnDefinitions.where((column) => column.id == removeId),
    ];
    if (existing.isEmpty ||
        (priceMasked && existing.any((column) => column.financial))) {
      return null;
    }
    for (final row in current) {
      row.removeExtraColumn(removeId);
    }
    onChanged();
    return null;
  }
  if (choice.systemKey != null) return choice.systemKey;
  final column = choice.column;
  if (column == null) return null;
  if (businessColumnsOf(current).any((c) => c.id == column.id)) {
    return column.key;
  }
  if (businessColumnsOf(current).length >= 32) {
    context.appError(
      (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
              AppLocalizationsZh())
          .businessColumnLimit,
    );
    return null;
  }
  if (current.isEmpty && createRow != null) current.add(createRow());
  for (final row in current) {
    row.addExtraColumn(column);
  }
  onChanged();
  return column.key;
}

class _BusinessColumnSignal extends ChangeNotifier {
  void changed() => notifyListeners();
}

Set<String> filledBusinessColumnKeys(Iterable<BusinessColumnsRow> rows) => {
  for (final row in rows)
    for (final column in row.extraColumnSnapshots)
      if (column.value?.trim().isNotEmpty ?? false) column.key,
};
