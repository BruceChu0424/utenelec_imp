// UtenCollapsingHeaderScrollView 联动滚动的「每格滚轮成本」与「滚轮交接门」回归。
//
// 用户口径(2026-09-22)：「所有页面鼠标上下滚动都一卡一卡的, 表格里面滚动还好,
// 就是表格一步一步往置顶移动的时候」+「表格置顶后得再滑一点点距离才开始动表内,
// 往下也一样, 之前一置顶瞬间就滚表内、看不到最前面的内容」+「不管在表格内还是
// 表格外滚, 都先把表格置顶」。
//
// 卡顿根因：NestedScrollView 的 body 高 = 视口剩余高, 头部每收一格 body 就变一次高,
// MasterDataTableView 表体的 LayoutBuilder 每次都整树重建(修前一格 25-31 个可见
// 单元格重建, 修后 0-3 个 = 与表内滚动同级)。本用例用探针钉住这一点, 再钉住门的
// 四条规则：交接那格到点即止、越点后先吃空行程、掉头即撤门、独立滚动件不被抢。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_collapsing_header_scroll_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const double _headerHeight = 260;

/// 故意不用默认值(50), 让 wheelGateDistance 参数真正被验证。
const double _gate = 40;

int _cellBuilds = 0;
int _bodyLayouts = 0;
ScrollController? _inner;

