// 全站文字框选（2026-09-03 全量覆盖）契约测试：
// - UtenContentContainer 默认包局部 SelectionArea（页面级选择区标准挂点），
//   selectable:false 退出（轮询页口径，准则 §3.4）；
// - 页面 region 嵌套 MasterDataTableView：行双击仍打开（最深 region 竞技场不抢）、
//   表体文字可选、表头文字被 SelectionContainer.disabled 隔离（保护列手势）；
// - selectable:true 多选表（任务中心）整表隔离，页面 region 不渗入；
// - UtenEditableGrid 整体隔离（单元格是 TextField 自带原生选择），行长按菜单不受
//   外层 region 影响；
// - UtenDialog 弹窗内容可选。
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

class _GridRow extends EditableGridRow {
  _GridRow(this.name);
  final String name;

  @override
  void dispose() {}
}

/// 表头/正文/页面文字是否处于某个选择区（registrar 非空 = 可框选）。
bool _selectableOf(WidgetTester tester, Finder finder) =>
    SelectionContainer.maybeOf(tester.element(finder)) != null;

Widget _table({
  bool selectable = false,
  bool enableTextSelection = true,
  Set<String>? selectedIds,
  void Function(_Row)? onRowTap,
}) {
  return MasterDataTableView<_Row>(
    columns: [
      MasterColumnDef<_Row>(
        key: 'id',
        label: 'ID',
        width: 240,
        value: (r) => r.id,
      ),
    ],
    items: const [_Row('a1'), _Row('a2')],
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
    selectable: selectable,
    enableTextSelection: enableTextSelection,
    idOf: (row) => row.id,
    selectedIds: selectedIds ?? const <String>{},
    onSelectedIdsChanged: (_) {},
    onRowTap: onRowTap,
  );
}

