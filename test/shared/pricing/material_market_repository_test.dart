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
      {'seriesId': 'copper', 'latestPrice': '12345.123456789'},
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
      expect(catalog.single.text('latestPrice'), '12345.123456789');
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
