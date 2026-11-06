// 会话级主档字典仓库(ADR-108 / perf-frontend-08):
//   · 依次用到 Master / Sales / Finance 三个名称服务与单位下拉: 币种/单位字典各只请求 1 次;
//   · 本端新建/改名单位(网络层记下写路径)后, 单位字典作废, 已加载的服务与下拉随之重取,
//     不重登也能看到新值; 与单位无关的写不作废任何字典。
import 'package:dio/dio.dart';
import 'dart:async';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';
import 'package:uten_imp/shared/paging/paged_read_intent.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/features/basic_data/providers/color_unit_dict.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/master_dictionary_repository.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

class _DictApi extends ApiClient {
  _DictApi() : super(Dio());

  final Map<String, int> calls = {};
  Completer<void>? gate;
  final precisionModes = <bool?>[];
  final identities = <AuthenticatedRequestIdentity?>[];
  List<Map<String, dynamic>> units = [
    {'id': 'unit-1', 'name': '件'},
  ];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls[path] = (calls[path] ?? 0) + 1;
    final logical = PagedReadIntent.currentRead;
    final active = PagedReadIntent.currentActivity;
    final scope = AuthenticatedRequestScope.current;
    precisionModes.add(BusinessPrecisionTransport.current?.readOnly);
    identities.add(scope?.identity);
    if (gate != null) await gate!.future;
    if (!(logical?.call() ?? true) || !(active?.call() ?? true)) {
      throw const UiWorkCancelled();
    }
    if (scope != null) scope.checkCurrent();
    if (path == ApiEndpoints.unitsDict) return units;
    if (path == ApiEndpoints.currenciesDict) {
      return const [
        {'id': 'cny', 'name': '人民币'},
      ];
    }
    return const [];
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {};
}

