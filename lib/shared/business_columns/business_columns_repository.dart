import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import 'business_column.dart';

class BusinessColumnsRepository {
  const BusinessColumnsRepository(this.api);
  final ApiClient api;

  Future<List<BusinessColumn>> search(String scope, String query) async =>
      (await api.getList(
        '/business-columns',
        query: {'scope': scope, 'q': query},
      )).map(BusinessColumn.fromJson).toList(growable: false);

  Future<bool> supportsArithmetic(String scope) async =>
      (await api.get(
        '/business-columns/capabilities',
        query: {'scope': scope},
      ))['arithmetic'] ==
      true;

  Future<BusinessColumn> create({
    required String scope,
    required String name,
    required String type,
    required String operation,
  }) async => BusinessColumn.fromJson(
    await api.post(
      '/business-columns',
      body: {
        'scope': scope,
        'name': name,
        'type': type,
        'operation': operation,
      },
    ),
  );
}

final businessColumnsRepositoryProvider = Provider<BusinessColumnsRepository>(
  (ref) => BusinessColumnsRepository(ref.watch(apiClientProvider)),
);
