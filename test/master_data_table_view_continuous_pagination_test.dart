import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';

String _value(String row) => row;

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.primary = false, this.eagerPage = false});
  final bool primary;
  final bool eagerPage;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final rows = MasterDataTableRowsController<String>();
  final primaryController = ScrollController();
  List<String> items = List.generate(20, (i) => 'A-$i');
  List<String> locals = [];
  final requests = <int>[];
  final responses = <Completer<List<String>>>[];
  int page = 1;
  int totalPages = 3;
  String scope = 'A';
  String? error;
  bool loading = false;
  final filters = <String, String?>{};
  Object revision = Object();

  Future<void> load(int target) async {
    final requestScope = scope;
    final response = Completer<List<String>>();
    requests.add(target);
    responses.add(response);
    setState(() {
      loading = true;
      error = null;
      if (widget.eagerPage) page = target;
    });
    try {
      final result = await response.future;
      if (!mounted || requestScope != scope) return;
      setState(() {
        items = result;
        page = target;
        loading = false;
      });
    } catch (_) {
      if (!mounted || requestScope != scope) return;
      setState(() {
        error = '连接失败';
        loading = false;
      });
    }
  }

  void switchQuery() => setState(() {
    scope = 'B';
    page = 1;
    loading = false;
    error = null;
    items = List.generate(20, (i) => 'B-$i');
  });

  void showShortPage() => setState(() {
    items = ['A-0'];
    locals = ['draft'];
  });
  void removeDraft() => setState(() => locals = []);
  void mutateFilter() => setState(() {
    filters['value'] = 'filtered';
    items = ['filtered'];
  });
  void silentRefresh() => setState(() {
    revision = Object();
    items = ['fresh'];
  });

  @override
  void dispose() {
    primaryController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final table = MasterDataTableView<String>(
      columns: const [
        MasterColumnDef(key: 'value', label: '值', width: 200, value: _value),
      ],
      items: items,
      unpagedItems: locals,
      rowsController: rows,
      rowKeyOf: _value,
      facets: const {},
      nullCounts: const {},
      filters: filters,
      onFilterChanged: (_, _) {},
      currentPage: page,
      totalPages: totalPages,
      paginationScope: scope,
      paginationRevision: revision,
      onPageChange: load,
      loadingMore: loading,
      error: error,
      onRetry: () => load(page),
      primary: widget.primary,
    );
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 700,
          height: 400,
          child: widget.primary
              ? PrimaryScrollController(
                  controller: primaryController,
                  child: table,
                )
              : table,
        ),
      ),
    );
  }
}

ScrollableState _vertical(WidgetTester tester) => tester
    .stateList<ScrollableState>(find.byType(Scrollable))
    .firstWhere((state) => state.position.axis == Axis.vertical);

Future<void> _wheel(
  WidgetTester tester, {
  double dy = 100,
  double dx = 0,
}) async {
  final list = find.byType(ListView).first;
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(tester.getCenter(list)));
  await tester.sendEventToBinding(pointer.scroll(Offset(dx, dy)));
  await tester.pump();
  await tester.pump();
}

Future<void> _bottom(WidgetTester tester) async {
  final position = _vertical(tester).position;
  position.jumpTo(position.maxScrollExtent);
  await tester.pump();
}

