// 空态「清除筛选」的出现条件（MasterDataTableView.externalFilterKeys）。
//
// 用户 2026-09-11 两条反馈各对一个用例：
// 1.「入库任务中心 明明没有任务了 还会显示个清除筛选的按钮」
//    —— 那是分段子页把 orderType 钉死（fixedOrderType），onFilterChanged 直接
//       return，按钮点了没反应；
// 2.「待检处置 没有内容 也出现了清除筛选按钮」
//    —— 类型筛选的入口在表外的分段条上一直看得见，表里再给一个是重复。
// 两种都由宿主声明 externalFilterKeys，本文件锁住「声明了就不出、没声明仍要出」。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

void main() {
  Widget host({
    required Map<String, String?> filters,
    Set<String> externalFilterKeys = const <String>{},
    List<String> clearedKeys = const [],
  }) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: MasterDataTableView<_Row>(
          columns: [
            MasterColumnDef<_Row>(
              key: 'name',
              label: '名称',
              width: 200,
              value: (item) => item.id,
            ),
          ],
          items: const <_Row>[], // 0 行 → 走空态
          facets: const {},
          nullCounts: const {},
          filters: filters,
          externalFilterKeys: externalFilterKeys,
          onFilterChanged: (key, _) => clearedKeys.add(key),
          emptyMessage: '没有任务',
        ),
      ),
    ),
  );

  testWidgets('筛选由宿主自管时，空态不出「清除筛选」，也不报筛选生效数', (tester) async {
    await tester.pumpWidget(
      host(
        filters: const {'orderType': 'PURCHASE'},
        externalFilterKeys: const {'orderType'},
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey('master-table-clear-filters')),
      findsNothing,
    );
    expect(find.textContaining('个表头筛选生效'), findsNothing);
    expect(find.text('没有任务'), findsOneWidget);
  });

  testWidgets('未声明为宿主自管的筛选照常给「清除筛选」出口，点了逐列回传 null', (tester) async {
    final cleared = <String>[];
    await tester.pumpWidget(
      host(filters: const {'status': 'OPEN'}, clearedKeys: cleared),
    );
    await tester.pumpAndSettle();

    final button = find.byKey(const ValueKey('master-table-clear-filters'));
    expect(button, findsOneWidget);
    expect(find.textContaining('1 个表头筛选生效'), findsOneWidget);

    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(cleared, ['status']);
  });

  testWidgets('混合时只清可清的那一列，计数也只数它', (tester) async {
    final cleared = <String>[];
    await tester.pumpWidget(
      host(
        filters: const {'orderType': 'PURCHASE', 'status': 'OPEN'},
        externalFilterKeys: const {'orderType'},
        clearedKeys: cleared,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('1 个表头筛选生效'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('master-table-clear-filters')));
    await tester.pumpAndSettle();
    expect(cleared, ['status'], reason: '钉死的 orderType 不能被这个按钮碰');
  });
}
