import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/uten_master_picker.dart';

Widget _field({
  bool allowClear = true,
  required ValueChanged<String?> changed,
  required Future<String?> Function() pick,
}) => MaterialApp(
  home: Scaffold(
    body: UtenMasterPickerField<String>(
      initialId: 'fixed',
      initialName: '固定往来方',
      label: '供应商',
      icon: Icons.store,
      allowClear: allowClear,
      onChanged: changed,
      onPick: pick,
      idOf: (id) => id,
      nameOf: (id) => '名称$id',
    ),
  ),
);

void main() {
  testWidgets(
    'required selectors retain selection while ordinary selectors can clear it',
    (tester) async {
      final changed = <String?>[];
      await tester.pumpWidget(
        _field(allowClear: false, changed: changed.add, pick: () async => null),
      );
      expect(find.byTooltip('清除选择'), findsNothing);
      expect(find.text('固定往来方'), findsOneWidget);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      expect(changed, isEmpty);
      await tester.pumpWidget(
        _field(changed: changed.add, pick: () async => null),
      );
      await tester.tap(find.byTooltip('清除选择'));
      await tester.pump();
      expect(changed, [null]);
      expect(find.text('固定往来方'), findsNothing);
    },
  );

  testWidgets('late selected row cannot publish into a disposed field', (
    tester,
  ) async {
    final selected = Completer<String?>();
    final changed = <String?>[];
    await tester.pumpWidget(
      _field(changed: changed.add, pick: () => selected.future),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpWidget(const SizedBox());
    selected.complete('late');
    await tester.pump();
    expect(changed, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