class _LayoutProbe extends SingleChildRenderObjectWidget {
  const _LayoutProbe({required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderLayoutProbe();
}

class _RenderLayoutProbe extends RenderProxyBox {
  @override
  void performLayout() {
    _bodyLayouts++;
    super.performLayout();
  }
}

Widget _table({int rows = 120}) => MasterDataTableView<String>(
  primary: true,
  // 16 列 × 140 = 2240 > 1400 视口宽：shift+滚轮用例需要横滚量。
  columns: [
    for (var c = 0; c < 16; c++)
      MasterColumnDef<String>(
        key: 'c$c',
        label: '列$c',
        width: 140,
        value: (v) => '$v-$c',
        cellBuilder: c == 0
            ? (_, v) {
                _cellBuilds++;
                return Text(v);
              }
            : null,
      ),
  ],
  items: [for (var i = 0; i < rows; i++) 'ROW-$i'],
  facets: const {},
  nullCounts: const {},
  filters: const {},
  onFilterChanged: (_, _) {},
  totalPages: 3,
  onPageChange: (_) {},
);

/// 对齐主档页：卡片在 collapsingHeader, 搜索行 + Expanded(表格) 在 body。
/// [sidePanel] 为 true 时 body 左侧再放一个**独立**竖向 SingleChildScrollView
/// (primary:false + 自己的 controller；不传 controller 的竖向滚动件会继承
/// NestedScrollView 注入的 inner controller, 成为联动的一员), 验证门不抢它的滚轮。
Widget _harness({required ScrollController outer, ScrollController? side}) {
  final sidePanel = side != null;
  final column = Column(
    children: [
      Container(
        key: const ValueKey('searchrow'),
        height: 48,
        color: Colors.blue,
        alignment: Alignment.centerLeft,
        child: const Text('SEARCH'),
      ),
      Expanded(child: _table()),
    ],
  );
  final body = Builder(
    builder: (context) {
      _inner = PrimaryScrollController.maybeOf(context);
      if (!sidePanel) return column;
      return Row(
        children: [
          SizedBox(
            width: 300,
            child: SingleChildScrollView(
              key: const ValueKey('sidepanel'),
              primary: false,
              controller: side,
              child: Column(
                children: [
                  for (var i = 0; i < 40; i++)
                    SizedBox(height: 40, child: Text('SIDE-$i')),
                ],
              ),
            ),
          ),
          Expanded(child: column),
        ],
      );
    },
  );
  return MaterialApp(
    home: Scaffold(
      body: UtenCollapsingHeaderScrollView(
        controller: outer,
        wheelGateDistance: _gate,
        collapsingHeader: Container(
          key: const ValueKey('card'),
          height: _headerHeight,
          color: Colors.amber,
          alignment: Alignment.centerLeft,
          child: const Text('CARD'),
        ),
        body: _LayoutProbe(child: body),
      ),
    ),
  );
}

Future<void> _pumpHarness(
  WidgetTester tester, {
  required ScrollController outer,
  ScrollController? side,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_harness(outer: outer, side: side));
  await tester.pumpAndSettle();
}

/// 一格滚轮：发事件后把帧跑到稳定, 返回这一格重建了多少个探针单元格。
Future<int> _wheel(
  WidgetTester tester,
  TestPointer pointer,
  Offset at,
  double dy,
) async {
  _cellBuilds = 0;
  _bodyLayouts = 0;
  await tester.sendEventToBinding(pointer.hover(at));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  var frames = 0;
  do {
    await tester.pump();
    frames++;
  } while (tester.binding.hasScheduledFrame && frames < 10);
  return _cellBuilds;
}

Offset _tableCenter(WidgetTester tester) => tester.getCenter(
  find.byWidgetPredicate((w) => w is MasterDataTableView<String>),
);

double _innerOffset() => _inner!.position.pixels;

void main() {
  testWidgets('收头部阶段每格滚轮不再整树重建表体(与表内滚动同级)', (tester) async {
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await _pumpHarness(tester, outer: outer);
    final at = _tableCenter(tester);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    // 预热一格再回来, 排除首帧一次性成本。
    await _wheel(tester, pointer, at, 100);
    await _wheel(tester, pointer, at, -100);

    // 收头部：3 格(100 + 100 + 60 到点)。修前每格 25-31 个可见单元格重建。
    for (var i = 0; i < 3; i++) {
      final builds = await _wheel(tester, pointer, at, 100);
      expect(
        builds,
        lessThanOrEqualTo(4),
        reason: '收头部第 ${i + 1} 格不该整树重建表体(只允许新露出的行)',
      );
      expect(_bodyLayouts, 1, reason: 'body 只按新高度布局一次');
    }
    expect(outer.offset, _headerHeight);
    // 放头部：表内回顶后再 3 格(先吃空行程再放、100、100)。修前每格 25-31 个重建。
    await _wheel(tester, pointer, at, -100);
    for (var i = 0; i < 3; i++) {
      final builds = await _wheel(tester, pointer, at, -100);
      expect(builds, 0, reason: '放头部第 ${i + 1} 格不该重建任何单元格');
    }
    expect(outer.offset, lessThan(_headerHeight));
  });

  testWidgets('滚轮门：到点即止、越点先吃空行程、往下对称、掉头即撤门', (tester) async {
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await _pumpHarness(tester, outer: outer);
    final at = _tableCenter(tester);
    final pointer = TestPointer(2, PointerDeviceKind.mouse);

    // 260 高的头部：两格收 200, 第三格只用 60 到点, 余下 40 丢弃——表内纹丝不动。
    await _wheel(tester, pointer, at, 100);
    await _wheel(tester, pointer, at, 100);
    expect(outer.offset, 200);
    await _wheel(tester, pointer, at, 100);
    expect(outer.offset, _headerHeight, reason: '第三格刚好停在置顶');
    expect(_innerOffset(), 0, reason: '交接那格的余量不带进表内');
    expect(find.text('ROW-0'), findsOneWidget, reason: '置顶时第一行还在');

    // 停顿窗（2026-09-25）：截停后 350ms 内同方向格属同一滚势，整格吞掉——
    // 「滚一下」没停就置顶了，必须停住等下一次滚才继续。
    await _wheel(tester, pointer, at, 100);
    expect(_innerOffset(), 0, reason: '停顿窗内的后续格被吞掉');
    await tester.pump(const Duration(milliseconds: 400));
    // 滚势停住后恢复空行程门：先吃 50 空行程, 这一格只剩 50 进表内; 再往后整格进表内。
    await _wheel(tester, pointer, at, 100);
    expect(_innerOffset(), 100 - _gate);
    await _wheel(tester, pointer, at, 100);
    expect(_innerOffset(), 200 - _gate);

    // 往下对称：表内 150 → 50 → 第三格 100 只用 50 回到顶, 余量丢弃, 头部还没动。
    await _wheel(tester, pointer, at, -100);
    expect(_innerOffset(), 100 - _gate);
    await _wheel(tester, pointer, at, -100);
    expect(_innerOffset(), 0, reason: '表内刚好回顶');
    expect(outer.offset, _headerHeight, reason: '回顶那格的余量不带去放头部');
    // 停顿窗内的同方向格被吞掉；停住后恢复空行程门：这一格只放 50; 之后整格放。
    await _wheel(tester, pointer, at, -100);
    expect(outer.offset, _headerHeight, reason: '停顿窗内的后续格被吞掉');
    await tester.pump(const Duration(milliseconds: 400));
    await _wheel(tester, pointer, at, -100);
    expect(outer.offset, _headerHeight - (100 - _gate));
    await _wheel(tester, pointer, at, -100);
    expect(outer.offset, _headerHeight - (200 - _gate));

    // 掉头即撤门：再往上滚, 头部立刻收(不吃空行程)。
    await _wheel(tester, pointer, at, 100);
    expect(outer.offset, _headerHeight - (100 - _gate));
  });

  testWidgets('停顿窗距离放行线：滚不停的人推够 250 即继续，不卡死在置顶', (tester) async {
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await _pumpHarness(tester, outer: outer);
    final at = _tableCenter(tester);
    final pointer = TestPointer(6, PointerDeviceKind.mouse);

    // 260 高的头部：三格收完，第三格截停在置顶点并开停顿窗。
    for (var i = 0; i < 3; i++) {
      await _wheel(tester, pointer, at, 100);
    }
    expect(outer.offset, _headerHeight);
    expect(_innerOffset(), 0);

    // 连续滚不停：第 1、2 格（累计 100/200 < 250）吞掉；第 3 格（300 ≥ 250）
    // 达到距离放行线——放行那格走正常门逻辑（先吃 50 空行程，余 50 进表内）。
    await _wheel(tester, pointer, at, 100);
    await _wheel(tester, pointer, at, 100);
    expect(_innerOffset(), 0, reason: '未达距离线仍属同一滚势');
    await _wheel(tester, pointer, at, 100);
    expect(outer.offset, _headerHeight, reason: '头部仍钉住');
    expect(_innerOffset(), 100 - _gate, reason: '推够距离后先吃空行程再进表内');
  });

  testWidgets('滚轮门：置顶时掉头往下, 头部立刻放, 不吃空行程', (tester) async {
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await _pumpHarness(tester, outer: outer);
    final at = _tableCenter(tester);
    final pointer = TestPointer(3, PointerDeviceKind.mouse);
    for (var i = 0; i < 3; i++) {
      await _wheel(tester, pointer, at, 100);
    }
    expect(outer.offset, _headerHeight);
    await _wheel(tester, pointer, at, -100);
    expect(outer.offset, _headerHeight - 100, reason: '反向是明确意图, 门不拦');
  });

  testWidgets('鼠标在表格外(头部上)滚, 同样先把表格置顶再进表内', (tester) async {
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await _pumpHarness(tester, outer: outer);
    final at = tester.getCenter(find.byKey(const ValueKey('card')));
    final pointer = TestPointer(4, PointerDeviceKind.mouse);
    for (var i = 0; i < 3; i++) {
      await _wheel(tester, pointer, at, 100);
    }
    expect(outer.offset, _headerHeight);
    expect(_innerOffset(), 0);
    // 头部滚走后鼠标落在搜索行(表格外、无内滚体)上, 继续滚：先吃空行程再进表内。
    final searchRow = tester.getCenter(find.byKey(const ValueKey('searchrow')));
    // （截停后停顿窗内的格被吞——先等窗过期再验证空行程门。）
    await tester.pump(const Duration(milliseconds: 400));
    await _wheel(tester, pointer, searchRow, 100);
    expect(_innerOffset(), 100 - _gate);
  });

  testWidgets('页内独立滚动件：头部未收完时上滚仍先置顶, 置顶后它自己滚, 不被抢', (tester) async {
    final outer = ScrollController();
    final side = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(side.dispose);
    await _pumpHarness(tester, outer: outer, side: side);
    final at = tester.getCenter(find.byKey(const ValueKey('sidepanel')));
    final pointer = TestPointer(5, PointerDeviceKind.mouse);
    double sideOffset() => side.offset;

    // 用户口径「不管在表格内还是表格外滚, 都先把表格置顶」：侧栏上滚也先收头部。
    await _wheel(tester, pointer, at, 100);
    expect(outer.offset, 100);
    expect(sideOffset(), 0);
    await _wheel(tester, pointer, at, 100);
    await _wheel(tester, pointer, at, 100);
    expect(outer.offset, _headerHeight);
    // （置顶截停后停顿窗内的格被吞——先等窗过期。）
    await tester.pump(const Duration(milliseconds: 400));
    // 置顶之后, 侧栏自己能滚：滚轮归它, 表内不动。
    await _wheel(tester, pointer, at, 100);
    expect(sideOffset(), 100);
    expect(_innerOffset(), 0);
    // 侧栏往下滚回顶, 头部不动(侧栏还能滚时归侧栏)。
    await _wheel(tester, pointer, at, -100);
    expect(sideOffset(), 0);
    expect(outer.offset, _headerHeight);
    // 侧栏已在顶、再往下：归联动, 表内在顶 → 放头部。
    await _wheel(tester, pointer, at, -100);
    expect(outer.offset, lessThan(_headerHeight));
  });

  testWidgets('shift+滚轮是横滚, 门不接管：表格横向滚、头部不动', (tester) async {
    final outer = ScrollController();
    addTearDown(outer.dispose);
    await _pumpHarness(tester, outer: outer);
    final at = _tableCenter(tester);
    final pointer = TestPointer(6, PointerDeviceKind.mouse);
    final headerCellBefore = tester.getTopLeft(find.text('列0')).dx;
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await _wheel(tester, pointer, at, 100);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(outer.offset, 0, reason: '头部不该动');
    expect(
      tester.getTopLeft(find.text('列0')).dx,
      lessThan(headerCellBefore),
      reason: '表格应横向滚动(表头随表体同步)',
    );
  });
}
