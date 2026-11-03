import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/sales/models/sales_doc.dart';
import 'package:uten_imp/features/sales/models/sales_order_progress.dart';
import 'package:uten_imp/features/sales/providers/sales_task_preload_provider.dart';
import 'package:uten_imp/features/sales/repositories/sales_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/paging/prepared_page_read.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

final _transport = StateProvider<ApiClient>(
  (ref) => throw UnimplementedError(),
);
final _grants = StateProvider<Set<String>>((ref) => {Perm.salesOrderView});
final _identity = StateProvider<AuthenticatedScope>(
  (ref) => const AuthenticatedScope(userId: 'first-owner'),
);

class _Budget {
  int active = 0;
  int maximum = 0;
  void enter() {
    active++;
    if (active > maximum) maximum = active;
  }

  void leave() => active--;
}

class _Call {
  _Call(this.path, this.query, this.id);
  final String path;
  final Map<String, dynamic> query;
  final String id;
  final done = Completer<Map<String, dynamic>>();

  void complete() {
    if (done.isCompleted) return;
    done.complete({
      'items': [
        {'id': id, 'orderId': id, 'billNo': id},
      ],
      'page': query['page'] ?? 1,
      'size': query['size'] ?? 20,
      'total': 1,
      'totalPages': 1,
      'readScopeVersion': id,
    });
  }
}

class _Api extends ApiClient {
  _Api(this.name, this.budget) : super(Dio());
  final String name;
  final _Budget budget;
  final calls = <_Call>[];

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final call = _Call(path, Map.of(query ?? {}), '$name-${calls.length}');
    calls.add(call);
    budget.enter();
    try {
      return await call.done.future;
    } finally {
      budget.leave();
    }
  }

  void finishOutstanding() {
    for (final call in calls) {
      call.complete();
    }
  }
}

ProviderContainer _container(
  _Api api, {
  SalesRepository Function(Ref ref, SalesDocType type)? repository,
}) => ProviderContainer(
  overrides: [
    _transport.overrideWith((ref) => api),
    apiClientProvider.overrideWith((ref) => ref.watch(_transport)),
    apiBaseUrlProvider.overrideWithValue('https://fixture.invalid/api'),
    authenticatedScopeProvider.overrideWith((ref) => ref.watch(_identity)),
    currentPermissionsProvider.overrideWith((ref) => ref.watch(_grants)),
    isSuperAdminProvider.overrideWithValue(false),
    if (repository != null) salesRepositoryProvider.overrideWith(repository),
  ],
);

class _RecordingProgressRepository extends SalesRepository {
  _RecordingProgressRepository(
    ApiClient api,
    PreparedPageRead<SalesOrderProgressRow> prepared,
  ) : super(api, SalesDocType.order, preparedProgress: prepared);

  final stages = <String>[];

  @override
  Future<void> prepareProgress(String stage) {
    stages.add(stage);
    return super.prepareProgress(stage);
  }
}

