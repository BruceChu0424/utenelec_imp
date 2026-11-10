import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_mutation_reload_safety.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/features/admin/providers/admin_providers.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/sensitive_read_boundary_provider.dart';

void main() {
  test(
    'rapid account changes cancel retired HTTP reads and accept the last account',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      ProviderSubscription? selected;
      for (var index = 0; index < 24; index++) {
        selected?.close();
        selected = fixture.container.listen(
          adminEffectivePermissionsProvider('employee-$index'),
          (_, _) {},
        );
        await fixture.adapter.ready(index + 1);
        await fixture.container.pump();
        await fixture.adapter.settleCancellation();
        expect(fixture.adapter.cancelled.take(index), everyElement(isTrue));
        expect(fixture.adapter.cancelled.last, isFalse);
        expect(fixture.safety.pendingReadCount, 1);
      }
      fixture.adapter.respond(23, '{"effective":["last-account:view"]}');
      final result = await fixture.container.read(
        adminEffectivePermissionsProvider('employee-23').future,
      );
      expect(result.effective, ['last-account:view']);
      expect(fixture.safety.pendingReadCount, 0);
      selected!.close();
    },
  );

  test(
    'shared catalog outlives one consumer and its initiating read activity',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      var initiatingPageCurrent = true;
      final first = PagedReadIntent.scopedRead(
        () => initiatingPageCurrent,
        () => fixture.container.listen(permissionCatalogProvider, (_, _) {}),
        activity: PagedReadActivityFence(
          isCurrent: () => initiatingPageCurrent,
        ),
      );
      final second = fixture.container.listen(
        permissionCatalogProvider,
        (_, _) {},
      );
      await fixture.adapter.ready(1);
      initiatingPageCurrent = false;
      first.close();
      await fixture.container.pump();
      await fixture.adapter.settleCancellation();
      expect(fixture.adapter.cancelled, [false]);
      expect(fixture.safety.pendingReadCount, 1);
      fixture.adapter.respond(0, '[]');
      expect(
        await fixture.container.read(permissionCatalogProvider.future),
        isEmpty,
      );
      second.close();
    },
  );

  test(
    'authority replacement cancels the previous account read before publishing new grants',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      final values = <List<String>>[];
      final subscription = fixture.container.listen(
        adminEffectivePermissionsProvider('employee'),
        (_, next) {
          if (next.hasValue) values.add(next.requireValue.effective);
        },
      );
      await fixture.adapter.ready(1);
      fixture.container.read(fixture.boundaryProvider.notifier).state = fixture
          .boundary(epoch: 2);
      await fixture.container.pump();
      await fixture.adapter.ready(2);
      await fixture.adapter.settleCancellation();
      expect(fixture.adapter.cancelled, [true, false]);
      fixture.adapter.respond(0, '{"effective":["retired:view"]}');
      fixture.adapter.respond(1, '{"effective":["current:view"]}');
      final result = await fixture.container.read(
        adminEffectivePermissionsProvider('employee').future,
      );
      expect(result.effective, ['current:view']);
      expect(values, [
        ['current:view'],
      ]);
      subscription.close();
    },
  );

  test(
    'shared catalog retains identity while retiring the initiating authenticated operation',
    () async {
      final fixture = _Fixture();
      addTearDown(fixture.dispose);
      var initiatingOperationCurrent = true;
      final scope = await AuthenticatedRequestScope.capture(
        baseUrl: fixture.dio.options.baseUrl,
        storage: null,
        isCurrent: () => initiatingOperationCurrent,
      );
      final first = await scope.run(
        () async =>
            fixture.container.listen(permissionCatalogProvider, (_, _) {}),
      );
      final second = fixture.container.listen(
        permissionCatalogProvider,
        (_, _) {},
      );
      await fixture.adapter.ready(1);
      initiatingOperationCurrent = false;
      first.close();
      await fixture.container.pump();
      await fixture.adapter.settleCancellation();
      expect(fixture.adapter.cancelled, [false]);
      fixture.adapter.respond(0, '[]');
      expect(
        await fixture.container.read(permissionCatalogProvider.future),
        isEmpty,
      );
      second.close();
    },
  );

  final reads = {
    'departments': adminDepartmentTreeProvider,
    'catalog': permissionCatalogProvider,
    'department permissions': adminDepartmentPermissionsProvider('department'),
    'baseline': adminPermissionBaselineProvider,
    'effective permissions': adminEffectivePermissionsProvider('employee'),
  };
  for (final entry in reads.entries) {
    test(
      '${entry.key} releases transport when the final consumer leaves',
      () async {
        final fixture = _Fixture();
        addTearDown(fixture.dispose);
        final subscription = fixture.container.listen(entry.value, (_, _) {});
        await fixture.adapter.ready(1);
        subscription.close();
        await fixture.container.pump();
        await fixture.adapter.settleCancellation();
        expect(fixture.adapter.cancelled, [true]);
        expect(fixture.safety.pendingReadCount, 0);
      },
    );
  }
}

class _Fixture {
  _Fixture() {
    dio = Dio(BaseOptions(baseUrl: 'https://example.test/api'))
      ..httpClientAdapter = adapter;
    api = ApiClient(dio, reloadSafety: safety);
    boundaryProvider = StateProvider((ref) => boundary());
    container = ProviderContainer(
      overrides: [
        apiClientProvider.overrideWithValue(api),
        sensitiveReadBoundaryProvider.overrideWith(
          (ref) => ref.watch(boundaryProvider),
        ),
      ],
    );
  }
  final adapter = _Adapter();
  final safety = ApiMutationReloadSafety();
  late final Dio dio;
  late final ApiClient api;
  late final StateProvider<SensitiveReadBoundary> boundaryProvider;
  late final ProviderContainer container;

  SensitiveReadBoundary boundary({int epoch = 1}) => SensitiveReadBoundary(
    identity: AuthenticatedScope(userId: 'operator', epoch: epoch),
    api: api,
    permissions: {'authorization:manage'},
    superAdmin: true,
  );

  Future<void> dispose() async {
    container.dispose();
    await adapter.settleCancellation();
    for (var index = 0; index < adapter.pending.length; index++) {
      if (!adapter.pending[index].isCompleted) adapter.respond(index, '{}');
    }
    dio.close(force: true);
  }
}

class _Adapter implements HttpClientAdapter {
  final pending = <Completer<ResponseBody>>[];
  final cancelled = <bool>[];

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    final index = pending.length;
    final result = Completer<ResponseBody>();
    pending.add(result);
    cancelled.add(false);
    cancelFuture?.then((_) => cancelled[index] = true);
    return result.future;
  }

  Future<void> ready(int count) async {
    for (var attempt = 0; pending.length < count && attempt < 100; attempt++) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(pending.length, count);
  }

  Future<void> settleCancellation() =>
      Future<void>.delayed(const Duration(milliseconds: 75));

  void respond(int index, String body) => pending[index].complete(
    ResponseBody.fromBytes(
      utf8.encode(body),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    ),
  );

  @override
  void close({bool force = false}) {}
}
