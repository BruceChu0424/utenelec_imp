// 访客端 Provider：申请列表 / 详情(接待人按姓名现搜，不再下发部门目录)。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/paged_result.dart';
import '../models/visitor_application.dart';
import '../repositories/visitor_repository.dart';

/// 我的访客申请（按状态过滤；status=null 全部）。
typedef VisitorApplicationsQuery = ({String? status, int page});

final visitorApplicationsProvider = FutureProvider.autoDispose
    .family<PagedResult<VisitorApplication>, VisitorApplicationsQuery>((
      ref,
      q,
    ) {
      return ref
          .watch(visitorRepositoryProvider)
          .myApplications(status: q.status, page: q.page);
    });

/// 申请详情（含审批轨迹）。
final visitorApplicationDetailProvider = FutureProvider.autoDispose
    .family<VisitorApplicationDetail, String>((ref, id) {
      return ref.watch(visitorRepositoryProvider).getApplication(id);
    });
