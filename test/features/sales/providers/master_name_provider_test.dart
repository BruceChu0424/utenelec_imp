import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';

void main() {
  test(
    'shared dictionary localizes known currency codes while keeping UUID and cache ownership',
    () async {
      final currencies = [
        {'id': 'usd', 'name': 'US Dollar', 'code': 'USD'},
        {'id': 'custom', 'name': '美元', 'code': 'USD'},
        {'id': 'cny', 'name': 'CNY', 'code': 'CNY', 'baseCurrency': true},
        {'id': 'legacy', 'name': '', 'code': '002'},
      ];
      final api = _StubApiClient(const [], currencies: currencies);
      final service = SalesMasterNameService(api);
      addTearDown(service.dispose);
      await service.ensureLoaded();
      expect(service.currencyEntries, {
        'usd': '美金',
        'custom': '美元',
        'cny': '人民币',
        'legacy': '',
      });
      expect(service.baseCurrencyId, 'cny');
      expect(service.currency('legacy'), '—');
      await service.ensureLoaded();
      expect(api.currencyReads, 1);
      expect(currencies.first['name'], 'US Dollar');
      expect(currencies.first['code'], 'USD');
    },
  );
  test('disabled clients remain resolvable but are not selectable', () async {
    final service = SalesMasterNameService(
      _StubApiClient([
        {'id': 'active', 'name': 'Active client', 'selectable': true},
        {'id': 'disabled', 'name': 'Historical client', 'selectable': false},
        {'id': 'old-active', 'code': 'C-OLD', 'name': 'Old server client'},
        {'id': 'stub', 'code': 'LEGACY-FIN-CL-7', 'name': '??????????'},
      ]),
    );

    await service.ensureLoaded();
    await service.loadClientNames(['active', 'disabled', 'old-active', 'stub']);

    expect(service.clientEntries, hasLength(4));
    expect(service.client('disabled'), 'Historical client');
    expect(service.client('stub'), '??????????');
    expect(service.selectableClientEntries, {
      'active': 'Active client',
      'old-active': 'Old server client',
    });
  });
}

class _StubApiClient extends ApiClient {
  _StubApiClient(this.clients, {this.currencies = const []}) : super(Dio());

  final List<Map<String, dynamic>> clients;
  final List<Map<String, dynamic>> currencies;
  int currencyReads = 0;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.currenciesDict) {
      currencyReads++;
      return currencies;
    }
    if (path == '/master/clients/lookup') {
      final ids = (query!['ids'] as String).split(',').toSet();
      return clients.where((row) => ids.contains(row['id'])).toList();
    }
    return const [];
  }
}