/// 模拟真实页面：UtenContentContainer（页面 region）包 说明文字 + 表格（自带嵌套 region）。
Widget _page({
  bool selectableTable = false,
  bool enableTableTextSelection = true,
  bool pageSelectable = true,
  void Function(_Row)? onRowTap,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 640,
        height: 300,
        child: UtenContentContainer.wide(
          selectable: pageSelectable,
          child: Column(
            children: [
              const Text('页面说明文字'),
              Expanded(
                child: _table(
                  selectable: selectableTable,
                  enableTextSelection: enableTableTextSelection,
                  onRowTap: onRowTap,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('UtenContentContainer 默认包局部 SelectionArea', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: UtenContentContainer(child: Text('内容'))),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SelectionArea), findsOneWidget);
    expect(_selectableOf(tester, find.text('内容')), isTrue);
  });

  testWidgets('UtenContentContainer selectable:false 不包（轮询页退出）', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: UtenContentContainer(selectable: false, child: Text('内容')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(SelectionArea), findsNothing);
    expect(_selectableOf(tester, find.text('内容')), isFalse);
  });

  testWidgets('页面 region 嵌套表格：行双击仍打开、正文可选、表头隔离、页文字可选', (tester) async {
    var opens = 0;
    await tester.pumpWidget(_page(onRowTap: (_) => opens++));
    await tester.pumpAndSettle();

    // 页面 region + 表体 region 共存（嵌套各管各的）。
    expect(find.byType(SelectionArea), findsNWidgets(2));
    // 表体文字可选；表头被 SelectionContainer.disabled 隔离（保护列手势）。
    expect(_selectableOf(tester, find.text('a1')), isTrue);
    expect(_selectableOf(tester, find.text('ID')), isFalse);
    // 页面（表格之外）文字也处于页面 region。
    expect(_selectableOf(tester, find.text('页面说明文字')), isTrue);

    // 双击行（手动时间窗判定）仍触发 onRowTap：外层 region 不抢竞技场。
    await tester.tap(find.text('a1'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('a1'));
    await tester.pump();
    expect(opens, 1);
  });

  testWidgets('页面 region 不包时（轮询页）：表格 region 仍独立工作', (tester) async {
    await tester.pumpWidget(_page(pageSelectable: false));
    await tester.pumpAndSettle();

    // 只剩表体自己的 region；页面文字不可选，表体文字仍可选。
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(_selectableOf(tester, find.text('页面说明文字')), isFalse);
    expect(_selectableOf(tester, find.text('a1')), isTrue);
  });

  testWidgets('重交互只读表可显式关闭文字选择且隔离外层 region', (tester) async {
    await tester.pumpWidget(_page(enableTableTextSelection: false));
    await tester.pumpAndSettle();

    // 只剩页面说明的 region；表格自身不再创建 SelectionArea，且 disabled
    // 边界阻止外层页面 region 渗入表头/表体。
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(_selectableOf(tester, find.text('页面说明文字')), isTrue);
    expect(_selectableOf(tester, find.text('ID')), isFalse);
    expect(_selectableOf(tester, find.text('a1')), isFalse);
  });

  testWidgets('多选表（任务中心）整表隔离：页面 region 不渗入勾选表体', (tester) async {
    await tester.pumpWidget(_page(selectableTable: true));
    await tester.pumpAndSettle();

    // 表体被 SelectionContainer.disabled 隔离，只剩页面 region 一个。
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(_selectableOf(tester, find.text('a1')), isFalse);
    expect(_selectableOf(tester, find.text('页面说明文字')), isTrue);
  });

  testWidgets('UtenEditableGrid 整体隔离：外层 region 不渗入，长按行菜单照常', (tester) async {
    final c = UtenEditableGridController<_GridRow>(
      initial: [_GridRow('行1'), _GridRow('行2')],
    );
    addTearDown(c.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            child: ListView(
              children: [
                UtenEditableGrid<_GridRow>(
                  controller: c,
                  columns: [
                    EditableGridColumn<_GridRow>(
                      key: 'name',
                      label: '名称',
                      width: 120,
                      cellBuilder: (context, row) => Text(row.name),
                    ),
                  ],
                  createBlankRow: () => _GridRow('新行'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 表头标签与单元格文字都被隔离（单元格是 TextField，自带原生长按选词复制）。
    expect(_selectableOf(tester, find.text('名称')), isFalse);
    expect(_selectableOf(tester, find.text('行1')), isFalse);

    // 长按行仍弹操作菜单（外层 region 不抢长按竞技场）。
    await tester.longPress(find.text('行2'));
    await tester.pump();
    expect(find.text('在上方插入空行'), findsOneWidget);
  });

  testWidgets('UtenDialog 弹窗内容可选', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () {
                UtenDialog.show(
                  context,
                  title: '确认操作',
                  content: const Text('单号 SO-2026-001'),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();

    expect(find.byType(SelectionArea), findsOneWidget);
    expect(_selectableOf(tester, find.text('单号 SO-2026-001')), isTrue);
    expect(_selectableOf(tester, find.text('确认操作')), isTrue);
  });

  // 多语言：选择工具条（长按弹出的 复制/全选）跟随 MaterialApp.locale，
  // 由 GlobalMaterialLocalizations 提供（zh 复制/全选、ko 복사/전체 선택、en Copy）。
  for (final (locale, copyLabel) in [
    (const Locale('zh'), '复制'),
    (const Locale('ko'), '복사'),
    (const Locale('en'), 'Copy'),
  ]) {
    testWidgets('选择工具条随语言本地化（${locale.languageCode}）', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          supportedLocales: const [Locale('zh'), Locale('ko'), Locale('en')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: const Scaffold(
            body: SelectionArea(child: Center(child: Text('可选文本'))),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 长按选中一个词 → 弹系统选择工具条。
      await tester.longPress(find.text('可选文本'));
      await tester.pumpAndSettle();

      expect(find.text(copyLabel), findsOneWidget);
    });
  }
}
