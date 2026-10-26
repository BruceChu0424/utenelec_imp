import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/components/data_display/paged_list_controller.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

PagedReadSnapshot<String, String> page(
  int number, {
  String value = 'fresh',
  int pages = 4,
}) => PagedReadSnapshot(
  page: PagedResult(
    items: pages == 0 ? <String>[] : ['$value-$number'],
    page: number,
    size: 10,
    total: pages * 10,
    totalPages: pages,
  ),
  snapshot: 'metadata-$value-$number',
  revision: value,
);

Future<
  ({
    ScopedPagedRead<String> reader,
    PagedReadWindowBinding<String> binding,
    int Function() visible,
    void Function(int) move,
  })
>
fixture({List<int> retained = const [1, 2, 3]}) async {
  final reader = ScopedPagedRead<String>();
  var visible = retained[0];
  late PagedResult<String> last;
  for (final number in retained) {
    last = await reader.read(
      number,
      scope: 'query',
      fetchPage: (p) async => page(p, value: 'old'),
      isCurrent: () => true,
      useCache: true,
      canPrefetch: () => false,
    );
  }
  final binding = readWindowBindingOf(last.items)!;
  binding.attachPresentation(
    Object(),
    retainedPages: () => retained,
    visiblePage: () => visible,
    isCurrent: () => true,
  );
  return (
    reader: reader,
    binding: binding,
    visible: () => visible,
    move: (p) => visible = p,
  );
}

