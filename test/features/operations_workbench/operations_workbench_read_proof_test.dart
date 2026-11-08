import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/operations_workbench/models/operations_workbench.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/complete_paged_snapshot.dart';
import 'package:uten_imp/shared/paging/scoped_paged_read.dart';

import '../../helpers/workbench_read_fixture.dart';

/// The workbench complete read joins the bounded concurrent pipeline only
/// through the server's per-batch read proof (V1123 `fulfillment-workbench`).
void main() {
  Map<String, dynamic> pageJson(
    int page,
    int size,
    int total, {
    String revision = 'r1',
    bool proof = true,
  }) {
    final start = (page - 1) * size;
    final count = (total - start).clamp(0, size);
    return {
      'items': [
        for (var i = 0; i < count; i++)
          {
            'taskId': 'task-${start + i + 1}',
            'supplyRoute': 'PURCHASE',
            'taskStatus': 'WAITING_ORDER',
          },
      ],
      'page': page,
      'size': size,
      'total': total,
      'totalPages': total == 0 ? 0 : (total + size - 1) ~/ size,
      'metadataIncluded': page == 1,
      if (page == 1)
        'summary': {
          'totalTasks': total,
          'overdueTasks': 0,
          'openTasks': total,
          'openQty': total,
          'statusCounts': {'WAITING_ORDER': total},
        },
      'readScopeVersion': 'scope-1',
      if (proof) 'readSnapshotRevision': workbenchReadProof(revision),
      if (proof) 'readDataVersion': workbenchReadProof('data-$revision'),
    };
  }

  OperationsWorkbenchData parse(Map<String, dynamic> json) =>
      OperationsWorkbenchData.fromJson(
        json,
        OperationsWorkbenchDepartment.purchase,
      );

  test('every parsed workbench batch carries the server read proof', () {
    final snapshot = parse(pageJson(1, 100, 3)).toPagedReadSnapshot();
    expect(snapshot, isA<VersionedPagedResultProof>());
    final proof = snapshot as VersionedPagedResultProof;
    expect(proof.readSnapshotRevision, workbenchReadProof('r1'));
    expect(proof.readDataVersion, workbenchReadProof('data-r1'));
    // A local rebuild of the accepted result keeps the same proof and the
    // typed snapshot's rows.
    final rebuilt = snapshot.withRows(snapshot.items.take(2).toList());
    expect(rebuilt, isA<VersionedPagedResultProof>());
    expect(
      (rebuilt as VersionedPagedResultProof).readSnapshotRevision,
      proof.readSnapshotRevision,
    );
    expect(rebuilt.snapshot.items.map((row) => row.taskId), [
      'task-1',
      'task-2',
    ]);
  });

  test(
    'two continuation batches are in flight and the result keeps server order',
    () async {
      final pending = <int, Completer<void>>{};
      var inFlight = 0, peak = 0;
      final requested = <int>[];
      final read = loadCompletePagedResult<OperationsWorkbenchTask>(
        isCurrent: () => true,
        maxConcurrentPages: 2,
        idOf: (row) => row.taskId,
        loadPage: (page, size) async {
          requested.add(page);
          inFlight++;
          peak = peak < inFlight ? inFlight : peak;
          if (page > 1) {
            final gate = pending[page] = Completer<void>();
            await gate.future;
          }
          inFlight--;
          return parse(pageJson(page, size, 350)).toPagedReadSnapshot();
        },
      );
      await pumpEventQueue();
      expect(requested, [1, 2, 3], reason: 'two tails scheduled at once');
      // Release out of order; the validator still publishes rows 1..350.
      pending[3]!.complete();
      await pumpEventQueue();
      pending[2]!.complete();
      await pumpEventQueue();
      pending[4]!.complete();
      final result = await read;
      expect(peak, 2);
      expect(result.items, hasLength(350));
      expect(result.items.first.taskId, 'task-1');
      expect(result.items.last.taskId, 'task-350');
      final typed =
          (result
                  as PagedReadSnapshot<
                    OperationsWorkbenchTask,
                    OperationsWorkbenchData
                  >)
              .snapshot;
      expect(typed.summary.totalTasks, 350, reason: 'first batch metadata');
      expect(typed.items, hasLength(350));
    },
  );

  test('a batch from a moved data version retires the whole read', () async {
    await expectLater(
      loadCompletePagedResult<OperationsWorkbenchTask>(
        isCurrent: () => true,
        maxConcurrentPages: 2,
        idOf: (row) => row.taskId,
        loadPage: (page, size) async => parse(
          pageJson(page, size, 250, revision: page == 3 ? 'r2' : 'r1'),
        ).toPagedReadSnapshot(),
      ),
      throwsA(
        isA<ApiException>().having((e) => e.code, 'code', 'SNAPSHOT_CHANGED'),
      ),
    );
  });

  test(
    'a batch without proof is refused before any tail is scheduled',
    () async {
      final requested = <int>[];
      await expectLater(
        loadCompletePagedResult<OperationsWorkbenchTask>(
          isCurrent: () => true,
          maxConcurrentPages: 2,
          idOf: (row) => row.taskId,
          loadPage: (page, size) async {
            requested.add(page);
            return parse(
              pageJson(page, size, 250, proof: false),
            ).toPagedReadSnapshot();
          },
        ),
        throwsA(
          isA<ApiException>().having(
            (e) => e.code,
            'code',
            'INCOMPLETE_READ_PROTOCOL',
          ),
        ),
      );
      expect(requested, [1]);
    },
  );
}
