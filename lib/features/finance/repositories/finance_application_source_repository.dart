import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';

String? financeApplicationSourceIdentity(
  Map<String, dynamic> row,
  String kind,
) {
  final id = row['id']?.toString().trim();
  final source = row['sourceKind']?.toString().trim();
  if (id == null ||
      id.isEmpty ||
      kind == 'TRAVEL_APPLICATION' && (source == null || source.isEmpty)) {
    return null;
  }
  return '${source ?? kind}|$id';
}

class FinanceApplicationSourceRepository {
  const FinanceApplicationSourceRepository(this.api);
  final ApiClient api;

  Future<PagedResult<Map<String, dynamic>>> page({
    required String kind,
    String? search,
    String? supplierId,
    String? currencyId,
    int page = 1,
    int size = 100,
  }) async => PagedResult.fromJson(
    await api.get(
      '/finance/applications/sources/page',
      query: {
        'kind': kind,
        'search': search ?? '',
        'page': page,
        'size': size,
        'supplierId': ?supplierId,
        'currencyId': ?currencyId,
      },
    ),
    (row) => row,
  );
}

final financeApplicationSourceRepositoryProvider =
    Provider<FinanceApplicationSourceRepository>(
      (ref) => FinanceApplicationSourceRepository(ref.watch(apiClientProvider)),
      dependencies: [apiClientProvider],
    );
