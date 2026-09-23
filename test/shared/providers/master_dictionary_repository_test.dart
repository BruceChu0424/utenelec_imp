// 会话级主档字典仓库(ADR-108 / perf-frontend-08):
//   · 依次用到 Master / Sales / Finance 三个名称服务与单位下拉: 币种/单位字典各只请求 1 次;
//   · 本端新建/改名单位(网络层记下写路径)后, 单位字典作废, 已加载的服务与下拉随之重取,
//     不重登也能看到新值; 与单位无关的写不作废任何字典。
import 'package:dio/dio.dart';
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
  List<Map<String, dynamic>> units = [
    {'id': 'unit-1', 'name': '件'},
  ];

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    calls[path] = (calls[path] ?? 0) + 1;
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
      expect(api.calls[ApiEndpoints.warehousesDict], 1);
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
