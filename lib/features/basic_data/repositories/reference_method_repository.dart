import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/master_facet.dart';
import '../models/reference_method_option.dart';
import '../models/settlement_method_admin.dart';

class ReferenceMethodRepository {
  ReferenceMethodRepository(this.api);
  final ApiClient api;

  Future<List<ReferenceMethodOption>> settlementMethods() async {
    final rows = await api.getList(ApiEndpoints.settlementMethods);
    return rows.map(ReferenceMethodOption.fromJson).toList();
  }

  /// 内联新增结算方式（settlement_method:create；单据编辑页下拉「添加」用）。
  /// 返回新建项（含 id），调用方刷新字典后自动选中新值；[terms] 为可选账期
  /// 策略（结算方式管理页 V453 提供；null=落库默认收货日当天到期）。
  Future<ReferenceMethodOption> createSettlement(
    String name, {
    Map<String, dynamic>? terms,
  }) async {
    final json = await api.post(
      ApiEndpoints.settlementMethods,
      body: {'name': name, 'terms': ?terms},
    );
    return ReferenceMethodOption.fromJson(json);
  }

  /// 结算方式管理页全量（含禁用行与账期策略；settlement_method:view）。
  ///
  /// [filters] 表头字段精确筛选（状态/系统角色/到期基准/到期规则），值为
  /// [kMasterFilterNullValue] 表示筛该字段为空（nullFields 哨兵）。
  Future<List<SettlementMethodAdminItem>> settlementAdminList({
    Map<String, String?> filters = const {},
  }) async {
    final rows = await api.getList(
      ApiEndpoints.settlementMethodsAdmin,
      query: masterFilterQueryParams(filters),
    );
    return rows.map(SettlementMethodAdminItem.fromJson).toList();
  }

  /// 结算方式表头筛选桶（各可筛字段可选值 + 空值计数）。
  Future<SettlementMethodFacets> settlementAdminFacets() async {
    final json = await api.get(ApiEndpoints.settlementMethodsAdminFacets);
    return SettlementMethodFacets.fromJson(json);
  }

  /// 维护账期策略与可选改名（settlement_method:edit；系统角色锁定由服务端拒绝）。
  Future<void> updateSettlementTerms(
    String id,
    Map<String, dynamic> body,
  ) async {
    await api.put(ApiEndpoints.settlementMethodTerms(id), body: body);
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
