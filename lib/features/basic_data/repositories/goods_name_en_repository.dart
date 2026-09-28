// Goods English name only (ADR-134): PUT /master/goods/{id}/name-en {nameEn, version}.
//
// Sales people hold goods:name_en:edit but not goods:edit, so they cannot use
// the full goods save. This narrow endpoint changes nothing but the English
// name (the server marks it MANUAL); visibility of the action comes from the
// detail capability GoodsDetail.canEditNameEn, never from a local Perm check.
// Kept apart from GoodsRepository so the wide goods interface (and its many
// test fakes) does not grow for one field.
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/goods_node.dart';

/// Trims user input; blank means "no English name" (sent as null).
String? normalizeGoodsNameEnInput(String? raw) {
  final value = raw?.trim() ?? '';
  return value.isEmpty ? null : value;
}

abstract interface class GoodsNameEnRepository {
  /// Saves [nameEn] (null clears it) with optimistic lock [version].
  Future<void> update(
    String goodsId, {
    required String? nameEn,
    required int? version,
  });
}

class DioGoodsNameEnRepository implements GoodsNameEnRepository {
  DioGoodsNameEnRepository(this.api);

  final ApiClient api;

  @override
  Future<void> update(
    String goodsId, {
    required String? nameEn,
    required int? version,
  }) async {
    final id = goodsId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(goodsId, 'goodsId', 'must not be blank');
    }
    final value = normalizeGoodsNameEnInput(nameEn);
    if (value != null && value.length > kGoodsNameEnMaxLength) {
      throw ArgumentError.value(
        value.length,
        'nameEn',
        'must be at most $kGoodsNameEnMaxLength characters',
      );
    }
    await api.put(
      ApiEndpoints.goodNameEn(id),
      body: {'nameEn': value, 'version': ?version},
    );
  }
}

final goodsNameEnRepositoryProvider = Provider<GoodsNameEnRepository>(
  (ref) => DioGoodsNameEnRepository(ref.watch(apiClientProvider)),
);
