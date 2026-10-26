import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uten_imp/components/data_display/uten_table_surface.dart';
import 'package:uten_imp/components/layout/uten_app_bar.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/components/layout/uten_vertical_scroll_area.dart';
import 'package:uten_imp/components/layout/uten_vertical_scrollbar.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _action = Key('page-end-action');
const _card = Key('page-end-card');
const _editor = Key('preserved-background-editor');
Finder _rail() => find.byKey(UtenPageScrollbarHost.railKey);

Widget _table({
  Key? key,
  bool primary = false,
  int count = 40,
  String name = 'Name',
  bool manyToolbarActions = false,
}) => MasterDataTableView<String>(
  key: key,
  primary: primary,
  bottomContentPadding: 16,
  totalPages: 2,
  onPageChange: (_) {},
  toolbarLeadingActions: manyToolbarActions
      ? [
          for (var i = 0; i < 80; i++)
            TextButton(onPressed: () {}, child: Text('Tool $i')),
        ]
      : null,
  columns: [
    MasterColumnDef<String>(
      key: 'name',
      label: name,
      width: 160,
      value: (s) => s,
    ),
  ],
  items: List.generate(count, (i) => 'Row $i'),
  facets: const {},
  nullCounts: const {},
  filters: const {},
  onFilterChanged: (_, _) {},
);

Widget _app(Widget home, {double zoom = 1, double keyboard = 0}) =>
    ProviderScope(
      child: MaterialApp(
        theme: ThemeData(platform: TargetPlatform.windows),
        scrollBehavior: const UtenScrollBehavior(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(viewInsets: EdgeInsets.only(bottom: keyboard)),
          child: UtenDisplayZoomBox(
            fontFactor: zoom,
            child: UtenPageScrollbarHost(child: child!),
          ),
        ),
        home: home,
      ),
    );

Widget _page(Widget body, {VoidCallback? onOpen}) => Scaffold(
  resizeToAvoidBottomInset: false,
  appBar: UtenAppBar(
    title: 'Layout',
    actions: [
      TextButton(
        key: _action,
        onPressed: onOpen ?? () {},
        child: const Text('Action'),
      ),
    ],
  ),
  body: UtenContentContainer(selectable: false, child: body),
);

