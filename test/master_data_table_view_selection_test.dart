// Feature 2：表体 SelectionArea 文字选择决策门测试。
//
// D-11 表体存在 SelectionArea；D-13 鼠标双击行仍触发 onRowTap（FM1 安全网——
//    验证 SelectionArea 的 mouse TapAndPanGestureRecognizer 不抢 InkWell 的点按，
//    期望通过：命中分发"最深优先"+ InkWell 更早 resolve(accepted) → 行导航正常）。
//    新交互契约：单击只选中（不触发 onRowTap），双击才打开（手动时间窗判定，
//    无 DoubleTapGestureRecognizer 竞技场 hold，不影响文本拖选）。
// D-12 触屏双击行仍导航；D-15 大表拖选+滚+刷新不崩（FM2 把关，best-effort）。

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/data_display/uten_selection_summary_pill.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/core/theme/dark_theme.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/capsule_nav_metrics.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

import 'support/audit_screenshot_support.dart';

class _Row {
  const _Row(this.id);
  final String id;
}

Widget _table({
  required List<_Row> items,
  void Function(_Row)? onRowTap,
  void Function(_Row)? onSelectionChanged,
  double height = 200,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 640,
        height: height,
        child: MasterDataTableView<_Row>(
          columns: [
            MasterColumnDef<_Row>(
              key: 'id',
              label: 'ID',
              width: 240,
              value: (r) => r.id,
            ),
          ],
          items: items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          onRowTap: onRowTap,
          onSelectionChanged: onSelectionChanged,
        ),
      ),
    ),
  );
}

/// 双击指定行（两次点按间隔 50ms，落在 350ms 手动双击判定窗内）。
Future<void> _doubleTapRow(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump(const Duration(milliseconds: 50));
  await tester.tap(finder);
  await tester.pump();
}

