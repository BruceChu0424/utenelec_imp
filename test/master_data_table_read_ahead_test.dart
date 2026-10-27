import 'dart:async';
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/components/layout/uten_scroll_prefetch_policy.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/models/product_category_node.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/basic_data/widgets/master_entity_detail_pane.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

const _pageSize = 24;
const _totalPages = 12;

String _id(String row) => row;
int _pageOf(String row) => int.parse(row.split('-')[2]);
PagedResult<String> _response(String scope, int page) => PagedResult(
  items: [
    for (var row = 0; row < _pageSize; row++) '$scope-page-$page-row-$row',
  ],
  page: page,
  size: _pageSize,
  total: _pageSize * _totalPages,
  totalPages: _totalPages,
);

class _Harness extends StatefulWidget {
  const _Harness({super.key, this.bindReadWindow = true});
  final bool bindReadWindow;

  @override
  State<_Harness> createState() => _HarnessState();
}

abstract interface class _ReadView {
  MasterDataTableRowsController<String> get rows;
  String get scope;
}

class _HarnessState extends State<_Harness> implements _ReadView {
  final reader = ScopedPagedRead<String>();
  @override
  final rows = MasterDataTableRowsController<String>();
  final requests = <({String scope, int page})>[];
  final held = <(String, int), Completer<PagedResult<String>>>{};
  PagedResult<String>? result;
  @override
  String scope = 'A';
  bool loading = false;
  int request = 0;

  @override
  void initState() {
    super.initState();
    unawaited(load(1));
  }

  Future<void> load(int page) async {
    final currentScope = scope;
    final generation = ++request;
    setState(() => loading = true);
    final next = await reader.read(
      page,
      scope: currentScope,
      fetchPage: (target) {
        requests.add((scope: currentScope, page: target));
        return held[(currentScope, target)]?.future ??
            Future.value(_response(currentScope, target));
      },
      isCurrent: () => mounted && scope == currentScope,
      useCache: true,
      // The component's visible-page binding must drive these speculative
      // reads; foreground-page prefetch would hide a missing binding here.
      canPrefetch: () => false,
    );
    if (!mounted || currentScope != scope || generation != request) return;
    setState(() {
      result = next;
      loading = false;
    });
  }

  Future<void> switchQuery() async {
    reader.invalidate();
    setState(() {
      scope = 'B';
      result = null;
    });
    await load(1);
  }

  @override
  void dispose() {
    reader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 1000,
        height: 520,
        child: MasterDataTableView<String>(
          columns: [
            MasterColumnDef<String>(
              key: 'value',
              label: 'Value',
              width: 400,
              value: _id,
              cellBuilder: (_, row) => SizedBox(
                key: ValueKey('anchor-$row'),
                height: 42,
                child: Text(row),
              ),
            ),
          ],
          rowKeyOf: _id,
          rowsController: rows,
          items: widget.bindReadWindow
              ? result?.items ?? const []
              : List.of(result?.items ?? const <String>[]),
          expensiveRowMounts: false,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          currentPage: result?.page ?? 1,
          totalPages: result?.totalPages ?? _totalPages,
          paginationScope: scope,
          paginationRevision: result,
          isLoading: loading && result == null,
          loadingMore: loading && result != null,
          onPageChange: load,
        ),
      ),
    ),
  );
}

class _PaneSession extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _PaneReadView implements _ReadView {
  _PaneReadView(this.rows);
  @override
  final MasterDataTableRowsController<String> rows;
  @override
  String get scope => 'A';
}