void main() {
  test(
    'opted-in controller uses the same atomic window helper while its original typed payload survives',
    () async {
      final controller = PagedListController<String>();
      addTearDown(controller.dispose);
      var fresh = false;
      final reads = <int>[];
      Future<PagedResult<String>> fetch(int p) async {
        reads.add(p);
        return page(p, value: fresh ? 'fresh' : 'old');
      }

      Future<void> load(int p, {bool cached = false}) => controller.load(
        p,
        fetch: () => fetch(p),
        fetchPage: fetch,
        queryScope: 'query',
        isCurrent: () => true,
        useCachedPage: cached,
        canPrefetch: () => false,
      );
      await load(1);
      await load(2, cached: true);
      await load(3, cached: true);
      final binding = readWindowBindingOf(controller.page!.items)!;
      binding.attachPresentation(
        Object(),
        retainedPages: () => [1, 2, 3],
        visiblePage: () => 2,
        isCurrent: () => true,
      );
      fresh = true;
      reads.clear();
      await load(2);
      expect(reads, [2, 1, 3]);
      expect(controller.page!.page, 2);
      expect(controller.page, isA<PagedReadSnapshot<String, String>>());
      expect(readWindowBindingOf(controller.page!.items)!.replacementPages, {
        1: ['fresh-1'],
        2: ['fresh-2'],
        3: ['fresh-3'],
      });
    },
  );

  test(
    'fresh retained window stays private and selects the live reading page with its complete original payload',
    () async {
      final f = await fixture();
      addTearDown(f.reader.dispose);
      final gates = {
        for (final p in [1, 2, 3]) p: Completer<PagedResult<String>>(),
      };
      final reads = <int>[];
      final pending = f.reader.read(
        1,
        scope: 'query',
        fetchPage: (p) {
          reads.add(p);
          return gates[p]!.future;
        },
        isCurrent: () => true,
        canPrefetch: () => false,
      );
      expect(f.binding.pending, isTrue);
      final first = page(1);
      gates[1]!.complete(first);
      await Future<void>.delayed(Duration.zero);
      expect(reads, [1, 2]);
      expect(f.binding.pending, isTrue);
      f.move(2);
      final second = page(2);
      gates[2]!.complete(second);
      await Future<void>.delayed(Duration.zero);
      gates[3]!.complete(page(3));
      final result = await pending;
      expect(result, same(second));
      expect(
        (result as PagedReadSnapshot<String, String>).snapshot,
        'metadata-fresh-2',
      );
      expect(readWindowBindingOf(result.items)!.replacementPages, {
        1: ['fresh-1'],
        2: ['fresh-2'],
        3: ['fresh-3'],
      });
      expect(f.binding.pending, isFalse);
      expect(f.binding.isCurrent, isTrue);
    },
  );

  test(
    'ordinary window failure retains the accepted window and clears pending',
    () async {
      final f = await fixture();
      addTearDown(f.reader.dispose);
      await expectLater(
        f.reader.read(
          1,
          scope: 'query',
          fetchPage: (p) async {
            if (p == 2) throw StateError('offline');
            return page(p);
          },
          isCurrent: () => true,
          canPrefetch: () => false,
        ),
        throwsStateError,
      );
      expect(f.binding.pending, isFalse);
      expect(f.binding.failed, isTrue);
      expect(f.binding.isCurrent, isTrue);
    },
  );

  test(
    'confirmed window rejection retires every accepted private binding',
    () async {
      final f = await fixture();
      addTearDown(f.reader.dispose);
      await expectLater(
        f.reader.read(
          1,
          scope: 'query',
          fetchPage: (_) async =>
              throw ApiException('FORBIDDEN', 'revoked', httpStatus: 403),
          isCurrent: () => true,
        ),
        throwsA(isA<ApiException>()),
      );
      expect(f.binding.isCurrent, isFalse);
    },
  );

  test(
    'empty authoritative refresh marks old bindings empty without attaching shared empty lists',
    () async {
      final f = await fixture();
      addTearDown(f.reader.dispose);
      final result = await f.reader.read(
        1,
        scope: 'query',
        fetchPage: (p) async => page(p, pages: 0),
        isCurrent: () => true,
        canPrefetch: () => false,
      );
      expect(result.items, isEmpty);
      expect(f.binding.empty, isTrue);
      expect(readWindowBindingOf(result.items), isNull);
    },
  );

  test(
    'deletion beyond the last page replaces the entire old window with the new valid last page',
    () async {
      final f = await fixture(retained: [78, 79, 80]);
      addTearDown(f.reader.dispose);
      f.move(79);
      final reads = <int>[];
      final result = await f.reader.read(
        79,
        scope: 'query',
        fetchPage: (p) async {
          reads.add(p);
          return page(p, pages: 2);
        },
        isCurrent: () => true,
        canPrefetch: () => false,
      );
      expect(reads, [79, 2]);
      expect(result.page, 2);
      expect(readWindowBindingOf(result.items)!.replacementPages, {
        2: ['fresh-2'],
      });
    },
  );

  test(
    'navigation during pending refresh adopts the completed fresh window before appending a page',
    () async {
      final f = await fixture();
      addTearDown(f.reader.dispose);
      final gate = Completer<PagedResult<String>>();
      final reads = <int>[];
      Future<PagedResult<String>> fetch(int p) async {
        reads.add(p);
        return p == 1 ? gate.future : page(p);
      }

      final refresh = f.reader.read(
        1,
        scope: 'query',
        fetchPage: fetch,
        isCurrent: () => true,
        canPrefetch: () => false,
      );
      f.move(3);
      final navigation = PagedReadIntent.navigation(
        3,
        () => f.reader.read(
          4,
          scope: 'query',
          fetchPage: fetch,
          isCurrent: () => true,
          useCache: true,
          canPrefetch: () => false,
        ),
      );
      expect(reads, [1]);
      gate.complete(page(1));
      await refresh;
      final result = await navigation;
      expect(reads, [1, 2, 3, 4]);
      expect(readWindowBindingOf(result.items)!.replacementPages, {
        1: ['fresh-1'],
        2: ['fresh-2'],
        3: ['fresh-3'],
        4: ['fresh-4'],
      });
    },
  );

  test(
    'explicit goto supersedes a pending window and never inherits its replacement',
    () async {
      final f = await fixture();
      addTearDown(f.reader.dispose);
      final gate = Completer<PagedResult<String>>();
      final refresh = f.reader.read(
        1,
        scope: 'query',
        fetchPage: (_) => gate.future,
        isCurrent: () => true,
        canPrefetch: () => false,
      );
      final rejected = expectLater(refresh, throwsStateError);
      final destination = await PagedReadIntent.navigation(
        1,
        () => f.reader.read(
          79,
          scope: 'query',
          fetchPage: (p) async => page(p, pages: 80),
          isCurrent: () => true,
          useCache: true,
          canPrefetch: () => false,
        ),
        replaceWindow: true,
      );
      expect(destination.page, 79);
      expect(readWindowBindingOf(destination.items)!.replacementPages, isNull);
      gate.complete(page(1));
      await rejected;
    },
  );

  test(
    'a query boundary retires a pending window and rejects its late receipt',
    () async {
      final f = await fixture();
      addTearDown(f.reader.dispose);
      final gate = Completer<PagedResult<String>>();
      final refresh = f.reader.read(
        1,
        scope: 'query',
        fetchPage: (_) => gate.future,
        isCurrent: () => true,
      );
      final rejected = expectLater(refresh, throwsStateError);
      final changed = await f.reader.read(
        1,
        scope: 'different query',
        fetchPage: (p) async => page(p, value: 'B'),
        isCurrent: () => true,
        canPrefetch: () => false,
      );
      expect(f.binding.isCurrent, isFalse);
      expect(readWindowBindingOf(changed.items)!.replacementPages, isNull);
      gate.complete(page(1));
      await rejected;
    },
  );
}
