import 'package:flutter/material.dart';

import '../buttons/uten_button.dart';
import '../feedback/uten_dialog.dart';
import '../inputs/uten_field_hint_icon.dart';
import '../../core/performance/ui_work_budget.dart';

/// A frozen checkbox selection, shared by download and paper output.
/// Raw selectors only restrict authorized server rows; they never supply cells.
class UtenTableOutputSelection {
  const UtenTableOutputSelection({
    this.ids = const {},
    this.rows = const [],
    this.displayRows = const [],
    this.load,
  });

  final Set<String> ids;
  final List<Map<String, String?>> rows;
  final List<Map<String, String?>> displayRows;
  final Future<UtenTableOutputSelection> Function()? load;
  Future<UtenTableOutputSelection> snapshot() async =>
      load == null ? this : await load!();
  int get count => ids.length;
}

enum UtenTableOutputScope { all, selected }

/// Missing nullable source fields have the same meaning in every selected row.
Future<List<Map<String, String?>>> rectangularUtenOutputRows(
  List<Map<String, String?>> rows, {
  required bool Function() isCurrent,
}) async {
  final work = UiWorkBudget(isCurrent: isCurrent);
  final keys = <String>{};
  for (final row in rows) {
    keys.addAll(row.keys);
    await work.checkpoint();
  }
  final result = <Map<String, String?>>[];
  for (final row in rows) {
    result.add({for (final key in keys) key: row[key]});
    await work.checkpoint();
  }
  work.ensureCurrent();
  return result;
}

/// One control is shared by the export form and standalone paper scope.
class UtenTableOutputScopeField extends StatelessWidget {
  const UtenTableOutputScopeField({
    super.key,
    required this.value,
    required this.selectedCount,
    required this.onChanged,
  });
  final UtenTableOutputScope value;
  final int selectedCount;
  final ValueChanged<UtenTableOutputScope> onChanged;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, bounds) {
      Widget choice(
        UtenTableOutputScope scope,
        String label,
        Key key,
        bool enabled,
      ) => Semantics(
        selected: value == scope,
        child: UtenButton(
          key: key,
          isExpanded: true,
          type: value == scope
              ? UtenButtonType.tonal
              : UtenButtonType.secondary,
          icon: value == scope
              ? Icons.radio_button_checked_rounded
              : Icons.radio_button_off_rounded,
          onPressed: enabled ? () => onChanged(scope) : null,
          child: Text(label),
        ),
      );
      final all = choice(
        UtenTableOutputScope.all,
        '全部结果',
        const ValueKey('table-output-all'),
        true,
      );
      final selected = choice(
        UtenTableOutputScope.selected,
        '仅已选（$selectedCount 项）',
        const ValueKey('table-output-selected'),
        selectedCount > 0,
      );
      if (bounds.maxWidth < 380 ||
          MediaQuery.textScalerOf(context).scale(14) > 20) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [all, const SizedBox(height: 8), selected],
        );
      }
      return Row(
        children: [
          Expanded(child: all),
          const SizedBox(width: 8),
          Expanded(child: selected),
        ],
      );
    },
  );
}

Future<UtenTableOutputScope?> showUtenTableOutputScope({
  required BuildContext context,
  required String action,
  required int selectedCount,
}) => showDialog<UtenTableOutputScope>(
  context: context,
  builder: (dialogContext) => UtenAlertDialog(
    maxWidth: 440,
    title: Row(
      children: [
        Flexible(child: Text('$action范围')),
        const UtenFieldHintIcon(info: '全部结果包含当前分类、搜索和表头筛选下的全部分页。', dense: true),
      ],
    ),
    content: UtenTableOutputScopeField(
      value: UtenTableOutputScope.all,
      selectedCount: selectedCount,
      onChanged: (scope) => Navigator.pop(dialogContext, scope),
    ),
    actionsAlignment: MainAxisAlignment.end,
    actions: [
      UtenButton(
        type: UtenButtonType.ghost,
        onPressed: () => Navigator.pop(dialogContext),
        child: const Text('取消'),
      ),
    ],
  ),
);
