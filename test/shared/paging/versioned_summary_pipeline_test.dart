import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/paging/versioned_summary_read.dart';

class _Source {
  _Source(this.total, {this.held = false, this.invalid});
  final int total;
  final bool held;
  final String? invalid;
  final requests = <(int, int, String?)>[];
  final started = <int, Completer<void>>{};
  final gates = <int, Completer<void>>{};
  final completed = <int, Completer<void>>{};
  final owners = <int, bool Function()?>{};
  final finishOrder = <int>[];
  int active = 0, peak = 0, waves = 0;
  final failure = ApiException('NETWORK', '原始尾批失败', httpStatus: 503);
  static final revision = 'b' * 64;
  static const quantity = '90071992547409.123456789012345678901234';
  int get pages => (total + 99) ~/ 100;
  Completer<void> start(int page) =>
      started.putIfAbsent(page, Completer<void>.new);
  Completer<void> done(int page) =>
      completed.putIfAbsent(page, Completer<void>.new);
  Future<Map<String, dynamic>> read(
    int page,
    int size,
    String? revision,
  ) async {
    requests.add((page, size, revision));
    owners[page] = PagedReadIntent.currentRead;
    active++;
    if (active > peak) {
      peak = active;
    }
    start(page).complete();
    try {
      if (page > 1 && held) {
        await gates.putIfAbsent(page, Completer<void>.new).future;
      }
      if (page > 1 && !held) {
        await Future<void>.delayed(Duration.zero);
      }
      if (page == 3 && invalid == 'network') {
        throw failure;
      }
      return {
        'page': page,
        'size': size,
        'total': total,
        'totalPages': pages,
        'readScopeVersion': (page == 3 && invalid == 'scope' ? 'e' : 'a') * 64,
        'readSnapshotRevision': invalid == 'legacy'
            ? 'legacy-proof'
            : _Source.revision,
        if (invalid != 'legacy')
          'readDataVersion': (page == 3 && invalid == 'data' ? 'd' : 'c') * 64,
        'items': [
          for (var i = (page - 1) * size; i < page * size && i < total; i++)
            <String, dynamic>{
              'id': page == 3 && invalid == 'empty-id'
                  ? ''
                  : page == 3 && invalid == 'duplicate'
                  ? 'row-0'
                  : 'row-$i',
              'name': '原始中文货品第$i条',
              'quantity': quantity,
              'currencyId': 'original-currency',
              'writable': false,
            },
        ],
        'totals': [
          {
            'key': 'quantity',
            'label': '原始合计',
            'type': 'number',
            'groups': [
              {'unit': '件', 'value': quantity},
            ],
          },
        ],
      };
    } finally {
      active--;
      finishOrder.add(page);
      done(page).complete();
    }
  }

  Future<void> release(int page) async {
    await start(page).future;
    gates[page]!.complete();
    await done(page).future;
  }

  Future<void> releaseWaves() async {
    for (var first = 2; first <= pages; first += 4) {
      final last = first + 3 < pages ? first + 3 : pages;
      await Future.wait([
        for (var page = first; page <= last; page++) start(page).future,
      ]);
      waves++;
      for (var page = last; page >= first; page--) {
        await release(page);
      }
    }
  }
}

Future<VersionedSummarySnapshot<Map<String, dynamic>>> _read(
  _Source source, {
  bool Function()? current,
  int concurrency = 4,
}) => readVersionedSummarySnapshot<Map<String, dynamic>>(
  loadPage: source.read,
  isCurrent: current ?? () => true,
  maxConcurrentPages: concurrency,
  decode: (row) => Map<String, dynamic>.unmodifiable(row),
  idOf: (row) => row['id'],
);