void main() {
  testWidgets('picker list retains bounded batch actions and clear selection', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 480);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await loadAuditScreenshotFonts(tester);
    var selected = <String>{'b'};
    final calls = <Set<String>>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: auditScreenshotTheme(
          buildLightTheme().copyWith(platform: TargetPlatform.android),
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.fromLTRB(28, 178, 28, 12),
            child: ClipRect(
              key: const Key('picker-batch-stage'),
              child: StatefulBuilder(
                builder: (context, update) => MasterDataTableView<String>(
                  columns: const [],
                  items: const ['a', 'b'],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  listItemBuilder: (_, id) => SizedBox(
                    key: ValueKey('picker-row-$id'),
                    height: 64,
                    child: Center(child: Text('记录 $id')),
                  ),
                  selectable: true,
                  idOf: (id) => id,
                  selectedIds: selected,
                  onSelectedIdsChanged: (next) => update(() => selected = next),
                  batchActionsBuilder: (_, ids) => [
                    UtenButton(
                      key: const Key('picker-batch-action'),
                      size: UtenButtonSize.large,
                      onPressed: () => calls.add(Set.of(ids)),
                      child: Text('办理 ${ids.length} 项'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final group = find.byType(UtenFloatingActionGroup);
    expect(group, findsOneWidget);
    final row = find.byKey(const ValueKey('picker-row-b'));
    await tester.ensureVisible(row);
    await tester.pumpAndSettle();
    final stage = tester.getRect(find.byKey(const Key('picker-batch-stage')));
    expect(
      tester.getRect(row).bottom,
      lessThanOrEqualTo(tester.getRect(group).top),
    );
    for (final control in [
      find.byKey(const Key('picker-batch-action')),
      find.byKey(const Key('master-table-clear-selection')),
    ]) {
      await tester.ensureVisible(control);
      await tester.pumpAndSettle();
      final rect = tester.getRect(control);
      expect(rect.left, greaterThanOrEqualTo(stage.left));
      expect(rect.right, lessThanOrEqualTo(stage.right));
      expect(rect.top, greaterThanOrEqualTo(stage.top));
      expect(rect.bottom, lessThanOrEqualTo(stage.bottom));
      expect(control.hitTestable(), findsOneWidget);
      await tester.tap(control);
      await tester.pumpAndSettle();
    }
    expect(calls, [
      {'b'},
    ]);
    expect(selected, isEmpty);
    expect(find.text('已选 0 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('local filter releases the previous tall-row action budget', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 600,
            height: 420,
            child: MasterDataTableView<String>(
              columns: [
                MasterColumnDef<String>(
                  key: 'kind',
                  label: '分类',
                  width: 260,
                  filterFromRows: true,
                  value: (id) => id,
                  cellBuilder: (_, id) =>
                      SizedBox(height: id == '高行' ? 180 : 32, child: Text(id)),
                ),
              ],
              items: const ['短行', '高行'],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              selectable: true,
              idOf: (id) => id,
              batchActionsBuilder: (_, _) => [
                for (var i = 0; i < 6; i++)
                  UtenButton(
                    size: UtenButtonSize.large,
                    onPressed: () {},
                    child: Text('操作 $i'),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = tester
        .widget<UtenFloatingActionGroup>(find.byType(UtenFloatingActionGroup))
        .maxHeight!;
    await tester.tap(find.text('分类').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('短行 (1)'));
    await tester.pumpAndSettle();
    expect(find.text('高行'), findsNothing);
    final after = tester
        .widget<UtenFloatingActionGroup>(find.byType(UtenFloatingActionGroup))
        .maxHeight!;
    expect(after, greaterThan(before + 60));
    expect(tester.takeException(), isNull);
  });

  for (final scenario in [
    (scale: 1.0, occlusion: 0.0),
    (scale: 1.6, occlusion: 0.0),
    (scale: 1.6, occlusion: 70.0),
  ]) {
    testWidgets(
      'local row budget keeps an editor and long actions usable $scenario',
      (tester) async {
        tester.view.physicalSize = const Size(375, 480);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await loadAuditScreenshotFonts(tester);
        final controllers = {
          for (final id in ['a', 'b', 'c']) id: TextEditingController(text: id),
        };
        final focus = {for (final id in controllers.keys) id: FocusNode()};
        addTearDown(() {
          for (final controller in controllers.values) {
            controller.dispose();
          }
          for (final node in focus.values) {
            node.dispose();
          }
        });
        final calls = <int>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: auditScreenshotTheme(
              buildLightTheme().copyWith(platform: TargetPlatform.android),
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: child!,
            ),
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.fromLTRB(28, 178, 28, 12),
                child: UtenCapsuleNavScope(
                  occlusion: scenario.occlusion,
                  child: ClipRect(
                    key: const Key('short-row-stage'),
                    child: MasterDataTableView<String>(
                      columns: [
                        MasterColumnDef<String>(
                          key: 'id',
                          label: '填写',
                          width: 240,
                          value: (id) => id,
                          cellBuilder: (context, id) => TextField(
                            key: ValueKey('short-editor-$id'),
                            controller: controllers[id],
                            focusNode: focus[id],
                          ),
                        ),
                      ],
                      items: const ['a', 'b', 'c'],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      selectable: true,
                      idOf: (id) => id,
                      rowWidgetKeyOf: (id) => ValueKey('short-data-row-$id'),
                      selectedIds: const {'c'},
                      batchActionsBuilder: (_, _) => [
                        for (var i = 0; i < 6; i++)
                          UtenButton(
                            key: ValueKey('short-action-$i'),
                            size: UtenButtonSize.large,
                            icon: i == 2 ? Icons.fact_check_outlined : null,
                            onPressed: () => calls.add(i),
                            child: Text(
                              i == 2 ? '确认更正 128 人 256 处员工证件信息并提交' : '办理操作 $i',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final field = find.byKey(const ValueKey('short-editor-c'));
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        // If chrome must scroll to fit a full row and action, reveal it with the
        // same ordinary toolbar drag available to a user, not a controller jump.
        final toolbar = find.textContaining('表头设置').first;
        if (scenario.occlusion > 0 &&
            toolbar.hitTestable().evaluate().isNotEmpty) {
          await tester.drag(toolbar, const Offset(0, -160));
          await tester.pumpAndSettle();
        }
        final stage = tester.getRect(find.byKey(const Key('short-row-stage')));
        void expectRowClear() {
          final row = tester.getRect(
            find.byKey(const ValueKey('short-data-row-c')),
          );
          final group = tester.getRect(find.byType(UtenFloatingActionGroup));
          expect(row.top, greaterThanOrEqualTo(stage.top));
          expect(row.bottom, lessThanOrEqualTo(group.top));
          expect(field.hitTestable(), findsOneWidget);
        }

        expectRowClear();
        await tester.tap(field);
        await tester.pumpAndSettle();
        expect(focus['c']!.hasFocus, isTrue);
        focus['c']!.unfocus();
        await tester.pumpAndSettle();
        final actionScroll = find.descendant(
          of: find.byType(UtenFloatingActionGroup),
          matching: find.byType(Scrollable),
        );
        expect(actionScroll, findsOneWidget);
        final scrollbar = tester.widget<Scrollbar>(
          find.descendant(
            of: find.byType(UtenFloatingActionGroup),
            matching: find.byType(Scrollbar),
          ),
        );
        expect(scrollbar.thumbVisibility, isTrue);
        expect(
          tester.state<ScrollableState>(actionScroll).position.maxScrollExtent,
          greaterThan(0),
        );
        var drags = 0;
        for (var i = 0; i < 6; i++) {
          final action = find.byKey(ValueKey('short-action-$i'));
          for (var attempt = 0; attempt < 4; attempt++) {
            final viewport = tester.getRect(actionScroll);
            final target = tester.getRect(action);
            if (action.hitTestable().evaluate().isNotEmpty &&
                target.top >= viewport.top - 0.5 &&
                target.bottom <= viewport.bottom + 0.5) {
              break;
            }
            final direction = target.center.dy > viewport.center.dy
                ? -1.0
                : 1.0;
            final gesture = await tester.startGesture(viewport.center);
            await gesture.moveBy(Offset(0, direction * 24));
            await tester.pump();
            await gesture.moveBy(
              Offset(0, viewport.center.dy - tester.getRect(action).center.dy),
            );
            await tester.pump(const Duration(milliseconds: 200));
            await gesture.up();
            await tester.pumpAndSettle();
            drags++;
          }
          expect(action.hitTestable(), findsOneWidget);
          final rect = tester.getRect(action);
          if (i == 2 && scenario.scale > 1) {
            expect(rect.height, greaterThan(48 * scenario.scale + 8));
          }
          final actionViewport = tester.getRect(actionScroll);
          expect(rect.top, greaterThanOrEqualTo(actionViewport.top - 0.5));
          expect(rect.bottom, lessThanOrEqualTo(actionViewport.bottom + 0.5));
          expect(rect.top, greaterThanOrEqualTo(stage.top));
          expect(
            rect.bottom,
            lessThanOrEqualTo(stage.bottom - scenario.occlusion),
          );
          await tester.tap(action);
          await tester.pumpAndSettle();
          expectRowClear();
        }
        expect(drags, greaterThan(0));
        expect(calls, [0, 1, 2, 3, 4, 5]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final scenario in [
    (dark: false, scale: 1.0, rtl: false, selected: true, occlusion: 0.0),
    (dark: true, scale: 1.6, rtl: false, selected: false, occlusion: 0.0),
    (dark: false, scale: 1.0, rtl: true, selected: false, occlusion: 48.0),
    (dark: true, scale: 1.6, rtl: true, selected: true, occlusion: 0.0),
  ]) {
    testWidgets('floating batch bounds respect a padded 375px stage $scenario', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(375, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await loadAuditScreenshotFonts(tester);
      var selected = scenario.selected ? <String>{'a1'} : <String>{};
      var runs = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: auditScreenshotTheme(
            (scenario.dark ? buildDarkTheme() : buildLightTheme()).copyWith(
              platform: TargetPlatform.android,
            ),
          ),
          builder: (context, child) => Directionality(
            textDirection: scenario.rtl ? TextDirection.rtl : TextDirection.ltr,
            child: MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
              child: child!,
            ),
          ),
          home: Scaffold(
            body: UtenCapsuleNavScope(
              occlusion: scenario.occlusion,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: ClipRect(
                  key: const Key('padded-batch-stage'),
                  child: StatefulBuilder(
                    builder: (context, update) => MasterDataTableView<_Row>(
                      columns: [
                        MasterColumnDef<_Row>(
                          key: 'id',
                          label: 'ID',
                          width: 240,
                          value: (row) => row.id,
                        ),
                      ],
                      items: const [_Row('a1')],
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      selectable: true,
                      idOf: (row) => row.id,
                      selectedIds: selected,
                      onSelectedIdsChanged: (next) =>
                          update(() => selected = next),
                      batchActionsBuilder: (_, ids) => [
                        UtenButton(
                          key: const Key('padded-batch-action'),
                          type: UtenButtonType.danger,
                          size: UtenButtonSize.large,
                          icon: Icons.fact_check_outlined,
                          onPressed: () => runs++,
                          child: Text('确认更正 ${ids.length} 人 ${ids.length} 处'),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final stage = tester.getRect(find.byKey(const Key('padded-batch-stage')));
      final pill = find.byType(UtenSelectionSummaryPill);
      final action = find.byKey(const Key('padded-batch-action'));
      void expectVisibleBounds() {
        for (final finder in [pill, action]) {
          final rect = tester.getRect(finder);
          expect(
            rect.left,
            greaterThanOrEqualTo(stage.left),
            reason:
                'Each complete control must stay within the local clip, including its outline.',
          );
          expect(rect.right, lessThanOrEqualTo(stage.right));
          expect(rect.top, greaterThanOrEqualTo(stage.top));
          expect(
            rect.bottom,
            lessThanOrEqualTo(stage.bottom - scenario.occlusion),
          );
          expect(finder.hitTestable(), findsOneWidget);
        }
        expect(
          tester.getSize(pill).width,
          lessThan(tester.getSize(action).width),
          reason:
              'The short selection pill must not stretch to match the business action.',
        );
      }

      expectVisibleBounds();
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(runs, 1);
      if (selected.isNotEmpty) {
        await tester.tap(find.byKey(const Key('master-table-clear-selection')));
        await tester.pumpAndSettle();
        expect(selected, isEmpty);
        expect(find.text('已选 0 项'), findsOneWidget);
        expectVisibleBounds();
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'a partial row explicitly selects all and a full row clears on the next click',
    (tester) async {
      bool? rowState;
      var selected = <String>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, update) {
                return MasterDataTableView<String>(
                  columns: [
                    MasterColumnDef<String>(
                      key: 'label',
                      label: '项目',
                      width: 200,
                      value: (value) => value,
                    ),
                  ],
                  items: const ['group'],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  selectable: true,
                  idOf: (item) => item,
                  rowWidgetKeyOf: (_) => const Key('partial-selection-row'),
                  selectedIds: selected,
                  selectionStateOf: (_) => rowState,
                  onSelectedIdsChanged: (next) => update(() {
                    selected = next;
                    rowState = next.contains('group');
                  }),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final checkbox = find.descendant(
        of: find.byKey(const Key('partial-selection-row')),
        matching: find.byType(Checkbox),
      );
      expect(tester.widget<Checkbox>(checkbox).value, isNull);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(selected, contains('group'));
      expect(tester.widget<Checkbox>(checkbox).value, isTrue);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(selected, isEmpty);
      expect(tester.widget<Checkbox>(checkbox).value, isFalse);
    },
  );
  testWidgets('body is wrapped in SelectionArea (cells selectable)', (
    tester,
  ) async {
    await tester.pumpWidget(_table(items: const [_Row('a1')]));
    await tester.pumpAndSettle();

    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets(
    'single click selects without opening (new contract: click = select)',
    (tester) async {
      var opens = 0;
      var selects = 0;
      await tester.pumpWidget(
        _table(
          items: const [_Row('a1'), _Row('a2')],
          onRowTap: (_) => opens++,
          onSelectionChanged: (_) => selects++,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('a1'));
      await tester.pump();

      // 单击：立即选中、绝不打开；pump 过双击窗口后依然不打开。
      expect(selects, 1);
      expect(opens, 0);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opens, 0);
    },
  );

  testWidgets(
    'mouse double click on row fires onRowTap inside SelectionArea (FM1 safety net)',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _table(items: const [_Row('a1'), _Row('a2')], onRowTap: (_) => taps++),
      );
      await tester.pumpAndSettle();

      // 鼠标双击第 1 行（SelectionArea 已包表体）。
      final center = tester.getCenter(find.text('a1'));
      var gesture = await tester.startGesture(
        center,
        pointer: 0,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 50));
      gesture = await tester.startGesture(
        center,
        pointer: 1,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.up();
      await tester.pump();

      // 期望：InkWell 赢竞技场，双击打开不被 SelectionArea 抢。
      expect(taps, 1);
    },
  );

  testWidgets('touch double tap on row navigates with SelectionArea present', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _table(items: const [_Row('a1')], onRowTap: (_) => taps++),
    );
    await tester.pumpAndSettle();

    await _doubleTapRow(tester, find.text('a1'));

    expect(taps, 1);
  });

  testWidgets(
    'selectable row remains selected when an already selected row is double clicked',
    (tester) async {
      var opens = 0;
      var selected = <String>{'a1'};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 640,
              height: 200,
              child: StatefulBuilder(
                builder: (context, setState) {
                  return MasterDataTableView<_Row>(
                    columns: [
                      MasterColumnDef<_Row>(
                        key: 'id',
                        label: 'ID',
                        width: 240,
                        value: (row) => row.id,
                      ),
                    ],
                    items: const [_Row('a1'), _Row('a2')],
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    selectable: true,
                    idOf: (row) => row.id,
                    selectedIds: selected,
                    onSelectedIdsChanged: (next) {
                      setState(() => selected = next);
                    },
                    onRowTap: (_) => opens++,
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await _doubleTapRow(tester, find.text('a1'));

      expect(opens, 1);
      expect(selected, {'a1'});
    },
  );

  testWidgets(
    'large table: select + scroll + refresh does not throw (FM2 CME gate)',
    (tester) async {
      await tester.pumpWidget(
        _table(
          items: [for (var i = 0; i < 300; i++) _Row('ROW-$i')],
          height: 300,
        ),
      );
      await tester.pumpAndSettle();

      // 鼠标拖选第 0 行，向下拖过视口（触发 auto-scroll + 行虚拟化 dispose）。
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('ROW-0')),
        pointer: 0,
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(const Offset(0, 400));
      await tester.pump();
      // 模拟刷新：换一批新的 item 对象（强制 cell 重建/dispose），观察是否抛
      // ConcurrentModificationError（_flushInactiveSelections 惰性迭代中途 dispose）。
      await tester.pumpWidget(
        _table(
          items: [for (var i = 0; i < 300; i++) _Row('ROW-$i')],
          height: 300,
        ),
      );
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      // 无异常即通过（test framework 会把 CME 当异常上报→测试失败）。
      expect(find.byType(SelectionArea), findsOneWidget);
    },
  );

  testWidgets(
    'selectable table shows selection summary even without batch commands',
    (tester) async {
      var selected = <String>{};
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 640,
              height: 260,
              child: StatefulBuilder(
                builder: (context, setState) => MasterDataTableView<_Row>(
                  columns: [
                    MasterColumnDef<_Row>(
                      key: 'id',
                      label: 'ID',
                      width: 240,
                      value: (row) => row.id,
                    ),
                  ],
                  items: const [_Row('a1'), _Row('a2')],
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                  selectable: true,
                  idOf: (row) => row.id,
                  selectedIds: selected,
                  onSelectedIdsChanged: (next) =>
                      setState(() => selected = next),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('已选 0 项'), findsOneWidget);
      await tester.tap(find.text('a1'));
      await tester.pump();
      expect(find.text('已选 1 项'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close_rounded));
      await tester.pump();
      expect(selected, isEmpty);
      expect(find.text('已选 0 项'), findsOneWidget);
    },
  );

  testWidgets(
    'batch actions float at bottom-right and remain available in fullscreen',
    (tester) async {
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var selected = <String>{};
      var runs = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => MasterDataTableView<_Row>(
                columns: [
                  MasterColumnDef<_Row>(
                    key: 'id',
                    label: 'ID',
                    width: 240,
                    value: (row) => row.id,
                  ),
                ],
                items: const [_Row('a1'), _Row('a2')],
                facets: const {},
                nullCounts: const {},
                filters: const {},
                onFilterChanged: (_, _) {},
                selectable: true,
                idOf: (row) => row.id,
                selectedIds: selected,
                onSelectedIdsChanged: (next) => setState(() => selected = next),
                batchActionsBuilder: (_, ids) => [
                  UtenButton(
                    key: const Key('floating-batch-action'),
                    size: UtenButtonSize.large,
                    onPressed: () => runs++,
                    child: Text('处理(${ids.length})'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('已选 0 项'), findsOneWidget);
      final action = find.byKey(const Key('floating-batch-action'));
      expect(action, findsOneWidget);
      final actionCenter = tester.getCenter(action);
      expect(actionCenter.dx, greaterThan(650));
      expect(actionCenter.dy, greaterThan(430));

      await tester.tap(find.text('a1'));
      await tester.pump();
      expect(find.text('已选 1 项'), findsOneWidget);
      await tester.tap(action);
      expect(runs, 1);

      await tester.tap(find.text('全屏'));
      await tester.pumpAndSettle();
      expect(action, findsOneWidget);
      await tester.tap(action);
      expect(runs, 2);
    },
  );
}
