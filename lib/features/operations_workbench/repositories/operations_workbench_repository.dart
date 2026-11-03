import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../shared/auth/read_owner_fence.dart';
import '../../../shared/paging/scoped_category_read.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../../shared/paging/prepared_page_read.dart';
import '../../../shared/paging/page_preparation_coordinator.dart';
import '../../../shared/paging/page_preparation_budget_provider.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/retain_read_snapshot.dart';
import '../../../core/network/data_write_revision.dart';
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

/// Entry categories need counts, not historical rows or table filter buckets.
abstract interface class OperationsWorkbenchOverviewGateway {
  Future<OperationsWorkbenchData> loadOverview({
    required OperationsWorkbenchDepartment department,
    String? keyword,
  });
}

/// Rows and an entry overview may finish independently. Keep the overview's
/// exact department/keyword/warehouse repository scope and never let a late
/// overview overwrite a newer accepted table summary.
Future<void> readWorkbenchCategoryOverview(
  WidgetRef ref, {
  required OperationsWorkbenchOverviewGateway repository,
  required OperationsWorkbenchDepartment department,
  required String? keyword,
  required bool Function() isCurrent,
  required void Function(Map<String, int>) accept,
  required void Function() rejected,
}) async {
  final owner = captureReadOwner(ref);
  try {
    final data = await ref
        .read(scopedCategoryReadProvider)
        .read(
          query: [repository, department, keyword],
          fetch: () =>
              repository.loadOverview(department: department, keyword: keyword),
        );
    if (owner() && isCurrent()) {
      accept(Map.unmodifiable(data.summary.statusCounts));
    }
  } catch (error) {
    if (owner() && isCurrent() && pagedReadAccessDenied(error)) rejected();
  }
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
    implements
        OperationsWorkbenchGateway,
        OperationsWorkbenchOverviewGateway,
        SubcontractBomGapGateway {
  const OperationsWorkbenchRepository(
    this.api, {
    this.prepared,
    this.preparedReader,
  });

  final ApiClient api;
  final PreparedPageRead<OperationsWorkbenchTask>? prepared;
  final PreparedPageRead<OperationsWorkbenchTask> Function()? preparedReader;

  @override
  Future<OperationsWorkbenchData> loadOverview({
    required OperationsWorkbenchDepartment department,
    String? keyword,
  }) async => OperationsWorkbenchData.fromJson(
    await api.get(
      '/operations/workbench/${department.apiValue}/overview',
      query: {
        if (keyword != null && keyword.trim().isNotEmpty)
          'keyword': keyword.trim(),
      },
    ),
    department,
  );

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
    bool preferPrepared = false,
  }) async {
    final query = <String, dynamic>{
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
        if (entry.value != null)
          (entry.key.startsWith('search.') ? entry.key : 'f.${entry.key}'):
              entry.value,
      'issuedFrom': ?issuedFrom,
      'issuedTo': ?issuedTo,
      'needFrom': ?needFrom,
      'needTo': ?needTo,
    };
    Future<PagedResult<OperationsWorkbenchTask>> fetch() async =>
        (await _fetch(department, query)).toPagedReadSnapshot();
    final reads = preparedReader?.call() ?? prepared;
    if (page == 1 && reads != null) {
      final response = await reads.read(
        [api, department, query],
        fetch,
        preferPrepared: preferPrepared,
      );
      return (response
              as PagedReadSnapshot<
                OperationsWorkbenchTask,
                OperationsWorkbenchData
              >)
          .snapshot;
    }
    return _fetch(department, query);
  }

  Future<OperationsWorkbenchData> _fetch(
    OperationsWorkbenchDepartment department,
    Map<String, dynamic> query,
  ) async => OperationsWorkbenchData.fromJson(
    await api.get('/operations/workbench/${department.apiValue}', query: query),
    department,
  );

  Future<void> prepareWorkingPage(
    OperationsWorkbenchDepartment department,
    String stage,
  ) async {
    final query = <String, dynamic>{'page': 1, 'size': 50, 'status': stage};
    await (preparedReader?.call() ?? prepared)?.prepare([
      api,
      department,
      query,
    ], () async => (await _fetch(department, query)).toPagedReadSnapshot());
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
      (ref) => OperationsWorkbenchRepository(
        ref.watch(apiClientProvider),
        preparedReader: () => ref.read(operationsWorkbenchPreparedProvider),
      ),
      dependencies: [apiClientProvider, operationsWorkbenchPreparedProvider],
    );

final operationsWorkbenchPreparedProvider = Provider.autoDispose((ref) {
  ref.watch(exportContextEpochProvider);
  ref.watch(dataWriteRevisionProvider);
  retainReadSnapshot(ref);
  final reads = PreparedPageRead<OperationsWorkbenchTask>();
  ref.onDispose(reads.dispose);
  return reads;
}, dependencies: [exportContextEpochProvider]);

final operationsWorkbenchPreparationProvider = Provider((ref) {
  final coordinator = PagePreparationCoordinator(
    budget: ref.read(pagePreparationBudgetProvider),
  );
  final retire = pagePreparationRetirementCallback(ref, coordinator.retire);

  ref.listen(exportContextEpochProvider, (_, _) => retire());
  ref.listen(dataWriteRevisionProvider, (_, _) => retire());
  ref.onDispose(coordinator.dispose);
  return coordinator;
}, dependencies: [exportContextEpochProvider]);
