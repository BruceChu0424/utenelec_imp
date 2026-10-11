import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_h_scroll_area.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';

class _Row extends EditableGridRow {
  _Row(this.label)
    : note = TextEditingController(text: '主表$label'),
      detail = TextEditingController(text: '子件$label');

  final String label;
  final TextEditingController note;
  final TextEditingController detail;
  final FocusNode detailFocus = FocusNode();
  int actionCount = 0;

  @override
  void dispose() {
    note.dispose();
    detail.dispose();
    detailFocus.dispose();
    super.dispose();
  }
}

class _Details extends StatefulWidget {
  const _Details(this.row);
  final _Row row;

  @override
  State<_Details> createState() => _DetailsState();
}

class _DetailsState extends State<_Details> {
  bool expanded = true;

  @override
  Widget build(BuildContext context) {
    final row = widget.row;
    return Container(
      key: ValueKey('card-${row.label}'),
      padding: const EdgeInsets.all(8),
      color: Colors.teal.shade50,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text('详情${row.label}'),
              const Spacer(),
              IconButton(
                key: ValueKey('toggle-${row.label}'),
                onPressed: () => setState(() => expanded = !expanded),
                icon: Icon(expanded ? Icons.expand_less : Icons.expand_more),
              ),
              IconButton(
                key: ValueKey('action-${row.label}'),
                onPressed: () => row.actionCount++,
                icon: const Icon(Icons.info_outline),
              ),
            ],
          ),
          if (expanded) ...[
            TextField(
              key: ValueKey('detail-input-${row.label}'),
              controller: row.detail,
              focusNode: row.detailFocus,
            ),
            SizedBox(height: 96, child: Text('展开内容${row.label}')),
          ],
        ],
      ),
    );
  }
}

