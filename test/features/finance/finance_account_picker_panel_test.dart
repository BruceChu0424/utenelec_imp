import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/finance/widgets/finance_account_picker_panel.dart';

void main() {
  testWidgets(
    'account picker requires all words across the displayed name and currency and keeps disabled rows out',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 844));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? selected;
      await _open(tester, const [
        FinanceAccountReference(
          id: 'cny',
          code: 'ZH001',
          name: '基本户',
          currencyName: '人民币',
          currencyCode: 'CNY',
          status: '使用',
        ),
        FinanceAccountReference(
          id: 'usd',
          code: 'ZH002',
          name: '外贸基本户',
          currencyName: '美金',
          currencyCode: 'USD',
          status: '使用',
        ),
        FinanceAccountReference(
          id: 'disabled',
          code: 'ZH003',
          name: '外贸基本户',
          currencyName: '美金',
          currencyCode: 'USD',
          status: '禁用',
        ),
      ], (value) => selected = value);
      await tester.enterText(_search(), 'USD 基本户');
      await tester.pumpAndSettle();
      expect(_titles(tester), ['ZH002 · 外贸基本户']);
      await tester.tap(find.text('ZH002 · 外贸基本户'));
      await tester.pumpAndSettle();
      expect(selected, 'usd');
    },
  );

  testWidgets(
    'account names rank before code-only hits and ties keep the supplied order',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _open(tester, const [
        FinanceAccountReference(
          id: 'code',
          code: 'MAIN',
          name: '别的账户',
          status: '使用',
        ),
        FinanceAccountReference(
          id: 'first',
          code: 'B',
          name: '备用 MAIN 账户',
          status: '使用',
        ),
        FinanceAccountReference(
          id: 'second',
          code: 'A',
          name: '备用 MAIN 账户',
          status: '使用',
        ),
        FinanceAccountReference(
          id: 'exact',
          code: 'Z',
          name: 'MAIN',
          status: '使用',
        ),
        FinanceAccountReference(
          id: 'literal',
          code: 'L',
          name: '字面_%账户',
          status: '使用',
        ),
      ], (_) {});
      await tester.enterText(_search(), 'MAIN');
      await tester.pumpAndSettle();
      expect(_titles(tester), [
        'Z · MAIN',
        'B · 备用 MAIN 账户',
        'A · 备用 MAIN 账户',
        'MAIN · 别的账户',
      ]);
      await tester.enterText(_search(), '%');
      await tester.pumpAndSettle();
      expect(_titles(tester), ['L · 字面_%账户']);
      expect(tester.takeException(), isNull);
    },
  );
}

Finder _search() => find.descendant(
  of: find.byType(UtenSearchBar),
  matching: find.byType(TextField),
);
List<String?> _titles(WidgetTester tester) => tester
    .widgetList<ListTile>(find.byType(ListTile))
    .map((tile) => (tile.title as Text).data)
    .toList();
Future<void> _open(
  WidgetTester tester,
  List<FinanceAccountReference> accounts,
  ValueChanged<String?> selected,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => selected(
              await showFinanceAccountPickerPanel(
                context: context,
                accounts: accounts,
              ),
            ),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}
