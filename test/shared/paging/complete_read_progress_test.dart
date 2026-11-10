import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/paging/complete_read_progress.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

/// 顶部加载进度通知的上游事件（2026-11-09）：只有发布渐进批次的完整读取
/// 才上报进度；分子 = 已验证累计行数，分母 = 服务端精确 total；取消/退休/
/// 失败一律 failed；归属（ScopedPagedRead）被退休时任务立即收尾。

/// An offset-exact server: page `p` of size `s` returns rows (p-1)*s … p*s-1.
class _OffsetServer {
  _OffsetServer(this.total);
  final int total;
  final requests = <(int, int)>[];
  Completer<void>? gate;

  Future<PagedResult<String>> load(int page, int size) async {
    requests.add((page, size));
    // 可选闸门：从第二批起挂起，模拟网络在途。
    if (requests.length >= 2) {
      if (gate case final pending?) await pending.future;
    }
    final start = (page - 1) * size;
    final end = (start + size).clamp(0, total);
    return PagedResult<String>(
      items: [for (var i = start; i < end; i++) 'row-$i'],
      page: page,
      size: size,
      total: total,
      totalPages: total == 0 ? 0 : (total + size - 1) ~/ size,
      readScopeVersion: 'scope-a',
    );
  }
}

UiWorkBudget _unbounded({bool Function()? isCurrent}) => UiWorkBudget(
  slice: const Duration(days: 1),
  maxItems: 1 << 30,
  isCurrent: isCurrent,
);

PagedResult<String> _page(int page, int size, int total) => PagedResult<String>(
  items: [
    for (
      var i = (page - 1) * size;
      i < (page - 1) * size + size && i < total;
      i++
    )
      'row-$i',
  ],
  page: page,
  size: size,
  total: total,
  totalPages: total == 0 ? 0 : (total + size - 1) ~/ size,
  readScopeVersion: 'scope-a',
);

