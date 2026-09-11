// UtenEditableGrid 表头快速筛选（EditableGridColumn.filterValueOf）契约测试。
//
// 2026-09-11「表头快速筛选补齐」批次：用户反馈同一张表有的列有下拉小箭头、
// 有的没有（下达车间页「类型」「货品」缺）。本测固定三条口径：
//   1. 声明 filterValueOf 的列才渲染筛选箭头，其余列保持纯标签；
//   2. 选中某个桶后表体只剩匹配行，选回「所有」全部恢复；
//   3. 空值不建桶（不出现空串桶），行集换掉后失效的筛选值自动撤回「所有」
//      ——否则表头 sanitize 回列名、表体仍在过滤，用户面对一张空表找不到入口。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';

class _Row extends EditableGridRow {
  _Row(this.kind, this.goods);

  final String kind;
  final String? goods;
}

UtenEditableGrid<_Row> _grid(UtenEditableGridController<_Row> controller) =>
    UtenEditableGrid<_Row>(
      controller: controller,
      showAddRow: false,
      showRowDelete: false,
      columns: [
        EditableGridColumn<_Row>(
          key: 'kind',
          label: '类型',
          width: 120,
          filterValueOf: (row) => row.kind,
          cellBuilder: (_, row) => Text(row.kind),
        ),
        EditableGridColumn<_Row>(
          key: 'goods',
          label: '货品',
          width: 160,
          // 空/未知 → null：不建桶，计入「未填」。
          filterValueOf: (row) =>
              (row.goods?.trim().isEmpty ?? true) ? null : row.goods,
          cellBuilder: (_, row) => Text(row.goods ?? ''),
        ),
        EditableGridColumn<_Row>(
          key: 'remark',
          label: '备注',
          width: 120,
          cellBuilder: (_, row) => Text('备注-${row.goods ?? ''}'),
        ),
      ],
    );

Future<void> _pump(
  WidgetTester tester,
  UtenEditableGridController<_Row> controller,
) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ListView(children: [_grid(controller)])),
    ),
  );
  await tester.pumpAndSettle();
}

/// 点开第 [column] 个可筛选列的表头下拉（0=类型，1=货品）。按箭头图标定位——
/// 表头选中后显示的是筛选值本身，与表体单元文案重名，按文本找会点到表体。
Future<void> _openFilter(WidgetTester tester, int column) async {
  await tester.tap(find.byIcon(Icons.arrow_drop_down_rounded).at(column));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('只有声明 filterValueOf 的列渲染表头筛选箭头', (tester) async {
    final controller = UtenEditableGridController<_Row>(
      initial: [_Row('自制候选', '甲'), _Row('自制子件', '乙')],
    );
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    // 类型 / 货品 两列各一个下拉箭头；备注列没有。
    expect(find.byIcon(Icons.arrow_drop_down_rounded), findsNWidgets(2));
  });

  testWidgets('选中桶后只剩匹配行，选回「所有」全部恢复', (tester) async {
    final controller = UtenEditableGridController<_Row>(
      initial: [_Row('自制候选', '甲产品'), _Row('自制子件', '乙子件'), _Row('自制候选', '丙产品')],
    );
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await _openFilter(tester, 0);
    // 桶带计数；空值不建桶。
    expect(find.text('自制候选（2）'), findsOneWidget);
    expect(find.text('自制子件（1）'), findsOneWidget);
    await tester.tap(find.text('自制子件（1）'));
    await tester.pumpAndSettle();

    expect(find.text('乙子件'), findsOneWidget);
    expect(find.text('甲产品'), findsNothing);
    expect(find.text('丙产品'), findsNothing);

    // 表头改显选中值（可见的激活筛选），再点开选「所有」恢复。
    expect(
      find.descendant(of: find.byType(InkWell), matching: find.text('自制子件')),
      findsWidgets,
    );
    await _openFilter(tester, 0);
    await tester.tap(find.text('所有'));
    await tester.pumpAndSettle();
    expect(find.text('甲产品'), findsOneWidget);
    expect(find.text('丙产品'), findsOneWidget);
  });

  testWidgets('空货品不建桶', (tester) async {
    final controller = UtenEditableGridController<_Row>(
      initial: [_Row('自制候选', '甲产品'), _Row('自制候选', '  '), _Row('自制候选', null)],
    );
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await _openFilter(tester, 1);
    expect(find.text('甲产品（1）'), findsOneWidget);
    // 只有「所有」+ 一个真实桶，没有空串桶。
    expect(find.text('（2）'), findsNothing);
    expect(find.textContaining('（'), findsOneWidget);
  });

  testWidgets('换行集后失效的筛选值自动撤回，不留看不见的筛选', (tester) async {
    final controller = UtenEditableGridController<_Row>(
      initial: [_Row('自制候选', '甲产品'), _Row('自制子件', '乙子件')],
    );
    addTearDown(controller.dispose);
    await _pump(tester, controller);

    await _openFilter(tester, 0);
    await tester.tap(find.text('自制子件（1）'));
    await tester.pumpAndSettle();
    expect(find.text('甲产品'), findsNothing);

    // 批量动作后整批换行（新行集里没有「自制子件」）：旧筛选值必须撤掉，
    // 否则表体全被滤空而表头看起来没筛选。
    controller.replaceAll([_Row('自制候选', '丁产品'), _Row('委外子件', '戊子件')]);
    await tester.pumpAndSettle();

    expect(find.text('丁产品'), findsOneWidget);
    expect(find.text('戊子件'), findsOneWidget);
    expect(find.text('没有符合表头筛选条件的行'), findsNothing);
  });
}
