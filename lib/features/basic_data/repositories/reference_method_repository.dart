import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/reference_method_option.dart';

class ReferenceMethodRepository {
  ReferenceMethodRepository(this.api);
  final ApiClient api;

  Future<List<ReferenceMethodOption>> settlementMethods() async {
    final rows = await api.getList(ApiEndpoints.settlementMethods);
    return rows.map(ReferenceMethodOption.fromJson).toList();
  }

  /// 内联新增结算方式（payment_style:edit；销售单据编辑页下拉「添加」用）。
  /// 返回新建项（含 id），调用方刷新字典后自动选中新值。
  Future<ReferenceMethodOption> createSettlement(String name) async {
    final json = await api.post(
      ApiEndpoints.settlementMethods,
      body: {'name': name},
    );
    return ReferenceMethodOption.fromJson(json);
  }

  Future<List<ReferenceMethodOption>> financeMethods(String direction) async {
    final rows = await api.getList(
      ApiEndpoints.financePaymentMethods,
      query: {'direction': direction},
    );
    return rows.map(ReferenceMethodOption.fromJson).toList();
  }
}

final referenceMethodRepositoryProvider = Provider<ReferenceMethodRepository>(
  (ref) => ReferenceMethodRepository(ref.watch(apiClientProvider)),
);

final settlementMethodOptionsProvider =
    FutureProvider.autoDispose<List<ReferenceMethodOption>>(
      (ref) => ref.watch(referenceMethodRepositoryProvider).settlementMethods(),
    );

final financePaymentMethodOptionsProvider = FutureProvider.autoDispose
    .family<List<ReferenceMethodOption>, String>(
      (ref, direction) => ref
          .watch(referenceMethodRepositoryProvider)
          .financeMethods(direction),
    );
