// 收付款类别仓库：树/子树/详情/CRUD。
//
// 仿 DioProductCategoryRepository，端点 /api/master/payment-styles。
// tree 支持按 category 大类过滤（如 category=EXPENSE 只返回费用子树）。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/payment_style_node.dart';

/// 收付款类别端点（基址 /api，由 ApiClient 注入）。
abstract final class PaymentStyleEndpoints {
  static const base = '/master/payment-styles';
  static String tree({String? category}) =>
      category == null ? '$base/tree' : '$base/tree?category=$category';
  static String subtree(String id) => '$base/$id/subtree';
  static String one(String id) => '$base/$id';
}

abstract interface class PaymentStyleRepository {
  Future<List<PaymentStyleNode>> tree({String? category});
  Future<List<PaymentStyleNode>> subtree(String id);
  Future<PaymentStyleDetail> detail(String id);
  Future<PaymentStyleDetail> create(PaymentStyleSaveInput input);
  Future<PaymentStyleDetail> update(String id, PaymentStyleUpdateInput input);
  Future<void> delete(String id);
}

class DioPaymentStyleRepository implements PaymentStyleRepository {
  DioPaymentStyleRepository(this.api);
  final ApiClient api;

  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async {
    final query = category == null
        ? null
        : <String, dynamic>{'category': category};
    final list = await api.getList(
      '${PaymentStyleEndpoints.base}/tree',
      query: query,
    );
    return list.map(PaymentStyleNode.fromJson).toList();
  }

  @override
  Future<List<PaymentStyleNode>> subtree(String id) async {
    final list = await api.getList(PaymentStyleEndpoints.subtree(id));
    return list.map(PaymentStyleNode.fromJson).toList();
  }

  @override
  Future<PaymentStyleDetail> detail(String id) async {
    final json = await api.get(PaymentStyleEndpoints.one(id));
    return PaymentStyleDetail.fromJson(json);
  }

  @override
  Future<PaymentStyleDetail> create(PaymentStyleSaveInput input) async {
    final json = await api.post(
      PaymentStyleEndpoints.base,
      body: input.toJson(),
    );
    return PaymentStyleDetail.fromJson(json);
  }

  @override
  Future<PaymentStyleDetail> update(
    String id,
    PaymentStyleUpdateInput input,
  ) async {
    final json = await api.put(
      PaymentStyleEndpoints.one(id),
      body: input.toJson(),
    );
    return PaymentStyleDetail.fromJson(json);
  }

  @override
  Future<void> delete(String id) => api.delete(PaymentStyleEndpoints.one(id));
}

final paymentStyleRepositoryProvider = Provider<PaymentStyleRepository>(
  (ref) => DioPaymentStyleRepository(ref.watch(apiClientProvider)),
);
