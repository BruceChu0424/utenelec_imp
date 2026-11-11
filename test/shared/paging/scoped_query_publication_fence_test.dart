import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/paging/complete_output_guard.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
}

class _View extends ConsumerStatefulWidget {
  const _View({super.key});
  @override
  ConsumerState<_View> createState() => _ViewState();
}

class _ViewState extends ConsumerState<_View>
    with ScopedPagedReadViewMixin<_View> {
  String query = 'A';
  Future<PagedResult<int>> read() => readScopedPage<int>(
    1,
    query: [query],
    currentQuery: () => [query],
    fetchPage: (_) async => const PagedResult<int>(
      items: [101],
      page: 1,
      size: 1,
      total: 1,
      totalPages: 1,
    ),
  );
  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  for (final retire in ['unchanged', 'query-only', 'explicit-invalidate']) {
    testWidgets('same event immediate result $retire', (tester) async {
      final container = ProviderContainer(
        overrides: [exportContextEpochProvider.overrideWith(_Epoch.new)],
      );
      addTearDown(container.dispose);
      final key = GlobalKey<_ViewState>();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(home: _View(key: key)),
        ),
      );
      final state = key.currentState!;
      await tester.runAsync(() async {
        final pending = state.read();
        if (retire != 'unchanged') state.query = 'B';
        if (retire == 'explicit-invalidate') state.invalidateScopedPageReads();
        if (retire == 'unchanged') {
          final result = await pending;
          expect(result.items, [101]);
        } else {
          await expectLater(
            pending,
            throwsA(isA<UiWorkCancelled>()),
            reason:
                'currentQuery is required specifically to retire results for a changed live query',
          );
        }
      });
    });
  }
  publicationBoundaries();
}

const _page = PagedResult<int>(
  items: [101],
  page: 1,
  size: 1,
  total: 1,
  totalPages: 1,
);

class _BoundaryView extends ConsumerStatefulWidget {
  const _BoundaryView({super.key});
  @override
  ConsumerState<_BoundaryView> createState() => _BoundaryState();
}

class _BoundaryState extends ConsumerState<_BoundaryView>
    with ScopedPagedReadViewMixin<_BoundaryView> {
  String query = 'A';
  int fetches = 0;
  int ownerRetirements = 0;
  final prefixes = <List<int>>[];
  void Function()? onIdentity;
  void Function()? onPrefix;
  Object? failure;
  bool twoBatches = false;

  @override
  void scopedPagedReadOwnerChanged() => ownerRetirements++;

  Future<PagedResult<int>> fetch([int page = 1]) async {
    fetches++;
    if (failure case final error?) throw error;
    return twoBatches
        ? PagedResult<int>(
            items: [100 + page],
            page: page,
            size: 1,
            total: 2,
            totalPages: 2,
          )
        : _page;
  }

  Future<PagedResult<int>> read({
    bool useCache = false,
    bool complete = false,
    bool sized = false,
    bool progressive = true,
  }) => readScopedPage<int>(
    1,
    query: [query],
    currentQuery: () => [query],
    fetchPage: (page) => fetch(page),
    fetchPageSized: sized ? (page, _) => fetch(page) : null,
    fetchComplete: complete ? () => fetch() : null,
    idOf: (row) {
      onIdentity?.call();
      return row;
    },
    useCache: useCache,
    onProgressiveBatch: progressive
        ? (partial) {
            prefixes.add(partial.items);
            onPrefix?.call();
          }
        : null,
  );

  @override
  Widget build(BuildContext context) => const SizedBox();
}

Future<_BoundaryState> _mountBoundary(WidgetTester tester) async {
  final container = ProviderContainer(
    overrides: [exportContextEpochProvider.overrideWith(_Epoch.new)],
  );
  addTearDown(container.dispose);
  final key = GlobalKey<_BoundaryState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: _BoundaryView(key: key)),
    ),
  );
  return key.currentState!;
}

