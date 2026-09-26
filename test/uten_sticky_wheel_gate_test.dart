// UtenStickyWheelGate（embedded 吸顶表滚轮截停门，2026-09-25）：
//  - 一格越过置顶点 → 正好停在点上，余量丢弃；
//  - 停顿窗内同方向的后续格（同一滚势的连续快滚）整格吞掉并续窗——
//    用户口径「滚一下没停就置顶了 → 停住，重新开始滚才继续」；
//  - 滚势停住后下一格正常继续滚表体；
//  - 掉头（往上滚）是明确意图：关窗放行；
//  - 短表页面余量不足（「一直滚不到置顶，总是差点」）→ 按需撑高表体后能到顶；
//  - UtenEditableGrid（编辑网格）与 MasterDataTableView（embedded）共用同一门；
//  - 短表垫高只补实测缺口、垫在表尾条/表体**下方**（2026-09-25「添加行/汇总
//    不跟着表格上移，中间像加了间隔」修复）：表尾条紧贴末行，空白最小化。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_sticky_header.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

String _identity(String value) => value;

/// 详情/审核页同构：页面 ListView（卡片 → embedded 明细表 → 底部留白）。
Widget _page({required Widget table, double cardHeight = 300}) => MaterialApp(
  home: Scaffold(
    body: SizedBox(
      width: 800,
      height: 600,
      child: ListView(
        children: [
          Container(
            key: const ValueKey('card'),
            height: cardHeight,
            color: Colors.amber,
            alignment: Alignment.centerLeft,
            child: const Text('CARD'),
          ),
          Padding(padding: const EdgeInsets.all(12), child: table),
          const SizedBox(height: 24),
        ],
      ),
    ),
  ),
);

MasterDataTableView<String> _table({
  required ValueNotifier<bool> pinned,
  int rows = 30,
}) {
  return MasterDataTableView<String>(
    embedded: true,
    stickyHeaderPinned: pinned,
    columns: const [
      MasterColumnDef<String>(
        key: 'value',
        label: '值',
        width: 240,
        value: _identity,
      ),
    ],
    items: [for (var i = 0; i < rows; i++) 'ROW-$i'],
    facets: const {},
    nullCounts: const {},
    filters: const {},
    onFilterChanged: (_, _) {},
  );
}

