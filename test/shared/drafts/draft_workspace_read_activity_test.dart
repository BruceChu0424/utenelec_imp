import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/drafts/draft_workspace_read.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

class _Source {
  int runs = 0;
  final calls = <(int, int)>[];
  final tail = Completer<PagedResult<int>>();
  Completer<void>? projection;

  PagedResult<int> page(int run, int number) => PagedResult(
    items: List.generate(100, (i) => run * 1000 + (number - 1) * 100 + i),
    page: number,
    size: 100,
    total: 300,
    totalPages: 3,
  );

  DraftWorkspaceRead<int> read({bool Function()? logicalCurrent}) =>
      DraftWorkspaceRead<int>(
        (owner) async {
          final run = ++runs;
          await owner.loadPages<int>(
            (number, size) {
              calls.add((run, number));
              return run == 1 && number == 2
                  ? tail.future
                  : Future.value(page(run, number));
            },
            (rows) async {
              if (projection != null) await projection!.future;
              return rows;
            },
          );
        },
        keyOf: (row) => row,
        ownerCurrent: logicalCurrent,
      );
}

class _Host extends StatelessWidget {
  const _Host(this.read);
  final DraftWorkspaceRead<int> read;
  @override
  Widget build(BuildContext context) {
    read.bindView(context);
    return const SizedBox();
  }
}

Future<void> _mount(
  WidgetTester tester,
  DraftWorkspaceRead<int> read,
  ValueNotifier<bool> active,
) => tester.pumpWidget(
  MaterialApp(
    home: ValueListenableBuilder<bool>(
      valueListenable: active,
      builder: (_, enabled, _) =>
          TickerMode(enabled: enabled, child: _Host(read)),
    ),
  ),
);

Future<void> _drain(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 5));
  }
}

void main() {
  test(
    'a cached complete family cannot outlive its logical owner without disposal',
    () async {
      var owner = true;
      final read = DraftWorkspaceRead<int>(
        (target) async => target.addRows([1]),
        ownerCurrent: () => owner,
      );
      addTearDown(read.dispose);
      read.start();
      expect(await read.completion, [1]);
      owner = false;
      await expectLater(
        read.completion,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'READ_SCOPE_CHANGED',
          ),
        ),
      );
    },
  );

  testWidgets(
    'snapshot-only hidden draft family stops its tail and never declares partial completion',
    (tester) async {
      final source = _Source(), active = ValueNotifier(true);
      final read = source.read();
      addTearDown(() {
        read.dispose();
        active.dispose();
      });
      await _mount(tester, read, active);
      read.start();
      await _drain(tester);
      await read.firstPage;
      expect(read.snapshot.rows, hasLength(100));
      expect(read.snapshot.complete, isFalse);
      active.value = false;
      await _drain(tester);
      source.tail.complete(source.page(1, 2));
      await _drain(tester);
      expect(source.calls, [(1, 1), (1, 2)]);
      expect(read.snapshot.rows, hasLength(100));
      expect(read.snapshot.complete, isFalse);
      expect(read.snapshot.error, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'explicit complete-set consumer keeps a shared draft family alive while its UI is hidden',
    (tester) async {
      final source = _Source(), active = ValueNotifier(true);
      final read = source.read();
      addTearDown(() {
        read.dispose();
        active.dispose();
      });
      await _mount(tester, read, active);
      read.start();
      await _drain(tester);
      final complete = read.completion;
      active.value = false;
      await _drain(tester);
      source.tail.complete(source.page(1, 2));
      await _drain(tester);
      expect(await complete, hasLength(300));
      expect(source.calls, [(1, 1), (1, 2), (1, 3)]);
      expect(read.snapshot.complete, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background demand after retirement reads fresh without reviving or publishing the old ticket',
    (tester) async {
      final source = _Source(), active = ValueNotifier(true);
      final read = source.read();
      addTearDown(() {
        read.dispose();
        active.dispose();
      });
      await _mount(tester, read, active);
      read.start();
      await _drain(tester);
      active.value = false;
      await _drain(tester);
      final complete = read.completion;
      await _drain(tester);
      final rows = await complete;
      expect(rows, hasLength(300));
      expect(rows.first, 2000);
      expect(source.calls, [(1, 1), (1, 2), (2, 1), (2, 2), (2, 3)]);
      source.tail.complete(source.page(1, 2));
      await _drain(tester);
      expect(read.snapshot.complete, isTrue);
      expect(read.snapshot.rows.first, 2000);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a projected page cannot publish after an async name/enrichment yield loses view demand',
    (tester) async {
      final source = _Source()..projection = Completer<void>();
      final active = ValueNotifier(true), read = source.read();
      addTearDown(() {
        read.dispose();
        active.dispose();
      });
      await _mount(tester, read, active);
      read.start();
      await _drain(tester);
      active.value = false;
      await _drain(tester);
      source.projection!.complete();
      await _drain(tester);
      expect(read.snapshot.rows, isEmpty);
      expect(read.snapshot.complete, isFalse);
      expect(source.calls, [(1, 1)]);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an initially inactive pane sends no speculative read while an explicit complete consumer gets every batch',
    (tester) async {
      final source = _Source(), active = ValueNotifier(false);
      final read = source.read();
      addTearDown(() {
        read.dispose();
        active.dispose();
      });
      await _mount(tester, read, active);
      read.start();
      await _drain(tester);
      expect(source.calls, isEmpty);
      expect(read.snapshot.complete, isFalse);
      expect(read.snapshot.rows, isEmpty);
      final completion = read.completion;
      await _drain(tester);
      expect(source.calls, [(1, 1), (1, 2)]);
      source.tail.complete(source.page(1, 2));
      await _drain(tester);
      final rows = await completion;
      expect(rows, hasLength(300));
      expect(rows.first, 1000);
      expect(rows.last, 1299);
      expect(rows.toSet(), hasLength(300));
      expect(source.calls, [(1, 1), (1, 2), (1, 3)]);
      expect(read.snapshot.complete, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'background demand never bypasses disposal or the logical family owner',
    (tester) async {
      final source = _Source(), active = ValueNotifier(true);
      var owner = true;
      final read = source.read(logicalCurrent: () => owner);
      addTearDown(() {
        read.dispose();
        active.dispose();
      });
      await _mount(tester, read, active);
      read.start();
      await _drain(tester);
      final complete = read.completion;
      final rejected = expectLater(
        complete,
        throwsA(
          isA<ApiException>().having(
            (error) => error.code,
            'code',
            'READ_SCOPE_CHANGED',
          ),
        ),
      );
      active.value = false;
      owner = false;
      read.dispose();
      source.tail.complete(source.page(1, 2));
      await _drain(tester);
      await rejected;
      expect(source.calls, [(1, 1), (1, 2)]);
      expect(read.current, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
