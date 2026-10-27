import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_content_container.dart';
import 'package:uten_imp/components/layout/uten_content_scrollbar.dart';
import 'package:uten_imp/components/layout/uten_page_scrollbar_host.dart';
import 'package:uten_imp/components/layout/uten_scroll_prefetch_policy.dart';
import 'package:uten_imp/core/theme/uten_scrollbar_style.dart';
import 'package:uten_imp/core/theme/uten_scroll_behavior.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

const _pageSize = 60;
List<String> _pageRows(int page, {String scope = 'A'}) =>
    List.generate(_pageSize, (i) => '$scope-${(page - 1) * _pageSize + i}');
String _value(String row) => row;
Finder _rail() => find.byKey(UtenPageScrollbarHost.railKey);
ScrollPosition _position(WidgetTester tester) =>
    tester.widget<UtenContentScrollbar>(_rail()).controller.position;

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.initialPage = 2});
  final int initialPage;
  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final controller = ScrollController();
  final rows = MasterDataTableRowsController<String>();
  late int page;
  late List<String> items;
  final requests = <int>[];
  final responses = <Completer<List<String>>>[];
  final receipts = <({double before, double after, double pixels})>[];
  bool loading = false;
  String? error;
  String scope = 'A';
  final selected = <String>{};
  @override
  void initState() {
    super.initState();
    page = widget.initialPage;
    items = _pageRows(page);
  }

  Future<void> load(int target) async {
    final requestScope = scope;
    final response = Completer<List<String>>();
    requests.add(target);
    responses.add(response);
    final p = controller.position;
    receipts.add((
      before: p.extentBefore,
      after: p.extentAfter,
      pixels: p.pixels,
    ));
    setState(() {
      loading = true;
      error = null;
    });
    try {
      final incoming = await response.future;
      if (!mounted || scope != requestScope) return;
      setState(() {
        items = incoming;
        page = target;
        loading = false;
      });
    } catch (_) {
      if (!mounted || scope != requestScope) return;
      setState(() {
        loading = false;
        error = 'Read failed';
      });
    }
  }

  void switchScope() => setState(() {
    scope = scope == 'A' ? 'B' : 'C';
    page = 1;
    items = _pageRows(1, scope: scope);
    loading = false;
    error = null;
    selected.clear();
  });
  void select(String id) => setState(() => selected.add(id));
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: ThemeData(platform: TargetPlatform.windows),
    scrollBehavior: const UtenScrollBehavior(),
    builder: (_, child) => UtenPageScrollbarHost(child: child!),
    home: Scaffold(
      body: UtenContentContainer(
        selectable: false,
        child: PrimaryScrollController(
          controller: controller,
          child: MasterDataTableView<String>(
            primary: true,
            virtualized: true,
            rowsController: rows,
            columns: const [
              MasterColumnDef(
                key: 'value',
                label: 'Value',
                width: 200,
                value: _value,
              ),
            ],
            items: items,
            rowKeyOf: _value,
            idOf: _value,
            selectable: true,
            selectedIds: selected,
            onSelectedIdsChanged: (ids) => setState(() {
              selected
                ..clear()
                ..addAll(ids);
            }),
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            currentPage: page,
            totalPages: 5,
            paginationScope: scope,
            onPageChange: load,
            loadingMore: loading,
            error: error,
          ),
        ),
      ),
    ),
  );
}

Future<void> _pump(
  WidgetTester tester,
  GlobalKey<_HarnessState> key, {
  int initialPage = 2,
}) async {
  await tester.pumpWidget(_Harness(key: key, initialPage: initialPage));
  await tester.pumpAndSettle();
  expect(_rail(), findsOneWidget);
  expect(
    key.currentState!.requests,
    isEmpty,
    reason: 'Initial layout never scans pages',
  );
}

