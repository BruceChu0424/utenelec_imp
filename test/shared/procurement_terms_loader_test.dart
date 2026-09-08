import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/shared/repositories/procurement_terms_loader.dart';

void main() {
  test(
    'large orders use bounded requests and return every requested default',
    () async {
      final api = _TermsApi();
      final ids = {for (var i = 0; i < 251; i++) 'goods-$i'};
      final result = await loadProcurementTerms(
        api,
        '/purchase/orders/last-terms',
        ids,
      );
      expect(result.keys.toSet(), ids);
      expect(api.batches.map((batch) => batch.length), [100, 100, 51]);
      expect(api.maxActive, 2);
      expect(
        result.values.every((terms) => terms.currencyId == 'currency'),
        isTrue,
      );
      expect(result.containsKey('unexpected'), isFalse);
    },
  );

  test('empty orders issue no default query', () async {
    final api = _TermsApi();
    expect(await loadProcurementTerms(api, '/terms', {}), isEmpty);
    expect(api.batches, isEmpty);
  });
}

class _TermsApi extends ApiClient {
  _TermsApi() : super(Dio());
  final batches = <List<String>>[];
  var active = 0;
  var maxActive = 0;

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    final ids = (query!['goodsIds'] as String).split(',');
    batches.add(ids);
    active++;
    if (active > maxActive) maxActive = active;
    await Future<void>.delayed(Duration.zero);
    active--;
    return {
      for (final id in ids) id: <String, dynamic>{'currencyId': 'currency'},
      'unexpected': <String, dynamic>{'currencyId': 'must-not-apply'},
    };
  }
}