Widget _app(
  UtenEditableGridController<_Row> controller, {
  double width = 460,
  bool details = true,
  bool wide = true,
  bool withFilter = false,
  TextDirection direction = TextDirection.ltr,
  Widget? Function(BuildContext, _Row)? detailsBuilder,
}) {
  return MaterialApp(
    home: Directionality(
      textDirection: direction,
      child: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: ListView(
              children: [
                UtenEditableGrid<_Row>(
                  key: const ValueKey('grid'),
                  controller: controller,
                  showColumnSettings: false,
                  confirmDelete: false,
                  initialPinnedColumnKeys: const {'name'},
                  createBlankRow: () => _Row('新增'),
                  cloneRow: (row) {
                    final clone = _Row(
                      row.label.endsWith('副本') ? row.label : '${row.label}副本',
                    );
                    clone.note.text = row.note.text;
                    clone.detail.text = row.detail.text;
                    return clone;
                  },
                  rowDetailsBuilder: details
                      ? (detailsBuilder ?? (_, row) => _Details(row))
                      : null,
                  columns: [
                    EditableGridColumn<_Row>(
                      key: 'name',
                      label: '产品名称',
                      width: 160,
                      textOf: (row) => row.label,
                      filterValueOf: withFilter ? (row) => row.label : null,
                      cellBuilder: (_, row) => Text(
                        row.label,
                        key: ValueKey('main-name-${row.label}'),
                      ),
                    ),
                    EditableGridColumn<_Row>(
                      key: 'note',
                      label: '备注',
                      width: wide ? 460 : 80,
                      cellBuilder: (_, row) => TextField(
                        key: ValueKey('main-input-${row.label}'),
                        controller: row.note,
                      ),
                    ),
                    if (wide)
                      EditableGridColumn<_Row>(
                        key: 'tail',
                        label: '后续产品字段',
                        width: 460,
                        cellBuilder: (_, row) => Text('尾列${row.label}'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  UtenEditableGridController<_Row> controller, {
  double width = 460,
  bool details = true,
  bool wide = true,
  bool withFilter = false,
  TextDirection direction = TextDirection.ltr,
  Widget? Function(BuildContext, _Row)? detailsBuilder,
}) async {
  tester.view.physicalSize = const Size(1100, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    _app(
      controller,
      width: width,
      details: details,
      wide: wide,
      withFilter: withFilter,
      direction: direction,
      detailsBuilder: detailsBuilder,
    ),
  );
  await tester.pumpAndSettle();
}

ScrollController _horizontal(WidgetTester tester) =>
    tester.widget<UtenHScrollArea>(find.byType(UtenHScrollArea)).controller!;

Future<void> _rightClick(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(
    tester.getCenter(finder),
    kind: PointerDeviceKind.mouse,
    buttons: kSecondaryButton,
  );
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('整宽详情不借主表列宽，横滚后仍可点击右侧按钮和编辑', (tester) async {
    final row = _Row('A');
    final controller = UtenEditableGridController<_Row>(initial: [row]);
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    final card = find.byKey(const ValueKey('card-A'));
    expect(tester.getSize(card).width, closeTo(460, 0.01));
    final left = tester.getTopLeft(card).dx;
    _horizontal(tester).jumpTo(600);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(card).dx, closeTo(left, 0.01));
    expect(tester.getSize(card).width, closeTo(460, 0.01));
    await tester.tap(find.byKey(const ValueKey('action-A')));
    expect(row.actionCount, 1);
    final input = find.byKey(const ValueKey('detail-input-A'));
    await tester.tap(input);
    await tester.enterText(input, '91.25');
    await tester.pumpAndSettle();
    expect(row.detail.text, '91.25');
    expect(row.detailFocus.hasFocus, isTrue);
    expect(_horizontal(tester).offset, closeTo(600, 0.01));
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField && identical(widget.controller, row.note),
      ),
      findsOneWidget,
      reason: '冻结列及详情不能重复挂载主行输入控制器',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情高度跟随展开收起，主行次序和末行横滚条随内容更新', (tester) async {
    final controller = UtenEditableGridController<_Row>(
      initial: [_Row('A'), _Row('B')],
    );
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    final card = find.byKey(const ValueKey('card-A'));
    final beforeHeight = tester.getSize(card).height;
    final beforeSecondTop = tester
        .getTopLeft(find.byKey(const ValueKey('main-name-B')))
        .dy;
    await tester.tap(find.byKey(const ValueKey('toggle-A')));
    await tester.pumpAndSettle();
    final afterHeight = tester.getSize(card).height;
    final afterSecondTop = tester
        .getTopLeft(find.byKey(const ValueKey('main-name-B')))
        .dy;
    expect(beforeHeight - afterHeight, greaterThan(96));
    expect(
      beforeSecondTop - afterSecondTop,
      closeTo(beforeHeight - afterHeight, 1),
    );
    expect(controller.rows.length, 2);
    expect(find.text('展开内容A'), findsNothing);
    final content = tester.getRect(find.byKey(const ValueKey('card-B')));
    final scrollArea = tester.getRect(find.byType(UtenHScrollArea));
    expect(scrollArea.bottom - content.bottom, closeTo(11, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('删除和插入主行后，另一行的详情展开状态及已填值不串行', (tester) async {
    final a = _Row('A');
    final b = _Row('B');
    final controller = UtenEditableGridController<_Row>(initial: [a, b]);
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    await tester.tap(find.byKey(const ValueKey('toggle-B')));
    await tester.pumpAndSettle();
    expect(find.text('展开内容B'), findsNothing);
    b.detail.text = '保留已填用料';
    controller.removeAt(0);
    await tester.pumpAndSettle();
    expect(find.text('展开内容B'), findsNothing);
    expect(b.detail.text, '保留已填用料');
    controller.insertAt(0, _Row('C'));
    await tester.pumpAndSettle();
    expect(find.text('展开内容C'), findsOneWidget);
    expect(find.text('展开内容B'), findsNothing);
    expect(b.detail.text, '保留已填用料');
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情交互不会成为选中行；主行复制贴和删除只操作产品记录', (tester) async {
    final a = _Row('A');
    final b = _Row('B');
    final controller = UtenEditableGridController<_Row>(initial: [a, b]);
    addTearDown(controller.dispose);
    await _pump(tester, controller);
    await tester.tap(find.byKey(const ValueKey('action-A')));
    expect(controller.selectedCount, 0);
    await _rightClick(tester, find.byKey(const ValueKey('main-name-A')));
    await tester.tap(find.text('复制选中 (1)'));
    await tester.pumpAndSettle();
    await _rightClick(tester, find.byKey(const ValueKey('main-name-A')));
    await tester.tap(find.text('粘贴'));
    await tester.pumpAndSettle();
    expect(controller.rows.map((row) => row.label), ['A', 'B', 'A副本']);
    expect(controller.rows.last.detail.text, a.detail.text);
    await tester.tap(find.byTooltip('删除该行').hitTestable().first);
    await tester.pumpAndSettle();
    expect(controller.rows.map((row) => row.label), ['B', 'A副本']);
    expect(find.byKey(const ValueKey('card-A')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('详情输入的键盘删除保留主行，窄表详情仍占可见面板整宽', (tester) async {
    final row = _Row('A');
    final controller = UtenEditableGridController<_Row>(initial: [row]);
    addTearDown(controller.dispose);
    await _pump(tester, controller, wide: false, width: 700);
    expect(tester.getSize(find.byKey(const ValueKey('card-A'))).width, 700);
    final input = find.byKey(const ValueKey('detail-input-A'));
    await tester.tap(input);
    await tester.enterText(input, '123');
    row.detail.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pumpAndSettle();
    expect(row.detail.text, isEmpty);
    expect(controller.rows, [row]);
    expect(row.note.text, '主表A');
  });

  testWidgets('详情随可见面板响应缩放；默认关闭或返回null不增加详情行', (tester) async {
    final controller = UtenEditableGridController<_Row>(initial: [_Row('A')]);
    addTearDown(controller.dispose);
    await _pump(tester, controller, width: 700);
    await tester.pumpWidget(_app(controller, width: 360));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('card-A'))).width, 360);
    await tester.pumpWidget(_app(controller, details: false));
    await tester.pumpAndSettle();
    expect(find.byType(_Details), findsNothing);
    expect(controller.rows.length, 1);
    await tester.pumpWidget(_app(controller, detailsBuilder: (_, _) => null));
    await tester.pumpAndSettle();
    expect(find.byType(_Details), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTL横滚也保持详情在可见面板内，冻结产品列仍在', (tester) async {
    final row = _Row('A');
    final controller = UtenEditableGridController<_Row>(initial: [row]);
    addTearDown(controller.dispose);
    await _pump(tester, controller, direction: TextDirection.rtl);
    final card = find.byKey(const ValueKey('card-A'));
    final left = tester.getTopLeft(card).dx;
    _horizontal(tester).jumpTo(400);
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(card).dx, closeTo(left, 0.01));
    await tester.tap(find.byKey(const ValueKey('action-A')));
    expect(row.actionCount, 1);
    expect(find.byType(UtenFrozenLeadingColumn), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('表头筛选只投影视图，详情跟随所属产品且不改已填数据', (tester) async {
    final a = _Row('A');
    final b = _Row('B');
    b.detail.text = '保留物料值';
    final controller = UtenEditableGridController<_Row>(initial: [a, b]);
    addTearDown(controller.dispose);
    await _pump(tester, controller, withFilter: true);
    await tester.tap(find.byIcon(Icons.arrow_drop_down_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('B（1）'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-A')), findsNothing);
    expect(find.byKey(const ValueKey('card-B')), findsOneWidget);
    expect(controller.rows, [a, b]);
    expect(b.detail.text, '保留物料值');
    await tester.tap(find.byIcon(Icons.arrow_drop_down_rounded).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('所有'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('card-A')), findsOneWidget);
    expect(find.byKey(const ValueKey('card-B')), findsOneWidget);
    expect(b.detail.text, '保留物料值');
    expect(tester.takeException(), isNull);
  });
}
