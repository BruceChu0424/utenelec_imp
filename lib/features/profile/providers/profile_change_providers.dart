// 个人信息修改 Provider。
// 文档：docs/03-页面/我的页.md

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../../shared/paging/scoped_paged_read_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;

import '../../basic_data/models/master_facet.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/profile_change_request.dart';
import '../repositories/profile_change_repository.dart';
import 'profile_column_queries.dart';

/// 本人完整员工档案。
///
/// 只能通过后端从当前认证主体解析员工档案，不能相信 session/JWT 中可陈旧的
/// employeeId 再调用 HR 详情端点；`null` 专指当前账号未绑定可用员工档案。
final myEmployeeProfileProvider = FutureProvider.autoDispose<EmployeeProfile?>((
  ref,
) {
  ref.watch(masterDataSessionKeyProvider);
  ref.watch(authenticatedScopeProvider);
  return ref.watch(employeeRepositoryProvider).getMe();
});

/// 员工自查列表（按状态过滤 + 分页；status null = 全部）。
final myProfileChangesReadProvider = Provider.autoDispose
    .family<ScopedPagedReadProviderLease<MyProfileChangeListItem>, String?>(
      (ref, status) {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(authenticatedScopeProvider);
        ref.watch(profileChangeRepositoryProvider);
        return ScopedPagedReadProviderLease(ref, query: (status,));
      },
      dependencies: [
        exportContextEpochProvider,
        masterDataSessionKeyProvider,
        authenticatedScopeProvider,
        profileChangeRepositoryProvider,
      ],
    );

Future<PagedReadSnapshot<T, ProfileChangePage<T>>> _profilePageSnapshot<T>(
  Future<ProfileChangePage<T>> pending,
) async {
  final result = await pending;
  return PagedReadSnapshot(
    page: PagedResult(
      items: result.items,
      page: result.page,
      size: result.size,
      total: result.total,
      totalPages: result.totalPages,
    ),
    snapshot: result,
  );
}

/// family key 含 page：列表页翻页时换 key 触发后端按页拉取（修原先写死 page=1
/// 致 >20 条静默截断的 bug）。计数入口（profile_page）传 page=1、读 page.total 即真总数。
final myProfileChangesProvider = FutureProvider.autoDispose
    .family<
      ProfileChangePage<MyProfileChangeListItem>,
      ({String? status, int page})
    >(
      (ref, key) async {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(authenticatedScopeProvider);
        final repository = ref.watch(profileChangeRepositoryProvider);
        final result = await ref
            .watch(myProfileChangesReadProvider(key.status))
            .read(
              key.page,
              fetchPage: (page) => _profilePageSnapshot(
                repository.myList(page: page, status: key.status),
              ),
            );
        return (result
                as PagedReadSnapshot<
                  MyProfileChangeListItem,
                  ProfileChangePage<MyProfileChangeListItem>
                >)
            .snapshot;
      },
      retry: pagedReadProviderRetry,
      dependencies: [
        masterDataSessionKeyProvider,
        authenticatedScopeProvider,
        profileChangeRepositoryProvider,
        myProfileChangesReadProvider,
      ],
    );

/// Table-only criteria stay separate from profile counters and other previews.
final myProfileChangeTableReadProvider = Provider.autoDispose
    .family<ScopedPagedReadProviderLease<MyProfileChangeListItem>, String?>(
      (ref, status) {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(authenticatedScopeProvider);
        ref.watch(profileChangeRepositoryProvider);
        final columns = ref.watch(profileMineColumnsProvider);
        return ScopedPagedReadProviderLease(ref, query: (status, columns));
      },
      dependencies: [
        exportContextEpochProvider,
        masterDataSessionKeyProvider,
        authenticatedScopeProvider,
        profileChangeRepositoryProvider,
        profileMineColumnsProvider,
      ],
    );

final myProfileChangeTableProvider = FutureProvider.autoDispose
    .family<
      ProfileChangePage<MyProfileChangeListItem>,
      ({String? status, int page})
    >(
      (ref, key) async {
        final repository = ref.watch(profileChangeRepositoryProvider);
        final columns = ref.watch(profileMineColumnsProvider);
        final result = await ref
            .watch(myProfileChangeTableReadProvider(key.status))
            .read(
              key.page,
              fetchPage: (page) => _profilePageSnapshot(
                repository.myList(
                  page: page,
                  status: key.status,
                  columns: columns.searches,
                  sort: columns.sort,
                  ascending: columns.ascending,
                ),
              ),
            );
        return (result
                as PagedReadSnapshot<
                  MyProfileChangeListItem,
                  ProfileChangePage<MyProfileChangeListItem>
                >)
            .snapshot;
      },
      retry: pagedReadProviderRetry,
      dependencies: [
        profileChangeRepositoryProvider,
        profileMineColumnsProvider,
        myProfileChangeTableReadProvider,
      ],
    );

