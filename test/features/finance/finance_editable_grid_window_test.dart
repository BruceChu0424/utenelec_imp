import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_input.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_pagination.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/features/finance/widgets/finance_editable_grid_window.dart';

class _Row extends EditableGridRow {
  _Row(this.id)
    : text = TextEditingController(text: '$id.000000000000000000000001');
  final int id;
  final TextEditingController text;
  int disposed = 0;
  @override
  void dispose() {
    disposed++;
    text.dispose();
    super.dispose();
  }
}

void main() {
  testWidgets(
    'two thousand owned rows stay complete and exact while only visible editors mount',
    (t) async {
      final all = UtenEditableGridController<_Row>()
        ..addRows([for (var i = 0; i < 2000; i++) _Row(i)]);
      await _pump(t, all);
      expect(_view(t).controller.length, 2000);
      expect(identical(_view(t).controller, all), true);
      expect(find.byType(UtenInput).evaluate().length, lessThan(100));
      expect(find.byType(UtenPagination), findsNothing);
      expect(identical(_view(t).controller[0], all[0]), isTrue);
      all[0].text.text = '12345678901234.123456789012345678901234';
      final scroll = t
          .widgetList<SingleChildScrollView>(find.byType(SingleChildScrollView))
          .firstWhere((widget) => widget.controller != null)
          .controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await t.pumpAndSettle();
      expect(_view(t).controller.length, 2000);
      expect(identical(_view(t).controller.rows.last, all.rows.last), true);
      expect(all[0].disposed, 0);
      all.rows.last.text.text = '1.';
      scroll.jumpTo(0);
      await t.pumpAndSettle();
      expect(all[0].text.text, '12345678901234.123456789012345678901234');
      expect(all.rows.last.text.text, '1.');
      await t.pumpWidget(const SizedBox());
      expect(all.rows.every((row) => row.disposed == 0), isTrue);
      all[0].text.text = 'still owned';
      expect(all[0].text.text, 'still owned');
      final rows = all.rows;
      all.dispose();
      expect(rows.every((row) => row.disposed == 1), isTrue);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'view delete and add mutate complete source once and old disabled callbacks cannot mutate it',
    (t) async {
      final all = UtenEditableGridController<_Row>()
        ..addRows([for (var i = 0; i < 60; i++) _Row(i)]);
      var next = 60;
      await _pump(t, all, editable: true, create: () => _Row(next++));
      final removed = all.rows.last;
      _view(t).onDeleteRow!(removed, 59);
      await t.pumpAndSettle();
      expect(all.length, 59);
      expect(removed.disposed, 1);
      await t.tap(find.widgetWithText(UtenButton, '添加行'));
      await t.pumpAndSettle();
      expect(all.length, 60);
      expect(all.rows.last.id, 60);
      expect(_view(t).controller.rows.last, all.rows.last);
      final staleDelete = _view(t).onDeleteRow!,
          staleAdd = t
              .widget<UtenButton>(find.widgetWithText(UtenButton, '添加行'))
              .onPressed!;
      await _pump(t, all, create: () => _Row(next++));
      staleDelete(all[0], 0);
      staleAdd();
      await t.pumpAndSettle();
      expect(all.length, 60);
      await t.pumpWidget(const SizedBox());
      all.dispose();
      expect(t.takeException(), isNull);
    },
  );
}

UtenEditableGrid<_Row> _view(WidgetTester t) => t.widget(
  find.byWidgetPredicate((widget) => widget is UtenEditableGrid<_Row>),
);
Future<void> _pump(
  WidgetTester t,
  UtenEditableGridController<_Row> all, {
  bool editable = false,
  _Row Function()? create,
}) async {
  t.view.physicalSize = const Size(1400, 850);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: FinanceEditableGridWindow<_Row>(
          controller: all,
          showAddRow: editable,
          createBlankRow: create,
          showRowDelete: editable,
          showRemoveRowsAction: editable,
          columns: [
            EditableGridColumn(
              key: 'id',
              label: '原行',
              width: 130,
              cellBuilder: (_, row) => Text(row.id.toString()),
            ),
            EditableGridColumn(
              key: 'amount',
              label: '原十进制输入',
              width: 500,
              cellBuilder: (_, row) => UtenInput(controller: row.text),
            ),
          ],
        ),
      ),
    ),
  );
  await t.pumpAndSettle();
}
