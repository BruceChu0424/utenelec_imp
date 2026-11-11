import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_query_identity.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read_view_mixin.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

class _Epoch extends ExportContextEpoch {
  @override
  int build() => 0;
  void advance() => state++;
}

/// Serves one complete query of [total] rows as fixed server pages of
/// [pageSize]. Pages at or after [gatePage] park on [gate] so a test can
/// change the query while a read is still in flight.
class _Source {
  _Source({required this.total, required this.pageSize, this.gatePage});
  final int total;
  final int pageSize;
  final int? gatePage;
  final gate = Completer<void>();
  int fetches = 0;

  Future<PagedResult<int>> fetch(int page) async {
    fetches++;
    final gatedAt = gatePage;
    if (gatedAt != null && page >= gatedAt) await gate.future;
    final start = (page - 1) * pageSize;
    final count = (total - start).clamp(0, pageSize);
    return PagedResult<int>(
      items: List<int>.generate(count, (index) => start + index),
      page: page,
      size: pageSize,
      total: total,
      totalPages: (total + pageSize - 1) ~/ pageSize,
    );
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

  Future<PagedResult<int>> read() => readScopedPage<int>(
    1,
    query: [widget.source, query],
    currentQuery: () => [widget.source, query],
    fetchPage: widget.source.fetch,
  );

  @override
  Widget build(BuildContext context) => const SizedBox();
}

Future<GlobalKey<_ViewState>> _mount(
  WidgetTester tester,
  _Source source,
) async {
  final container = ProviderContainer(
    overrides: [exportContextEpochProvider.overrideWith(_Epoch.new)],
  );
  addTearDown(container.dispose);
  final key = GlobalKey<_ViewState>();
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: _View(key: key, source: source),
      ),
    ),
  );
  return key;
}

/// The complete read parks on real zero-delay timers whose number depends on
/// the real wall clock of the budget slice, so the harness pumps until the
/// observed future settles instead of a fixed number of frames.
Future<T> _drive<T>(WidgetTester tester, Future<T> future) async {
  var done = false;
  future.then((_) => done = true, onError: (_) => done = true);
  for (var round = 0; !done && round < 4000; round++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  return future;
}

void main() {
  testWidgets(
    'one complete read answers every ownership re-check of a synchronous segment with a single query compare',
    (tester) async {
      const rows = 600;
      final source = _Source(total: rows, pageSize: rows);
      final stats = ScopedReadCheckStats();
      debugScopedReadCheckStats = stats;
      addTearDown(() => debugScopedReadCheckStats = null);
      final key = await _mount(tester, source);
      stats.reset();
      final result = await _drive(tester, key.currentState!.read());
      expect(result.items.length, rows);
      expect(source.fetches, 1);
      // The fence itself stays hot: the loop still re-checks ownership around
      // every row and batch (checkpoint + row check ≈ 2 current calls/row).
      expect(stats.ownerChecks, greaterThan(rows * 3));
      expect(stats.epochReads, stats.queryCompares);
      // The deep query compare runs once per event-loop segment, not once per
      // re-check: even a worst-case segment per row keeps at least twice as
      // many re-checks as compares (a clean read re-checks ≈ per-row while it
      // compares once per await boundary), so a retirement can never skip a
      // segment and reuse can never fall back to per-check comparison.
      expect(
        stats.queryCompares * 2,
        lessThan(stats.ownerChecks),
        reason:
            'compares=${stats.queryCompares} re-checks=${stats.ownerChecks} '
            'loop checks=${stats.loopChecks}',
      );
      debugPrint(
        'scoped owner check budget: rows=$rows '
        're-checks=${stats.ownerChecks} compares=${stats.queryCompares} '
        'loop checks=${stats.loopChecks}',
      );
    },
  );

  testWidgets(
    'a mid-read query change still retires the old flight and the fresh read completes',
    (tester) async {
      const rows = 60;
      final source = _Source(total: rows, pageSize: 30, gatePage: 2);
      final key = await _mount(tester, source);
      final view = key.currentState!;
      final pending = view.read();
      final retired = expectLater(pending, throwsA(anything));
      // Let the first batch finish and the second batch park on the gate.
      for (var round = 0; round < 20; round++) {
        await tester.pump(const Duration(milliseconds: 1));
      }
      // The old flight is parked inside its gated second batch; change the
      // live query and start the next read, then release the gate.
      view.query = 'B';
      final fresh = view.read();
      source.gate.complete();
      await retired;
      final result = await _drive(tester, fresh);
      expect(result.items.length, rows);
    },
  );
}
