import 'package:flutter/material.dart';
import '../../components/data_display/uten_review_input_cell.dart';
import '../../components/layout/uten_editable_grid.dart';

/// Keeps the creation table's columns and renders retained values beside amendments.
List<EditableGridColumn<T>> reviewedGridColumns<T extends EditableGridRow>({
  required List<EditableGridColumn<T>> columns,
  required Map<T, Map<String, String?>> baseline,
  required Map<String, String?> Function(T) valuesOf,
  required Listenable Function(T) listenableOf,
  required Set<String> editableKeys,
  required String keyPrefix,
  bool Function(T row, String columnKey)? allowReadOnlyInteraction,
}) => [
  for (final column in columns)
    EditableGridColumn<T>(
      key: column.key,
      label: column.label,
      width: column.width,
      numeric: column.numeric,
      defaultVisible: column.defaultVisible,
      exportDefinition: column.exportDefinition,
      exactValueOf: column.exactValueOf,
      exactListenableOf: column.exactListenableOf,
      required: column.required,
      headerInfo: column.headerInfo,
      textOf: column.textOf,
      listenableOf: column.listenableOf,
      filterValueOf: column.filterValueOf,
      columnSearchEnabled: column.columnSearchEnabled,
      frozenTextOf: column.frozenTextOf,
      chromeWidth: column.chromeWidth,
      chromeWidthOf: column.chromeWidthOf,
      fillsCellHeight: column.fillsCellHeight,
      cellColor: column.cellColor,
      cellColorListenableOf: column.cellColorListenableOf,
      legendOf: column.legendOf,
      reviewReasonOf: column.reviewReasonOf,
      aiSensitive: column.aiSensitive,
      cellBuilder: (context, row) {
        final input = column.cellBuilder(context, row);
        if (!editableKeys.contains(column.key)) {
          if (allowReadOnlyInteraction?.call(row, column.key) == true) {
            return input;
          }
          return Focus(
            canRequestFocus: false,
            descendantsAreFocusable: false,
            child: AbsorbPointer(child: input),
          );
        }
        final before = baseline[row];
        if (before == null || !before.containsKey(column.key)) return input;
        return ListenableBuilder(
          listenable: listenableOf(row),
          builder: (context, _) => UtenReviewInputCell(
            before: before[column.key],
            after: valuesOf(row)[column.key],
            beforeKey: ValueKey('$keyPrefix-${column.key}-${row.hashCode}'),
            child: input,
          ),
        );
      },
    ),
];
