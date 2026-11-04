import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/components/layout/uten_vertical_scroll_area.dart';
import 'package:uten_imp/components/layout/uten_vertical_scrollbar.dart';
import 'package:uten_imp/core/router/entry_page_scrollbar.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';

void main() {
  test('entry policy covers tablets but retains deeper operations', () {
    for (final path in UtenEntryPageScrollbarPolicy.entries) {
      for (final width in [390.0, 600.0, 839.0, 1024.0, 1279.0]) {
        expect(
          UtenEntryPageScrollbarPolicy.hidesRail('$path?filter=unread', width),
          isTrue,
          reason: '$path at $width',
        );
      }
      expect(UtenEntryPageScrollbarPolicy.hidesRail(path, 1280), isFalse);
      expect(UtenEntryPageScrollbarPolicy.hidesRail(path, 1920), isFalse);
    }
    for (final path in [
      '/warehouse/TRANSFER/new',
      '/warehouse/TRANSFER/doc-1',
      '/purchase/orders/new',
      '/purchase/orders/order-1/edit',
      '/notice/publish',
      '/employee/onboarding',
      '/payroll/generate',
      '/settings/software-publish',
      '/profile/edit',
      '/profile/me/changes',
      '/operations/workbench/purchase',
    ]) {
      expect(
        UtenEntryPageScrollbarPolicy.hidesRail(path, 390),
        isFalse,
        reason: path,
      );
    }
  });

  for (final automatic in [true, false]) {
    testWidgets(
      '${automatic ? 'automatic' : 'explicit'} entry rail stays hidden while touch and wheel scroll',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1024, 768);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final entryScroll = ScrollController();
        final editorScroll = ScrollController();
        final editorText = TextEditingController(text: '未提交草稿');
        addTearDown(entryScroll.dispose);
        addTearDown(editorScroll.dispose);
        addTearDown(editorText.dispose);
        final router = GoRouter(
          initialLocation: '/warehouse',
          routes: [
            DraftAwareGoRoute(
              path: '/warehouse',
              builder: (context, _) => Scaffold(
                appBar: AppBar(
                  title: const Text('仓库管理'),
                  actions: [
                    TextButton(
                      onPressed: () => context.push('/warehouse/TRANSFER/new'),
                      child: const Text('新建调拨单'),
                    ),
                  ],
                ),
                body: _viewport(entryScroll, automatic: automatic),
              ),
            ),
            DraftAwareGoRoute(
              path: '/warehouse/TRANSFER/new',
              builder: (_, _) => Scaffold(
                appBar: AppBar(title: const Text('新建单据')),
                body: UtenVerticalScrollArea(
                  controller: editorScroll,
                  pageScrollbar: true,
                  child: ListView(
                    controller: editorScroll,
                    children: [
                      TextField(controller: editorText),
                      const SizedBox(height: 12000),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
        addTearDown(router.dispose);
        await tester.pumpWidget(
          MaterialApp.router(
            routerConfig: router,
            scrollBehavior: const UtenScrollBehavior(),
            builder: (_, child) => UtenPageScrollbarHost(child: child!),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.byKey(UtenPageScrollbarHost.railKey), findsNothing);
        final initialPosition = entryScroll.position;
        await tester.drag(find.byType(ListView), const Offset(0, -500));
        await tester.pumpAndSettle();
        final touchOffset = entryScroll.offset;
        expect(touchOffset, greaterThan(0));
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(400, 300));
        await tester.sendEventToBinding(
          const PointerScrollEvent(
            position: Offset(400, 300),
            scrollDelta: Offset(0, 300),
          ),
        );
        await tester.pumpAndSettle();
        expect(entryScroll.offset, greaterThan(touchOffset));
        final retainedOffset = entryScroll.offset;
        for (final width in [1366.0, 390.0, 1280.0, 1024.0]) {
          tester.view.physicalSize = Size(width, 768);
          await tester.pumpAndSettle();
          expect(entryScroll.position, same(initialPosition));
          expect(entryScroll.offset, retainedOffset);
          expect(
            find.byKey(UtenPageScrollbarHost.railKey),
            width >= 1280 ? findsOneWidget : findsNothing,
          );
          expect(tester.takeException(), isNull);
        }
        for (var i = 0; i < 3; i++) {
          await tester.tap(find.text('新建调拨单'));
          await tester.pumpAndSettle();
          expect(find.text('新建单据'), findsOneWidget);
          final visibleBar = find.byWidgetPredicate(
            (widget) => widget is UtenContentScrollbar && widget.visible,
          );
          expect(visibleBar, findsOneWidget);
          editorScroll.jumpTo(0);
          await tester.pumpAndSettle();
          final rail = tester.getRect(visibleBar);
          expect(rail.height, greaterThan(100));
          final drag = await tester.startGesture(
            Offset(rail.right - 7, rail.top + 26),
            kind: PointerDeviceKind.mouse,
          );
          await drag.moveBy(const Offset(0, 160));
          await tester.pump();
          await drag.up();
          await tester.pumpAndSettle();
          expect(editorScroll.offset, greaterThan(0));
          expect(editorText.text, '未提交草稿');
          router.pop();
          await tester.pumpAndSettle();
          expect(find.byKey(UtenPageScrollbarHost.railKey), findsNothing);
          expect(entryScroll.offset, retainedOffset);
          expect(tester.takeException(), isNull);
        }
        await mouse.removePointer();
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('entry scope does not suppress a popup or imperative editor', (
    tester,
  ) async {
    final entryScroll = ScrollController();
    final popupScroll = ScrollController();
    final pushedScroll = ScrollController();
    addTearDown(entryScroll.dispose);
    addTearDown(popupScroll.dispose);
    addTearDown(pushedScroll.dispose);
    late BuildContext pageContext;
    await tester.pumpWidget(
      MaterialApp(
        scrollBehavior: const UtenScrollBehavior(),
        home: UtenEntryPageScrollbar(
          location: '/warehouse',
          child: Builder(
            builder: (context) {
              pageContext = context;
              return Scaffold(body: _viewport(entryScroll));
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (var i = 0; i < 3; i++) {
      final dialog = showDialog<void>(
        context: pageContext,
        builder: (_) => Dialog(
          child: SizedBox(
            width: 350,
            height: 260,
            child: _viewport(popupScroll),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final popupBar = find.descendant(
        of: find.byType(Dialog),
        matching: find.byType(UtenContentScrollbar),
      );
      expect(tester.widget<UtenContentScrollbar>(popupBar).visible, isTrue);
      expect(tester.getSize(popupBar).height, greaterThan(0));
      Navigator.of(pageContext).pop();
      await dialog;
      await tester.pumpAndSettle();
    }
    final pushed = Navigator.of(pageContext).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            Scaffold(body: _viewport(pushedScroll, automatic: true)),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenVerticalScrollbar>(find.byType(UtenVerticalScrollbar))
          .visible,
      isTrue,
    );
    Navigator.of(pageContext).pop();
    await pushed;
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'real entry table retains all rows and scroll state across rail changes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1366, 768);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final rows = List.generate(5000, (index) => '员工 $index');
      const tableKey = Key('entry-table');
      await tester.pumpWidget(
        MaterialApp(
          scrollBehavior: const UtenScrollBehavior(),
          home: UtenEntryPageScrollbar(
            location: '/employee',
            child: Scaffold(
              body: UtenPageScrollbarHost(
                child: MasterDataTableView<String>(
                  key: tableKey,
                  columns: [
                    MasterColumnDef<String>(
                      key: 'name',
                      label: '员工',
                      width: 240,
                      value: (row) => row,
                    ),
                  ],
                  items: rows,
                  facets: const {},
                  nullCounts: const {},
                  filters: const {},
                  onFilterChanged: (_, _) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final tableState = tester.state(find.byKey(tableKey));
      final list = tester.widget<ListView>(find.byType(ListView).first);
      final controller = list.controller!;
      controller.jumpTo(240);
      await tester.pumpAndSettle();
      final position = controller.position;
      for (final width in [1024.0, 1366.0, 390.0, 1024.0, 1366.0]) {
        tester.view.physicalSize = Size(width, 768);
        await tester.pumpAndSettle();
        expect(tester.state(find.byKey(tableKey)), same(tableState));
        expect(controller.position, same(position));
        expect(controller.offset, 240);
        expect(
          tester
              .widget<MasterDataTableView<String>>(find.byKey(tableKey))
              .items,
          same(rows),
        );
        expect(
          find.byKey(UtenPageScrollbarHost.railKey),
          width < 1280 ? findsNothing : findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox());
    },
  );
}

Widget _viewport(ScrollController scroll, {bool automatic = false}) {
  final view = ListView.builder(
    controller: scroll,
    itemExtent: 48,
    itemCount: 5000,
    itemBuilder: (_, index) => Text('入口 $index'),
  );
  return automatic
      ? view
      : UtenVerticalScrollArea(
          controller: scroll,
          pageScrollbar: true,
          child: view,
        );
}
