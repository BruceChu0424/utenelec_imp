// 访客端 Provider：申请列表 / 详情(接待人按姓名现搜，不再下发部门目录)。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../models/visitor_application.dart';
import '../repositories/visitor_repository.dart';
import 'visitor_session_provider.dart';

/// 我的访客申请（按状态过滤；status=null 全部）。
typedef VisitorApplicationsQuery = ({String? status, int page});

final visitorApplicationsReadProvider = Provider.autoDispose
    .family<ScopedPagedReadProviderLease<VisitorApplication>, String?>(
      (ref, status) {
        ref.watch(visitorSessionProvider);
        ref.watch(visitorRepositoryProvider);
        return ScopedPagedReadProviderLease(ref, query: (status,));
      },
      dependencies: [
        exportContextEpochProvider,
        visitorSessionProvider,
        visitorRepositoryProvider,
      ],
    );

final visitorApplicationsProvider = FutureProvider.autoDispose
    .family<PagedResult<VisitorApplication>, VisitorApplicationsQuery>(
      (ref, q) {
        ref.watch(visitorSessionProvider);
        final repository = ref.watch(visitorRepositoryProvider);
        return ref
            .watch(visitorApplicationsReadProvider(q.status))
            .read(
              q.page,
              fetchPage: (page) =>
                  repository.myApplications(status: q.status, page: page),
            );
      },
      retry: pagedReadProviderRetry,
      dependencies: [
        visitorSessionProvider,
        visitorRepositoryProvider,
        visitorApplicationsReadProvider,
      ],
    );

/// 申请详情（含审批轨迹）。
final visitorApplicationDetailProvider = FutureProvider.autoDispose
    .family<VisitorApplicationDetail, String>((ref, id) {
      return ref.watch(visitorRepositoryProvider).getApplication(id);
    });
