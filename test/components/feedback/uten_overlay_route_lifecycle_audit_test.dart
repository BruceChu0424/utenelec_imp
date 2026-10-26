import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_busy_overlay.dart';
import 'package:uten_imp/components/data_display/uten_table_row_drag.dart';
import 'package:uten_imp/components/feedback/uten_context_menu.dart';
import 'package:uten_imp/components/feedback/uten_context_menu_policy.dart';
import 'package:uten_imp/components/layout/uten_grid_header_filter_cell.dart';
import 'package:uten_imp/components/layout/uten_table_column_kit.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/measurement/widgets/weight_text.dart';

Future<GlobalKey<NavigatorState>> _host(
  WidgetTester tester,
  Widget child,
) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      builder: (_, child) => UtenContextMenuPolicy(child: child!),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 400, height: 200, child: child),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  return navigator;
}

Future<void> _push(
  WidgetTester tester,
  GlobalKey<NavigatorState> navigator, {
  VoidCallback? onAction,
}) async {
  navigator.currentState!.push<void>(
    MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        body: Center(
          child: TextButton(
            key: const Key('new-page-action'),
            onPressed: onAction ?? () {},
            child: const Text('新页面操作'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

void main() {
  testWidgets('被新页面覆盖的忙碌宿主不能继续用root遮罩阻止新页面操作', (tester) async {
    var oldActions = 0;
    final navigator = await _host(
      tester,
      Stack(
        children: [
          TextButton(onPressed: () => oldActions++, child: const Text('旧页面操作')),
          const UtenBusyOverlay(title: '旧页面正在处理'),
        ],
      ),
    );
    expect(find.text('旧页面正在处理'), findsOneWidget);
    var actions = 0;
    await _push(tester, navigator, onAction: () => actions++);
    final button = tester.getCenter(find.byKey(const Key('new-page-action')));
    await tester.tapAt(button);
    await tester.pump();
    expect(
      actions,
      1,
      reason: '旧页面的TickerMode已关闭，root Overlay中的旧ModalBarrier仍在新路由上层',
    );
    navigator.currentState!.pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('旧页面正在处理'), findsOneWidget);
    await tester.tapAt(tester.getCenter(find.text('旧页面操作')));
    await tester.pump();
    expect(oldActions, 0, reason: '页面返回后仍在运行的业务继续受遮罩保护');
  });

  testWidgets('表头设置在所属页面被覆盖后关闭，不能漂到新页面上层', (tester) async {
    final navigator = await _host(
      tester,
      UtenColumnChooserButton(
        entries: const [UtenColumnChooserEntry(key: 'name', label: '旧表格货品名')],
        hiddenKeys: const {},
        onToggle: (_) {},
        onToggleAll: (_) {},
      ),
    );
    await tester.tap(find.text('表头设置 1/1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('uten-column-chooser')), findsOneWidget);
    await _push(tester, navigator);
    expect(
      find.byKey(const ValueKey('uten-column-chooser')),
      findsNothing,
      reason: '旧宿主仍被Navigator保留，dispose不能清理root Overlay中的菜单',
    );
  });

  testWidgets('编辑表格筛选菜单在所属页面被覆盖后关闭', (tester) async {
    final navigator = await _host(
      tester,
      GridHeaderFilterCell(
        label: '旧表格筛选',
        buckets: const [
          GridHeaderFilterBucket(value: 'a', display: '候选A', count: 1),
        ],
        nullCount: 0,
        selected: null,
        onChanged: (_) {},
      ),
    );
    await tester.tap(find.text('旧表格筛选'));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('uten-grid-column-filter-menu')),
      findsOneWidget,
    );
    await _push(tester, navigator);
    expect(find.byKey(const Key('uten-grid-column-filter-menu')), findsNothing);
  });

  testWidgets('称重单位菜单在所属页面被覆盖后关闭', (tester) async {
    final navigator = await _host(
      tester,
      WeightUnitMenuButton<String>(
        prefix: '称重单位',
        value: '千克',
        options: const ['千克', '克'],
        labelOf: (unit) => unit,
        onSelected: (_) {},
      ),
    );
    await tester.tap(find.text('称重单位: 千克'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('weight-unit-option-克')), findsOneWidget);
    await _push(tester, navigator);
    expect(find.byKey(const ValueKey('weight-unit-option-克')), findsNothing);
  });

  testWidgets('行右键菜单在所属页面被覆盖后关闭，不允许作用于已离开的表格', (tester) async {
    final navigator = await _host(
      tester,
      UtenContextMenuRegion(
        entriesBuilder: () => [UtenMenuItem(label: '旧页面行操作', onTap: () {})],
        child: const Center(child: Text('旧页面行')),
      ),
    );
    final pointer = await tester.startGesture(
      tester.getCenter(find.text('旧页面行')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await pointer.up();
    await tester.pumpAndSettle();
    expect(find.text('旧页面行操作'), findsOneWidget);
    await _push(tester, navigator);
    expect(find.text('旧页面行操作'), findsNothing);
  });

  testWidgets('主数据表格筛选菜单在所属页面被覆盖后关闭', (tester) async {
    final navigator = await _host(
      tester,
      MasterDataTableView<String>(
        columns: [
          MasterColumnDef<String>(
            key: 'status',
            label: '主表状态',
            width: 200,
            value: (row) => row,
          ),
        ],
        items: const ['原状态'],
        facets: const {
          'status': [MasterFacetBucket(value: '原状态', count: 1)],
        },
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        embedded: true,
        showColumnChooser: false,
      ),
    );
    await tester.tap(find.text('主表状态'));
    await tester.pumpAndSettle();
    expect(find.text('原状态 (1)'), findsOneWidget);
    await _push(tester, navigator);
    expect(find.text('原状态 (1)'), findsNothing);
  });

  testWidgets('忙碌页面弹出确认框时不能被自己的root遮罩盖住形成等待死锁', (tester) async {
    final navigator = await _host(
      tester,
      const UtenBusyOverlay(title: '正在处理业务'),
    );
    var confirmed = false;
    showDialog<void>(
      context: navigator.currentState!.context,
      builder: (context) => AlertDialog(
        title: const Text('业务需要确认'),
        actions: [
          TextButton(
            onPressed: () {
              confirmed = true;
              Navigator.pop(context);
            },
            child: const Text('继续业务'),
          ),
        ],
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    await tester.tapAt(tester.getCenter(find.text('继续业务')));
    await tester.pump();
    expect(
      confirmed,
      isTrue,
      reason: '透明Dialog不会关闭下方路由的TickerMode，需按所属路由的current状态让位',
    );
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump();
    expect(find.text('正在处理业务'), findsOneWidget);
  });

  for (final trigger in ['Escape', '应用失焦', '窗口失焦']) {
    testWidgets('行菜单在$trigger后关闭，返回后可再次右键且不执行业务动作', (tester) async {
      var actions = 0;
      await _host(
        tester,
        UtenContextMenuRegion(
          entriesBuilder: () => [
            UtenMenuItem(label: '当前行操作', onTap: () => actions++),
          ],
          child: const Center(child: Text('当前行')),
        ),
      );
      Future<void> open() async {
        final pointer = await tester.startGesture(
          tester.getCenter(find.text('当前行')),
          kind: PointerDeviceKind.mouse,
          buttons: kSecondaryButton,
        );
        await pointer.up();
        await tester.pumpAndSettle();
      }

      await open();
      expect(find.text('当前行操作'), findsOneWidget);
      if (trigger == 'Escape') {
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      } else if (trigger == '应用失焦') {
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      } else {
        tester.binding.handleViewFocusChanged(
          ui.ViewFocusEvent(
            viewId: tester.view.viewId,
            state: ui.ViewFocusState.unfocused,
            direction: ui.ViewFocusDirection.forward,
          ),
        );
      }
      await tester.pumpAndSettle();
      expect(find.text('当前行操作'), findsNothing);
      expect(actions, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      tester.binding.handleViewFocusChanged(
        ui.ViewFocusEvent(
          viewId: tester.view.viewId,
          state: ui.ViewFocusState.focused,
          direction: ui.ViewFocusDirection.backward,
        ),
      );
      await open();
      await tester.tap(find.text('当前行操作'));
      await tester.pumpAndSettle();
      expect(actions, 1);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('行菜单的宿主经GlobalKey重挂载时关闭，旧浮层不跨新宿主位置', (tester) async {
    final rowKey = GlobalKey();
    var moved = false;
    late StateSetter change;
    await _host(
      tester,
      StatefulBuilder(
        builder: (_, setState) {
          change = setState;
          final row = UtenContextMenuRegion(
            key: rowKey,
            entriesBuilder: () => [UtenMenuItem(label: '重挂载行操作', onTap: () {})],
            child: const Center(child: Text('重挂载行')),
          );
          return Row(
            children: [
              Expanded(child: moved ? const SizedBox.shrink() : row),
              Expanded(child: moved ? row : const SizedBox.shrink()),
            ],
          );
        },
      ),
    );
    final pointer = await tester.startGesture(
      tester.getCenter(find.text('重挂载行')),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryButton,
    );
    await pointer.up();
    await tester.pumpAndSettle();
    expect(find.text('重挂载行操作'), findsOneWidget);
    change(() => moved = true);
    await tester.pumpAndSettle();
    expect(find.text('重挂载行操作'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('业务表格右键后经页面快捷键切页，返回仍能双击和右键进入详情', (tester) async {
    final navigator = GlobalKey<NavigatorState>();
    var detailOpenings = 0;
    MaterialPageRoute<void> page(String title) => MaterialPageRoute<void>(
      builder: (_) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: Center(
          child: TextButton(
            onPressed: () => navigator.currentState!.pop(),
            child: const Text('返回货品资料'),
          ),
        ),
      ),
    );
    Future<void> detail() async {
      detailOpenings++;
      await navigator.currentState!.push<void>(page('货品详情'));
    }

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) => CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.f9): () {
              navigator.currentState!.push<void>(page('其他业务页面'));
            },
          },
          child: UtenContextMenuPolicy(child: child!),
        ),
        home: Scaffold(
          body: SizedBox(
            width: 700,
            height: 450,
            child: MasterDataTableView<String>(
              columns: [
                MasterColumnDef<String>(
                  key: 'name',
                  label: '货品名称',
                  width: 250,
                  value: (row) => row,
                ),
              ],
              items: const ['业务货品'],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              onRowTap: (_) => detail(),
              rowMenuBuilder: (_) => [
                UtenMenuItem(label: '查看货品详情', onTap: detail),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> rightClick() async {
      final pointer = await tester.startGesture(
        tester.getCenter(find.text('业务货品')),
        kind: PointerDeviceKind.mouse,
        buttons: kSecondaryButton,
      );
      await pointer.up();
      await tester.pumpAndSettle();
    }

    await rightClick();
    expect(find.text('查看货品详情'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.f9);
    await tester.pumpAndSettle();
    expect(find.text('其他业务页面'), findsOneWidget);
    expect(find.text('查看货品详情'), findsNothing);
    await tester.tap(find.text('返回货品资料'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('业务货品'));
    await tester.pump(const Duration(milliseconds: 70));
    await tester.tap(find.text('业务货品'));
    await tester.pumpAndSettle();
    expect(find.text('货品详情'), findsOneWidget);
    expect(detailOpenings, 1);
    await tester.tap(find.text('返回货品资料'));
    await tester.pumpAndSettle();
    await rightClick();
    await tester.tap(find.text('查看货品详情'));
    await tester.pumpAndSettle();
    expect(find.text('货品详情'), findsOneWidget);
    expect(detailOpenings, 2);
    await tester.tap(find.text('返回货品资料'));
    await tester.pumpAndSettle();
    expect(find.text('业务货品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('程序化inactive打开在attach同步关闭后安全早退，不解引用输入或残留拖拽周期Timer', (
    tester,
  ) async {
    var facetReads = 0;
    await _host(
      tester,
      MasterDataTableView<String>(
        columns: [
          MasterColumnDef<String>(
            key: 'name',
            label: '货品名称',
            width: 240,
            value: (row) => row,
          ),
        ],
        items: const ['同步货品'],
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
        loadFacetPage: (_, _, _) async {
          facetReads++;
          return const MasterFacetPage(items: [], hasMore: false);
        },
        selectable: true,
        idOf: (row) => row,
        onSelectedIdsChanged: (_) {},
        rowDrag: UtenTableRowDrag<String>(
          canDragRow: (_) => true,
          dragRowsOf: (row) => [row],
          canDrop: (_, _) => true,
          onDrop: (_, _, _) async {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    addTearDown(
      () => tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      ),
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester
        .widget<InkWell>(
          find.byKey(const ValueKey('master-column-filter-name')),
        )
        .onTap!();
    await tester.pump();
    expect(facetReads, 0);
    expect(tester.takeException(), isNull);

    final dragRegion = tester
        .widgetList<RawGestureDetector>(
          find.ancestor(
            of: find.text('同步货品'),
            matching: find.byType(RawGestureDetector),
          ),
        )
        .singleWhere(
          (widget) =>
              widget.gestures.containsKey(LongPressGestureRecognizer) &&
              widget.gestures.containsKey(VerticalDragGestureRecognizer),
        );
    final factory =
        dragRegion.gestures[LongPressGestureRecognizer]!
            as GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>;
    final recognizer = factory.constructor();
    factory.initializer(recognizer);
    final periods = <Duration>[];
    final timers = <Timer>[];
    try {
      runZoned(
        () => recognizer.onLongPressStart!(
          LongPressStartDetails(
            globalPosition: tester.getCenter(find.text('同步货品')),
          ),
        ),
        zoneSpecification: ZoneSpecification(
          createPeriodicTimer: (_, parent, zone, duration, callback) {
            periods.add(duration);
            final timer = parent.createPeriodicTimer(zone, duration, callback);
            timers.add(timer);
            return timer;
          },
        ),
      );
    } finally {
      recognizer.dispose();
      for (final timer in timers) {
        timer.cancel();
      }
    }
    expect(periods, isNot(contains(const Duration(milliseconds: 120))));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('同步货品'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