ProviderContainer _container(_DictApi api) {
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      masterDataSessionKeyProvider.overrideWithValue('account-a'),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'shared dictionary producer survives its first UI leaving with the same immutable identity',
    () async {
      final gate = Completer<void>();
      final api = _DictApi()..gate = gate;
      final repository = MasterDictionaryRepository(api);
      addTearDown(repository.dispose);
      var firstCurrent = true;
      final firstScope = await AuthenticatedRequestScope.capture(
        baseUrl: 'https://metadata.invalid/api',
        storage: null,
        isCurrent: () => firstCurrent,
      );
      final first = firstScope.run(
        () => PagedReadIntent.scopedRead(
          () => firstCurrent,
          () => repository.load(ApiEndpoints.unitsDict),
          activity: PagedReadActivityFence(isCurrent: () => firstCurrent),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      final second = repository.load(ApiEndpoints.unitsDict);
      firstCurrent = false;
      gate.complete();
      final values = await Future.wait([first, second]);
      expect(identical(values.first, values.last), isTrue);
      expect(repository.cached(ApiEndpoints.unitsDict), same(values.last));
      expect(api.calls[ApiEndpoints.unitsDict], 1);
      expect(api.identities.single, firstScope.identity);
      expect(api.precisionModes.single, isTrue);
    },
  );

  test(
    'headless shared dictionary never borrows write precision and still retires on own session',
    () async {
      var own = true;
      final api = _DictApi()..gate = Completer<void>();
      final repository = MasterDictionaryRepository(api, isCurrent: () => own);
      addTearDown(repository.dispose);
      final write = BusinessPrecisionTransport();
      final loading = write.run(() => repository.load(ApiEndpoints.unitsDict));
      final rejected = expectLater(loading, throwsA(isA<UiWorkCancelled>()));
      await Future<void>.delayed(Duration.zero);
      expect(api.precisionModes.single, isTrue);
      own = false;
      api.gate!.complete();
      await rejected;
      expect(repository.cached(ApiEndpoints.unitsDict), isNull);
    },
  );

  test(
    'a shared dictionary write generation cannot publish its old in-flight rows',
    () async {
      final api = _DictApi()..gate = Completer<void>();
      final repository = MasterDictionaryRepository(api);
      addTearDown(repository.dispose);
      final loading = repository.load(ApiEndpoints.unitsDict);
      final rejected = expectLater(loading, throwsA(isA<UiWorkCancelled>()));
      await Future<void>.delayed(Duration.zero);
      repository.invalidate(ApiEndpoints.unitsDict);
      api.gate!.complete();
      await rejected;
      expect(repository.cached(ApiEndpoints.unitsDict), isNull);
      api.gate = null;
      api.units = [
        {'id': 'unit-1', 'name': '新单位'},
      ];
      expect(
        (await repository.load(ApiEndpoints.unitsDict)).single['name'],
        '新单位',
      );
      expect(api.calls[ApiEndpoints.unitsDict], 2);
    },
  );

  test(
    'business dictionaries retain original cache and invalidation keys on minimal sources',
    () async {
      final api = _DictApi();
      final repository = MasterDictionaryRepository(api);
      addTearDown(repository.dispose);
      for (final pair in [
        (masterAccountsDictKey, ApiEndpoints.businessReferenceAccounts),
        (ApiEndpoints.warehousesDict, ApiEndpoints.businessReferenceWarehouses),
        (
          ApiEndpoints.departmentsTree,
          ApiEndpoints.businessReferenceDepartments,
        ),
      ]) {
        final values = await Future.wait([
          repository.load(pair.$1),
          repository.load(pair.$1),
        ]);
        expect(identical(values.first, values.last), true);
        expect(api.calls[pair.$2], 1);
        expect(api.calls[pair.$1], isNull);
        expect(repository.cached(pair.$1), same(values.first));
        repository.invalidate(pair.$1);
        expect(repository.cached(pair.$1), isNull);
        await repository.load(pair.$1);
        expect(api.calls[pair.$2], 2);
      }
    },
  );
  test(
    'three name services and the unit dropdown share one fetch per dict',
    () async {
      final api = _DictApi();
      final container = _container(api);

      await container.read(masterNameServiceProvider).ensureLoaded();
      await container.read(salesMasterNameServiceProvider).ensureLoaded();
      await container.read(financeNameServiceProvider).ensureLoaded();
      await container.read(unitDictProvider.future);

      expect(api.calls[ApiEndpoints.currenciesDict], 1);
      expect(api.calls[ApiEndpoints.unitsDict], 1);
      expect(api.calls[ApiEndpoints.businessReferenceWarehouses], 1);
      expect(api.calls[ApiEndpoints.warehousesDict], isNull);
      expect(container.read(masterNameServiceProvider).unit('unit-1'), '件');
    },
  );

  test(
    'a local unit write invalidates the unit dict everywhere, others stay',
    () async {
      final api = _DictApi();
      final container = _container(api);
      container.listen(unitDictProvider, (_, _) {});
      final names = container.read(masterNameServiceProvider);
      await names.ensureLoaded();
      await container.read(unitDictProvider.future);
      expect(api.calls[ApiEndpoints.unitsDict], 1);

      // 与主档无关的写: 不作废任何字典。
      container.read(lastDataWriteProvider.notifier).state = (
        seq: 1,
        path: '/api/sales/orders',
      );
      await Future<void>.delayed(Duration.zero);
      expect(api.calls[ApiEndpoints.unitsDict], 1);

      // 新建了一个单位: 网络层记下写路径 → 单位字典作废, 服务与下拉各自重取到新值。
      api.units = [
        {'id': 'unit-1', 'name': '件'},
        {'id': 'unit-2', 'name': '箱'},
      ];
      container.read(lastDataWriteProvider.notifier).state = (
        seq: 2,
        path: '/api/master/units',
      );
      await Future<void>.delayed(Duration.zero);
      final units = await container.read(unitDictProvider.future);
      await Future<void>.delayed(Duration.zero);

      expect(units.map((unit) => unit.name), containsAll(['件', '箱']));
      expect(names.unit('unit-2'), '箱');
      // 单飞: 服务与下拉同时要单位字典, 只多请求 1 次; 币种字典没被作废。
      expect(api.calls[ApiEndpoints.unitsDict], 2);
      expect(api.calls[ApiEndpoints.currenciesDict], 1);
    },
  );

  test('write paths map to the right dictionaries', () {
    expect(masterDictKeysForWrite('/api/master/warehouses/warehouse-1'), [
      ApiEndpoints.warehousesDict,
    ]);
    expect(masterDictKeysForWrite('/api/master/accounts/account-1'), [
      masterAccountsDictKey,
    ]);
    expect(masterDictKeysForWrite('/api/org/departments/department-1'), [
      ApiEndpoints.departmentsTree,
    ]);
    expect(
      masterDictKeysForWrite('/api/business-references/warehouses'),
      isEmpty,
    );
    expect(masterDictKeysForWrite('/api/master/units/u-1'), [
      ApiEndpoints.unitsDict,
    ]);
    expect(masterDictKeysForWrite('/api/master/currencies'), [
      ApiEndpoints.currenciesDict,
    ]);
    expect(masterDictKeysForWrite('/api/master/goods/g-1'), isEmpty);
    expect(masterDictKeysForWrite('/api/sales/orders'), isEmpty);
  });
}
