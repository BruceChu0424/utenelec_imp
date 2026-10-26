import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/components/layout/uten_vertical_scroll_area.dart';
import 'package:uten_imp/components/layout/uten_vertical_scrollbar.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _hostKey = Key('page-host');

Widget _app(Widget child) => MaterialApp(
  scrollBehavior: const UtenScrollBehavior(),
  theme: ThemeData(platform: TargetPlatform.windows),
  home: Scaffold(
    body: UtenPageScrollbarHost(key: _hostKey, child: child),
  ),
);

Widget _area(
  ScrollController controller, {
  bool page = true,
  int priority = UtenPageScrollbarPriority.page,
  double contentHeight = 1800,
  Key? contentKey,
}) => UtenVerticalScrollArea(
  controller: controller,
  pageScrollbar: page,
  pageScrollbarPriority: priority,
  child: ListView(
    controller: controller,
    children: [SizedBox(key: contentKey, height: contentHeight)],
  ),
);

Finder _rail() => find.byKey(UtenPageScrollbarHost.railKey);

UtenContentScrollbar _localBar(
  WidgetTester tester,
  ScrollController controller,
) => tester.widget<UtenContentScrollbar>(
  find.byWidgetPredicate(
    (widget) =>
        widget is UtenContentScrollbar &&
        widget.key != UtenPageScrollbarHost.railKey &&
        identical(widget.controller, controller),
  ),
);

void _expectOuterRail(WidgetTester tester) {
  final host = tester.getRect(find.byKey(_hostKey));
  final rail = tester.getRect(_rail());
  expect(rail.right, closeTo(host.right - 2, .01));
}