void main() {
  test(
    'progressive complete read reports cumulative rows and server total',
    () async {
      final events = <CompleteReadProgressEvent>[];
      CompleteReadProgressReporter.addListener(events.add);
      final server = _OffsetServer(250);
      final result = await loadCompletePagedResult<String>(
        loadPage: (page, size) => server.load(page, size),
        isCurrent: () => true,
        idOf: (row) => row,
        budget: _unbounded(),
        onProgressiveBatch: (_) {},
      );
      expect(result.items.length, 250);
      CompleteReadProgressReporter.removeListener(events.add);
      expect(events.map((e) => e.phase), [
        CompleteReadProgressPhase.started,
        ...List.filled(4, CompleteReadProgressPhase.batch),
        CompleteReadProgressPhase.succeeded,
      ]);
      expect(
        events
            .where((e) => e.phase == CompleteReadProgressPhase.batch)
            .map((e) => (e.loaded, e.total)),
        [(50, 250), (100, 250), (200, 250), (250, 250)],
        reason: '50/50/100/200 是每批新增行数；loaded 是累计已验证行数',
      );
    },
  );

  test('unknown-total read reports total=null (indeterminate)', () async {
    final events = <CompleteReadProgressEvent>[];
    CompleteReadProgressReporter.addListener(events.add);
    // 固定 100 批、总量恒 -1（两页：100 + 50 行），totalPages 恒 2。
    await loadCompletePagedResult<String>(
      loadPage: (page, size) async => PagedResult<String>(
        items: [
          for (
            var i = (page - 1) * size;
            i < (page - 1) * size + (page == 2 ? 50 : size);
            i++
          )
            'row-$i',
        ],
        page: page,
        size: size,
        total: -1,
        totalPages: 2,
        readScopeVersion: 'scope-a',
      ),
      isCurrent: () => true,
      idOf: (row) => row,
      budget: _unbounded(),
      requireStableTotal: false,
      allowUnknownTotal: true,
      onProgressiveBatch: (_) {},
    );
    CompleteReadProgressReporter.removeListener(events.add);
    final batches = events
        .where((e) => e.phase == CompleteReadProgressPhase.batch)
        .toList();
    expect(batches, isNotEmpty);
    expect(
      batches.every((e) => e.total == null),
      isTrue,
      reason: '无可靠总量时上报 null，界面走不定进度，不编造百分比',
    );
    expect(events.last.phase, CompleteReadProgressPhase.succeeded);
    expect(events.last.total, isNull);
  });

  test('reads without a progressive slot never report', () async {
    final events = <CompleteReadProgressEvent>[];
    CompleteReadProgressReporter.addListener(events.add);
    await loadCompletePagedResult<String>(
      loadPage: (page, size) async => _page(page, size, 120),
      isCurrent: () => true,
      idOf: (row) => row,
      budget: _unbounded(),
    );
    expect(events, isEmpty, reason: '辅助完整读取（facets 等）不上报进度');
    CompleteReadProgressReporter.removeListener(events.add);
  });

  test('failure and retirement both end as failed', () async {
    final events = <CompleteReadProgressEvent>[];
    CompleteReadProgressReporter.addListener(events.add);
    await expectLater(
      loadCompletePagedResult<String>(
        loadPage: (page, size) async {
          if (page == 1) return _page(page, size, 250);
          throw ApiException('BOOM', '读取失败');
        },
        isCurrent: () => true,
        idOf: (row) => row,
        budget: _unbounded(),
        onProgressiveBatch: (_) {},
      ),
      throwsA(isA<ApiException>()),
    );
    expect(events.last.phase, CompleteReadProgressPhase.failed);

    events.clear();
    var current = true;
    await expectLater(
      loadCompletePagedResult<String>(
        loadPage: (page, size) async {
          if (page == 1) return _page(page, size, 250);
          current = false; // 批次之间被退休
          return _page(page, size, 250);
        },
        isCurrent: () => current,
        idOf: (row) => row,
        budget: _unbounded(),
        onProgressiveBatch: (_) {},
      ),
      throwsA(anything),
    );
    expect(events.last.phase, CompleteReadProgressPhase.failed);
    CompleteReadProgressReporter.removeListener(events.add);
  });

  test(
    'retiring a ScopedPagedRead cancels its progress task at once',
    () async {
      final events = <CompleteReadProgressEvent>[];
      CompleteReadProgressReporter.addListener(events.add);
      final reader = ScopedPagedRead<String>(idOf: (row) => row);
      final server = _OffsetServer(400)..gate = Completer<void>();
      final read = reader.read(
        1,
        scope: 'q1',
        fetchPage: (page) => server.load(page, 400),
        fetchPageSized: (page, size) => server.load(page, size),
        isCurrent: () => true,
        onProgressiveBatch: (_) {},
      );
      // 第一批立即上报；第二批被闸门挂在网络上。
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(
        events.any((e) => e.phase == CompleteReadProgressPhase.batch),
        isTrue,
        reason: '首批即刻上报真实计数',
      );

      reader.invalidate(); // 用户切页 / 查询条件变化
      expect(
        events.last.phase,
        CompleteReadProgressPhase.failed,
        reason: '退休立即收尾提示，不等迟到的网络返回',
      );
      server.gate!.complete();
      await expectLater(read, throwsA(anything));
      // 恰好一次 failed：迟到的错误路径不得重复收尾。
      expect(
        events.where((e) => e.phase == CompleteReadProgressPhase.failed).length,
        1,
      );
      CompleteReadProgressReporter.removeListener(events.add);
    },
  );

  test(
    'cursor history read reports indeterminate progress (total=null)',
    () async {
      final events = <CompleteReadProgressEvent>[];
      CompleteReadProgressReporter.addListener(events.add);
      await loadCompleteCursorSnapshot<String, PagedResult<String>, int>(
        loadPage: (cursor, size) async {
          final start = cursor ?? 0;
          return PagedResult<String>(
            items: [
              for (var i = start; i < start + size && i < 450; i++) 'row-$i',
            ],
            page: start ~/ size + 1,
            size: size,
            total: 450,
            totalPages: (450 + size - 1) ~/ size,
            readScopeVersion: 'scope-a',
          );
        },
        rowsOf: (page) => page.items,
        nextCursorOf: (page) =>
            page.items.isEmpty || page.items.last == 'row-449'
            ? null
            : int.parse(page.items.last.split('-')[1]) + 1,
        rebuildSnapshot: (first, rows) => first.withRows(
          rows,
          page: 1,
          size: rows.length,
          total: rows.length,
          totalPages: 1,
        ),
        isCurrent: () => true,
        idOf: (row) => row,
        onBatch: (rows, hasMore) {},
      );
      CompleteReadProgressReporter.removeListener(events.add);
      expect(events.first.phase, CompleteReadProgressPhase.started);
      final batches = events
          .where((e) => e.phase == CompleteReadProgressPhase.batch)
          .toList();
      // Cursor history batches: a small first batch, then continuations at the
      // bounded maximum (2026-11-09: 200→1000, so this 450-row history completes
      // in one 400-row continuation after the first 50).
      const plan = CompleteReadBatchPlan.progressive;
      final expectedLoaded = <int>[plan.firstBatchSize];
      for (
        var loaded = plan.firstBatchSize;
        loaded < 450;
        loaded += plan.maxBatchSize
      ) {
        expectedLoaded.add((loaded + plan.maxBatchSize).clamp(0, 450));
      }
      expect(batches.map((e) => e.loaded), expectedLoaded);
      expect(
        batches.every((e) => e.total == null),
        isTrue,
        reason: '游标无总量语义：一律不定进度，不编造百分比',
      );
      expect(events.last.phase, CompleteReadProgressPhase.succeeded);
    },
  );

  test(
    'silent reread of an accepted result creates no new progress task',
    () async {
      final events = <CompleteReadProgressEvent>[];
      CompleteReadProgressReporter.addListener(events.add);
      final server = _OffsetServer(120);
      final reader = ScopedPagedRead<String>(idOf: (row) => row);
      Future<PagedResult<String>> readOnce() => reader.read(
        1,
        scope: 'q1',
        fetchPage: (page) => server.load(page, 120),
        fetchPageSized: (page, size) => server.load(page, size),
        isCurrent: () => true,
        onProgressiveBatch: (_) {},
      );
      await readOnce();
      final tasksAfterFirst = events
          .where((e) => e.phase == CompleteReadProgressPhase.started)
          .length;
      // 同查询重读：已接受结果在场，渐进槽不复用，不再开新进度任务。
      await readOnce();
      final tasksAfterSecond = events
          .where((e) => e.phase == CompleteReadProgressPhase.started)
          .length;
      expect(tasksAfterSecond, tasksAfterFirst);
      CompleteReadProgressReporter.removeListener(events.add);
    },
  );
}