/// 员工自查单批详情。
final myProfileChangeDetailProvider = FutureProvider.autoDispose
    .family<ProfileChangeBatch, String>((ref, batchId) {
      ref.watch(masterDataSessionKeyProvider);
      ref.watch(authenticatedScopeProvider);
      return ref.watch(profileChangeRepositoryProvider).myBatchDetail(batchId);
    });

/// HR 队列（按状态过滤 + 分页；status null = pending）。
/// family key 含 page：列表页翻页按页拉取（修原先写死 page=1 致 >20 条静默截断；
/// HR 全公司队列 >20 待审是常态，截断风险高于个人页）。
/// 员工详情页「待审修改」区块等只按状态取用；HR 队列页另有带部门筛选的
/// [hrProfileChangeQueueProvider]（两者同一后端端点，key 形状不同）。
final hrProfileChangesProvider = FutureProvider.autoDispose
    .family<
      ProfileChangePage<HrProfileChangeListItem>,
      ({String? status, int page})
    >((ref, key) {
      ref.watch(masterDataSessionKeyProvider);
      ref.watch(authenticatedScopeProvider);
      return ref
          .watch(profileChangeRepositoryProvider)
          .hrList(page: key.page, status: key.status);
    });

/// Employee-detail preview: query the employee before pagination; global page
/// one cannot establish whether a different employee has pending batches.
final hrProfileEmployeePendingProvider = FutureProvider.autoDispose
    .family<ProfileChangePage<HrProfileChangeListItem>, String>((
      ref,
      employeeId,
    ) {
      ref.watch(masterDataSessionKeyProvider);
      ref.watch(authenticatedScopeProvider);
      return ref
          .watch(profileChangeRepositoryProvider)
          .hrList(employeeId: employeeId, status: 'pending', size: 3);
    });

/// HR 队列页专用（2026-09-10）：key 增 departmentId——表头「部门」筛选下推后端
/// （原先只裁剪当前页，命中行可能落在其他页）；换筛选即换 key，回第 1 页由页面负责。
final hrProfileChangeQueueReadProvider = Provider.autoDispose
    .family<
      ScopedPagedReadProviderLease<HrProfileChangeListItem>,
      ({String? status, String? departmentId})
    >(
      (ref, query) {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(authenticatedScopeProvider);
        ref.watch(profileChangeRepositoryProvider);
        final columns = ref.watch(profileHrColumnsProvider);
        return ScopedPagedReadProviderLease(ref, query: (query, columns));
      },
      dependencies: [
        exportContextEpochProvider,
        masterDataSessionKeyProvider,
        authenticatedScopeProvider,
        profileChangeRepositoryProvider,
        profileHrColumnsProvider,
      ],
    );

final hrProfileChangeQueueProvider = FutureProvider.autoDispose
    .family<
      ProfileChangePage<HrProfileChangeListItem>,
      ({String? status, String? departmentId, int page})
    >(
      (ref, key) async {
        ref.watch(masterDataSessionKeyProvider);
        ref.watch(authenticatedScopeProvider);
        final repository = ref.watch(profileChangeRepositoryProvider);
        final columns = ref.watch(profileHrColumnsProvider);
        final result = await ref
            .watch(
              hrProfileChangeQueueReadProvider((
                status: key.status,
                departmentId: key.departmentId,
              )),
            )
            .read(
              key.page,
              fetchPage: (page) => _profilePageSnapshot(
                repository.hrList(
                  page: page,
                  status: key.status,
                  departmentId: key.departmentId,
                  columns: columns.searches,
                  sort: columns.sort,
                  ascending: columns.ascending,
                ),
              ),
            );
        return (result
                as PagedReadSnapshot<
                  HrProfileChangeListItem,
                  ProfileChangePage<HrProfileChangeListItem>
                >)
            .snapshot;
      },
      retry: pagedReadProviderRetry,
      dependencies: [
        masterDataSessionKeyProvider,
        authenticatedScopeProvider,
        profileChangeRepositoryProvider,
        hrProfileChangeQueueReadProvider,
        profileHrColumnsProvider,
      ],
    );

/// HR 队列表头筛选桶（部门），按当前分段状态取后端聚合（全量，非当前页）。
final hrProfileChangeFacetsProvider = FutureProvider.autoDispose
    .family<Map<String, List<MasterFacetBucket>>, String?>((ref, status) {
      ref.watch(masterDataSessionKeyProvider);
      ref.watch(authenticatedScopeProvider);
      return ref
          .watch(profileChangeRepositoryProvider)
          .hrFacets(status: status);
    });

/// HR 单批详情。
final hrProfileChangeDetailProvider = FutureProvider.autoDispose
    .family<ProfileChangeBatch, String>((ref, batchId) {
      ref.watch(masterDataSessionKeyProvider);
      ref.watch(authenticatedScopeProvider);
      return ref.watch(profileChangeRepositoryProvider).hrBatchDetail(batchId);
    });
