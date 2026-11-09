// 表格公共层合同（AGENTS.md「业务列表单页连续展示」2026-11-08 条）：逐批读取
// 增长期间（行是完整读取仍在继续的已校验前缀）右下悬浮批量动作等完整结果——
// 动作保留原位（不跳布局）但不可点、不可聚焦、无读屏点按动作；宿主的已有选择
// 原样保留、不被清空；完整结果到达后恢复并按原选择执行；读取失败（会话退休）
// 时悬浮组照旧整体隐藏。普通视图与全屏路由同一口径。
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';

const _total = 120;
const _actionKey = Key('progressive-batch-approve');

PagedResult<String> _rows(int count) => PagedResult<String>(
  items: [for (var i = 0; i < count; i++) 'row-$i'],
  page: 1,
  size: count,
  total: _total,
  totalPages: 1,
);

/// One query's reader session: [prefix] publishes a validated growing prefix,
/// [complete] the complete result that replaces it, [fail] retires the session
/// the way a failed read that already showed progressive rows does.
class _Query {
  final session = PagedReadWindowSession<String>(isCurrent: () => true);

  List<String> prefix(int count) =>
      session.bindResult(_rows(count), pending: true, growing: true).items;

  List<String> complete() => session.bindResult(_rows(_total)).items;

  void fail() => session.invalidate();
}

class _Harness {
  late StateSetter update;
  late List<String> items;
  Set<String> selected = <String>{};
  final executed = <Set<String>>[];

  Widget build() => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 900,
        height: 640,
        child: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MasterDataTableView<String>(
              showFullscreenToggle: true,
              columns: [
                MasterColumnDef<String>(
                  key: 'id',
                  label: '编号',
                  width: 240,
                  value: (row) => row,
                ),
              ],
              items: items,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              selectable: true,
              idOf: (row) => row,
              selectedIds: selected,
              onSelectedIdsChanged: (next) => setState(() => selected = next),
              batchActionsBuilder: (_, ids) => [
                UtenButton(
                  key: _actionKey,
                  size: UtenButtonSize.large,
                  onPressed: ids.isEmpty
                      ? null
                      : () => executed.add(Set.of(ids)),
                  child: Text('批量审核(${ids.length})'),
                ),
              ],
            );
          },
        ),
      ),
    ),
  );
}

Finder get _action => find.byKey(_actionKey);

/// Growing rows keep the footer spinner running until the complete result, so
/// the table never settles meanwhile: advance a fixed number of frames instead.
Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// The action keeps its place and label while it waits.
void _expectWaiting(WidgetTester tester, {required int selectedCount}) {
  expect(_action, findsOneWidget);
  expect(find.text('批量审核($selectedCount)'), findsOneWidget);
  expect(_action.hitTestable(), findsNothing);
  expect(
    find.ancestor(
      of: _action,
      matching: find.byWidgetPredicate(
        (widget) => widget is AnimatedOpacity && widget.opacity < 1,
      ),
    ),
    findsOneWidget,
  );
  expect(
    tester
        .getSemantics(_action)
        .getSemanticsData()
        .hasAction(SemanticsAction.tap),
    isFalse,
  );
}

void _expectReady(WidgetTester tester) {
  expect(_action.hitTestable(), findsOneWidget);
  expect(
    find.ancestor(
      of: _action,
      matching: find.byWidgetPredicate(
        (widget) => widget is AnimatedOpacity && widget.opacity < 1,
      ),
    ),
    findsNothing,
  );
  expect(
    tester
        .getSemantics(_action)
        .getSemanticsData()
        .hasAction(SemanticsAction.tap),
    isTrue,
  );
}

void main() {
  testWidgets(
    'floating batch actions wait for the complete result while rows grow; '
    'the kept selection acts after completion and a failure hides them',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final first = _Query();
      final harness = _Harness()..items = first.complete();
      await tester.pumpWidget(harness.build());
      await tester.pumpAndSettle();

      // A selection made on the complete result, including a row beyond the
      // next query's first batch of 50.
      harness.update(() => harness.selected = {'row-0', 'row-90'});
      await tester.pumpAndSettle();
      _expectReady(tester);
      await tester.tap(_action);
      await tester.pump();
      expect(harness.executed, [
        {'row-0', 'row-90'},
      ]);

      // A new query grows: its first 50 rows are on screen and the read goes on.
      final second = _Query();
      harness.update(() => harness.items = second.prefix(50));
      await _frames(tester);
      expect(find.text('row-0'), findsOneWidget);
      _expectWaiting(tester, selectedCount: 2);
      await tester.tap(_action, warnIfMissed: false);
      await tester.pump();
      expect(harness.executed, hasLength(1));
      // The table never clears or rewrites the host's selection meanwhile.
      expect(harness.selected, {'row-0', 'row-90'});

      // A later, larger prefix of the same read still waits.
      harness.update(() => harness.items = second.prefix(100));
      await _frames(tester);
      _expectWaiting(tester, selectedCount: 2);

      // The complete result replaces the prefix: the action is back and acts on
      // the kept selection, without a replayed earlier attempt.
      harness.update(() => harness.items = second.complete());
      await tester.pumpAndSettle();
      _expectReady(tester);
      await tester.tap(_action);
      await tester.pump();
      expect(harness.executed, [
        {'row-0', 'row-90'},
        {'row-0', 'row-90'},
      ]);

      // A read that fails after showing progressive rows retires its session:
      // the floating group stays hidden exactly as before.
      final third = _Query();
      harness.update(() => harness.items = third.prefix(50));
      await _frames(tester);
      _expectWaiting(tester, selectedCount: 2);
      third.fail();
      harness.update(() {});
      await tester.pumpAndSettle();
      expect(_action, findsNothing);
      expect(find.text('数据加载失败'), findsOneWidget);
      expect(harness.selected, {'row-0', 'row-90'});
      expect(harness.executed, hasLength(2));
      expect(tester.takeException(), isNull);
      semantics.dispose();
    },
  );

  testWidgets('the fullscreen table applies the same wait and recovery', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final first = _Query();
    final harness = _Harness()
      ..items = first.complete()
      ..selected = {'row-3'};
    await tester.pumpWidget(harness.build());
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('master-table-fullscreen-toggle')),
    );
    await tester.pumpAndSettle();
    _expectReady(tester);

    final second = _Query();
    harness.update(() => harness.items = second.prefix(50));
    await _frames(tester);
    _expectWaiting(tester, selectedCount: 1);
    await tester.tap(_action, warnIfMissed: false);
    await tester.pump();
    expect(harness.executed, isEmpty);

    harness.update(() => harness.items = second.complete());
    await tester.pumpAndSettle();
    _expectReady(tester);
    await tester.tap(_action);
    await tester.pump();
    expect(harness.executed, [
      {'row-3'},
    ]);
    expect(tester.takeException(), isNull);
    semantics.dispose();
  });
}
