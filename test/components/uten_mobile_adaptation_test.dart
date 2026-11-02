import 'dart:async';
import 'dart:ui' show PointerDeviceKind;
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/buttons/uten_button.dart';
import 'package:uten_imp/components/inputs/uten_search_bar.dart';
import 'package:uten_imp/components/layout/uten_action_overflow.dart';
import 'package:uten_imp/components/layout/uten_floating_action_group.dart';
import 'package:uten_imp/components/layout/uten_paged_grid.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_control_theme.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/ui/capsule_nav_metrics.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app(Widget child) => ProviderScope(
  child: MaterialApp(
    theme: buildLightTheme().copyWith(platform: TargetPlatform.windows),
    builder: (_, body) => UtenControlTheme(child: body!),
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('auxiliary icon presentation keeps names and desktop wording', (
    tester,
  ) async {
    _window(tester, const Size(390, 850));
    var calls = 0;
    await tester.pumpWidget(
      _app(
        Center(
          child: UtenButton(
            compactIcon: Icons.settings_outlined,
            onPressed: () => calls++,
            child: const Text('表头设置 9/11'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('表头设置 9/11'), findsNothing);
    expect(find.byTooltip('表头设置 9/11'), findsOneWidget);
    expect(find.bySemanticsLabel('表头设置 9/11'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.settings_outlined));
    expect(calls, 1);
    tester.view.physicalSize = const Size(1280, 850);
    await tester.pumpAndSettle();
    expect(find.text('表头设置 9/11'), findsOneWidget);
    expect(find.byIcon(Icons.settings_outlined), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'compact paint shrinks while its hit target and label remain usable',
    (tester) async {
      _window(tester, const Size(390, 850));
      var calls = 0;
      await tester.pumpWidget(
        _app(
          Center(
            child: UtenButton(
              size: UtenButtonSize.small,
              onPressed: () => calls++,
              child: const Text('表头设置'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byType(UtenButton);
      final painted = find
          .descendant(of: button, matching: find.byType(Material))
          .first;
      expect(tester.getRect(painted).height, 36);
      expect(tester.getRect(button).height, greaterThanOrEqualTo(48));
      await tester.tapAt(tester.getRect(button).topLeft + const Offset(1, 1));
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'smaller application zoom retains the compact button window hit target',
    (tester) async {
      _window(tester, const Size(390, 850));
      var calls = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLightTheme(),
          builder: (_, body) => UtenDisplayZoomBox(
            fontFactor: .5,
            child: UtenControlTheme(child: body!),
          ),
          home: Scaffold(
            body: Center(
              child: UtenButton(
                onPressed: () => calls++,
                child: const Text('添加'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byType(UtenButton);
      expect(tester.getRect(button).height, greaterThanOrEqualTo(48));
      await tester.tapAt(tester.getRect(button).topLeft + const Offset(1, 1));
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 390.0, 768.0, 1280.0]) {
    testWidgets('responsive button density and target at $width', (
      tester,
    ) async {
      _window(tester, Size(width, 850));
      late ThemeData adapted;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) {
              adapted = Theme.of(context);
              return Align(
                alignment: Alignment.bottomRight,
                child: UtenButton(
                  size: UtenButtonSize.large,
                  icon: Icons.save_outlined,
                  onPressed: () {},
                  child: const Text('保存单据'),
                ),
              );
            },
          ),
        ),
      );
      final style = tester
          .widget<DefaultTextStyle>(
            find
                .ancestor(
                  of: find.text('保存单据'),
                  matching: find.byType(DefaultTextStyle),
                )
                .first,
          )
          .style;
      expect(style.fontSize, width < 840 ? 13 : 16);
      expect(adapted.textTheme.bodyLarge!.fontSize, width < 840 ? 14 : 16);
      expect(
        tester.getSize(find.byType(UtenButton)).height,
        greaterThanOrEqualTo(48),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('dropdown keeps state, disabled actions and single submission', (
    tester,
  ) async {
    _window(tester, const Size(390, 850));
    var calls = 0;
    final pending = Completer<void>();
    await tester.pumpWidget(
      _app(
        Align(
          alignment: Alignment.topRight,
          child: UtenActionOverflow(
            forceCompact: true,
            children: [
              UtenButton(
                onPressed: () async {
                  calls++;
                  await pending.future;
                },
                child: const Text('导出明细'),
              ),
              const UtenButton(child: Text('不可用操作')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('导出明细'), findsNothing);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    expect(find.text('导出明细'), findsOneWidget);
    await tester.tap(find.text('导出明细'));
    await tester.pump();
    await tester.tap(find.text('导出明细'));
    await tester.pump();
    expect(calls, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('导出明细'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byTooltip('更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('不可用操作'));
    await tester.pump();
    expect(calls, 1);
    expect(find.text('导出明细'), findsOneWidget);
  });

  testWidgets(
    'table search stays outside compact menu and keeps composing text',
    (tester) async {
      _window(tester, const Size(390, 850));
      final search = GlobalKey();
      var calls = 0;
      Widget table(bool loading) => _app(
        MasterDataTableView<String>(
          columns: [
            MasterColumnDef<String>(
              key: 'name',
              label: '名称',
              width: 200,
              value: (s) => s,
            ),
          ],
          items: loading ? const [] : const ['货品A'],
          isLoading: loading,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          toolbarLeadingActions: [
            SizedBox(
              width: 180,
              child: UtenSearchBar(
                key: search,
                hint: '搜索货品',
                onChanged: (_) {},
              ),
            ),
            TextButton(onPressed: () => calls++, child: const Text('打印明细')),
          ],
          toolbarActions: [
            UtenButton(onPressed: () => calls++, child: const Text('下载表格')),
          ],
        ),
      );
      await tester.pumpWidget(table(false));
      await tester.pumpAndSettle();
      final state = search.currentState;
      await tester.tap(find.byTooltip('搜索货品'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '搜索原文');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('打印明细'), findsNothing);
      await tester.tap(find.byTooltip('表格操作'));
      await tester.pumpAndSettle();
      expect(find.text('打印明细'), findsOneWidget);
      expect(search.currentState, same(state));
      await tester.tap(find.text('打印明细'));
      await tester.pumpAndSettle();
      expect(calls, 1);
      // A previously opened portal must not retain a deferred render child
      // while the same search/control subtree moves into fullscreen layout.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(1, 1));
      await mouse.moveTo(
        tester.getCenter(
          find.byKey(const ValueKey('master-table-fullscreen-toggle')),
        ),
      );
      await tester.pump(const Duration(seconds: 1));
      await tester.tap(
        find.byKey(const ValueKey('master-table-fullscreen-toggle')),
      );
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('退出全屏'), findsOneWidget);
      expect(search.currentState, same(state));
      await tester.tap(
        find.byKey(const ValueKey('master-table-fullscreen-toggle')),
      );
      await tester.pumpAndSettle();
      expect(search.currentState, same(state));
      expect(tester.takeException(), isNull);
      await mouse.removePointer();
      await tester.pumpWidget(table(true));
      await tester.pump();
      expect(search.currentState, same(state));
      expect(find.byTooltip('搜索货品：搜索原文'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('mobile card pager is above full-height scrolling content', (
    tester,
  ) async {
    _window(tester, const Size(390, 850));
    await tester.pumpWidget(
      _app(
        UtenCapsuleNavScope(
          occlusion: 90,
          child: UtenPagedGrid<int>(
            items: List.generate(25, (i) => i),
            itemBuilder: (_, i, _) => SizedBox(height: 80, child: Text('卡片$i')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(UtenGridPager)).dy, 0);
    final scroll = find.descendant(
      of: find.byType(UtenPagedGrid<int>),
      matching: find.byType(SingleChildScrollView),
    );
    expect(tester.getRect(scroll).bottom, 850);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'bottom actions stay above navigation and primary stays rightmost',
    (tester) async {
      _window(tester, const Size(390, 850));
      await tester.pumpWidget(
        _app(
          UtenCapsuleNavScope(
            occlusion: 90,
            child: Align(
              alignment: Alignment.bottomRight,
              child: UtenFloatingActionGroup(
                children: [
                  UtenButton(onPressed: () {}, child: const Text('取消')),
                  UtenButton(onPressed: () {}, child: const Text('另存草稿')),
                  UtenButton(onPressed: () {}, child: const Text('确认提交')),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('取消'), findsNothing);
      expect(tester.getRect(find.text('确认提交')).bottom, lessThan(760));
      expect(
        tester.getRect(find.text('确认提交')).right,
        greaterThan(tester.getRect(find.byTooltip('其他操作')).right),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