void publicationBoundaries() {
  for (final mode in ['page', 'sized', 'complete', 'cache']) {
    testWidgets(
      'same-turn $mode result cannot grant output qualification after query drift',
      (tester) async {
        final state = await _mountBoundary(tester);
        await tester.runAsync(() async {
          if (mode == 'cache') await state.read();
          state.prefixes.clear();
          final guard = CompleteOutputGuard();
          final ticket = guard.begin<PagedResult<int>>(identity: 'A');
          final pending = state
              .read(
                complete: mode == 'complete',
                sized: mode == 'sized',
                useCache: mode == 'cache',
              )
              .then((result) {
                guard.accept(ticket);
                return result;
              });
          state.query = 'B';
          await expectLater(pending, throwsA(isA<UiWorkCancelled>()));
          expect(state.prefixes, isEmpty);
          expect(guard.hasComplete('A'), isFalse);
          expect(
            state.fetches,
            1,
            reason: 'cache must stay a cache; stale work is not replayed',
          );
        });
      },
    );
  }

  testWidgets(
    'prefix publication rechecks a query changed during row validation',
    (tester) async {
      final state = await _mountBoundary(tester);
      state.twoBatches = true;
      state.onIdentity = () => state.query = 'B';
      await tester.runAsync(() async {
        await expectLater(state.read(), throwsA(isA<UiWorkCancelled>()));
        expect(state.prefixes, isEmpty);
        expect(state.fetches, 1);
      });
    },
  );

  testWidgets(
    'final result without progressive publication rechecks after row validation',
    (tester) async {
      final state = await _mountBoundary(tester);
      state.onIdentity = () => state.query = 'B';
      final guard = CompleteOutputGuard();
      final ticket = guard.begin<PagedResult<int>>(identity: 'A');
      await tester.runAsync(() async {
        final pending = state.read(progressive: false).then((result) {
          guard.accept(ticket);
          return result;
        });
        await expectLater(pending, throwsA(isA<UiWorkCancelled>()));
        expect(guard.hasComplete('A'), isFalse);
        expect(state.prefixes, isEmpty);
        expect(state.fetches, 1);
      });
    },
  );

  testWidgets(
    'prefix consumer changing query cannot promote that prefix to a complete result',
    (tester) async {
      final state = await _mountBoundary(tester);
      state.twoBatches = true;
      state.onPrefix = () => state.query = 'B';
      await tester.runAsync(() async {
        await expectLater(state.read(), throwsA(isA<UiWorkCancelled>()));
        expect(
          state.prefixes,
          [
            [101],
          ],
          reason:
              'the prefix was valid at entry, then its consumer retired the query',
        );
        expect(state.fetches, 1);
      });
    },
  );

  testWidgets(
    'unchanged query publishes a prefix and reuses its accepted complete cache',
    (tester) async {
      final state = await _mountBoundary(tester);
      state.twoBatches = true;
      await tester.runAsync(() async {
        expect((await state.read()).items, [101, 102]);
        expect((await state.read(useCache: true)).items, [101, 102]);
        expect(state.prefixes, [
          [101],
        ]);
        expect(state.fetches, 2);
      });
    },
  );

  for (final switched in [false, true]) {
    testWidgets('same-turn 403 ownership querySwitched=$switched', (
      tester,
    ) async {
      final state = await _mountBoundary(tester);
      state.failure = ApiException('FORBIDDEN', 'denied', httpStatus: 403);
      await tester.runAsync(() async {
        final pending = state.read();
        if (switched) state.query = 'B';
        await expectLater(
          pending,
          throwsA(
            isA<ApiException>().having(
              (error) => error.code,
              'code',
              'FORBIDDEN',
            ),
          ),
        );
        expect(state.ownerRetirements, switched ? 0 : 1);
        expect(state.prefixes, isEmpty);
      });
    });
  }
}
