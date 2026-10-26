import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/data_display/uten_table_surface.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:uten_imp/components/layout/uten_vertical_scroll_area.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _globalHostKey = Key('global-navigator-scrollbar-host');
const _shellHostKey = Key('nearest-shell-scrollbar-host');
const _contentKey = Key('independent-page-content');

Finder _rail() => find.byKey(UtenPageScrollbarHost.railKey);

Widget _globalApp({
  required Widget home,
  double zoom = 1,
  Map<String, WidgetBuilder>? routes,
}) => MaterialApp(
  scrollBehavior: const UtenScrollBehavior(),
  theme: ThemeData(platform: TargetPlatform.windows),
  builder: (_, child) => UtenDisplayZoomBox(
    fontFactor: zoom,
    child: UtenPageScrollbarHost(key: _globalHostKey, child: child!),
  ),
  home: home,
  routes: routes ?? const {},
);

void _setWindow(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _table() => MasterDataTableView<String>(
  columns: [
    MasterColumnDef<String>(
      key: 'name',
      label: 'Name',
      width: 240,
      value: (row) => row,
    ),
  ],
  items: List.generate(100, (i) => 'Row $i'),
  facets: const {},
  nullCounts: const {},
  filters: const {},
  onFilterChanged: (_, _) {},
);

class _Controllers {
  final page = ScrollController();
  final raw = ScrollController();
  final shell = ScrollController();
  final popup = ScrollController();
  void dispose() {
    page.dispose();
    raw.dispose();
    shell.dispose();
    popup.dispose();
  }
}

Widget _longList(ScrollController controller, {Key? contentKey}) => ListView(
  controller: controller,
  children: [SizedBox(key: contentKey, height: 3000)],
);

Widget _localArea(ScrollController controller) => UtenVerticalScrollArea(
  pageScrollbar: true,
  controller: controller,
  child: _longList(controller),
);

class _IndependentPage extends StatelessWidget {
  const _IndependentPage({required this.controllers, this.mode = 'container'});
  final _Controllers controllers;
  final String mode;

  @override
  Widget build(BuildContext context) {
    final controller = mode == 'container' ? controllers.page : controllers.raw;
    final list = _longList(controller, contentKey: _contentKey);
    final body = mode == 'container'
        ? UtenContentContainer.wide(selectable: false, child: list)
        : UtenPageEdgePadding(
            padding: EdgeInsets.all(mode == 'raw-zero' ? 0 : 24),
            child: list,
          );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Independent page'),
        actions: [
          IconButton(
            tooltip: 'Open raw page',
            onPressed: () => Navigator.pushNamed(context, '/raw'),
            icon: const Icon(Icons.open_in_new),
          ),
          IconButton(
            tooltip: 'Open shell page',
            onPressed: () => Navigator.pushNamed(context, '/shell'),
            icon: const Icon(Icons.dashboard_customize),
          ),
          IconButton(
            tooltip: 'Open independent modal',
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Modal independent viewport'),
                content: SizedBox(
                  width: 360,
                  height: 300,
                  child: _localArea(controllers.popup),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Close independent modal'),
                  ),
                ],
              ),
            ),
            icon: const Icon(Icons.view_sidebar_outlined),
          ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}

Widget _navigatorApp(
  _Controllers controllers, {
  String mode = 'container',
  double zoom = 1,
}) => _globalApp(
  zoom: zoom,
  home: _IndependentPage(controllers: controllers, mode: mode),
  routes: {
    '/raw': (_) =>
        _IndependentPage(controllers: controllers, mode: 'raw-padding'),
    '/shell': (context) => Scaffold(
      appBar: AppBar(title: const Text('Shell-scoped page')),
      body: Row(
        children: [
          const SizedBox(width: 80),
          Expanded(
            child: UtenPageScrollbarHost(
              key: _shellHostKey,
              child: UtenPageEdgePadding(
                padding: const EdgeInsets.all(24),
                child: _localArea(controllers.shell),
              ),
            ),
          ),
        ],
      ),
    ),
  },
);

void main() {
  for (final size in [
    const Size(1366, 768),
    const Size(1920, 1080),
    const Size(2560, 1440),
  ]) {
    for (final zoom in [1.0, 1.5, 2.0]) {
      testWidgets(
        'full-height rail respects system safe area at $size zoom $zoom',
        (tester) async {
          _setWindow(tester, size);
          final controller = ScrollController();
          addTearDown(controller.dispose);
          await tester.pumpWidget(
            MaterialApp(
              theme: ThemeData(platform: TargetPlatform.windows),
              scrollBehavior: const UtenScrollBehavior(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(padding: const EdgeInsets.fromLTRB(0, 18, 4, 24)),
                child: UtenDisplayZoomBox(
                  fontFactor: zoom,
                  child: UtenPageScrollbarHost(child: child!),
                ),
              ),
              home: Scaffold(
                body: SafeArea(
                  child: UtenPageEdgePadding(
                    padding: const EdgeInsets.fromLTRB(24, 130, 24, 70),
                    child: _localArea(controller),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final rail = tester.getRect(_rail());
          expect(rail.top, closeTo(18, .01));
          expect(rail.bottom, closeTo(size.height - 24, .01));
          expect(rail.right, closeTo(size.width - 4 - 2, .01));
          expect(rail.width, closeTo(14, .01));
          controller.jumpTo(100);
          tester.view.physicalSize = Size(size.width - 100, size.height - 50);
          await tester.pumpAndSettle();
          final resized = tester.getRect(_rail());
          expect(resized.top, closeTo(18, .01));
          expect(resized.bottom, closeTo(size.height - 50 - 24, .01));
          expect(resized.right, closeTo(size.width - 100 - 4 - 2, .01));
          expect(controller.offset, 100);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final size in [
    const Size(1366, 768),
    const Size(1920, 1080),
    const Size(2560, 1440),
  ]) {
    for (final extended in [false, true]) {
      testWidgets(
        'master rail stays at window right2 at $size with rail extended=$extended',
        (tester) async {
          _setWindow(tester, size);
          await tester.pumpWidget(
            _globalApp(
              home: Scaffold(
                body: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    NavigationRail(
                      extended: extended,
                      minExtendedWidth: 216,
                      selectedIndex: 0,
                      onDestinationSelected: (_) {},
                      destinations: const [
                        NavigationRailDestination(
                          icon: Icon(Icons.dashboard),
                          label: Text('Workbench'),
                        ),
                        NavigationRailDestination(
                          icon: Icon(Icons.settings),
                          label: Text('Settings'),
                        ),
                      ],
                    ),
                    Expanded(
                      child: UtenPageScrollbarHost(
                        key: _shellHostKey,
                        child: UtenContentContainer(
                          selectable: false,
                          child: Padding(
                            padding: const EdgeInsets.only(top: 70, bottom: 18),
                            child: _table(),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(
            _rail(),
            findsOneWidget,
            reason:
                'The global fallback must not duplicate the nearest shell host',
          );
          final host = tester.getRect(find.byKey(_shellHostKey));
          final nav = tester.getRect(find.byType(NavigationRail));
          final rail = tester.getRect(_rail());
          final header = tester.getRect(find.byType(UtenTableHeaderSurface));
          expect(host.left, closeTo(nav.right, .01));
          expect(rail.right, closeTo(size.width - 2, .01));
          expect(rail.top, host.top);
          expect(rail.bottom, host.bottom);
          expect(rail.width, 14);
          expect(
            header.left,
            closeTo(
              host.left + UtenContentContainer.gutterForWidth(host.width),
              .01,
            ),
          );
          expect(header.right, lessThanOrEqualTo(rail.left));
          expect(
            tester
                .element(_rail())
                .findAncestorWidgetOfExactType<UtenPageScrollbarHost>()!
                .key,
            _shellHostKey,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final tableHeight in [208.0, 248.0]) {
    testWidgets(
      'explicit main table keeps its rail outside a short body at height $tableHeight',
      (tester) async {
        _setWindow(tester, const Size(1366, 768));
        await tester.pumpWidget(
          _globalApp(
            home: Scaffold(
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Align(
                  alignment: Alignment.bottomRight,
                  child: SizedBox(height: tableHeight, child: _table()),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final list = tester.widget<ListView>(find.byType(ListView).first);
        final body = tester.getRect(find.byType(ListView).first);
        expect(body.height, inInclusiveRange(96, 180));
        expect(
          _rail(),
          findsOneWidget,
          reason:
              'An explicit main table is not an automatic small-panel candidate',
        );
        expect(
          tester.widget<UtenContentScrollbar>(_rail()).controller,
          same(list.controller),
        );
        expect(tester.getRect(_rail()).right, closeTo(1364, .01));
        expect(tester.getRect(_rail()).top, 0);
        expect(tester.getRect(_rail()).bottom, 768);
        expect(
          tester.getRect(find.byType(UtenTableHeaderSurface)).right,
          lessThanOrEqualTo(tester.getRect(_rail()).left),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final mode in ['container', 'raw-padding']) {
    testWidgets('global Navigator host owns a standalone $mode Scaffold', (
      tester,
    ) async {
      _setWindow(tester, const Size(1366, 768));
      final controllers = _Controllers();
      addTearDown(controllers.dispose);
      await tester.pumpWidget(_navigatorApp(controllers, mode: mode));
      await tester.pumpAndSettle();
      expect(_rail(), findsOneWidget);
      final rail = tester.getRect(_rail());
      expect(rail.right, closeTo(1364, .01));
      expect(
        tester
            .element(_rail())
            .findAncestorWidgetOfExactType<UtenPageScrollbarHost>()!
            .key,
        _globalHostKey,
      );
      final controller = mode == 'container'
          ? controllers.page
          : controllers.raw;
      expect(
        tester.widget<UtenContentScrollbar>(_rail()).controller.position,
        same(controller.position),
      );
      expect(
        tester.getRect(find.byKey(_contentKey)).right,
        lessThanOrEqualTo(rail.left),
      );
      expect(tester.takeException(), isNull);
    });
  }

  for (final zoom in [1.0, 2.0]) {
    testWidgets(
      'raw zero-padding page entry owns one page24 end inset at zoom $zoom',
      (tester) async {
        _setWindow(tester, const Size(1366, 768));
        final controllers = _Controllers();
        addTearDown(controllers.dispose);
        await tester.pumpWidget(
          _navigatorApp(controllers, mode: 'raw-zero', zoom: zoom),
        );
        await tester.pumpAndSettle();
        final rail = tester.getRect(_rail());
        final content = tester.getRect(find.byKey(_contentKey));
        expect(rail.right, closeTo(1366 - 2, .01));
        expect(rail.width, closeTo(14, .01));
        expect(rail.top, 0);
        expect(rail.bottom, 768);
        expect(content.left, 0);
        expect(content.right, closeTo(1366 - 24, .01));
        expect(rail.left - content.right, closeTo(8, .01));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'global host above Navigator still excludes PopupRoute scrollbars',
    (tester) async {
      _setWindow(tester, const Size(1366, 768));
      final controllers = _Controllers();
      addTearDown(controllers.dispose);
      await tester.pumpWidget(_navigatorApp(controllers));
      await tester.pumpAndSettle();
      controllers.page.jumpTo(90);
      await tester.tap(find.byTooltip('Open independent modal'));
      await tester.pumpAndSettle();
      expect(_rail(), findsNothing);
      final local = tester.widget<UtenContentScrollbar>(
        find.byWidgetPredicate(
          (widget) =>
              widget is UtenContentScrollbar &&
              identical(widget.controller, controllers.popup),
        ),
      );
      expect(local.visible, isTrue);
      await tester.tap(find.text('Close independent modal'));
      await tester.pumpAndSettle();
      expect(_rail(), findsOneWidget);
      expect(controllers.page.offset, 90);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'global fallback and nearest shell host switch without duplicates or lost offsets',
    (tester) async {
      _setWindow(tester, const Size(1366, 768));
      final controllers = _Controllers();
      addTearDown(controllers.dispose);
      await tester.pumpWidget(_navigatorApp(controllers));
      await tester.pumpAndSettle();
      controllers.page.jumpTo(75);
      await tester.tap(find.byTooltip('Open raw page'));
      await tester.pumpAndSettle();
      expect(_rail(), findsOneWidget);
      expect(
        tester.widget<UtenContentScrollbar>(_rail()).controller.position,
        same(controllers.raw.position),
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(controllers.page.offset, 75);
      await tester.tap(find.byTooltip('Open shell page'));
      await tester.pumpAndSettle();
      expect(_rail(), findsOneWidget);
      expect(
        tester
            .element(_rail())
            .findAncestorWidgetOfExactType<UtenPageScrollbarHost>()!
            .key,
        _shellHostKey,
      );
      expect(
        tester.widget<UtenContentScrollbar>(_rail()).controller,
        same(controllers.shell),
      );
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(_rail(), findsOneWidget);
      expect(controllers.page.offset, 75);
      expect(
        tester
            .element(_rail())
            .findAncestorWidgetOfExactType<UtenPageScrollbarHost>()!
            .key,
        _globalHostKey,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