/// 页面滚动 position（夹具里最外层 ListView 的）。
ScrollPosition _pagePosition(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

/// 置顶点（截停门核心量出的页面滚动量）。
double _pinOffset(WidgetTester tester) => tester
    .widget<UtenStickyWheelGate>(find.byType(UtenStickyWheelGate))
    .tracker
    .pinOffset!;

/// 表头上（悬停在首行数据上，处于截停门覆盖区内）发一格滚轮。
Future<void> _wheelOverTable(
  WidgetTester tester,
  TestPointer pointer,
  double dy,
) async {
  await tester.sendEventToBinding(
    pointer.hover(tester.getCenter(find.text('ROW-0').first)),
  );
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  testWidgets('越过置顶点的一格截停在点上，顶部内容不错失', (tester) async {
    final pinned = ValueNotifier<bool>(false);
    addTearDown(pinned.dispose);
    await tester.pumpWidget(_page(table: _table(pinned: pinned)));
    await tester.pumpAndSettle();

    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await _wheelOverTable(tester, pointer, 1000);
    await tester.pumpAndSettle();

    // 正好停在置顶点（表头顶到视口顶所需的页面滚动量），余量丢弃
    //（tracker.pinned 要滚过点 0.5px 才翻真，恰停在点上以 pinOffset 为准）。
    final atPin = _pagePosition(tester).pixels;
    expect(atPin, _pinOffset(tester));
    // 表头行内的文字顶边只剩行内边距（表头已贴视口顶）。
    expect(tester.getTopLeft(find.text('值')).dy, lessThan(20));
    expect(find.text('ROW-0'), findsOneWidget, reason: '截停时第一行仍在视口内');
    expect(atPin, lessThan(1000), reason: '同一大格不冲进表体深处');
  });

  testWidgets('停顿窗（时间放行）：截停后同一滚势的后续格被吞，停住后再滚才继续', (tester) async {
    final pinned = ValueNotifier<bool>(false);
    addTearDown(pinned.dispose);
    await tester.pumpWidget(_page(table: _table(pinned: pinned)));
    await tester.pumpAndSettle();

    final pointer = TestPointer(2, PointerDeviceKind.mouse);
    await _wheelOverTable(tester, pointer, 1000);
    await tester.pumpAndSettle();
    final atPin = _pagePosition(tester).pixels;
    expect(atPin, _pinOffset(tester), reason: '先截停在置顶点');
    expect(tester.getTopLeft(find.text('值')).dy, lessThan(20));

    // 同一滚势（连续快滚，未过 350ms 停顿窗且累计 240 < 250 距离放行线）：
    // 整格吞掉，纹丝不动。
    for (var i = 0; i < 2; i++) {
      await _wheelOverTable(tester, pointer, 120);
      expect(
        _pagePosition(tester).pixels,
        atPin,
        reason: '停顿窗内的同方向格应被吞掉(第 ${i + 1} 格)',
      );
    }

    // 滚势停住（窗口过期）后再滚：表体继续向下滚。
    await tester.pump(const Duration(milliseconds: 400));
    await _wheelOverTable(tester, pointer, 120);
    await tester.pumpAndSettle();
    expect(
      _pagePosition(tester).pixels,
      greaterThan(atPin),
      reason: '停住后重新开始滚，应继续滚表体',
    );
    expect(pinned.value, isTrue, reason: '滚过置顶点后表头保持吸顶');
    // 吸顶后数据行从表头下方滚过：表头仍贴视口顶。
    expect(tester.getTopLeft(find.text('值')).dy, lessThan(20));
  });

  testWidgets('停顿窗（距离放行）：滚不停的人推够距离即继续，不卡死在置顶点', (tester) async {
    final pinned = ValueNotifier<bool>(false);
    addTearDown(pinned.dispose);
    await tester.pumpWidget(_page(table: _table(pinned: pinned)));
    await tester.pumpAndSettle();

    final pointer = TestPointer(6, PointerDeviceKind.mouse);
    await _wheelOverTable(tester, pointer, 1000);
    await tester.pumpAndSettle();
    final atPin = _pagePosition(tester).pixels;
    expect(atPin, _pinOffset(tester), reason: '先截停在置顶点');

    // 连续滚不停：第 1、2 格（累计 120/240 < 250）吞掉；第 3 格（360 ≥ 250）
    // 达到距离放行线——这格正常滚，页面越过置顶点继续。
    await _wheelOverTable(tester, pointer, 120);
    await _wheelOverTable(tester, pointer, 120);
    expect(_pagePosition(tester).pixels, atPin, reason: '未达距离线仍属同一滚势');
    await _wheelOverTable(tester, pointer, 120);
    await tester.pumpAndSettle();
    expect(
      _pagePosition(tester).pixels,
      greaterThan(atPin),
      reason: '推够距离放行线后必须继续滚，不能卡死在置顶点',
    );
    expect(pinned.value, isTrue);
  });

  testWidgets('掉头（往上滚）是明确意图：关窗放行', (tester) async {
    final pinned = ValueNotifier<bool>(false);
    addTearDown(pinned.dispose);
    await tester.pumpWidget(_page(table: _table(pinned: pinned)));
    await tester.pumpAndSettle();

    final pointer = TestPointer(3, PointerDeviceKind.mouse);
    await _wheelOverTable(tester, pointer, 1000);
    await tester.pumpAndSettle();
    final atPin = _pagePosition(tester).pixels;

    // 窗内反向滚不被吞：页面立刻回退、表头解除吸顶。
    await _wheelOverTable(tester, pointer, -120);
    await tester.pumpAndSettle();
    expect(_pagePosition(tester).pixels, lessThan(atPin));
    expect(pinned.value, isFalse);
  });

  testWidgets('短表页面余量不足：滚轮按需撑高后能到置顶（财务「总差一点」修复）', (tester) async {
    final pinned = ValueNotifier<bool>(false);
    addTearDown(pinned.dispose);
    // 两行的短表：表格总高远小于视口，页面余量不足以把表头送到视口顶。
    await tester.pumpWidget(_page(table: _table(pinned: pinned, rows: 2)));
    await tester.pumpAndSettle();
    expect(
      _pagePosition(tester).maxScrollExtent,
      lessThan(300),
      reason: '前置：短表页面余量应不足（夹具卡片高 300）',
    );

    final pointer = TestPointer(4, PointerDeviceKind.mouse);
    final pin = _pinOffset(tester);
    for (var i = 0; i < 12 && _pagePosition(tester).pixels < pin - 0.5; i++) {
      await _wheelOverTable(tester, pointer, 100);
      await tester.pumpAndSettle();
    }

    expect(_pagePosition(tester).pixels, pin, reason: '按需撑高后必须正好停在置顶点');
    expect(tester.getTopLeft(find.text('值')).dy, lessThan(20));
    expect(find.text('ROW-0'), findsOneWidget, reason: '置顶时第一行可见');
    // 停顿窗内继续滚不带走（短表尤其容易冲过）。
    await _wheelOverTable(tester, pointer, 120);
    expect(_pagePosition(tester).pixels, pin);
  });

  testWidgets('编辑网格（UtenEditableGrid）共用同一截停门', (tester) async {
    final pinned = ValueNotifier<bool>(false);
    addTearDown(pinned.dispose);
    final controller = UtenEditableGridController<_GateRow>(
      initial: [for (var i = 0; i < 30; i++) _GateRow('ROW-$i')],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _page(
        table: UtenEditableGrid<_GateRow>(
          controller: controller,
          stickyHeaderPinned: pinned,
          columns: [
            EditableGridColumn<_GateRow>(
              key: 'text',
              label: '文本',
              width: 240,
              cellBuilder: (context, row) => Text(row.text),
            ),
          ],
          createBlankRow: () => _GateRow(''),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pointer = TestPointer(5, PointerDeviceKind.mouse);
    await _wheelOverTable(tester, pointer, 1000);
    await tester.pumpAndSettle();

    expect(
      _pagePosition(tester).pixels,
      _pinOffset(tester),
      reason: '编辑网格的表头同样截停在置顶点',
    );
    expect(tester.getTopLeft(find.text('文本')).dy, lessThan(20));
    final atPin = _pagePosition(tester).pixels;

    // 停顿窗内同方向格被吞。
    await _wheelOverTable(tester, pointer, 120);
    expect(_pagePosition(tester).pixels, atPin);
  });

  // —— 2026-09-25「添加行/汇总不跟着表格上移」修复的回归锁 ——

  /// 编辑页同构（底部多留悬浮动作组让位 = 真实编辑页的页面底 padding）。
  Widget editPageLikeDocPages({
    required Widget table,
    double cardHeight = 300,
  }) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 800,
        height: 600,
        child: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Container(
              key: const ValueKey('card'),
              height: cardHeight,
              color: Colors.amber,
              child: const Text('CARD'),
            ),
            table,
            // 表格下方还有一整段内容的长页（超过视口高的剩余量）：置顶点之后
            // 仍有滚动余量——正好验证「整块表格连表尾一起上移」。垫高只补
            // 到置顶点为止，多余空白不会出现在这段内容与表格之间。
            const SizedBox(height: 500),
          ],
        ),
      ),
    ),
  );

  /// 滚到表头置顶（短表走按需垫高通道，多格滚到停住为止）。
  Future<void> wheelToPin(
    WidgetTester tester,
    TestPointer pointer,
    ScrollPosition position,
    double pin,
  ) async {
    for (var i = 0; i < 16 && position.pixels < pin - 0.5; i++) {
      await _wheelOverTable(tester, pointer, 100);
      await tester.pumpAndSettle();
    }
    expect(position.pixels, pin, reason: '前置：必须正好停在置顶点');
  }

  testWidgets('短表吸顶：「添加行/汇总」表尾条紧贴末行，空白只落表尾之下', (tester) async {
    final pinned = ValueNotifier<bool>(false);
    addTearDown(pinned.dispose);
    final controller = UtenEditableGridController<_GateRow>(
      initial: [for (var i = 0; i < 2; i++) _GateRow('ROW-$i')],
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      editPageLikeDocPages(
        table: UtenEditableGrid<_GateRow>(
          controller: controller,
          stickyHeaderPinned: pinned,
          columns: [
            EditableGridColumn<_GateRow>(
              key: 'text',
              label: '文本',
              width: 240,
              cellBuilder: (context, row) => Text(row.text),
            ),
          ],
          createBlankRow: () => _GateRow(''),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final pointer = TestPointer(6, PointerDeviceKind.mouse);
    final position = _pagePosition(tester);
    await wheelToPin(tester, pointer, position, _pinOffset(tester));

    // 表头置顶：末行紧贴表头下方。
    expect(tester.getTopLeft(find.text('文本')).dy, lessThan(20));
    // 表尾条（添加行）必须**紧贴末行**：旧实现把表体撑到近视口高，表尾条
    // 被推到视口底缘（top≈536），与末行之间隔出近一屏空白。
    final lastRowBottom = tester.getBottomRight(find.text('ROW-1')).dy;
    final addBarTop = tester.getTopLeft(find.text('添加行')).dy;
    expect(
      addBarTop - lastRowBottom,
      lessThan(100),
      reason: '表尾条必须紧贴末行（中间不允许整屏间隔）',
    );
    expect(addBarTop, lessThan(350), reason: '表尾条不应被推到视口底缘');
    expect(
      tester.getBottomRight(find.text('添加行')).dy,
      lessThan(600),
      reason: '吸顶时表尾条必须在视口内',
    );

    // 停顿窗过后继续滚：整块表格（表头+行+表尾条）一起上移——表尾跟着表体走。
    await tester.pump(const Duration(milliseconds: 400));
    await _wheelOverTable(tester, pointer, 200);
    await tester.pumpAndSettle();
    expect(
      tester.getTopLeft(find.text('添加行')).dy,
      lessThan(addBarTop),
      reason: '继续滚动时「添加行」必须跟着表格一起上移',
    );
  });

  testWidgets('短表吸顶：垫高只补实测缺口，不把表后内容隔出一屏空白（MDTV）', (tester) async {
    final pinned = ValueNotifier<bool>(false);
    addTearDown(pinned.dispose);
    await tester.pumpWidget(_page(table: _table(pinned: pinned, rows: 2)));
    await tester.pumpAndSettle();

    final pointer = TestPointer(7, PointerDeviceKind.mouse);
    final position = _pagePosition(tester);
    await wheelToPin(tester, pointer, position, _pinOffset(tester));

    // 表头置顶 + 末行可见。
    expect(tester.getTopLeft(find.text('值')).dy, lessThan(20));
    expect(find.text('ROW-1'), findsOneWidget);
    // 旧「视口高−表头−24」公式会把表体撑满整屏，页面可滚余量远超置顶点；
    // 现在 maxScrollExtent 只比置顶点多出门补差的 24 缓冲——空白最小化。
    expect(
      position.maxScrollExtent - _pinOffset(tester),
      lessThan(48),
      reason: '垫高只补缺口，不允许整屏级多余空白',
    );
  });
}

class _GateRow extends EditableGridRow {
  _GateRow(this.text);

  final String text;
}
