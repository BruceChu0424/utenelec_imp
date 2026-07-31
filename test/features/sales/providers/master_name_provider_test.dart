import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';

void main() {
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
  _StubApiClient(this.clients) : super(Dio());

  final List<Map<String, dynamic>> clients;

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    return path == ApiEndpoints.clientsDict ? clients : const [];
  }
}
