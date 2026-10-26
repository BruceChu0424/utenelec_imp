import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/models/retained_async_page.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read_provider.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void advance() => state++;
}

class _Source {
  final calls = <(String, int)>[];
  final holds = <(String, int), Completer<PagedResult<int>>>{};
  int revision = 1;

  PagedResult<int> page(int number) => PagedResult(
    items: [revision * 100 + number],
    page: number,
    size: 1,
    total: 3,
    totalPages: 3,
    readScopeVersion: '$revision',
  );

  Future<PagedResult<int>> fetch(String query, int number) async {
    calls.add((query, number));
    return holds[(query, number)]?.future ?? page(number);
  }
}

final _source = Provider<_Source>((ref) => throw UnimplementedError());
final _reads = Provider.autoDispose
    .family<ScopedPagedReadProviderLease<int>, String>((ref, query) {
      ref.watch(_source);
      return ScopedPagedReadProviderLease(ref, query: query);
    }, dependencies: [exportContextEpochProvider, _source]);
final _pages = FutureProvider.autoDispose
    .family<PagedResult<int>, (String, int)>((ref, key) {
      final source = ref.watch(_source);
      return ref
          .watch(_reads(key.$1))
          .read(key.$2, fetchPage: (page) => source.fetch(key.$1, page));
    }, dependencies: [_reads, _source], retry: pagedReadProviderRetry);

class _View extends ConsumerStatefulWidget {
  const _View({super.key});
  @override
  ConsumerState<_View> createState() => _ViewState();
}

class _ViewState extends ConsumerState<_View> {
  final _retained = RetainedAsyncPage<PagedResult<int>>();
  String query = 'A';
  int page = 1;

  Future<void> goTo(int next) =>
      ref.read(_reads(query)).paginate(next, () async {
        setState(() => page = next);
        final provider = _pages((query, next));
    ref.invalidate(provider);
        await _retained.waitFor(ref, provider, () => ref.read(provider.future));
      });

  Future<void> refresh() async {
    ref.read(_reads(query)).invalidate();
    final provider = _pages((query, page));
    ref.invalidate(provider);
    await ref.read(provider.future);
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(_reads(query)).bindView(context, currentQuery: () => query);
    final result = _retained.resolveFor(ref, query, _pages((query, page)));
    return Text(
      result.hasError
          ? 'error'
          : result.hasValue
          ? 'rows=${result.requireValue.items.join(',')}'
          : 'loading',
    );
  }
}

Future<(_ViewState, ProviderContainer)> _mount(
  WidgetTester tester,
  _Source source, {
  ValueNotifier<bool>? active,
}) async {
  final key = GlobalKey<_ViewState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        _source.overrideWithValue(source),
        exportContextEpochProvider.overrideWith(_Epoch.new),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: active == null
              ? _View(key: key)
              : ValueListenableBuilder<bool>(
                  valueListenable: active,
                  builder: (_, enabled, _) => TickerMode(
                    enabled: enabled,
                    child: _View(key: key),
                  ),
                ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final view = key.currentState!;
  return (view, ProviderScope.containerOf(view.context));
}

void main() {
  testWidgets(
    'provider paging adopts a warm request and revisits cached rows',
    (tester) async {
      final source = _Source();
      final second = Completer<PagedResult<int>>();
      source.holds[('A', 2)] = second;
      final (view, _) = await _mount(tester, source);
      expect(source.calls, [('A', 1), ('A', 2)]);
      final next = view.goTo(2);
      await tester.pump();
      expect(source.calls.where((call) => call.$2 == 2), hasLength(1));
      second.complete(source.page(2));
      await tester.pumpAndSettle();
      await next;
      final previous = view.goTo(1);
      await tester.pumpAndSettle();
      await previous;
      expect(find.text('rows=101'), findsOneWidget);
      expect(source.calls.where((call) => call.$2 == 1), hasLength(1));
      source.holds.remove(('A', 2));
      source.revision = 2;
      final refreshing = view.refresh();
      await tester.pumpAndSettle();
      await refreshing;
      expect(find.text('rows=201'), findsOneWidget);
      expect(source.calls.where((call) => call.$2 == 1), hasLength(2));
    },
  );

  testWidgets(
    'a completed Riverpod future cannot leave a cache intent behind',
    (tester) async {
      final source = _Source();
      final container = ProviderContainer(
        overrides: [
          _source.overrideWithValue(source),
          exportContextEpochProvider.overrideWith(_Epoch.new),
        ],
      );
      addTearDown(container.dispose);
      final first = _pages(('A', 1));
      final second = _pages(('A', 2));
      final firstWatch = container.listen(first, (_, _) {});
      addTearDown(firstWatch.close);
      await container.read(first.future);
      final lease = container.read(_reads('A'));
      await lease.paginate(2, () async {
        final secondWatch = container.listen(second, (_, _) {});
        addTearDown(secondWatch.close);
        await container.read(second.future);
      });
      await lease.paginate(1, () async => await container.read(first.future));
      final before = source.calls.where((call) => call.$2 == 1).length;
      container.invalidate(first);
      await container.read(first.future);
      expect(source.calls.where((call) => call.$2 == 1), hasLength(before + 1));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('prefetch denial retires retained rows without a reread loop', (
    tester,
  ) async {
    final source = _Source();
    final denied = Completer<PagedResult<int>>();
    source.holds[('A', 2)] = denied;
    final (view, _) = await _mount(tester, source);
    expect(find.text('rows=101'), findsOneWidget);
    denied.completeError(ApiException('FORBIDDEN', 'revoked', httpStatus: 403));
    await tester.pumpAndSettle();
    expect(find.text('rows=101'), findsNothing);
    expect(find.text('error'), findsOneWidget);
    expect(source.calls, [('A', 1), ('A', 2)]);
    source.holds.remove(('A', 2));
    final retry = view.refresh();
    await tester.pumpAndSettle();
    await retry;
    expect(find.text('rows=101'), findsOneWidget);
    expect(source.calls.where((call) => call.$2 == 1), hasLength(2));
  });

  testWidgets(
    'inactive readers skip look-ahead and owner ABA drops old pages',
    (tester) async {
      final inactiveSource = _Source();
      final active = ValueNotifier(false);
      addTearDown(active.dispose);
      await _mount(tester, inactiveSource, active: active);
      expect(inactiveSource.calls, [('A', 1)]);
      await tester.pumpWidget(const SizedBox());
      final source = _Source();
      final oldSecond = Completer<PagedResult<int>>();
      source.holds[('A', 2)] = oldSecond;
      final (view, container) = await _mount(tester, source);
      source.holds.remove(('A', 2));
      source.revision = 3;
      final epoch =
          container.read(exportContextEpochProvider.notifier) as _Epoch;
      epoch.advance();
      epoch.advance();
      await tester.pumpAndSettle();
      oldSecond.complete(
        PagedResult(
          items: const [999],
          page: 2,
          size: 1,
          total: 3,
          totalPages: 3,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('rows=301'), findsOneWidget);
      final next = view.goTo(2);
      await tester.pumpAndSettle();
      await next;
      expect(find.text('rows=302'), findsOneWidget);
      expect(find.text('rows=999'), findsNothing);
    },
  );
}