void main() {
  testWidgets('eager host page numbers cannot skip a failed continuation', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, eagerPage: true));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    await _bottom(tester);
    await _wheel(tester);
    expect(host.page, 2);
    expect(find.widgetWithText(TextFormField, '1'), findsOneWidget);
    host.responses.single.completeError(StateError('offline'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextFormField, '1'), findsOneWidget);
    await _bottom(tester);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(host.requests, [2, 2]);
    host.responses.last.complete(['A-20']);
    await tester.pumpAndSettle();
    // The response advances the loaded boundary; the viewport still starts
    // within page 1, so its displayed page must not advance prematurely.
    expect(find.widgetWithText(TextFormField, '1'), findsOneWidget);
    expect(host.rows.items.length, 21);
  });

  testWidgets(
    'in-place filter mutation and silent refresh invalidate earlier pages',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await _bottom(tester);
      await _wheel(tester);
      host.responses.last.complete(['A-20']);
      await tester.pumpAndSettle();
      expect(host.rows.items.length, 21);
      host.silentRefresh();
      await tester.pumpAndSettle();
      expect(host.rows.items, ['fresh']);
      host.mutateFilter();
      await tester.pumpAndSettle();
      expect(host.rows.items, ['filtered']);
      expect(_vertical(tester).position.pixels, 0);
    },
  );

  testWidgets('fullscreen append keeps the same row window and page input', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全屏'));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    await _bottom(tester);
    await _wheel(tester);
    expect(host.requests, [2]);
    host.responses.last.complete(['A-20']);
    await tester.pumpAndSettle();
    expect(host.rows.items.length, 21);
    expect(find.widgetWithText(TextFormField, '1'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final mode in ['table', 'primary']) {
    testWidgets(
      '$mode appends once and shows the page actually reached by scrolling',
      (tester) async {
        final key = GlobalKey<_HarnessState>();
        await tester.pumpWidget(_Harness(key: key, primary: mode == 'primary'));
        await tester.pumpAndSettle();
        final host = key.currentState!;
        await _bottom(tester);
        expect(
          host.requests,
          isEmpty,
          reason: 'layout/programmatic scrolling does not prefetch',
        );
        await _wheel(tester);
        await _wheel(tester);
        final before = _vertical(tester).position.pixels;
        expect(host.requests, [2]);
        expect(host.page, 1);
        expect(host.rows.items.length, 20);
        host.responses.single.complete(List.generate(20, (i) => 'A-${20 + i}'));
        await tester.pumpAndSettle();
        expect(host.page, 2);
        expect(host.rows.items, List.generate(40, (i) => 'A-$i'));
        expect(_vertical(tester).position.pixels, closeTo(before, 0.5));
        expect(find.widgetWithText(TextFormField, '1'), findsOneWidget);
        await _bottom(tester);
        await tester.pumpAndSettle();
        expect(find.widgetWithText(TextFormField, '2'), findsOneWidget);
        expect(host.requests, [
          2,
        ], reason: 'scrolling cached rows does not fetch');
        await _wheel(tester);
        host.responses.last.complete(['A-40']);
        await tester.pumpAndSettle();
        expect(host.requests, [2, 3]);
        await _bottom(tester);
        await _wheel(tester);
        expect(host.requests, [2, 3], reason: 'last page cannot request again');
        expect(host.rows.items.length, 41);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'failure preserves previous rows and retry appends without duplicates',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await _bottom(tester);
      await _wheel(tester);
      host.responses.single.completeError(StateError('offline'));
      await tester.pumpAndSettle();
      expect(host.rows.items.length, 20);
      expect(host.page, 1);
      await _bottom(tester);
      expect(find.text('连接失败'), findsOneWidget);
      await _wheel(tester);
      expect(host.requests, [2], reason: 'failed requests do not loop');
      await tester.tap(find.text('重试'));
      await tester.pump();
      host.responses.last.complete(['A-19', 'A-20']);
      await tester.pumpAndSettle();
      expect(host.requests, [2, 2]);
      expect(host.rows.items.length, 21);
      expect(host.rows.items.where((row) => row == 'A-19').length, 1);
      expect(host.page, 2);
    },
  );

  testWidgets('new query invalidates pending append and old rows', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await tester.pumpAndSettle();
    final host = key.currentState!;
    await _bottom(tester);
    await _wheel(tester);
    host.switchQuery();
    await tester.pumpAndSettle();
    host.responses.single.complete(['A-stale']);
    await tester.pumpAndSettle();
    expect(host.rows.items, List.generate(20, (i) => 'B-$i'));
    expect(host.page, 1);
    expect(_vertical(tester).position.pixels, 0);
  });

  testWidgets(
    'manual paging replaces the window; horizontal/upward scrolling does not append',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await tester.pumpAndSettle();
      final host = key.currentState!;
      await _bottom(tester);
      await _wheel(tester, dy: 0, dx: 300);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await _wheel(tester);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await _wheel(tester, dy: -20);
      expect(host.requests, isEmpty);
      await tester.tap(find.text('下一页'));
      await tester.pump();
      host.responses.single.complete(['page-two']);
      await tester.pumpAndSettle();
      expect(host.rows.items, ['page-two']);
      expect(_vertical(tester).position.pixels, 0);
    },
  );

  testWidgets('short page can append and unpaged draft rows stay live', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    final host = key.currentState!;
    host.showShortPage();
    await tester.pumpAndSettle();
    await _wheel(tester);
    expect(host.requests, [2]);
    host.responses.single.complete(['A-1']);
    await tester.pumpAndSettle();
    expect(host.rows.items, ['draft', 'A-0', 'A-1']);
    host.removeDraft();
    await tester.pumpAndSettle();
    expect(host.rows.items, ['A-0', 'A-1']);
  });
}
