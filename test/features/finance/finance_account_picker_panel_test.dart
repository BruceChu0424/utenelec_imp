import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
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
      await tester.tap(find.text('外贸基本户'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(find.text('选择收款账户'), findsOneWidget);
      expect(_isSelected(tester, 'usd'), isTrue);
      await tester.tap(find.byKey(const Key('finance-account-picker-confirm')));
      await tester.pumpAndSettle();
      expect(selected, 'usd');
    },
  );

  for (final dismissal in ['取消', '关闭', '遮罩']) {
    testWidgets('account draft is discarded by $dismissal', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final results = <String?>[];
      await _open(
        tester,
        const [
          FinanceAccountReference(id: 'old', name: '原账户', status: '使用'),
          FinanceAccountReference(id: 'new', name: '新账户', status: '使用'),
        ],
        results.add,
        selectedId: 'old',
      );
      await tester.tap(find.text('新账户'));
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      if (dismissal == '遮罩') {
        await tester.tapAt(const Offset(20, 400));
      } else if (dismissal == '关闭') {
        await tester.tap(find.byTooltip('关闭'));
      } else {
        await tester.tap(find.text('取消'));
      }
      await tester.pumpAndSettle();
      expect(results, [null]);
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();
      expect(_isSelected(tester, 'old'), isTrue);
    });
  }

  testWidgets('disabled initial account cannot be confirmed', (tester) async {
    await _open(
      tester,
      const [
        FinanceAccountReference(id: 'disabled', name: '禁用账户', status: '禁用'),
        FinanceAccountReference(id: 'usable', name: '可用账户', status: '使用'),
      ],
      (_) {},
      selectedId: 'disabled',
    );
    expect(find.text('禁用账户'), findsNothing);
    expect(
      tester
          .widget<UtenButton>(
            find.byKey(const Key('finance-account-picker-confirm')),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('local search keeps an eligible draft until confirmation', (
    tester,
  ) async {
    String? selected;
    await _open(tester, const [
      FinanceAccountReference(id: 'first', name: '第一账户', status: '使用'),
      FinanceAccountReference(id: 'second', name: '第二账户', status: '使用'),
    ], (value) => selected = value);
    await tester.tap(find.text('第一账户'));
    await tester.pumpAndSettle();
    await tester.enterText(_search(), '第二');
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.text('已选择：第一账户'), findsOneWidget);
    await tester.tap(find.byKey(const Key('finance-account-picker-confirm')));
    await tester.pumpAndSettle();
    expect(selected, 'first');
  });

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
bool _isSelected(WidgetTester tester, String id) {
  final table = tester.widget<MasterDataTableView<FinanceAccountReference>>(
    find.byType(MasterDataTableView<FinanceAccountReference>),
  );
  return table.isSelected!(table.items.firstWhere((item) => item.id == id));
}

List<String?> _titles(WidgetTester tester) => tester
    .widget<MasterDataTableView<FinanceAccountReference>>(
      find.byType(MasterDataTableView<FinanceAccountReference>),
    )
    .items
    .map((a) => '${a.code} · ${a.name}')
    .toList();
Future<void> _open(
  WidgetTester tester,
  List<FinanceAccountReference> accounts,
  ValueChanged<String?> selected, {
  String? selectedId,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => selected(
              await showFinanceAccountPickerPanel(
                context: context,
                accounts: accounts,
                selectedId: selectedId,
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
