import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/responsive/display_zoom.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/theme/uten_tokens.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

void main() {
  for (final (factor, textScale) in [(0.85, 1.0), (2.0, 2.0)]) {
    testWidgets(
      'pager keeps complete hit targets, counter and exact page factor=$factor',
      (tester) async {
        _view(tester, const Size(320, 900));
        final calls = <int>[];
        var loads = 0;
        var page = 1;
        await tester.pumpWidget(
          _app(
            factor: factor,
            textScale: textScale,
            platform: TargetPlatform.android,
            child: StatefulBuilder(
              builder: (context, setState) => Scaffold(
                body: SizedBox(
                  width: 160,
                  height: 100,
                  child: MasterDataTableView<String>(
                    columns: [
                      MasterColumnDef<String>(
                        key: 'name',
                        label: '名称',
                        width: 80,
                        value: (row) => row,
                      ),
                    ],
                    items: const ['真实行'],
                    facets: const {},
                    filters: const {},
                    nullCounts: const {},
                    onFilterChanged: (_, _) {},
                    totalPages: 1000000,
                    currentPage: page,
                    onLoadMore: () => loads++,
                    onPageChange: (value) async {
                      calls.add(value);
                      setState(() => page = value);
                    },
                    showFullscreenToggle: false,
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final initialLoads = loads;
        expect(find.text('1 / 1000000'), findsOneWidget);
        final next = find.byKey(const ValueKey('master-table-page-next'));
        final scroll = Scrollable.of(tester.element(next), axis: Axis.vertical);
        await tester.scrollUntilVisible(
          next,
          80,
          scrollable: find.byElementPredicate(
            (element) =>
                element is StatefulElement && identical(element.state, scroll),
          ),
        );
        await tester.pumpAndSettle();
        for (final key in [
          'master-table-page-previous',
          'master-table-page-next',
        ]) {
          final rect = tester.getRect(find.byKey(ValueKey(key)));
          expect(rect.width, greaterThanOrEqualTo(47.9));
          expect(rect.height, greaterThanOrEqualTo(47.9));
        }
        expect(
          loads,
          initialLoads,
          reason: 'scrolling the presentation is not a business page request',
        );
        await tester.tap(next.hitTestable());
        await tester.pumpAndSettle();
        expect(calls, [2]);
        expect(find.text('2 / 1000000'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'column minimum follows context after resize and keeps desktop 48 contract',
    (tester) async {
      _view(tester, const Size(900, 900));
      final tableKey = GlobalKey();
      var actions = 0;
      Widget page(TargetPlatform platform, double factor) => _app(
        factor: factor,
        platform: platform,
        child: Scaffold(
          body: SizedBox(
            width: 500,
            height: 400,
            child: MasterDataTableView<String>(
              key: tableKey,
              columns: [
                MasterColumnDef<String>(
                  key: 'handle',
                  label: '办理',
                  width: 110,
                  value: (_) => '',
                  minimumWidthOf: (context) =>
                      UtenControlMetrics.usesTouchTargets(context)
                      ? UtenControlMetrics.minimumHitExtent(
                              context,
                              desktop: 32,
                            ) +
                            25
                      : 48,
                  cellHorizontalPaddingOf: (context) =>
                      UtenControlMetrics.usesTouchTargets(context) ? 12 : 7,
                  cellBuilder: (context, _) {
                    final extent = UtenControlMetrics.minimumHitExtent(
                      context,
                      desktop: 32,
                    );
                    return SizedBox.square(
                      dimension: extent,
                      child: IconButton(
                        key: const ValueKey('original-column-action'),
                        padding: EdgeInsets.zero,
                        constraints: BoxConstraints.tightFor(
                          width: extent,
                          height: extent,
                        ),
                        onPressed: () => actions++,
                        icon: const Icon(Icons.undo),
                      ),
                    );
                  },
                  cellBuilderHandlesSemantics: true,
                ),
              ],
              items: const ['row-1'],
              facets: const {},
              filters: const {},
              nullCounts: const {},
              onFilterChanged: (_, _) {},
              showFullscreenToggle: false,
            ),
          ),
        ),
      );
      await tester.pumpWidget(page(TargetPlatform.windows, 1));
      await tester.pumpAndSettle();
      final state = tableKey.currentState;
      final header = _header(tester);
      final grip = find.descendant(
        of: header,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is GestureDetector &&
              widget.onHorizontalDragUpdate != null &&
              widget.onHorizontalDragStart == null &&
              widget.behavior == HitTestBehavior.opaque,
        ),
      );
      // The grip straddles the column border. Its visible inner half belongs to
      // this cell; starting outside that half hits the neighbouring cell.
      final start = tester.getCenter(grip) - const Offset(2, 0);
      final gripRender = tester.renderObject(grip);
      expect(
        tester
            .hitTestOnBinding(start)
            .path
            .any((entry) => identical(entry.target, gripRender)),
        isTrue,
      );
      await tester.dragFrom(start, const Offset(-500, 0));
      await tester.pumpAndSettle();
      expect(_width(tester), 48);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('original-column-action')))
            .width,
        greaterThanOrEqualTo(32),
      );
      await tester.tap(find.byKey(const ValueKey('original-column-action')));
      expect(actions, 1);
      await tester.pumpWidget(page(TargetPlatform.android, 0.85));
      await tester.pumpAndSettle();
      expect(tableKey.currentState, same(state));
      expect(_width(tester), greaterThanOrEqualTo(48 / 0.85 + 25));
      final rect = tester.getRect(
        find.byKey(const ValueKey('original-column-action')),
      );
      expect(rect.width, greaterThanOrEqualTo(47.9));
      expect(rect.height, greaterThanOrEqualTo(47.9));
      await tester.tap(find.byKey(const ValueKey('original-column-action')));
      expect(actions, 2);
      expect(tester.takeException(), isNull);
    },
  );
}

void _view(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Widget _app({
  required Widget child,
  required double factor,
  double textScale = 1,
  required TargetPlatform platform,
}) => MaterialApp(
  theme: buildLightTheme().copyWith(platform: platform),
  builder: (context, body) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: UtenDisplayZoomBox(fontFactor: factor, child: body!),
  ),
  home: child,
);

Finder _header(WidgetTester tester) {
  final containers = find.ancestor(
    of: find.text('办理'),
    matching: find.byType(Container),
  );
  for (final element in containers.evaluate()) {
    final container = element.widget as Container;
    final box = container.constraints;
    if (box != null && box.maxWidth.isFinite && box.minWidth == box.maxWidth) {
      return find.byWidget(container);
    }
  }
  throw TestFailure('没有找到办理列表头');
}

double _width(WidgetTester tester) =>
    tester.widget<Container>(_header(tester)).constraints!.maxWidth;
