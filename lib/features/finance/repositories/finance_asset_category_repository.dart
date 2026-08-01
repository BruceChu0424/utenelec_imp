import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/finance_asset_category_models.dart';
import '../models/finance_asset_models.dart';

abstract interface class FinanceAssetCategoryRepository {
  Future<List<FinanceAssetCategory>> list(FinanceAssetLedger objectType);

  Future<FinanceAssetCategory> create(FinanceAssetCategoryInput input);

  Future<FinanceAssetCategory> update(
    String id,
    FinanceAssetCategoryInput input,
  );

  Future<FinanceAssetCategory> activate(
    String id, {
    required int? expectedVersion,
  });
}

class ApiFinanceAssetCategoryRepository
    implements FinanceAssetCategoryRepository {
  ApiFinanceAssetCategoryRepository(this._api);

  final ApiClient _api;
  static const _path = '/finance/asset-categories';

  Map<String, dynamic> _payload(Map<String, dynamic> response) {
    final data = response['data'];
    return data is Map<String, dynamic> ? data : response;
  }

  @override
  Future<List<FinanceAssetCategory>> list(FinanceAssetLedger objectType) async {
    final response = _payload(
      await _api.get(_path, query: {'objectType': objectType.apiValue}),
    );
    final items = response['items'] ?? response['categories'];
    if (items is! List<dynamic>) return const <FinanceAssetCategory>[];
    return items
        .whereType<Map<Object?, Object?>>()
        .map(
          (item) =>
              FinanceAssetCategory.fromJson(Map<String, dynamic>.from(item)),
        )
        .toList(growable: false);
  }

  @override
  Future<FinanceAssetCategory> create(FinanceAssetCategoryInput input) async {
    return FinanceAssetCategory.fromJson(
      _payload(await _api.post(_path, body: input.toJson())),
    );
  }

  @override
  Future<FinanceAssetCategory> update(
    String id,
    FinanceAssetCategoryInput input,
  ) async {
    return FinanceAssetCategory.fromJson(
      _payload(await _api.put('$_path/$id', body: input.toJson())),
    );
  }

  @override
  Future<FinanceAssetCategory> activate(
    String id, {
    required int? expectedVersion,
  }) async {
    return FinanceAssetCategory.fromJson(
      _payload(
        await _api.post(
          '$_path/$id/activate',
          body: <String, dynamic>{'expectedVersion': ?expectedVersion},
        ),
      ),
    );
  }
}

final financeAssetCategoryRepositoryProvider =
    Provider<FinanceAssetCategoryRepository>((ref) {
      return ApiFinanceAssetCategoryRepository(ref.watch(apiClientProvider));
    });
