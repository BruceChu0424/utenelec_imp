import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
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

// The former preparation/adjacent-window assertions are replaced by complete reads.
void main() {
  testWidgets(
    'a view receives all internal batches once and local reuse never fetches another page',
    (tester) async {
      final source = _Source();
      final (view, _) = await _mount(tester, source);
      final pending = view.read(1);
      await _drain(tester);
      final result = await pending;
      expect(result.items, [1, 2, 3]);
      expect((result.page, result.totalPages), (1, 1));
      expect(source.calls, [('A', 1), ('A', 2), ('A', 3)]);
      final reused = view.read(9, cached: true);
      await _drain(tester);
      expect((await reused).items, [1, 2, 3]);
      expect(source.calls.length, 3);
      final fresh = view.read(1);
      await _drain(tester);
      await fresh;
      expect(source.calls.length, 6);
    },
  );
  testWidgets(
    'different typed slots and query identities cannot reuse another accepted result',
    (tester) async {
      final source = _Source();
      final (view, _) = await _mount(tester, source);
      final first = view.read(1, slot: 'ledger');
      await _drain(tester);
      await first;
      final second = view.read(1, slot: 'trace', cached: true);
      await _drain(tester);
      await second;
      view.query = 'B';
      final changed = view.read(1, slot: 'ledger', cached: true);
      await _drain(tester);
      await changed;
      expect(source.calls, [
        ('A', 1),
        ('A', 2),
        ('A', 3),
        ('A', 1),
        ('A', 2),
        ('A', 3),
        ('B', 1),
        ('B', 2),
        ('B', 3),
      ]);
    },
  );
  testWidgets(
    'owner ABA retires a held middle batch and prevents it from finishing the old read',
    (tester) async {
      final source = _Source();
      final gate = Completer<PagedResult<int>>();
      source.holds[('A', 2)] = gate;
      final (view, container) = await _mount(tester, source);
      final pending = view.read(1);
      final rejected = expectLater(pending, throwsA(anything));
      await _drain(tester);
      (container.read(exportContextEpochProvider.notifier) as _Epoch).advance();
      await _drain(tester);
      gate.complete(source.page('A', 2));
      await _drain(tester);
      await rejected;
      expect(source.calls, [('A', 1), ('A', 2)]);
      expect(view.retirements, 1);
      source.holds.clear();
      final fresh = view.read(1);
      await _drain(tester);
      expect((await fresh).items, [1, 2, 3]);
    },
  );
  testWidgets(
    'an access rejection retires accepted private data and reports the original cause exactly once',
    (tester) async {
      final source = _Source();
      final (view, _) = await _mount(tester, source);
      final first = view.read(1);
      await _drain(tester);
      view.accepted = await first;
      source.deny = true;
      view.clearQueryOnRetirement = true;
      final rejected = expectLater(view.read(1), throwsA(isA<ApiException>()));
      await _drain(tester);
      await rejected;
      expect(view.accepted, isNull);
      expect(view.retirements, 1);
      expect(view.retirementCauses.single?.code, 'FORBIDDEN');
      expect(view.query, 'cleared');
    },
  );
}
