import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/pricing/material_market_models.dart';
import 'package:uten_imp/shared/pricing/material_market_repository.dart';

class _Api extends ApiClient {
  _Api() : super(Dio());
  String? method, path;
  Object? body;
  Map<String, dynamic> response = {
    'status': 'UNMAPPED',
    'seriesId': null,
    'bindingVersion': 0,
    'current': null,
    'canManage': true,
  };

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    method = 'GET';
    this.path = path;
    return response;
  }

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    method = 'GET';
    this.path = path;
    return [
      {
        'seriesId': 'shfe_cu_main_daily',
        'name': '沪铜主力(日终)',
        'currency': 'CNY',
        'unit': '吨',
        'selectable': true,
      },
    ];
  }

  @override
  Future<Map<String, dynamic>> put(String path, {Object? body}) async {
    method = 'PUT';
    this.path = path;
    this.body = body;
    return response;
  }
}

void main() {
  test(
    'v2 replay remains research-only and delayed quote has its own deadline',
    () {
      final now = DateTime.utc(2026, 10, 20, 9);
      final analysis = MaterialMarketAnalysis({
        'status': 'RESEARCH_ONLY',
        'seriesId': 'shfe_cu_main_daily',
        'bindingVersion': 1,
        'expiresAt': '2026-10-21T08:00:00Z',
        'refreshAfterSeconds': 60,
        'benchmark': {
          'seriesId': 'shfe_cu_main_daily',
          'name': '沪铜主力(日终)',
          'selectable': true,
        },
        'current': {
          'schemaVersion': 2,
          'status': 'RESEARCH_ONLY',
          'validationBasis': 'LATEST_HISTORY_REPLAY',
          'modelPriceBasis': 'CHAIN_LINKED_CURRENT_ANCHOR',
          'validation': {'passed': true},
        },
        'latestQuote': {
          'status': 'CURRENT',
          'price': '81400.123456789',
          'expiresAt': '2026-10-20T09:00:20Z',
        },
      });
      expect(analysis.researchOnlyAt(now), true);
      expect(analysis.actionableAt(now), false);
      expect(analysis.canShowProjectionAt(now), true);
      expect(analysis.latestQuote!.text('price'), '81400.123456789');
      expect(
        analysis.latestQuote!.currentAt(now.add(const Duration(seconds: 21))),
        false,
      );
      expect(
        analysis.canShowProjectionAt(now.add(const Duration(seconds: 21))),
        true,
      );
      final invalidReady = MaterialMarketAnalysis({
        ...analysis.data,
        'status': 'READY',
        'current': {...analysis.current!.data, 'status': 'READY'},
      });
      expect(invalidReady.actionableAt(now), false);
    },
  );

  test(
    'market reads and catalog use encoded goods context and exact text',
    () async {
      final api = _Api();
      final repository = ApiMaterialMarketRepository(api);
      final result = await repository.analysis('goods/a');
      expect(result.status, 'UNMAPPED');
      expect(api.path, '/master/goods/goods%2Fa/price-analysis/market');
      expect(api.method, 'GET');
      final catalog = await repository.catalog('goods/a');
      expect(api.path, '/master/goods/goods%2Fa/price-analysis/market/catalog');
      expect(catalog.single.seriesId, 'shfe_cu_main_daily');
      expect(catalog.single.selectable, true);
      expect(catalog.single.data.containsKey('latestPrice'), false);
    },
  );

  test(
    'explicit link and unlink use CAS and retain tombstone version',
    () async {
      final api = _Api();
      final repository = ApiMaterialMarketRepository(api);
      api.response = {
        ...api.response,
        'seriesId': 'copper',
        'bindingVersion': 8,
      };
      expect(
        (await repository.bind(
          'a',
          seriesId: 'copper',
          expectedVersion: 7,
        )).seriesId,
        'copper',
      );
      expect(api.body, {'seriesId': 'copper', 'expectedVersion': 7});
      expect(api.method, 'PUT');
      api.response = {...api.response, 'seriesId': null, 'bindingVersion': 9};
      final unlinked = await repository.bind(
        'a',
        seriesId: null,
        expectedVersion: 8,
      );
      expect(unlinked.bindingVersion, 9);
      expect(api.body, {'seriesId': null, 'expectedVersion': 8});
    },
  );

  test(
    'unconfirmed successful writes never appear as saved bindings',
    () async {
      final api = _Api();
      final repository = ApiMaterialMarketRepository(api);
      for (final response in <Map<String, dynamic>>[
        {},
        {...api.response, 'seriesId': 'different', 'bindingVersion': 1},
        {...api.response, 'seriesId': 'copper', 'bindingVersion': 0},
      ]) {
        api.response = response;
        await expectLater(
          repository.bind('a', seriesId: 'copper', expectedVersion: 0),
          throwsFormatException,
        );
      }
    },
  );

  test('stale envelope and unvalidated model cannot activate a signal', () {
    final current = {
      'schemaVersion': 1,
      'status': 'READY',
      'validation': {'passed': true},
    };
    MaterialMarketAnalysis envelope(
      String status,
      Map<String, dynamic> snapshot,
    ) => MaterialMarketAnalysis({
      'status': status,
      'bindingVersion': 1,
      'expiresAt': '2099-10-21T08:00:00Z',
      'current': snapshot,
    });
    expect(envelope('STALE', current).actionable, false);
    expect(envelope('STALE', current).canShowProjection, false);
    expect(
      envelope('READY', {
        ...current,
        'validation': {'passed': false},
      }).actionable,
      false,
    );
    expect(envelope('READY', current).actionable, true);
  });
}