({double center, double length}) _thumb(WidgetTester tester) {
  final rail = tester.widget<UtenContentScrollbar>(_rail());
  final pos = rail.railDelegate?.metrics ?? _position(tester);
  final rect = tester.getRect(_rail());
  final inset = rail.bottomInset.clamp(0.0, rect.height);
  final fullTrack = rect.height - inset;
  final arrow = math.min(UtenScrollbarStyle.arrowExtent, fullTrack / 3);
  final track = fullTrack - 2 * arrow;
  final viewport = pos.viewportDimension;
  final visibleViewport = viewport - rail.bottomInset.clamp(0.0, viewport);
  final ratio =
      (visibleViewport /
              (pos.maxScrollExtent - pos.minScrollExtent + visibleViewport))
          .clamp(.05, 1.0);
  final length = (track * ratio)
      .clamp(math.min(UtenScrollbarStyle.minimumThumbLength, track * .8), track)
      .toDouble();
  final fraction =
      (pos.pixels - pos.minScrollExtent) /
      (pos.maxScrollExtent - pos.minScrollExtent);
  return (
    center: rect.top + arrow + (track - length) * fraction + length / 2,
    length: length,
  );
}

Future<void> _approach(WidgetTester tester, String method, bool prepend) async {
  final pos = _position(tester);
  final distance = UtenScrollPrefetchPolicy.distanceOf(pos);
  final before = method == 'track'
      ? distance + pos.viewportDimension * .4
      : distance + 16;
  pos.jumpTo(
    prepend ? pos.minScrollExtent + before : pos.maxScrollExtent - before,
  );
  await tester.pump();
  final rect = tester.getRect(_rail());
  final startPixels = pos.pixels;
  if (method == 'wheel') {
    final pointer = TestPointer(31, PointerDeviceKind.mouse);
    final at = tester.getCenter(find.byType(ListView).first);
    await tester.sendEventToBinding(pointer.hover(at));
    await tester.sendEventToBinding(
      pointer.scroll(Offset(0, prepend ? -32 : 32)),
    );
  } else if (method == 'arrow') {
    await tester.tapAt(
      Offset(rect.center.dx, prepend ? rect.top + 5 : rect.bottom - 5),
    );
  } else if (method == 'track') {
    final thumb = _thumb(tester);
    final tapY = prepend ? rect.top + 20 : rect.bottom - 20;
    expect(
      prepend
          ? tapY < thumb.center - thumb.length / 2
          : tapY > thumb.center + thumb.length / 2,
      isTrue,
      reason: 'Track page tap is outside the real thumb',
    );
    await tester.tapAt(Offset(rect.center.dx, tapY));
  } else {
    final thumb = _thumb(tester);
    final gesture = await tester.startGesture(
      Offset(rect.center.dx, thumb.center),
      kind: PointerDeviceKind.mouse,
    );
    await gesture.moveBy(Offset(0, prepend ? -24 : 24));
    await tester.pump();
    await gesture.moveBy(Offset(0, prepend ? -24 : 24));
    await gesture.up();
  }
  // Start the track's animation ticker before advancing its elapsed time.
  await tester.pump();
  // Start animateTo's ticker epoch before advancing its150ms duration.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 180));
  await tester.pump();
  expect(
    _position(tester).pixels,
    prepend ? lessThan(startPixels) : greaterThan(startPixels),
  );
}

Future<void> _goto(WidgetTester tester, int page) async {
  final input = find.byType(TextFormField).first;
  await tester.enterText(input, '$page');
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pump();
}

