import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:flutter/material.dart';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/finance/widgets/finance_account_picker_panel.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import '../../support/audit_screenshot_support.dart';

void main() {
  if (Platform.environment['UTEN_CAPTURE_FINANCE_PICKER'] == 'true') {
    for (final width in [390.0, 1200.0]) {
      testWidgets('account picker visual $width', (tester) async {
        await tester.binding.setSurfaceSize(Size(width, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await loadAuditScreenshotFonts(tester);
        final capture = GlobalKey();
        await _open(
          tester,
          const [
            FinanceAccountReference(
              id: 'cny',
              code: 'ZH000010',
              name: '基本户',
              currencyName: '人民币',
              currencyCode: 'CNY',
              baseCurrency: true,
              status: '使用',
            ),
            FinanceAccountReference(
              id: 'usd',
              code: 'ZH000023',
              name: '香港公司账号',
              currencyName: '美金',
              currencyCode: 'USD',
              status: '使用',
            ),
          ],
          (_) {},
          captureKey: capture,
        );
        await tester.tap(find.text('基本户'));
        await tester.pumpAndSettle();
        await saveAuditScreenshot(
          tester,
          capture,
          'finance-account-picker-${width.toInt()}',
        );
      });
    }
  }
  for (final width in [390.0, 1200.0]) {
    testWidgets('account table shares the search inset at width $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? selected;
      await _open(tester, const [
        FinanceAccountReference(id: 'first', name: '第一账户', status: '使用'),
        FinanceAccountReference(id: 'second', name: '第二账户', status: '使用'),
      ], (value) => selected = value);

      final search = tester.getRect(find.byType(UtenSearchBar));
      final table = tester.getRect(
        find.byType(MasterDataTableView<FinanceAccountReference>),
      );
      expect(table.left, search.left);
      expect(table.right, search.right);
      expect(table.left, greaterThan(0));
      // 快速切换只更新当前滑窗草稿，取消不得回填任何账户。
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('第一账户'));
        await tester.pump();
        await tester.tap(find.text('第二账户'));
        await tester.pump();
      }
      expect(_isSelected(tester, 'second'), isTrue);
      expect(selected, isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('account headers search the complete usable dictionary', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _open(tester, const [
      FinanceAccountReference(
        id: 'cny',
        code: 'CNY-1',
        name: '本地收款',
        currencyCode: 'CNY',
        status: '使用',
        baseCurrency: true,
      ),
      FinanceAccountReference(
        id: 'usd',
        code: 'USD-1',
        name: '外贸收款',
        currencyCode: 'USD',
        status: '使用',
      ),
    ], (_) {});
    await tester.tap(find.text('账户名称'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('uten-column-keyword-input')),
      '外贸',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('外贸收款'), findsOneWidget);
    expect(find.text('本地收款'), findsNothing);
    expect(tester.takeException(), isNull);
  });

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
  GlobalKey? captureKey,
}) async {
  await tester.pumpWidget(
    RepaintBoundary(
      key: captureKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: captureKey == null
            ? null
            : auditScreenshotTheme(buildLightTheme()),
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
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}
