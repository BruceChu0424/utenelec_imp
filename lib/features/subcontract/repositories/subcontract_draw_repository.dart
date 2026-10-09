// ADR-143 委外领料：/api/subcontract/draw-tasks/* 的数据访问。
//
// 页面只依赖 [SubcontractDrawGateway]，测试用假实现替换；数量一律由服务端算好。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../models/subcontract_draw.dart';

abstract interface class SubcontractDrawGateway {
  /// 「待处理·领料」列表。[status] 为空 = 全部；[orderId] / [orderItemIds] 为定位筛选
  /// (进行中「可领料」跳转、可领料通知深链)。
  Future<SubcontractDrawTaskList> list({
    int page = 1,
    int size = 50,
    String? keyword,
    String? status,
    String? orderId,
    List<String> orderItemIds = const [],
  });

  /// 领料计数(ADR-171 修订二): 红 = 调用者可动手的可领行数; 黄 = 已提交领料、
  /// 等仓库发出的行数。无领料权限两者恒为 0。
  Future<({int drawable, int submitted})> drawCounts();

  Future<SubcontractDrawTaskDetail> detail(String orderItemId);

  /// 只读预览：按「交期、订货单号、行号」联合分配后的本批可领与物料出仓明细。
  Future<SubcontractDrawPreview> preview(
    List<SubcontractDrawRequestItem> items,
  );

  Future<SubcontractDrawSubmitResult> submit({
    required List<SubcontractDrawRequestItem> items,
    required String idempotencyKey,
  });

  /// 撤回这些委外订货明细已提交、仓库尚未发出的领料。
  Future<SubcontractDrawWithdrawResult> withdraw(List<String> orderItemIds);

  /// 结束领料(不再发外)：撤回未发领料并关闭该明细的领料计划。
  Future<void> close(String orderItemId, String reason);
}

class SubcontractDrawRepository implements SubcontractDrawGateway {
  const SubcontractDrawRepository(this.api);

  /// 一次批量领料最多带入的委外任务数(与服务端预览/提交上限一致)。
  static const batchLimit = 50;

  /// 「待处理」拍平表的领料行一次拉全的上限(与服务端 MAX_PAGE_SIZE 一致)；
  /// 领料行钉在表格顶部不走分页，超过上限属于数据异常，服务端计数口径可对账。
  static const listLimit = 200;
  static const base = '/subcontract/draw-tasks';

  final ApiClient api;

  @override
  Future<SubcontractDrawTaskList> list({
    int page = 1,
    int size = 50,
    String? keyword,
    String? status,
    String? orderId,
    List<String> orderItemIds = const [],
  }) async {
    final ids = orderItemIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);
    final json = await api.get(
      base,
      query: {
        'page': page,
        'size': size,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (status != null && status.isNotEmpty) 'status': status,
        if (orderId != null && orderId.isNotEmpty) 'orderId': orderId,
        if (ids.isNotEmpty) 'orderItemIds': ids.join(','),
      },
    );
    return SubcontractDrawTaskList.fromJson(json);
  }

  @override
  Future<({int drawable, int submitted})> drawCounts() async {
    final json = await api.get('$base/count');
    int of(String key) {
      final value = json[key];
      return value is num ? value.toInt() : 0;
    }

    return (drawable: of('drawable'), submitted: of('submitted'));
  }

  @override
  Future<SubcontractDrawTaskDetail> detail(String orderItemId) async =>
      SubcontractDrawTaskDetail.fromJson(
        await api.get('$base/${Uri.encodeComponent(orderItemId)}/materials'),
      );

  @override
  Future<SubcontractDrawPreview> preview(
    List<SubcontractDrawRequestItem> items,
  ) async => SubcontractDrawPreview.fromJson(
    await api.post(
      '$base/preview',
      body: {'items': items.map((item) => item.toJson()).toList()},
    ),
  );

  @override
  Future<SubcontractDrawSubmitResult> submit({
    required List<SubcontractDrawRequestItem> items,
    required String idempotencyKey,
  }) async => SubcontractDrawSubmitResult.fromJson(
    await api.post(
      '$base/submit',
      body: {
        'items': items.map((item) => item.toJson()).toList(),
        'idempotencyKey': idempotencyKey,
      },
    ),
  );

  @override
  Future<SubcontractDrawWithdrawResult> withdraw(
    List<String> orderItemIds,
  ) async => SubcontractDrawWithdrawResult.fromJson(
    await api.post('$base/withdraw', body: {'orderItemIds': orderItemIds}),
  );

  @override
  Future<void> close(String orderItemId, String reason) async {
    await api.post(
      '$base/${Uri.encodeComponent(orderItemId)}/close',
      body: {'reason': reason},
    );
  }
}

final subcontractDrawRepositoryProvider = Provider<SubcontractDrawGateway>(
  (ref) => SubcontractDrawRepository(ref.watch(apiClientProvider)),
);