void main() {
  for (final method in ['wheel', 'thumb', 'track', 'arrow']) {
    for (final prepend in [false, true]) {
      testWidgets(
        '$method prefetches ${prepend ? 'above' : 'below'} before the real viewport reaches its loaded edge',
        (tester) async {
          final key = GlobalKey<_HarnessState>();
          await _pump(tester, key);
          final host = key.currentState!;
          await _approach(tester, method, prepend);
          expect(host.requests, [prepend ? 1 : 3]);
          final receipt = host.receipts.single;
          expect(
            prepend ? receipt.before : receipt.after,
            greaterThan(1),
            reason: 'Request must start before the loaded boundary',
          );
          expect(
            host.requests,
            hasLength(1),
            reason: 'In-flight read is deduplicated',
          );
          host.responses.single.complete(_pageRows(prepend ? 1 : 3));
          await tester.pumpAndSettle();
          expect(host.rows.items, hasLength(_pageSize * 2));
          if (prepend) expect(_position(tester).pixels, greaterThan(0));
          expect(
            host.requests,
            hasLength(1),
            reason: 'Layout/anchor acceptance does not crawl more pages',
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'Shift and unrelated nested viewport do not prefetch the owning table',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await _pump(tester, key);
      final p = _position(tester);
      p.jumpTo(p.maxScrollExtent - UtenScrollPrefetchPolicy.distanceOf(p) - 16);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendEventToBinding(
        PointerScrollEvent(
          position: tester.getCenter(_rail()),
          scrollDelta: const Offset(0, 100),
        ),
      );
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      expect(key.currentState!.requests, isEmpty);
      final listContext = tester.element(find.byType(ListView).first);
      ScrollUpdateNotification(
        metrics: FixedScrollMetrics(
          minScrollExtent: 0,
          maxScrollExtent: 100,
          pixels: 90,
          viewportDimension: 50,
          axisDirection: AxisDirection.down,
          devicePixelRatio: 1,
        ),
        context: listContext,
        scrollDelta: 20,
      ).dispatch(listContext);
      await tester.pump();
      // The synthetic notification context resolves no table-owned Scrollable.
      expect(key.currentState!.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read failure and a changed query do not retry or accept stale data while scrolling',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await _pump(tester, key);
      final host = key.currentState!;
      await _approach(tester, 'arrow', false);
      host.responses.single.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      for (var i = 0; i < 3; i++) {
        await tester.tapAt(
          tester.getRect(_rail()).bottomCenter - const Offset(0, 5),
        );
        await tester.pump();
      }
      expect(host.requests, [3]);
      host.switchScope();
      await tester.pumpAndSettle();
      expect(host.rows.items.every((row) => row.startsWith('B-')), isTrue);
      expect(host.requests, [3]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'successful explicit pager seeds exactly one previous buffer and retains requested rows and selection',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await _pump(tester, key, initialPage: 1);
      final host = key.currentState!;
      await _goto(tester, 3);
      expect(host.requests, [3]);
      host.responses.first.complete(_pageRows(3));
      for (var i = 0; i < 8 && host.requests.length < 2; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(host.requests, [3, 2]);
      host.select('A-120');
      await tester.pump();
      final before = tester.getTopLeft(find.text('A-120'));
      host.responses[1].complete(_pageRows(2));
      await tester.pumpAndSettle();
      expect(host.rows.items, hasLength(_pageSize * 2));
      expect(host.selected, contains('A-120'));
      expect(tester.getTopLeft(find.text('A-120')).dy, closeTo(before.dy, .01));
      expect(find.widgetWithText(TextFormField, '3'), findsOneWidget);
      expect(
        _position(tester).extentBefore,
        greaterThan(0),
        reason: 'The up arrow now has a real previous buffer',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(host.requests, [3, 2]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed or invalidated explicit pager never seeds previous reads',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await _pump(tester, key, initialPage: 1);
      final host = key.currentState!;
      await _goto(tester, 3);
      host.responses.first.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(host.requests, [3]);
      host.switchScope();
      await tester.pumpAndSettle();
      await _goto(tester, 4);
      expect(host.requests, [3, 4]);
      host.switchScope();
      await tester.pumpAndSettle();
      host.responses.last.complete(_pageRows(4));
      await tester.pumpAndSettle();
      expect(host.requests, [3, 4]);
      expect(tester.takeException(), isNull);
    },
  );
}