void main() {
  testWidgets(
    'a retained source moves between overlapping hosts without stale ownership',
    (tester) async {
      final controller = ScrollController();
      final moved = ValueNotifier(false);
      final sourceKey = GlobalKey();
      final focus = FocusNode();
      final editor = TextEditingController(text: 'retained source input');
      const firstHost = Key('source-origin-host');
      const secondHost = Key('source-destination-host');
      addTearDown(controller.dispose);
      addTearDown(moved.dispose);
      addTearDown(focus.dispose);
      addTearDown(editor.dispose);
      final source = UtenVerticalScrollArea(
        key: sourceKey,
        controller: controller,
        pageScrollbar: true,
        child: ListView(
          controller: controller,
          children: [
            const SizedBox(height: 160),
            TextField(controller: editor, focusNode: focus),
            const SizedBox(height: 1800),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.windows),
          scrollBehavior: const UtenScrollBehavior(),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: moved,
              builder: (context, destination, _) => Stack(
                fit: StackFit.expand,
                children: [
                  UtenPageScrollbarHost(
                    key: firstHost,
                    child: destination ? const SizedBox.expand() : source,
                  ),
                  UtenPageScrollbarHost(
                    key: secondHost,
                    child: destination ? source : const SizedBox.expand(),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final sourceElement = tester.element(find.byKey(sourceKey));
      final scrollable = find
          .descendant(
            of: find.byKey(sourceKey),
            matching: find.byType(Scrollable),
          )
          .first;
      final scrollableState = tester.state<ScrollableState>(scrollable);
      final editorState = tester.state(find.byType(TextField));
      final originalMin = controller.position.minScrollExtent;
      final originalMax = controller.position.maxScrollExtent;
      focus.requestFocus();
      await tester.pumpAndSettle();
      controller.jumpTo(140);
      for (final destination in [true, false, true]) {
        final previousPosition = controller.position;
        moved.value = destination;
        // The stale origin and live destination occupy identical coordinates.
        // Geometry therefore cannot hide an old owner's registration race.
        await tester.pump();
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        expect(_rail(), findsOneWidget);
        expect(
          tester
              .element(_rail())
              .findAncestorWidgetOfExactType<UtenPageScrollbarHost>()!
              .key,
          destination ? secondHost : firstHost,
        );
        expect(tester.element(find.byKey(sourceKey)), same(sourceElement));
        expect(
          tester.state<ScrollableState>(scrollable),
          same(scrollableState),
        );
        expect(tester.state(find.byType(TextField)), same(editorState));
        // SDK Scrollable.didChangeDependencies recreates its position with
        // oldPosition absorption during a real reparent (scrollable.dart617-636,
        // 669-674). The public controller, State, active range and offset must
        // survive; identity is asserted separately for same-tree paint toggles.
        expect(
          tester.widget<ListView>(find.byType(ListView)).controller,
          same(controller),
        );
        expect(controller.positions, hasLength(1));
        expect(scrollableState.position, same(controller.position));
        expect(controller.position.minScrollExtent, originalMin);
        expect(controller.position.maxScrollExtent, originalMax);
        if (!identical(previousPosition, controller.position)) {
          expect(controller.positions, isNot(contains(previousPosition)));
        }
        expect(controller.offset, 140);
        expect(focus.hasFocus, isTrue);
        expect(editor.text, 'retained source input');
        expect(tester.takeException(), isNull);
      }
    },
  );

  testWidgets('main viewport rail moves past the preserved page margin', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 70, 24, 18),
          child: _area(controller, contentKey: const Key('page-content')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    _expectOuterRail(tester);
    expect(tester.getTopLeft(find.byKey(const Key('page-content'))).dx, 24);
    expect(tester.getRect(_rail()).top, 0);
    expect(tester.getRect(_rail()).height, 600);
    expect(_localBar(tester, controller).visible, isFalse);
    expect(
      tester.widget<UtenContentScrollbar>(_rail()).controller,
      same(controller),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'automatic viewport transfers only its paint and keeps the same position',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          Padding(
            padding: const EdgeInsets.all(24),
            child: ListView(
              controller: controller,
              children: const [SizedBox(height: 1800)],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectOuterRail(tester);
      final hosted = tester.widget<UtenContentScrollbar>(_rail());
      expect(hosted.controller.position, same(controller.position));
      expect(
        tester
            .widget<UtenVerticalScrollbar>(find.byType(UtenVerticalScrollbar))
            .visible,
        isFalse,
      );
      controller.jumpTo(120);
      await tester.pumpAndSettle();
      expect(controller.offset, 120);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'two main panes keep the left rail local and host the right pane only',
    (tester) async {
      final left = ScrollController(), right = ScrollController();
      addTearDown(left.dispose);
      addTearDown(right.dispose);
      await tester.pumpWidget(
        _app(
          Padding(
            padding: const EdgeInsets.all(24),
            child: Row(
              children: [
                Expanded(child: _area(left)),
                const SizedBox(width: 20),
                Expanded(child: _area(right)),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectOuterRail(tester);
      expect(
        tester.widget<UtenContentScrollbar>(_rail()).controller,
        same(right),
      );
      expect(_localBar(tester, left).visible, isTrue);
      expect(_localBar(tester, right).visible, isFalse);
      expect(left.offset, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a page table outranks its outer automatic viewport', (
    tester,
  ) async {
    final outer = ScrollController(), table = ScrollController();
    addTearDown(outer.dispose);
    addTearDown(table.dispose);
    await tester.pumpWidget(
      _app(
        Padding(
          padding: const EdgeInsets.all(24),
          child: SingleChildScrollView(
            controller: outer,
            child: Column(
              children: [
                const SizedBox(height: 35),
                SizedBox(
                  height: 340,
                  child: _area(
                    table,
                    priority: UtenPageScrollbarPriority.table,
                  ),
                ),
                const SizedBox(height: 1200),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<UtenContentScrollbar>(_rail()).controller,
      same(table),
    );
    expect(_localBar(tester, table).visible, isFalse);
    expect(
      tester
          .widget<UtenVerticalScrollbar>(find.byType(UtenVerticalScrollbar))
          .visible,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('hierarchy or opted-out embedded areas keep local rails', (
    tester,
  ) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        Padding(
          padding: const EdgeInsets.all(24),
          child: _area(controller, page: false),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_rail(), findsNothing);
    expect(_localBar(tester, controller).visible, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'no overflow hides the global rail and content growth does not remount editors',
    (tester) async {
      final controller = ScrollController(),
          text = TextEditingController(text: 'kept input');
      final height = ValueNotifier(100.0);
      var mounts = 0;
      addTearDown(controller.dispose);
      addTearDown(text.dispose);
      addTearDown(height.dispose);
      await tester.pumpWidget(
        _app(
          Padding(
            padding: const EdgeInsets.all(24),
            child: ValueListenableBuilder<double>(
              valueListenable: height,
              child: _EditorProbe(controller: text, onMount: () => mounts++),
              builder: (_, value, child) => SingleChildScrollView(
                controller: controller,
                child: SizedBox(height: value, child: child),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_rail(), findsNothing);
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'kept typed input');
      final focus = tester
          .widget<EditableText>(find.byType(EditableText))
          .focusNode;
      final editorState = tester.state(find.byType(TextField));
      height.value = 1800;
      await tester.pumpAndSettle();
      _expectOuterRail(tester);
      expect(tester.state(find.byType(TextField)), same(editorState));
      expect(mounts, 1);
      expect(text.text, 'kept typed input');
      expect(focus.hasFocus, isTrue);
      height.value = 100;
      await tester.pumpAndSettle();
      expect(_rail(), findsNothing);
      expect(mounts, 1);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'TickerMode suspends hosting without detaching the preserved viewport',
    (tester) async {
      final controller = ScrollController();
      final active = ValueNotifier(true);
      addTearDown(controller.dispose);
      addTearDown(active.dispose);
      await tester.pumpWidget(
        _app(
          Padding(
            padding: const EdgeInsets.all(24),
            child: ValueListenableBuilder<bool>(
              valueListenable: active,
              child: _area(controller),
              builder: (_, enabled, child) =>
                  TickerMode(enabled: enabled, child: child!),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(125);
      await tester.pumpAndSettle();
      final position = controller.position;
      active.value = false;
      await tester.pumpAndSettle();
      expect(_rail(), findsNothing);
      expect(controller.position, same(position));
      expect(controller.offset, 125);
      active.value = true;
      await tester.pumpAndSettle();
      _expectOuterRail(tester);
      expect(controller.offset, 125);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Offstage alone suspends hosting and a retained source can return',
    (tester) async {
      final controller = ScrollController();
      final hidden = ValueNotifier(false);
      addTearDown(controller.dispose);
      addTearDown(hidden.dispose);
      await tester.pumpWidget(
        _app(
          ValueListenableBuilder<bool>(
            valueListenable: hidden,
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: _area(controller),
            ),
            builder: (_, offstage, child) =>
                Offstage(offstage: offstage, child: child),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectOuterRail(tester);
      controller.jumpTo(90);
      final position = controller.position;
      hidden.value = true;
      await tester.pumpAndSettle();
      expect(_rail(), findsNothing);
      expect(controller.position, same(position));
      hidden.value = false;
      await tester.pumpAndSettle();
      _expectOuterRail(tester);
      expect(controller.offset, 90);
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'popup keeps its own rail and suspends the underlying page rail',
    (tester) async {
      final page = ScrollController(), popup = ScrollController();
      addTearDown(page.dispose);
      addTearDown(popup.dispose);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Popup'),
                      content: SizedBox(
                        width: 360,
                        height: 300,
                        child: _area(popup),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Close popup'),
                        ),
                      ],
                    ),
                  ),
                  child: const Text('Open popup'),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _area(page),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectOuterRail(tester);
      page.jumpTo(100);
      await tester.tap(find.text('Open popup'));
      await tester.pumpAndSettle();
      expect(_rail(), findsNothing);
      expect(_localBar(tester, popup).visible, isTrue);
      await tester.tap(find.text('Close popup'));
      await tester.pumpAndSettle();
      _expectOuterRail(tester);
      expect(page.offset, 100);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'a pushed page suspends the old host and pop restores the same scroll position',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute(
                      builder: (context) => Scaffold(
                        body: TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('Back to original page'),
                        ),
                      ),
                    ),
                  ),
                  child: const Text('Open another page'),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _area(controller),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      controller.jumpTo(150);
      final position = controller.position;
      await tester.tap(find.text('Open another page'));
      await tester.pumpAndSettle();
      expect(_rail(), findsNothing);
      expect(controller.position, same(position));
      await tester.tap(find.text('Back to original page'));
      await tester.pumpAndSettle();
      _expectOuterRail(tester);
      expect(controller.position, same(position));
      expect(controller.offset, 150);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Drawer blocks the outer rail throughout its close animation', (
    tester,
  ) async {
    final page = ScrollController(), drawer = ScrollController();
    final scaffoldKey = GlobalKey<ScaffoldState>();
    addTearDown(page.dispose);
    addTearDown(drawer.dispose);
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (hostContext) => Scaffold(
            key: scaffoldKey,
            onDrawerChanged: (_) =>
                UtenPageScrollbarHost.invalidate(hostContext),
            drawer: Drawer(
              child: UtenPageScrollbarModalBlocker(
                child: SafeArea(
                  child: Column(
                    children: [
                      TextButton(
                        onPressed: () =>
                            scaffoldKey.currentState!.closeDrawer(),
                        child: const Text('Close drawer'),
                      ),
                      Expanded(child: _area(drawer)),
                    ],
                  ),
                ),
              ),
            ),
            body: Column(
              children: [
                TextButton(
                  onPressed: () => scaffoldKey.currentState!.openDrawer(),
                  child: const Text('Open drawer'),
                ),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: _area(page),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    _expectOuterRail(tester);
    page.jumpTo(110);
    await tester.tap(find.text('Open drawer'));
    await tester.pump();
    expect(_rail().hitTestable(), findsNothing);
    await tester.pumpAndSettle();
    expect(_rail(), findsNothing);
    expect(_localBar(tester, drawer).visible, isTrue);
    await tester.tap(find.text('Close drawer'));
    await tester.pump();
    expect(scaffoldKey.currentState!.isDrawerOpen, isFalse);
    expect(_rail(), findsNothing);
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      _rail(),
      findsNothing,
      reason: 'The closing scrim still owns the whole surface',
    );
    await tester.pumpAndSettle();
    _expectOuterRail(tester);
    expect(page.offset, 110);
    expect(tester.takeException(), isNull);
  });

  testWidgets('short windows use a proportional primary-viewport threshold', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(800, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      _app(
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 35, 24, 35),
          child: _area(controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    _expectOuterRail(tester);
    expect(tester.getRect(_rail()).height, 180);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real nonembedded master table registers its body at the shell edge',
    (tester) async {
      await tester.pumpWidget(
        _app(
          Padding(
            padding: const EdgeInsets.all(24),
            child: MasterDataTableView<String>(
              columns: [
                MasterColumnDef<String>(
                  key: 'name',
                  label: 'Name',
                  width: 240,
                  value: (row) => row,
                ),
              ],
              items: List.generate(80, (i) => 'Row $i'),
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      _expectOuterRail(tester);
      final list = tester.widget<ListView>(find.byType(ListView).first);
      expect(
        tester.widget<UtenContentScrollbar>(_rail()).controller,
        same(list.controller),
      );
      expect(_localBar(tester, list.controller!).visible, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}

class _EditorProbe extends StatefulWidget {
  const _EditorProbe({required this.controller, required this.onMount});
  final TextEditingController controller;
  final VoidCallback onMount;
  @override
  State<_EditorProbe> createState() => _EditorProbeState();
}

class _EditorProbeState extends State<_EditorProbe> {
  @override
  void initState() {
    super.initState();
    widget.onMount();
  }

  @override
  Widget build(BuildContext context) =>
      Column(children: [TextField(controller: widget.controller)]);
}
