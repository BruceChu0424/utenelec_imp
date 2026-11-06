import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
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
    .family<PagedResult<int>, (String, int)>(
      (ref, key) {
        final source = ref.watch(_source);
        return ref
            .watch(_reads(key.$1))
            .read(key.$2, fetchPage: (page) => source.fetch(key.$1, page));
      },
      dependencies: [_reads, _source],
      retry: pagedReadProviderRetry,
    );

class _View extends ConsumerStatefulWidget {
  const _View({super.key});
  @override
  ConsumerState<_View> createState() => _ViewState();
}

class _ViewState extends ConsumerState<_View> {
  final _retained = RetainedAsyncPage<PagedResult<int>>();
  String query = 'A';
  int page = 1;

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

// Provider-owned complete snapshots replace user page navigation and look-ahead.
void main() {
  test(
    'invalid snapshots stop automatic full-query replay while network recovery remains enabled',
    () async {
      for (final error in <Object>[
        ApiException('SNAPSHOT_CHANGED', ''),
        ApiException('INVALID_PAGINATION', ''),
        ApiException('FORBIDDEN', '', httpStatus: 403),
        const FormatException('malformed'),
        StateError('missing typed snapshot'),
        const UiWorkCancelled(),
      ]) {
        var requests = 0;
        final provider = FutureProvider<int>((ref) async {
          requests++;
          throw error;
        }, retry: pagedReadProviderRetry);
        final container = ProviderContainer();
        final subscription = container.listen(provider, (_, _) {});
        await expectLater(
          container.read(provider.future),
          throwsA(same(error)),
        );
        expect(pagedReadProviderRetry(0, error), isNull);
        expect(requests, 1);
        container.invalidate(provider);
        await expectLater(
          container.read(provider.future),
          throwsA(same(error)),
        );
        expect(requests, 2, reason: 'Explicit refresh remains available.');
        subscription.close();
        container.dispose();
      }
      expect(pagedReadProviderRetry(0, NetworkException()), isNotNull);
      expect(
        pagedReadProviderRetry(
          0,
          ApiException('INTERNAL', '', httpStatus: 503),
        ),
        isNotNull,
      );
      expect(
        pagedReadProviderRetry(
          0,
          ApiException('RATE_LIMITED', '', httpStatus: 429),
        ),
        isNotNull,
      );
    },
  );
  testWidgets(
    'the first provider result contains the complete query and idle frames issue no reads',
    (tester) async {
      final source = _Source();
      final (_, container) = await _mount(tester, source);
      expect(find.text('rows=101,102,103'), findsOneWidget);
      expect(source.calls, [('A', 1), ('A', 2), ('A', 3)]);
      await tester.pump(const Duration(seconds: 1));
      expect(source.calls.length, 3);
      final result = await container.read(_pages(('A', 1)).future);
      expect((result.page, result.totalPages), (1, 1));
    },
  );
  testWidgets(
    'explicit refresh obtains one new complete result and keeps no stale navigation intent',
    (tester) async {
      final source = _Source();
      final (view, _) = await _mount(tester, source);
      source.revision = 2;
      final refresh = view.refresh();
      await tester.pumpAndSettle();
      await refresh;
      expect(find.text('rows=201,202,203'), findsOneWidget);
      expect(source.calls.length, 6);
      source.revision = 3;
      final again = view.refresh();
      await tester.pumpAndSettle();
      await again;
      expect(find.text('rows=301,302,303'), findsOneWidget);
      expect(source.calls.length, 9);
    },
  );
  testWidgets(
    'provider epoch replacement rejects a held old response and only shows the new owner snapshot',
    (tester) async {
      final source = _Source();
      final (_, container) = await _mount(tester, source);
      source.revision = 2;
      final gate = Completer<PagedResult<int>>();
      source.holds[('A', 2)] = gate;
      final old = container
          .read(_reads('A'))
          .read(1, fetchPage: (page) => source.fetch('A', page));
      final rejected = expectLater(old, throwsA(anything));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1));
      source.holds.clear();
      source.revision = 3;
      (container.read(exportContextEpochProvider.notifier) as _Epoch).advance();
      await tester.pumpAndSettle();
      gate.complete(
        const PagedResult(
          items: [202],
          page: 2,
          size: 1,
          total: 3,
          totalPages: 3,
          readScopeVersion: '2',
        ),
      );
      await tester.pumpAndSettle();
      await rejected;
      expect(find.text('rows=301,302,303'), findsOneWidget);
      expect(source.calls.where((call) => call.$2 == 3).length, 2);
    },
  );
}