void main() {
  for (final (total, pages, waves) in [(10001, 101, 26), (2414, 25, 7)]) {
    test(
      'complete$total keeps every tail/Chinese/exact value: $pages batches, $waves controlled RTT waves',
      () async {
        final source = _Source(total, held: true);
        final result = _read(source);
        final driver = source.releaseWaves();
        final snapshot = await result;
        await driver;
        expect(snapshot.items, hasLength(total));
        expect(
          snapshot.items.map((row) => row['id']).toSet(),
          hasLength(total),
        );
        for (var index = 0; index < total; index++) {
          expect(snapshot.items[index]['id'], 'row-$index');
          expect(snapshot.items[index]['name'], '原始中文货品第$index条');
          expect(snapshot.items[index]['quantity'], _Source.quantity);
          expect(snapshot.items[index]['currencyId'], 'original-currency');
          expect(snapshot.items[index]['writable'], isFalse);
        }
        expect(snapshot.items.last['id'], 'row-${total - 1}');
        expect(snapshot.page.total, total);
        expect(
          snapshot.page.totals.single.groups.single.valueText,
          _Source.quantity,
        );
        expect(
          source.requests.map((q) => q.$1),
          List.generate(pages, (i) => i + 1),
        );
        expect(source.requests.every((q) => q.$2 == 100), isTrue);
        expect(source.requests.first.$3, isNull);
        expect(
          source.requests.skip(1).every((q) => q.$3 == _Source.revision),
          isTrue,
        );
        expect(source.peak, 4);
        expect(source.waves + 1, waves);
        expect(source.finishOrder.take(5), [1, 5, 4, 3, 2]);
      },
    );
  }
  for (final invalid in ['network', 'scope', 'data', 'duplicate', 'empty-id']) {
    test(
      'later $invalid failure retires held earlier page and publishes no prefix',
      () async {
        final source = _Source(1001, held: true, invalid: invalid);
        var published = false;
        final result = _read(source).then((value) {
          published = true;
          return value;
        });
        final expected = expectLater(
          result,
          throwsA(
            invalid == 'network'
                // 真失败带匿名关联号后缀（read_failure_diagnostics）：原始 code
                // 与消息前缀原样到达，实例不再是同一个。
                ? isA<ApiException>()
                      .having((error) => error.code, 'code', 'NETWORK')
                      .having(
                        (error) => error.message,
                        'message',
                        startsWith('原始尾批失败'),
                      )
                : isA<ApiException>().having(
                    (e) => e.code,
                    'code',
                    invalid == 'scope'
                        ? 'READ_SCOPE_CHANGED'
                        : 'SNAPSHOT_CHANGED',
                  ),
          ),
        );
        await Future.wait([
          for (final page in [2, 3, 4, 5]) source.start(page).future,
        ]);
        await source.release(3);
        await expected;
        expect(
          source.gates[2]!.isCompleted,
          isFalse,
          reason: 'Failure cannot wait for the ordered head',
        );
        expect(published, isFalse);
        expect(source.requests.map((q) => q.$1), [1, 2, 3, 4, 5]);
        expect(
          source.owners.entries
              .where((e) => e.key > 1)
              .every((e) => e.value!() == false),
          isTrue,
        );
        for (final page in [2, 4, 5]) {
          await source.release(page);
        }
        expect(published, isFalse);
      },
    );
  }
  test(
    'identity/visibility retirement cancels continuation ownership without publishing',
    () async {
      final source = _Source(1001, held: true);
      var current = true, published = false;
      final result = _read(source, current: () => current).then((value) {
        published = true;
        return value;
      });
      final expected = expectLater(result, throwsA(isA<UiWorkCancelled>()));
      await Future.wait([
        for (final page in [2, 3, 4, 5]) source.start(page).future,
      ]);
      current = false;
      for (final page in [5, 4, 3, 2]) {
        await source.release(page);
      }
      await expected;
      expect(published, isFalse);
      expect(source.requests, hasLength(5));
    },
  );
  test(
    'only the bounded pending window is launched while its ordered head is held',
    () async {
      final source = _Source(601, held: true);
      final result = _read(source);
      await Future.wait([
        for (final page in [2, 3, 4, 5]) source.start(page).future,
      ]);
      for (final page in [5, 4, 3]) {
        await source.release(page);
      }
      expect(source.requests, hasLength(5));
      expect(source.started.containsKey(6), isFalse);
      await source.release(2);
      await Future.wait([source.start(6).future, source.start(7).future]);
      await source.release(7);
      await source.release(6);
      expect((await result).items.last['id'], 'row-600');
    },
  );
  test(
    'default remains serial even when a legacy summary has a version string',
    () async {
      final source = _Source(301, invalid: 'legacy');
      final result = await _read(source, concurrency: 1);
      expect(result.items, hasLength(301));
      expect(source.peak, 1);
      expect(source.requests, hasLength(4));
    },
  );
  test(
    'parallel opt-in refuses weak proof before scheduling any tail',
    () async {
      final source = _Source(301, invalid: 'legacy');
      await expectLater(
        _read(source),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'INCOMPLETE_READ_PROTOCOL',
          ),
        ),
      );
      expect(source.requests, hasLength(1));
    },
  );
  test(
    'public concurrent reader requires record identity before doing I/O',
    () async {
      var called = false;
      await expectLater(
        loadCompletePagedResult<Map<String, dynamic>>(
          maxConcurrentPages: 4,
          isCurrent: () => true,
          loadPage: (page, size) {
            called = true;
            throw StateError('Must not load');
          },
        ),
        throwsArgumentError,
      );
      expect(called, isFalse);
    },
  );
  test(
    'duplicate identities cannot become an accepted complete snapshot',
    () async {
      final source = _Source(401, invalid: 'duplicate');
      await expectLater(
        _read(source),
        throwsA(
          isA<ApiException>().having((e) => e.code, 'code', 'SNAPSHOT_CHANGED'),
        ),
      );
    },
  );
}