Future<_PaneReadView> _pumpRealPane(
  WidgetTester tester,
  List<int> requests,
) async {
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  await tester.binding.setSurfaceSize(const Size(1400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final config = MasterEntityPaneConfig<String, String>(
    noun: '货品',
    icon: Icons.inventory_2_outlined,
    defaultCodePrefix: 'HP',
    columns: [
      MasterColumnDef<String>(
        key: 'value',
        label: '货品名称',
        width: 400,
        value: _id,
        cellBuilder: (_, row) => SizedBox(
          key: ValueKey('anchor-$row'),
          height: 42,
          child: Text(row),
        ),
      ),
    ],
    idOf: _id,
    statusOf: (_) => '使用',
    labelOf: _id,
    loadCategory: (id) async => ProductCategoryDetail(
      id: id,
      code: 'C1',
      name: '成品类',
      level: 0,
      path: '成品类',
      childCount: 0,
    ),
    loadPage: (query) async {
      requests.add(query.page);
      return _response('A', query.page);
    },
    loadFacets: (_) async => const MasterPaneFacets(fields: {}, nullCounts: {}),
    batchEntityPath: '/master/goods',
    statusResourceOf: (id) => '/master/goods/$id',
    canCreate: false,
    canEdit: false,
    canDelete: false,
    canStatus: false,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        apiClientProvider.overrideWithValue(ApiClient(Dio())),
        sessionProvider.overrideWith(_PaneSession.new),
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'pane-read-ahead-test'),
        ),
        currentPermissionsProvider.overrideWithValue({Perm.goodsView}),
        isSuperAdminProvider.overrideWithValue(false),
        sharedPreferencesProvider.overrideWithValue(preferences),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MasterEntityDetailPane<String, String>(
            config: config,
            categoryId: 'category',
            externalKeyword: null,
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
  final table = tester.widget<MasterDataTableView<String>>(
    find.byType(MasterDataTableView<String>),
  );
  return _PaneReadView(table.rowsController!);
}

Finder _anchor(String scope, int page, int row) =>
    find.byKey(ValueKey('anchor-$scope-page-$page-row-$row'));

ScrollableState _vertical(WidgetTester tester) => Scrollable.of(
  tester.element(
    find.byWidgetPredicate((widget) {
      final key = widget.key;
      return key is ValueKey<String> && key.value.startsWith('anchor-');
    }).first,
  ),
  axis: Axis.vertical,
);

Future<void> _settle(WidgetTester tester) async {
  // Speculative transport deliberately yields to the event queue. Fixed frame
  // steps include that work without pumpAndSettle returning between two jobs.
  for (var frame = 0; frame < 30; frame++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Future<void> _appendThrough(
  WidgetTester tester,
  _ReadView host,
  int target,
) async {
  for (var attempt = 0; attempt < _totalPages; attempt++) {
    final last = host.rows.items.map(_pageOf).reduce(math.max);
    if (last >= target) return;
    await host.rows.loadNextPage();
    await _settle(tester);
  }
  fail('Presentation did not reach page $target');
}

Future<void> _lookAtPage(
  WidgetTester tester,
  _ReadView host,
  int page, {
  required double rowExtent,
  bool wheel = false,
}) async {
  final first = host.rows.items.map(_pageOf).reduce(math.min);
  final position = _vertical(tester).position;
  final target = ((page - first) * _pageSize + 2) * rowExtent;
  if (!wheel) {
    position.jumpTo(target.clamp(0, position.maxScrollExtent));
    await _settle(tester);
  }
  final row = _anchor(host.scope, page, 2);
  for (
    var attempt = 0;
    (row.evaluate().isEmpty || (wheel && host.rows.visiblePage != page)) &&
        attempt < 80;
    attempt++
  ) {
    final viewport = tester.getRect(find.byWidget(_vertical(tester).widget));
    final visible = find
        .byWidgetPredicate((widget) {
          final key = widget.key;
          return key is ValueKey<String> &&
              key.value.startsWith('anchor-${host.scope}-page-');
        })
        .evaluate()
        .where((element) {
          final box = element.findRenderObject()! as RenderBox;
          return (box.localToGlobal(Offset.zero) & box.size).overlaps(viewport);
        })
        .map((element) {
          final key = (element.widget.key! as ValueKey<String>).value.split(
            '-',
          );
          return (int.parse(key[3]) - 1) * _pageSize + int.parse(key[5]);
        });
    final firstVisible = visible.isEmpty
        ? ((host.rows.visiblePage ?? first) - 1) * _pageSize
        : visible.reduce(math.min);
    final direction = firstVisible <= (page - 1) * _pageSize + 2 ? 1 : -1;
    if (wheel) {
      final pointer = TestPointer(31, PointerDeviceKind.mouse);
      final scrollable = _vertical(tester);
      await tester.sendEventToBinding(
        pointer.hover(tester.getCenter(find.byWidget(scrollable.widget))),
      );
      await tester.sendEventToBinding(
        pointer.scroll(Offset(0, direction * 160)),
      );
    } else {
      position.jumpTo(
        (position.pixels + direction * 160).clamp(0, position.maxScrollExtent),
      );
    }
    await _settle(tester);
  }
  expect(
    row,
    findsOneWidget,
    reason:
        'Page $page is already presented; visible=${host.rows.visiblePage} '
        'pixels=${position.pixels} first=$first '
        'retained=${host.rows.items.map(_pageOf).toSet()}',
  );
  if (!wheel) {
    await Scrollable.ensureVisible(tester.element(row));
    await _settle(tester);
  }
  expect(host.rows.visiblePage, page);
}

void main() {
  testWidgets('removing the visible-page binding disables speculative reads', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key, bindReadWindow: false));
    await _settle(tester);
    final host = key.currentState!;
    expect(host.requests, [(scope: 'A', page: 1)]);
    await host.rows.loadNextPage();
    await _settle(tester);
    expect(host.requests, [(scope: 'A', page: 1), (scope: 'A', page: 2)]);
    expect(host.rows.items, hasLength(_pageSize * 2));
  });

  testWidgets(
    'goods master pane prepares two pages past five and reuses backward reads',
    (tester) async {
      final requests = <int>[];
      final host = await _pumpRealPane(tester, requests);
      expect(requests, [1, 2, 3]);
      final rowExtent =
          tester.getTopLeft(_anchor('A', 1, 1)).dy -
          tester.getTopLeft(_anchor('A', 1, 0)).dy;
      for (var page = 2; page <= 7; page++) {
        await _appendThrough(tester, host, page + 1);
        await _lookAtPage(tester, host, page, rowExtent: rowExtent);
        final position = _vertical(tester).position;
        expect(
          position.extentAfter,
          greaterThan(UtenScrollPrefetchPolicy.distanceOf(position)),
        );
        expect(requests.where((target) => target == page + 2), hasLength(1));
      }
      final before = List<int>.of(requests);
      expect(host.rows.items.map(_pageOf), isNot(contains(1)));
      for (var page = 6; page >= 1; page--) {
        while (!host.rows.items.any((row) => _pageOf(row) == page)) {
          await host.rows.loadPreviousPage();
          await _settle(tester);
        }
        await _lookAtPage(tester, host, page, rowExtent: rowExtent);
      }
      expect(
        requests,
        before,
        reason: 'The real pane must use cached GET rows',
      );
      expect(requests.toSet(), hasLength(requests.length));
      expect(tester.takeException(), isNull);
    },
  );

  for (final wheel in [false, true]) {
    testWidgets(
      '${wheel ? 'wheel' : 'scrollbar jump'} keeps two pages ready across the fifth-page eviction',
      (tester) async {
        final key = GlobalKey<_HarnessState>();
        await tester.pumpWidget(_Harness(key: key));
        await _settle(tester);
        final host = key.currentState!;
        expect(host.requests.map((read) => read.page), [1, 2, 3]);
        final rowExtent =
            tester.getTopLeft(_anchor('A', 1, 1)).dy -
            tester.getTopLeft(_anchor('A', 1, 0)).dy;

        for (var page = 2; page <= 8; page++) {
          await _appendThrough(tester, host, page + 1);
          await _lookAtPage(
            tester,
            host,
            page,
            rowExtent: rowExtent,
            wheel: wheel,
          );
          final position = _vertical(tester).position;
          expect(
            position.extentAfter,
            greaterThan(UtenScrollPrefetchPolicy.distanceOf(position)),
            reason: 'Page $page must prepare before reaching the loaded edge',
          );
          expect(
            host.requests.where((read) => read.page == page + 2),
            hasLength(1),
            reason: 'Reading page $page must already prepare page ${page + 2}',
          );
        }
        expect(
          host.rows.items.map(_pageOf).reduce(math.min),
          greaterThan(1),
          reason: 'The test has crossed the presentation cache boundary',
        );
        expect(
          host.requests.map((read) => read.page).toSet(),
          hasLength(host.requests.length),
          reason: 'Cached presentation advances must not repeat transport',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'backward scrolling restores evicted pages without network reads',
    (tester) async {
      final key = GlobalKey<_HarnessState>();
      await tester.pumpWidget(_Harness(key: key));
      await _settle(tester);
      final host = key.currentState!;
      final rowExtent =
          tester.getTopLeft(_anchor('A', 1, 1)).dy -
          tester.getTopLeft(_anchor('A', 1, 0)).dy;
      for (var page = 2; page <= 8; page++) {
        await _appendThrough(tester, host, page + 1);
        await _lookAtPage(tester, host, page, rowExtent: rowExtent);
      }
      final before = List.of(host.requests);
      expect(host.rows.items.map(_pageOf), isNot(contains(1)));
      for (var page = 7; page >= 1; page--) {
        await _lookAtPage(
          tester,
          host,
          page,
          rowExtent: rowExtent,
          wheel: true,
        );
      }
      expect(host.requests, before);
      expect(host.rows.visiblePage, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a query switch retires a pending speculative response', (
    tester,
  ) async {
    final key = GlobalKey<_HarnessState>();
    await tester.pumpWidget(_Harness(key: key));
    await _settle(tester);
    final host = key.currentState!;
    final gate = Completer<PagedResult<String>>();
    host.held[('A', 4)] = gate;
    await _appendThrough(tester, host, 3);
    final rowExtent =
        tester.getTopLeft(_anchor('A', 1, 1)).dy -
        tester.getTopLeft(_anchor('A', 1, 0)).dy;
    await _lookAtPage(tester, host, 2, rowExtent: rowExtent);
    expect(host.requests, contains((scope: 'A', page: 4)));
    await host.switchQuery();
    await _settle(tester);
    gate.complete(_response('A', 4));
    await _settle(tester);
    await _appendThrough(tester, host, 3);
    expect(host.rows.items.every((row) => row.startsWith('B-')), isTrue);
    expect(host.requests, contains((scope: 'B', page: 3)));
    expect(
      host.requests.where((read) => read.scope == 'A' && read.page > 4),
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });
}
