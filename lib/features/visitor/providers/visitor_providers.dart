// 访客端 Provider：申请列表 / 详情(接待人按姓名现搜，不再下发部门目录)。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_provider.dart';
import '../../../shared/paging/shared_read_provider_owner.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../models/visitor_application.dart';
import '../repositories/visitor_repository.dart';
import '../network/visitor_api_client.dart';
import 'visitor_session_provider.dart';
import 'visitor_column_queries.dart';

/// 我的访客申请（按状态过滤；status=null 全部）。
typedef VisitorApplicationsQuery = ({String? status, int page});

final visitorApplicationsReadProvider = Provider.autoDispose
    .family<ScopedPagedReadProviderLease<VisitorApplication>, String?>(
      (ref, status) {
        ref.watch(visitorSessionProvider);
        ref.watch(visitorRepositoryProvider);
        final columns = ref.watch(visitorMineColumnsProvider);
        return ScopedPagedReadProviderLease(ref, query: (status, columns));
      },
      dependencies: [
        exportContextEpochProvider,
        visitorSessionProvider,
        visitorRepositoryProvider,
        visitorMineColumnsProvider,
      ],
    );

final visitorApplicationsProvider = FutureProvider.autoDispose
    .family<PagedResult<VisitorApplication>, VisitorApplicationsQuery>(
      (ref, q) async {
        final session = ref.watch(visitorSessionProvider);
        final api = ref.watch(visitorApiProvider);
        final repository = ref.watch(visitorRepositoryProvider);
        final columns = ref.watch(visitorMineColumnsProvider);
        final reader = ref.watch(visitorApplicationsReadProvider(q.status));
        final scope = await api.captureRequestScope(
          isCurrent: () =>
              ref.mounted &&
              identical(ref.read(visitorSessionProvider), session) &&
              identical(ref.read(visitorApiProvider), api),
        );
        return scope.run(
          () => reader.read(
            q.page,
            fetchPage: (page) => repository.myApplications(
              status: q.status,
              page: page,
              size: 100,
              columns: columns.searches,
              sort: columns.sort,
              ascending: columns.ascending,
            ),
            fetchPageSized: (page, size) => repository.myApplications(
              status: q.status,
              page: page,
              size: size,
              columns: columns.searches,
              sort: columns.sort,
              ascending: columns.ascending,
            ),
          ),
        );
      },
      retry: pagedReadProviderRetry,
      dependencies: [
        visitorSessionProvider,
        visitorRepositoryProvider,
        visitorApplicationsReadProvider,
        visitorMineColumnsProvider,
      ],
    );

/// 申请详情（含审批轨迹）。
final visitorApplicationDetailProvider = FutureProvider.autoDispose
    .family<VisitorApplicationDetail, String>((ref, id) async {
      final session = ref.watch(visitorSessionProvider);
      final api = ref.watch(visitorApiProvider);
      final repository = ref.watch(visitorRepositoryProvider);
      bool current() =>
          ref.mounted &&
          identical(ref.read(visitorSessionProvider), session) &&
          identical(ref.read(visitorApiProvider), api);
      // The visitor client owns credentials independently of employee UI.
      final scope = await api.captureRequestScope(isCurrent: current);
      return scope.run(
        () => runSharedProviderRead(
          ref,
          () => repository.getApplication(id),
          isCurrent: current,
        ),
      );
    });