void _window(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _area(ScrollController c) => UtenVerticalScrollArea(
  controller: c,
  pageScrollbar: true,
  child: ListView(controller: c, children: const [SizedBox(height: 2500)]),
);

class _KeepTab extends StatefulWidget {
  const _KeepTab({required this.child});
  final Widget child;
  @override
  State<_KeepTab> createState() => _KeepTabState();
}

class _KeepTabState extends State<_KeepTab> with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

void main() {
  for (final size in [
    const Size(1366, 650),
    const Size(1920, 950),
    const Size(2560, 1300),
  ]) {
    for (final zoom in [1.0, 1.5, 2.0]) {
      testWidgets(
        'three page edges and all chrome are window sized at $size zoom $zoom',
        (tester) async {
          _window(tester, size);
          await tester.pumpWidget(
            _app(
              _page(
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(key: _card, height: 48),
                    Expanded(child: _table()),
                  ],
                ),
              ),
              zoom: zoom,
            ),
          );
          await tester.pumpAndSettle();
          final rail = tester.getRect(_rail());
          final end = size.width - 24;
          expect(rail.right, closeTo(size.width - 2, .001));
          expect(rail.width, closeTo(14, .001));
          expect(rail.top, 0);
          expect(rail.bottom, size.height);
          expect(tester.getRect(find.byKey(_action)).right, closeTo(end, .001));
          expect(tester.getRect(find.byKey(_card)).right, closeTo(end, .001));
          expect(
            tester.getRect(find.byType(UtenTableHeaderSurface)).right,
            closeTo(end, .001),
          );
          expect(
            tester
                .getRect(find.byKey(const ValueKey('master-table-page-next')))
                .right,
            closeTo(end, .001),
          );
          for (final scroll in find.byType(SingleChildScrollView).evaluate()) {
            final widget = scroll.widget as SingleChildScrollView;
            if (widget.scrollDirection == Axis.horizontal) {
              expect(
                tester
                    .getRect(
                      find.byElementPredicate((e) => identical(e, scroll)),
                    )
                    .right,
                closeTo(end, .001),
              );
            }
          }
          expect(rail.left - end, closeTo(8, .001));
          final thumb = find.descendant(
            of: _rail(),
            matching: find.byWidgetPredicate(
              (w) => w is CustomPaint && w.foregroundPainter != null,
            ),
          );
          final dynamic painter = tester
              .widget<CustomPaint>(thumb)
              .foregroundPainter;
          // Private painter type; verify its public scale as well as box geometry.
          // ignore: avoid_dynamic_calls
          expect((painter.unitScale as double) * zoom, closeTo(1, .001));
          final arrow = find.descendant(
            of: _rail(),
            matching: find.byKey(const ValueKey('uten-scrollbar-down')),
          );
          expect(tester.getRect(arrow).height, closeTo(16, .001));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'no overflow and Popup keep the same background width input and focus',
    (tester) async {
      _window(tester, const Size(1366, 650));
      final count = ValueNotifier(40);
      final focus = FocusNode();
      final editor = TextEditingController(text: 'stable');
      addTearDown(count.dispose);
      addTearDown(focus.dispose);
      addTearDown(editor.dispose);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => _page(
              Column(
                children: [
                  TextField(key: _editor, focusNode: focus, controller: editor),
                  Expanded(
                    child: ValueListenableBuilder<int>(
                      valueListenable: count,
                      builder: (_, n, _) => _table(count: n),
                    ),
                  ),
                ],
              ),
              onOpen: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  content: const Text('Popup'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      focus.requestFocus();
      await tester.pump();
      final state = tester.state(find.byKey(_editor));
      final rect = tester.getRect(find.byType(UtenTableHeaderSurface));
      count.value = 0;
      await tester.pumpAndSettle();
      expect(_rail(), findsNothing);
      expect(tester.getRect(find.byType(UtenTableHeaderSurface)), rect);
      count.value = 40;
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byType(UtenTableHeaderSurface)), rect);
      await tester.tap(find.byKey(_action));
      await tester.pumpAndSettle();
      expect(_rail(), findsNothing);
      expect(tester.getRect(find.byType(UtenTableHeaderSurface)), rect);
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.getRect(find.byType(UtenTableHeaderSurface)), rect);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(tester.state(find.byKey(_editor)), same(state));
      expect(editor.text, 'stable');
      expect(focus.hasFocus, isTrue);
      expect(tester.getRect(find.byType(UtenTableHeaderSurface)), rect);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retained tab domains do not let an old priority200 table outrank new priority100',
    (tester) async {
      _window(tester, const Size(1366, 650));
      final active = ValueNotifier(false);
      final b = ScrollController();
      addTearDown(active.dispose);
      addTearDown(b.dispose);
      await tester.pumpWidget(
        _app(
          _page(
            ValueListenableBuilder<bool>(
              valueListenable: active,
              builder: (_, second, _) => Stack(
                children: [
                  TickerMode(
                    enabled: !second,
                    child: Offstage(
                      offstage: second,
                      child: UtenPageLayoutDomainScope(
                        domain: 'A',
                        active: !second,
                        child: _table(),
                      ),
                    ),
                  ),
                  TickerMode(
                    enabled: second,
                    child: Offstage(
                      offstage: !second,
                      child: UtenPageLayoutDomainScope(
                        domain: 'B',
                        active: second,
                        child: _area(b),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_rail(), findsOneWidget);
      active.value = true;
      await tester.pumpAndSettle();
      expect(tester.widget<UtenContentScrollbar>(_rail()).controller, same(b));
      expect(tester.getRect(find.byType(ListView)).right, closeTo(1342, .001));
      active.value = false;
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenContentScrollbar>(_rail()).controller,
        isNot(same(b)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'genuinely independent toolbar locks local16 without covering actions or moving the page surface',
    (tester) async {
      _window(tester, const Size(1366, 650));
      final count = ValueNotifier(40);
      addTearDown(count.dispose);
      await tester.pumpWidget(
        _app(
          _page(
            ValueListenableBuilder<int>(
              valueListenable: count,
              builder: (_, n, _) => _table(count: n, manyToolbarActions: true),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final toolbar = find.byWidgetPredicate(
        (w) =>
            w is UtenVerticalScrollbar &&
            w.controller.positions.length == 1 &&
            w.controller.position.hasContentDimensions &&
            w.controller.position.maxScrollExtent >
                w.controller.position.minScrollExtent,
      );
      expect(toolbar, findsOneWidget);
      final bar = tester.widget<UtenVerticalScrollbar>(toolbar);
      expect(bar.visible, isTrue);
      final controller = bar.controller, position = bar.controller.position;
      expect(tester.getRect(find.byType(UtenTableHeaderSurface)).right, 1342);
      controller.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('Tool 79').hitTestable(), findsOneWidget);
      count.value = 0;
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenVerticalScrollbar>(toolbar).controller,
        same(controller),
      );
      expect(controller.position, same(position));
      expect(tester.getRect(find.byType(UtenTableHeaderSurface)).right, 1342);
      count.value = 40;
      await tester.pumpAndSettle();
      expect(controller.position, same(position));
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ultra-short table presentation explicitly stays local with reachable actions',
    (tester) async {
      _window(tester, const Size(1366, 650));
      const panel = Key('ultra-short-local-presentation');
      await tester.pumpWidget(
        _app(
          _page(
            Align(
              alignment: Alignment.topLeft,
              child: SizedBox(key: panel, height: 110, child: _table()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_rail(), findsNothing);
      final stage = find.byWidgetPredicate(
        (w) =>
            w is UtenVerticalScrollbar &&
            w.controller.positions.length == 1 &&
            w.controller.position.viewportDimension <= 110 &&
            w.controller.position.maxScrollExtent > 0,
      );
      expect(stage, findsOneWidget);
      final controller = tester.widget<UtenVerticalScrollbar>(stage).controller;
      expect(tester.widget<UtenVerticalScrollbar>(stage).visible, isTrue);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(UtenTableHeaderSurface)).right,
        closeTo(tester.getRect(find.byKey(panel)).right - 32, .001),
      );
      expect(find.byType(UtenContentScrollbar), findsOneWidget);
      expect(
        tester
            .widget<UtenContentScrollbar>(find.byType(UtenContentScrollbar))
            .visible,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'same-edge independent automatic panes retain their structural layout lease across height changes',
    (tester) async {
      _window(tester, const Size(1366, 650));
      final top = ScrollController(), bottom = ScrollController();
      final taller = ValueNotifier(false);
      addTearDown(top.dispose);
      addTearDown(bottom.dispose);
      addTearDown(taller.dispose);
      Widget list(ScrollController c) =>
          ListView(controller: c, children: const [SizedBox(height: 2000)]);
      await tester.pumpWidget(
        _app(
          _page(
            ValueListenableBuilder<bool>(
              valueListenable: taller,
              builder: (_, changed, _) => Column(
                children: [
                  SizedBox(height: 230, child: list(top)),
                  SizedBox(height: changed ? 250 : 200, child: list(bottom)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final topList = find.byWidgetPredicate(
        (w) => w is ListView && identical(w.controller, top),
      );
      final bottomList = find.byWidgetPredicate(
        (w) => w is ListView && identical(w.controller, bottom),
      );
      final topViewport = find.descendant(
        of: topList,
        matching: find.byType(Viewport),
      );
      final bottomViewport = find.descendant(
        of: bottomList,
        matching: find.byType(Viewport),
      );
      expect(tester.getRect(topViewport).right, 1342);
      expect(tester.getRect(bottomViewport).right, 1326);
      taller.value = true;
      await tester.pumpAndSettle();
      expect(tester.getRect(topViewport).right, 1342);
      expect(tester.getRect(bottomViewport).right, 1326);
      expect(
        tester.widget<UtenContentScrollbar>(_rail()).controller.position,
        same(top.position),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'real retained TabBarView branches isolate table200 and page100 without manual domain scopes',
    (tester) async {
      _window(tester, const Size(1366, 650));
      final b = ScrollController();
      addTearDown(b.dispose);
      late TabController tabs;
      const tableKey = Key('retained-tab-A');
      await tester.pumpWidget(
        _app(
          DefaultTabController(
            length: 2,
            child: Builder(
              builder: (context) {
                tabs = DefaultTabController.of(context);
                return _page(
                  Column(
                    children: [
                      const TabBar(
                        tabs: [
                          Tab(text: 'A'),
                          Tab(text: 'B'),
                        ],
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [
                            _KeepTab(child: _table(key: tableKey)),
                            _KeepTab(child: _area(b)),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final aState = tester.state(find.byKey(tableKey));
      tabs.index = 1;
      await tester.pumpAndSettle();
      expect(tester.widget<UtenContentScrollbar>(_rail()).controller, same(b));
      expect(
        tester
            .getRect(
              find.byWidgetPredicate(
                (w) => w is ListView && identical(w.controller, b),
              ),
            )
            .right,
        1342,
      );
      tabs.index = 0;
      await tester.pumpAndSettle();
      expect(tester.state(find.byKey(tableKey)), same(aState));
      expect(
        tester.widget<UtenContentScrollbar>(_rail()).controller,
        isNot(same(b)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'IndexedStack retained branches keep distinct layout domains and reject hidden paint',
    (tester) async {
      _window(tester, const Size(1366, 650));
      final active = ValueNotifier(0);
      final b = ScrollController();
      addTearDown(active.dispose);
      addTearDown(b.dispose);
      await tester.pumpWidget(
        _app(
          _page(
            ValueListenableBuilder<int>(
              valueListenable: active,
              builder: (_, index, _) =>
                  IndexedStack(index: index, children: [_table(), _area(b)]),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_rail(), findsOneWidget);
      active.value = 1;
      await tester.pumpAndSettle();
      expect(tester.widget<UtenContentScrollbar>(_rail()).controller, same(b));
      expect(
        tester
            .getRect(
              find.byWidgetPredicate(
                (w) => w is ListView && identical(w.controller, b),
              ),
            )
            .right,
        1342,
      );
      active.value = 0;
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenContentScrollbar>(_rail()).controller,
        isNot(same(b)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'PageRoute domains keep cached priority200 separate from new priority100',
    (tester) async {
      _window(tester, const Size(1366, 650));
      final b = ScrollController();
      addTearDown(b.dispose);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => _page(
              _table(),
              onOpen: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => _page(_area(b))),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(_action));
      await tester.pumpAndSettle();
      expect(tester.widget<UtenContentScrollbar>(_rail()).controller, same(b));
      expect(tester.getRect(find.byType(ListView)).right, closeTo(1342, .001));
      Navigator.of(tester.element(find.byType(ListView))).pop();
      await tester.pumpAndSettle();
      expect(
        tester.widget<UtenContentScrollbar>(_rail()).controller,
        isNot(same(b)),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'two main panes sharing a primary controller retain left16 and right0 by unique token',
    (tester) async {
      _window(tester, const Size(1366, 650));
      final shared = ScrollController();
      addTearDown(shared.dispose);
      const left = Key('left-main-table'), right = Key('right-main-table');
      await tester.pumpWidget(
        _app(
          _page(
            PrimaryScrollController(
              controller: shared,
              child: Row(
                children: [
                  Expanded(
                    child: _table(key: left, primary: true, name: 'Left'),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _table(key: right, primary: true, name: 'Right'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(shared.positions, hasLength(2));
      expect(_rail(), findsOneWidget);
      final headers = find.byType(UtenTableHeaderSurface);
      expect(
        tester.getRect(headers.first).right,
        closeTo(tester.getRect(find.byKey(left)).right - 16, .001),
      );
      expect(tester.getRect(headers.last).right, closeTo(1342, .001));
      final local = find.descendant(
        of: find.byKey(left),
        matching: find.byWidgetPredicate((w) => w is UtenContentScrollbar),
      );
      expect(tester.widget<UtenContentScrollbar>(local).visible, isTrue);
      final body = find.descendant(
        of: find.byKey(right),
        matching: find.byType(ListView),
      );
      expect(
        tester.widget<ListView>(body).controller!.position,
        same(tester.widget<UtenContentScrollbar>(_rail()).controller.position),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'soft keyboard limits full-height paint without changing page end layout',
    (tester) async {
      _window(tester, const Size(390, 844));
      final c = ScrollController();
      addTearDown(c.dispose);
      await tester.pumpWidget(_app(_page(_area(c)), keyboard: 280));
      await tester.pumpAndSettle();
      expect(tester.getRect(_rail()).bottom, 564);
      expect(tester.getRect(find.byType(ListView)).right, 366);
      expect(tester.getRect(_rail()).left - 366, 8);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local edge padding retains original inset and supports intrinsic unbounded content',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: UtenPageScrollRoleScope.local(
              child: IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: UtenPageEdgePadding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                        child: SizedBox(key: _card, height: 40),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(_card)).left, 16);
      expect(tester.getRect(find.byKey(_card)).right, 784);
      expect(tester.takeException(), isNull);
    },
  );
}
