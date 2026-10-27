import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void advance() => state++;
}

class _Source {
  final calls = <(String, int)>[];
  final holds = <(String, int), Completer<PagedResult<int>>>{};
  bool deny = false;

  PagedResult<int> page(String query, int number) => PagedResult(
    items: [number],
    page: number,
    size: 1,
    total: 3,
    totalPages: 3,
  );

  Future<PagedResult<int>> fetch(String query, int number) async {
    calls.add((query, number));
    if (deny) throw ApiException('FORBIDDEN', 'revoked', httpStatus: 403);
    return holds[(query, number)]?.future ?? page(query, number);
  }
}

class _View extends ConsumerStatefulWidget {
  const _View({super.key, required this.source});
  final _Source source;
  @override
  ConsumerState<_View> createState() => _ViewState();
}

class _ViewState extends ConsumerState<_View>
    with ScopedPagedReadViewMixin<_View> {
  String query = 'A';
  int retirements = 0;
  final retirementCauses = <ApiException?>[];
  bool clearQueryOnRetirement = false;
  PagedResult<int>? accepted;
  int builds = 0;

  @override
  void scopedPagedReadOwnerChanged() {
    retirements++;
    retirementCauses.add(scopedPagedReadRejection);
    if (clearQueryOnRetirement) query = 'cleared';
    if (mounted) setState(() => accepted = null);
  }

  Future<PagedResult<int>> read(
    int page, {
    bool cached = false,
    Object slot = 'page',
    bool Function()? canPrefetch,
  }) {
    final frozen = query;
    return readScopedPage<int>(
      page,
      slot: slot,
      query: [widget.source, query],
      currentQuery: () => [widget.source, query],
      fetchPage: (number) => widget.source.fetch(frozen, number),
      useCache: cached,
      canPrefetch: canPrefetch,
    );
  }

  @override
  Widget build(BuildContext context) {
    builds++;
    return const SizedBox();
  }
}

Future<(_ViewState, ProviderContainer)> _mount(
  WidgetTester tester,
  _Source source, {
  ValueNotifier<bool>? visible,
}) async {
  final container = ProviderContainer(
    overrides: [exportContextEpochProvider.overrideWith(_Epoch.new)],
  );
  addTearDown(container.dispose);
  final key = GlobalKey<_ViewState>();
  final view = _View(key: key, source: source);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: visible == null
            ? view
            : ValueListenableBuilder<bool>(
                valueListenable: visible,
                builder: (_, active, _) =>
                    TickerMode(enabled: active, child: view),
              ),
      ),
    ),
  );
  return (key.currentState!, container);
}

