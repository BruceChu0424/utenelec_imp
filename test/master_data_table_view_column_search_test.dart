import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  test(
    'keyword controls follow column meaning and allow business overrides',
    () {
      MasterColumnDef<String> column(
        String key,
        String label, {
        String type = 'text',
        bool? enabled,
      }) => MasterColumnDef(
        key: key,
        label: label,
        type: type,
        width: 120,
        columnSearchEnabled: enabled,
        value: (v) => v,
      );
      for (final c in [
        column('billNo', '单据号'),
        column('spec', '规格'),
        column('supplier', '供应商'),
        column('remark', '备注'),
      ]) {
        expect(c.supportsKeywordSearch, isTrue, reason: c.label);
      }
      for (final c in [
        column('date', '日期'),
        column('createdAt', '创建时间'),
        column('quantity', '需求数量'),
        column('status', '状态'),
        column('amount', '金额'),
        column('unit', '单位'),
        column('flags', '是否赠品'),
        column('actions', '操作'),
        column('value', '自定义值', type: 'number'),
        column('name', '名称', enabled: false),
      ]) {
        expect(c.supportsKeywordSearch, isFalse, reason: c.label);
      }
      expect(
        column('materialStatus', '物料描述', enabled: true).supportsKeywordSearch,
        isTrue,
      );
    },
  );

  testWidgets(
    'date and status keep sort or exact choices without keyword input',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MasterDataTableView<String>(
              columns: [
                MasterColumnDef(
                  key: 'date',
                  label: '日期',
                  type: 'date',
                  width: 150,
                  sortable: true,
                  value: (_) => '2026-10-17',
                ),
                MasterColumnDef(
                  key: 'status',
                  label: '状态',
                  width: 150,
                  value: (r) => r,
                ),
              ],
              items: const ['已完成'],
              facets: const {
                'status': [MasterFacetBucket(value: '已完成', count: 1)],
              },
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('日期'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('从远到近'), findsOneWidget);
      await tester.tap(find.text('从远到近'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('状态'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
      expect(find.text('已完成 (1)'), findsOneWidget);
    },
  );

  const rows = [
    ('A1', '三联单控开关', '白色'),
    ('A2', '单联双控开关', '灰色'),
    ('B1', '电视插座', '白色'),
  ];

  Widget host({
    bool server = false,
    Map<String, String?> filters = const {},
    void Function(String, String?)? onChanged,
  }) => MaterialApp(
    home: Scaffold(
      body: MasterDataTableView<(String, String, String)>(
        columns: [
          MasterColumnDef(
            key: 'code',
            label: '编号',
            width: 90,
            value: (r) => r.$1,
          ),
          MasterColumnDef(
            key: 'name',
            label: '货品名称',
            width: 220,
            value: (r) => r.$2,
          ),
          MasterColumnDef(
            key: 'color',
            label: '颜色',
            width: 90,
            value: (r) => r.$3,
          ),
        ],
        items: rows,
        facets: const {
          'name': [MasterFacetBucket(value: '三联单控开关', count: 1)],
        },
        nullCounts: const {},
        filters: filters,
        onFilterChanged: onChanged ?? (_, _) {},
        serverColumnSearch: server,
        onPageChange: server ? (_) async {} : null,
      ),
    ),
  );

  Future<void> search(
    WidgetTester tester,
    String header,
    String query, {
    bool enter = true,
  }) async {
    await tester.tap(find.text(header).first);
    await tester.pumpAndSettle();
    final input = find.byKey(const Key('uten-column-keyword-input'));
    await tester.enterText(input, query);
    await tester.pump();
    if (enter) {
      await tester.testTextInput.receiveAction(TextInputAction.search);
    } else {
      await tester.tap(find.text('搜索'));
    }
    await tester.pumpAndSettle();
    expect(input, findsNothing);
  }

  testWidgets(
    'enter applies contains search to rows, with fewer than six facets',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await search(tester, '货品名称', '开关');
      expect(find.text('A1'), findsOneWidget);
      expect(find.text('A2'), findsOneWidget);
      expect(find.text('B1'), findsNothing);
      expect(find.text('货品名称：开关'), findsOneWidget);
    },
  );

  testWidgets(
    'every column can search, columns intersect, reset restores rows',
    (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();
      await search(tester, '货品名称', '开关', enter: false);
      await search(tester, '颜色', '灰色');
      expect(find.text('A2'), findsOneWidget);
      expect(find.text('A1'), findsNothing);
      await tester.tap(find.text('颜色：灰色'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('所有'));
      await tester.pumpAndSettle();
      expect(find.text('A1'), findsOneWidget);
      expect(find.text('B1'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'server search preserves exact filters and forwards a separate keyword',
    (tester) async {
      final changes = <(String, String?)>[];
      await tester.pumpWidget(
        host(
          server: true,
          onChanged: (key, value) => changes.add((key, value)),
        ),
      );
      await tester.pumpAndSettle();
      await search(tester, '货品名称', '开关', enter: false);
      expect(changes, [('search.name', '开关')]);
      expect(
        find.text('B1'),
        findsOneWidget,
        reason: 'A server query must await its authoritative response.',
      );
    },
  );

  testWidgets('no-match search keeps header available to clear', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    await search(tester, '编号', 'missing');
    expect(find.text('A1'), findsNothing);
    await search(tester, '编号：missing', '');
    expect(find.text('A1'), findsOneWidget);
    expect(find.text('B1'), findsOneWidget);
  });
}
