import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

/// 2026-10-24 用户口径（货品页「禁用货品」前导分组标题行）：
/// 1. 「下拉查看详情」紧跟副标题文案相邻排布，不再被 Expanded 推到行右端；
/// 2. 表格横向滚动时标题行文案钉在视口左缘不动（_ViewportPinnedRow），
///    任何横滚位置都看得见、点得到（点击展开仍生效）。
void main() {
  const viewport = Size(480, 500);
  // 5 列 × 200 = 1000px，远超 480px 视口，保证可横滚。
  Widget cell(BuildContext _, _Row row) => Text(row.id);
  Widget host() => MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: viewport.width,
          height: viewport.height,
          child: MasterDataTableView<_Row>(
            columns: [
              for (var i = 1; i <= 5; i++)
                MasterColumnDef<_Row>(
                  key: 'c$i',
                  label: '列$i',
                  width: 200,
                  value: (row) => row.id,
                  cellBuilder: cell,
                ),
            ],
            items: const [_Row('g-1'), _Row('g-2')],
            leadingGroups: const [
              MasterDataGroup<_Row>(
                id: 'disabled',
                title: '禁用货品(1)',
                subtitle: '当前分类子树内已停用的货品',
                items: [_Row('d-1')],
                total: 1,
              ),
            ],
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            idOf: (row) => row.id,
          ),
        ),
      ),
    ),
  );

  testWidgets('「下拉查看详情」紧跟副标题，不被推到行右端', (tester) async {
    await tester.binding.setSurfaceSize(viewport);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final subtitle = find.text('当前分类子树内已停用的货品');
    final label = find.text('下拉查看详情');
    expect(subtitle, findsOneWidget);
    expect(label, findsOneWidget);
    final s = tester.getRect(subtitle);
    final l = tester.getRect(label);
    // 相邻：提示左缘紧贴副标题右缘（同排文案段间距 8px，容忍省略测量误差）。
    // 旧布局用 Expanded 推行尾时该间隙 ≈ 100px+，此断言即防回退。
    expect(l.left, greaterThanOrEqualTo(s.right));
    expect(l.left - s.right, lessThan(20));
    // 提示后紧跟旋转箭头，整簇不顶满行右端（右侧留白，证明没有被推到行尾）。
    final arrow = tester.getRect(
      find.byIcon(Icons.keyboard_arrow_down_rounded),
    );
    expect(arrow.left - l.right, lessThan(8));
    expect(arrow.right, lessThan(viewport.width - 40));
  });

  testWidgets('横滚表格时分组标题行钉在视口左缘不动，展开点击仍可用', (tester) async {
    await tester.binding.setSurfaceSize(viewport);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final title = find.text('禁用货品(1)');
    final before = tester.getRect(title);
    final anchor = find.text('g-1').first;
    final anchorBefore = tester.getRect(anchor);

    // 往左拖表体，把首列滚出视口。
    await tester.drag(anchor, const Offset(-400, 0));
    await tester.pumpAndSettle();

    // 表确实横滚了：数据格左移出视口。
    expect(
      tester.getRect(anchor).left,
      lessThan(anchorBefore.left - 200),
      reason: '参照格未移动，说明本次拖拽没有产生横向滚动',
    );
    // 标题行钉视口：文案原位不动，副标题与提示仍在视口内可见。
    expect(tester.getRect(title).topLeft, before.topLeft);
    expect(tester.getRect(find.text('当前分类子树内已停用的货品')).left,
        lessThan(viewport.width));
    expect(tester.getRect(find.text('下拉查看详情')).right, lessThan(viewport.width));

    // 钉住的位置仍可交互：点击展开，分组行顶上来。
    await tester.tap(title);
    await tester.pumpAndSettle();
    expect(find.text('d-1'), findsWidgets);
    expect(tester.takeException(), isNull);
  });
}