Future<void> _drain(WidgetTester tester) async {
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets(
    'explicit preparation reuses only its existing typed slot without publishing UI',
    (tester) async {
      final source = _Source();
      final (view, _) = await _mount(tester, source);
      await view.prepareScopedNext<int>(1, slot: 'ledger');
      expect(source.calls, isEmpty);
      final accepted = await view.read(
        1,
        slot: 'ledger',
        canPrefetch: () => false,
      );
      view.accepted = accepted;
      await _drain(tester);
      final builds = view.builds;
      await view.prepareScopedNext<int>(1);
      await view.prepareScopedNext<String>(1, slot: 'ledger');
      await PagedReadIntent.bufferSeed(
        () => view.prepareScopedNext<int>(1, slot: 'ledger'),
      );
      await _drain(tester);
      expect(source.calls, [('A', 1)]);
      final prepared = view.prepareScopedNext<int>(1, slot: 'ledger');
      await _drain(tester);
      await prepared;
      expect(source.calls, [('A', 1), ('A', 2), ('A', 3)]);
      expect(view.accepted, same(accepted));
      expect(view.accepted?.page, 1);
      expect(view.builds, builds);
      await view.read(
        2,
        slot: 'ledger',
        cached: true,
        canPrefetch: () => false,
      );
      await _drain(tester);
      expect(source.calls, [('A', 1), ('A', 2), ('A', 3)]);
    },
  );

  testWidgets(
    'explicit preparation observes optional, ticker and route gates',
    (tester) async {
      final source = _Source();
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final (view, _) = await _mount(tester, source, visible: visible);
      await view.read(1, canPrefetch: () => false);
      await _drain(tester);
      var prepared = view.prepareScopedNext<int>(1, canPrepare: () => false);
      await _drain(tester);
      await prepared;
      visible.value = false;
      await tester.pump();
      prepared = view.prepareScopedNext<int>(1, canPrepare: () => true);
      await _drain(tester);
      await prepared;
      visible.value = true;
      await tester.pump();
      final navigator = Navigator.of(view.context);
      unawaited(
        navigator.push<void>(
          MaterialPageRoute(builder: (_) => const SizedBox()),
        ),
      );
      await tester.pumpAndSettle();
      prepared = view.prepareScopedNext<int>(1, canPrepare: () => true);
      await _drain(tester);
      await prepared;
      expect(source.calls, [('A', 1)]);
      navigator.pop();
      await tester.pumpAndSettle();
      prepared = view.prepareScopedNext<int>(1, canPrepare: () => true);
      await _drain(tester);
      await prepared;
      expect(source.calls, [('A', 1), ('A', 2), ('A', 3)]);
    },
  );

  for (final boundary in ['gate', 'ticker', 'query', 'owner', 'dispose']) {
    testWidgets('queued explicit preparation stops after $boundary changes', (
      tester,
    ) async {
      final source = _Source();
      final held = source.holds[('A', 2)] = Completer<PagedResult<int>>();
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final (view, container) = await _mount(tester, source, visible: visible);
      await view.read(1, canPrefetch: () => false);
      await _drain(tester);
      var canPrepare = true;
      final first = view.prepareScopedNext<int>(
        1,
        canPrepare: () => canPrepare,
      );
      await _drain(tester);
      final queued = view.prepareScopedNext<int>(
        2,
        canPrepare: () => canPrepare,
      );
      expect(source.calls, [('A', 1), ('A', 2)]);
      switch (boundary) {
        case 'gate':
          canPrepare = false;
        case 'ticker':
          visible.value = false;
        case 'query':
          view.query = 'B';
        case 'owner':
          (container.read(exportContextEpochProvider.notifier) as _Epoch)
              .advance();
        case 'dispose':
          await tester.pumpWidget(const SizedBox());
      }
      await tester.pump();
      held.complete(source.page('A', 2));
      await _drain(tester);
      await Future.wait([first, queued]);
      final retried = view.prepareScopedNext<int>(
        2,
        canPrepare: () => canPrepare,
      );
      await _drain(tester);
      await retried;
      expect(source.calls, [('A', 1), ('A', 2)]);
    });
  }

  testWidgets(
    'explicit preparation uses the existing current-rejection cause once',
    (tester) async {
      final source = _Source();
      final (view, _) = await _mount(tester, source);
      view.accepted = await view.read(1, canPrefetch: () => false);
      await _drain(tester);
      source.deny = true;
      final prepared = view.prepareScopedNext<int>(1);
      await _drain(tester);
      await prepared;
      expect(source.calls, [('A', 1), ('A', 2)]);
      expect(view.retirements, 1);
      expect(view.retirementCauses.single?.message, 'revoked');
      expect(view.accepted, isNull);
      expect(view.scopedPagedReadRejection, isNull);
      await view.prepareScopedNext<int>(1);
      await _drain(tester);
      expect(source.calls, [('A', 1), ('A', 2)]);
    },
  );

  testWidgets(
    'rejection cause is visible only inside the synchronous retirement hook',
    (tester) async {
      final source = _Source()..deny = true;
      final (view, _) = await _mount(tester, source);
      view.clearQueryOnRetirement = true;
      Object? rejected;
      try {
        await view.read(1);
      } catch (error) {
        rejected = error;
      }
      expect(rejected, isA<ApiException>());
      expect(view.retirements, 1);
      expect(view.retirementCauses.single, same(rejected));
      expect(view.scopedPagedReadRejection, isNull);
    },
  );

  testWidgets('owner changes carry no stale rejection cause', (tester) async {
    final source = _Source()..deny = true;
    final (view, container) = await _mount(tester, source);
    await expectLater(view.read(1), throwsA(isA<ApiException>()));
    expect(view.retirementCauses.single?.message, 'revoked');
    (container.read(exportContextEpochProvider.notifier) as _Epoch).advance();
    expect(view.retirements, 2);
    expect(view.retirementCauses.last, isNull);
    expect(view.scopedPagedReadRejection, isNull);
  });

  testWidgets(
    'a late denial from the old query cannot retire or label the new query',
    (tester) async {
      final source = _Source();
      final held = source.holds[('A', 1)] = Completer<PagedResult<int>>();
      final visible = ValueNotifier(false);
      addTearDown(visible.dispose);
      final (view, _) = await _mount(tester, source, visible: visible);
      final oldRead = view.read(1);
      final failure = ApiException(
        'FORBIDDEN',
        'old query denied',
        httpStatus: 403,
      );
      final handled = expectLater(oldRead, throwsA(same(failure)));
      view.query = 'B';
      view.accepted = await view.read(1);
      held.completeError(failure);
      await handled;
      await _drain(tester);
      expect(view.scopedPagedReadRejection, isNull);
      expect(view.retirementCauses, isEmpty);
      expect(view.retirements, 0);
      expect(view.accepted?.items, [1]);
    },
  );

  testWidgets('two prepared pages are reused; ordinary refresh stays fresh', (
    tester,
  ) async {
    final source = _Source();
    final (view, _) = await _mount(tester, source);
    await view.read(1);
    await _drain(tester);
    expect(source.calls, [('A', 1), ('A', 2), ('A', 3)]);
    await view.read(2, cached: true);
    await _drain(tester);
    expect(source.calls, [('A', 1), ('A', 2), ('A', 3)]);
    await view.read(1, cached: true);
    await _drain(tester);
    expect(source.calls, [('A', 1), ('A', 2), ('A', 3)]);
    await view.read(1);
    await _drain(tester);
    expect(source.calls, [
      ('A', 1),
      ('A', 2),
      ('A', 3),
      ('A', 1),
      ('A', 2),
      ('A', 3),
    ]);
  });

  testWidgets('input changes stop the old query before its debounce reload', (
    tester,
  ) async {
    final source = _Source();
    final held = source.holds[('A', 3)] = Completer<PagedResult<int>>();
    final (view, _) = await _mount(tester, source);
    await view.read(2);
    await _drain(tester);
    expect(source.calls, [('A', 2), ('A', 3)]);
    view.query = 'B';
    held.complete(source.page('A', 3));
    await _drain(tester);
    expect(source.calls, [
      ('A', 2),
      ('A', 3),
    ], reason: 'old previous-page read must not start');
    await view.read(2, cached: true);
    await _drain(tester);
    expect(source.calls, [('A', 2), ('A', 3), ('B', 2), ('B', 3), ('B', 1)]);
  });

  testWidgets('owner A-B-A retires data and cannot revive an old response', (
    tester,
  ) async {
    final source = _Source();
    final held = source.holds[('A', 1)] = Completer<PagedResult<int>>();
    final (view, container) = await _mount(tester, source);
    final pending = view.read(1);
    final rejected = expectLater(pending, throwsStateError);
    (container.read(exportContextEpochProvider.notifier) as _Epoch).advance();
    (container.read(exportContextEpochProvider.notifier) as _Epoch).advance();
    expect(view.retirements, 2);
    held.complete(source.page('A', 1));
    await rejected;
    source.holds.clear();
    await view.read(1, cached: true);
    await _drain(tester);
    expect(source.calls.where((call) => call == ('A', 1)), hasLength(2));
  });

  testWidgets('hidden views stop prefetch and denial retires accepted rows', (
    tester,
  ) async {
    final source = _Source();
    final visible = ValueNotifier(false);
    addTearDown(visible.dispose);
    final (view, _) = await _mount(tester, source, visible: visible);
    view.accepted = await view.read(1);
    await _drain(tester);
    expect(source.calls, [('A', 1)]);
    visible.value = true;
    await tester.pump();
    final prepared = view.prepareScopedNext<int>(1);
    await _drain(tester);
    await prepared;
    expect(source.calls, [('A', 1), ('A', 2), ('A', 3)]);
    source.deny = true;
    await expectLater(view.read(1), throwsA(isA<ApiException>()));
    expect(view.retirements, 1);
    expect(view.accepted, isNull);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