Future<void> _flush(ProviderContainer container) async {
  for (var turn = 0; turn < 4; turn++) {
    await container.pump();
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'same-API repository replacement retires old queued jobs and preserves physical budget',
    () async {
      final budget = _Budget();
      final api = _Api('unchanged-api', budget);
      final prepared = PreparedPageRead<SalesOrderProgressRow>();
      final first = _RecordingProgressRepository(api, prepared);
      final second = _RecordingProgressRepository(api, prepared);
      final selected = StateProvider<SalesRepository>((ref) => first);
      final container = _container(
        api,
        repository: (ref, type) => type == SalesDocType.order
            ? ref.watch(selected)
            : SalesRepository(ref.watch(apiClientProvider), type),
      );
      addTearDown(() {
        container.dispose();
        prepared.dispose();
        api.finishOutstanding();
      });
      final keep = container.listen(salesTaskPreloaderProvider, (_, _) {});
      addTearDown(keep.close);
      final preloader = container.read(salesTaskPreloaderProvider);
      final epoch = container.read(exportContextEpochProvider);
      preloader.prepare('progress', canPrepare: () => true);
      expect(api.calls, hasLength(2));
      expect(first.stages, ['DRAFT', 'IN_PROGRESS']);

      container.read(selected.notifier).state = second;
      await _flush(container);
      expect(container.read(salesTaskPreloaderProvider), same(preloader));
      expect(container.read(apiClientProvider), same(api));
      expect(container.read(apiBaseUrlProvider), 'https://fixture.invalid/api');
      expect(container.read(exportContextEpochProvider), epoch);
      api.calls[0].complete();
      await _flush(container);
      expect(
        api.calls,
        hasLength(2),
        reason:
            'Replacing a repository retires its queued READY_TO_SHIP even before the page prepares again',
      );
      expect(first.stages, ['DRAFT', 'IN_PROGRESS']);
      expect(budget.active, 1);

      preloader.prepare('progress', canPrepare: () => true);
      expect(
        api.calls,
        hasLength(3),
        reason:
            'The new source cannot reuse the old source\'s completed DRAFT from the shared lease',
      );
      expect(second.stages, ['DRAFT']);
      expect(budget.active, 2);
      api.calls[1].complete();
      await _flush(container);
      expect(api.calls, hasLength(4));
      expect(second.stages, ['DRAFT', 'IN_PROGRESS']);
      api.calls[2].complete();
      await _flush(container);
      expect(api.calls, hasLength(5));
      expect(second.stages, ['DRAFT', 'IN_PROGRESS', 'READY_TO_SHIP']);
      expect(first.stages, ['DRAFT', 'IN_PROGRESS']);
      expect(budget.maximum, 2);
      api.finishOutstanding();
      await _flush(container);
      expect(budget.active, 0);
    },
  );

  test('an expired completed category warms again on reentry', () async {
    final budget = _Budget();
    final api = _Api('fixture', budget);
    final container = _container(api);
    addTearDown(() {
      container.dispose();
      api.finishOutstanding();
    });
    var subscription = container.listen(salesTaskPreloaderProvider, (_, _) {});
    final preloader = container.read(salesTaskPreloaderProvider);
    preloader.prepare('progress', canPrepare: () => true);
    api.finishOutstanding();
    await _flush(container);
    api.finishOutstanding();
    await _flush(container);
    expect(api.calls, hasLength(3));
    expect(budget.active, 0);
    subscription.close();

    // The implementation deliberately uses monotonic Stopwatches, which fake
    // async time does not advance. Exercise the real freshness boundary once.
    await Future<void>.delayed(
      PreparedPageRead.defaultFreshFor + const Duration(milliseconds: 50),
    );
    subscription = container.listen(salesTaskPreloaderProvider, (_, _) {});
    addTearDown(subscription.close);
    expect(container.read(salesTaskPreloaderProvider), same(preloader));
    preloader.prepare('progress', canPrepare: () => true);
    expect(api.calls, hasLength(5));
    expect(api.calls.skip(3).map((call) => call.query['stage']), [
      'DRAFT',
      'IN_PROGRESS',
    ]);
    api.finishOutstanding();
    await _flush(container);
    expect(api.calls, hasLength(6));
    expect(api.calls.last.query['stage'], 'READY_TO_SHIP');
    api.finishOutstanding();
    await _flush(container);
    expect(budget.maximum, 2);
    expect(budget.active, 0);
  });

  test(
    'departure and reentry preserve the same physical worker budget',
    () async {
      final budget = _Budget();
      final api = _Api('fixture', budget);
      final container = _container(api);
      addTearDown(() {
        container.dispose();
        api.finishOutstanding();
      });
      final firstListener = container.listen(
        salesTaskPreloaderProvider,
        (_, _) {},
      );
      final firstPage = container.read(salesTaskPreloaderProvider);
      var firstPageMounted = true;
      firstPage.prepare('progress', canPrepare: () => firstPageMounted);
      expect(api.calls, hasLength(2));
      firstPageMounted = false;
      firstListener.close();
      await _flush(container);

      final nextListener = container.listen(
        salesTaskPreloaderProvider,
        (_, _) {},
      );
      addTearDown(nextListener.close);
      final secondPage = container.read(salesTaskPreloaderProvider);
      expect(secondPage, same(firstPage));
      secondPage.prepare('returns', canPrepare: () => true);
      expect(
        api.calls,
        hasLength(2),
        reason: 'The previous page still owns both physical slots',
      );
      api.calls[0].complete();
      await _flush(container);
      expect(api.calls, hasLength(3));
      expect(api.calls.last.path, '/sales/returns');
      expect(api.calls.last.query['status'], kSalesStatusDraft);
      api.calls[1].complete();
      await _flush(container);
      expect(
        api.calls,
        hasLength(3),
        reason: 'Returns prepare only the working draft segment',
      );
      expect(budget.maximum, 2);
      api.finishOutstanding();
      await _flush(container);
      expect(budget.active, 0);
    },
  );

  test(
    'hidden work resumes the same category without exceeding two reads',
    () async {
      final budget = _Budget();
      final api = _Api('fixture', budget);
      final container = _container(api);
      addTearDown(() {
        container.dispose();
        api.finishOutstanding();
      });
      final keep = container.listen(salesTaskPreloaderProvider, (_, _) {});
      addTearDown(keep.close);
      final preloader = container.read(salesTaskPreloaderProvider);
      var visible = true;
      preloader.prepare('progress', canPrepare: () => visible);
      expect(api.calls.map((call) => call.query['stage']), [
        'DRAFT',
        'IN_PROGRESS',
      ]);
      visible = false;
      api.calls[0].complete();
      api.calls[1].complete();
      await _flush(container);
      expect(api.calls, hasLength(2));
      expect(budget.active, 0);

      visible = true;
      preloader.prepare('progress', canPrepare: () => visible);
      expect(api.calls, hasLength(3));
      expect(api.calls.last.query['stage'], 'READY_TO_SHIP');
      api.calls.last.complete();
      await _flush(container);
      expect(budget.maximum, 2);
    },
  );

  test(
    'write and epoch changes retire queued jobs while keeping physical budget',
    () async {
      final budget = _Budget();
      final first = _Api('first', budget);
      final second = _Api('second', budget);
      final container = _container(first);
      addTearDown(() {
        container.dispose();
        first.finishOutstanding();
        second.finishOutstanding();
      });
      final keep = container.listen(salesTaskPreloaderProvider, (_, _) {});
      addTearDown(keep.close);
      final preloader = container.read(salesTaskPreloaderProvider);
      preloader.prepare('progress', canPrepare: () => true);
      expect(first.calls, hasLength(2));
      container.read(_transport.notifier).state = second;
      await _flush(container);

      for (var change = 0; change < 12; change++) {
        if (change.isEven) {
          container.read(dataWriteRevisionProvider.notifier).state++;
        } else {
          container.read(readScopeRevisionProvider.notifier).state++;
        }
        await _flush(container);
        final current = container.read(salesTaskPreloaderProvider);
        expect(current, same(preloader));
        current.prepare(
          change == 11 ? 'returns' : 'quotes',
          canPrepare: () => true,
        );
        expect(second.calls, isEmpty);
        expect(budget.active, 2);
      }

      first.calls[0].complete();
      await _flush(container);
      expect(second.calls, hasLength(1));
      expect(second.calls.single.path, '/sales/returns');
      expect(second.calls.single.query['status'], kSalesStatusDraft);
      first.calls[1].complete();
      await _flush(container);
      expect(
        second.calls,
        hasLength(1),
        reason: 'Approved returns belong to date-gated history',
      );
      expect(second.calls.single.query['status'], kSalesStatusDraft);
      expect(second.calls.single.query.containsKey('dateFrom'), isFalse);
      expect(second.calls.single.query.containsKey('dateTo'), isFalse);
      expect(
        first.calls,
        hasLength(2),
        reason: 'The retired READY_TO_SHIP job never runs',
      );
      expect(budget.maximum, 2);
      second.finishOutstanding();
      await _flush(container);
      expect(budget.active, 0);
    },
  );

  for (final boundary in [
    'write',
    'read-scope',
    'permissions',
    'identity',
    'api',
  ]) {
    for (final inFlight in [false, true]) {
      test(
        '$boundary retires ${inFlight ? 'in-flight' : 'complete'} repository preparation',
        () async {
          final budget = _Budget();
          final first = _Api('first', budget);
          final second = _Api('second', budget);
          final container = _container(first);
          addTearDown(() {
            container.dispose();
            first.finishOutstanding();
            second.finishOutstanding();
          });
          final keep = container.listen(
            salesRepositoryProvider(SalesDocType.order),
            (_, _) {},
          );
          addTearDown(keep.close);
          final previous = container.read(
            salesRepositoryProvider(SalesDocType.order),
          );
          final preparation = previous.prepareProgress('DRAFT');
          expect(first.calls, hasLength(1));
          Future<void>? oldRejected;
          if (inFlight) {
            oldRejected = expectLater(
              previous.progress(size: 50, stage: 'DRAFT', preferPrepared: true),
              throwsStateError,
            );
          } else {
            first.calls.single.complete();
            await preparation;
          }

          final epoch = container.read(exportContextEpochProvider);
          switch (boundary) {
            case 'write':
              container.read(dataWriteRevisionProvider.notifier).state++;
            case 'read-scope':
              container.read(readScopeRevisionProvider.notifier).state++;
            case 'permissions':
              container.read(_grants.notifier).state = {
                Perm.salesOrderView,
                Perm.salesShipmentView,
              };
            case 'identity':
              container.read(_identity.notifier).state =
                  const AuthenticatedScope(userId: 'second-owner');
            case 'api':
              container.read(_transport.notifier).state = second;
          }
          await _flush(container);
          if (boundary != 'write') {
            expect(
              container.read(exportContextEpochProvider),
              greaterThan(epoch),
            );
          }
          final current = container.read(
            salesRepositoryProvider(SalesDocType.order),
          );
          expect(current, isNot(same(previous)));
          if (inFlight) {
            first.calls.single.complete();
            await preparation;
            await oldRejected;
          }
          final expectedApi = boundary == 'api' ? second : first;
          final before = expectedApi.calls.length;
          final fresh = current.progress(
            size: 50,
            stage: 'DRAFT',
            preferPrepared: true,
          );
          expect(expectedApi.calls, hasLength(before + 1));
          expectedApi.calls.last.complete();
          final result = await fresh;
          expect(result.items.single.orderId, expectedApi.calls.last.id);
          expect(result.items.single.orderId, isNot(first.calls.first.id));
          await expectLater(
            previous.progress(size: 50, stage: 'DRAFT', preferPrepared: true),
            throwsStateError,
          );
        },
      );
    }
  }
}
