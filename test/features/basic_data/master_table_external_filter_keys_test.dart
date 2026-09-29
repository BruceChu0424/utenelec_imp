// 空态「当前有 N 个表头筛选生效」描述的计数口径（externalFilterKeys）。
//
// 沿革：2026-09-11 两条用户反馈（「没有任务却出清除筛选按钮」「分段条上看得见的
// 筛选表里再给一个是重复」）曾引出 externalFilterKeys 门控空态「清除筛选」按钮；
// 2026-09-28 用户口径升级为按钮全站退役——本文件改锁两件事：
// 1. 空态永不出「清除筛选」按钮（无论筛选是否宿主自管）；
// 2. 筛选生效数描述仍只数非宿主自管的列（externalFilterKeys 不计数）。
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
          onFilterChanged: (_, _) {},
          emptyMessage: '没有任务',
        ),
      ),
    ),
  );

  testWidgets('筛选由宿主自管时，空态不报筛选生效数', (tester) async {
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

  testWidgets('非宿主自管的筛选：报生效数，但不再给「清除筛选」按钮', (tester) async {
    await tester.pumpWidget(host(filters: const {'status': 'OPEN'}));
    await tester.pumpAndSettle();

    // 2026-09-28 用户口径：按钮全站退役，清除入口在表外分段条。
    expect(
      find.byKey(const ValueKey('master-table-clear-filters')),
      findsNothing,
    );
    expect(find.text('清除筛选'), findsNothing);
    expect(find.textContaining('1 个表头筛选生效'), findsOneWidget);
  });

  testWidgets('混合时计数只数非宿主自管的那列', (tester) async {
    await tester.pumpWidget(
      host(
        filters: const {'orderType': 'PURCHASE', 'status': 'OPEN'},
        externalFilterKeys: const {'orderType'},
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('1 个表头筛选生效'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('master-table-clear-filters')),
      findsNothing,
    );
  });
}
