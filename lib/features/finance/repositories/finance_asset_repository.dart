import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';

enum FinanceAssetLedger { fixedAsset, deferredExpense }

extension FinanceAssetLedgerPath on FinanceAssetLedger {
  String get basePath => switch (this) {
    FinanceAssetLedger.fixedAsset => '/finance/fixed-assets',
    FinanceAssetLedger.deferredExpense => '/finance/deferred-expenses',
  };

  String get postingPath => switch (this) {
    FinanceAssetLedger.fixedAsset => '/finance/fa/depreciate',
    FinanceAssetLedger.deferredExpense => '/finance/fa/amortize',
  };

  String get postingCountKey => switch (this) {
    FinanceAssetLedger.fixedAsset => 'assets',
    FinanceAssetLedger.deferredExpense => 'items',
  };
}

class FinanceAssetRepository {
  FinanceAssetRepository(this._api);

  final ApiClient _api;

  Future<PagedResult<Map<String, dynamic>>> list(
    FinanceAssetLedger ledger, {
    int page = 1,
    int size = 20,
  }) async {
    final response = await _api.get(
      ledger.basePath,
      query: {'page': page, 'size': size},
    );
    return PagedResult.fromJson(response, (json) => json);
  }

  Future<void> create(
    FinanceAssetLedger ledger,
    Map<String, dynamic> body,
  ) async {
    await _api.post(ledger.basePath, body: body);
  }

  Future<void> update(
    FinanceAssetLedger ledger,
    String id,
    Map<String, dynamic> body,
  ) async {
    await _api.put('${ledger.basePath}/$id', body: body);
  }

  Future<void> delete(FinanceAssetLedger ledger, String id) async {
    await _api.delete('${ledger.basePath}/$id');
  }

  Future<int> postPeriod(FinanceAssetLedger ledger, String period) async {
    final response = await _api.post(
      ledger.postingPath,
      query: {'period': period},
    );
    return (response[ledger.postingCountKey] as num?)?.toInt() ?? 0;
  }
}

final financeAssetRepositoryProvider = Provider<FinanceAssetRepository>((ref) {
  return FinanceAssetRepository(ref.watch(apiClientProvider));
});
