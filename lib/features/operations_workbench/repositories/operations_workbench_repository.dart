import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/operations_workbench.dart';

abstract interface class OperationsWorkbenchGateway {
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  });
}

/// 委外任务中心缺 BOM 的申请行「通知研发完善」(ADR-143 §二.3)。
///
/// 与列表读取分开一个接口：列表的测试替身不必跟着实现写动作。
abstract interface class SubcontractBomGapGateway {
  /// 给这条委外申请明细的委外件通知研发完善 BOM(幂等：已有未完成任务时只把
  /// 当前账号加入等待名单；该委外件已有 BOM 时服务端不做任何事)。
  Future<SubcontractBomForwardResult> forwardBom(String applicationItemId);
}

class OperationsWorkbenchRepository
    implements OperationsWorkbenchGateway, SubcontractBomGapGateway {
  const OperationsWorkbenchRepository(this.api);

  final ApiClient api;

  @override
  Future<OperationsWorkbenchData> load({
    required OperationsWorkbenchDepartment department,
    int page = 1,
    int size = 20,
    String? keyword,
    String? status,
    String? exception,
    String? dateFrom,
    String? dateTo,
    String? sort,
    String? order,
    Map<String, String?> columnFilters = const {},
    String? issuedFrom,
    String? issuedTo,
    String? needFrom,
    String? needTo,
  }) async {
    final json = await api.get(
      '/operations/workbench/${department.apiValue}',
      query: {
        'page': page,
        'size': size,
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
        if (status != null && status.isNotEmpty) 'status': status,
        if (exception != null && exception.isNotEmpty) 'exception': exception,
        'dateFrom': ?dateFrom,
        'dateTo': ?dateTo,
        'sort': ?sort,
        if (sort != null) 'order': order ?? 'asc',
        for (final entry in columnFilters.entries)
          if (entry.value != null) 'f.${entry.key}': entry.value,
        'issuedFrom': ?issuedFrom,
        'issuedTo': ?issuedTo,
        'needFrom': ?needFrom,
        'needTo': ?needTo,
      },
    );
    return OperationsWorkbenchData.fromJson(json, department);
  }

  @override
  Future<SubcontractBomForwardResult> forwardBom(
    String applicationItemId,
  ) async => SubcontractBomForwardResult.fromJson(
    // 带一个空 body：Flutter Web 上无 body 的 POST 有 15 秒连接上限。
    await api.post(
      ApiEndpoints.subcontractApplicationItemForwardBom(applicationItemId),
      body: const <String, Object?>{},
    ),
  );
}

final operationsWorkbenchRepositoryProvider =
    Provider<OperationsWorkbenchRepository>(
      (ref) => OperationsWorkbenchRepository(ref.watch(apiClientProvider)),
    );
