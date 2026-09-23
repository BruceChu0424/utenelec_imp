// 被访人「我的访客」页的四档计数(ADR-100)。
//
// 随工作台徽章汇总一次带回(ADR-108, 原端点 /visitor-approval/host-pending-count 同一口径),
// 不单独轮询; 卡面红黄两枚(待我确认 / 在办合计)由服务端目录算好, 本 provider 只给页内
// 两个黄分段用(服务端同一次扫描保证 ongoing = hrReviewing + awaitingVisit)。
// 无 visitor:host-confirm 权限时全 0。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../visitor/repositories/visitor_staff_repository.dart';
import '../../../shared/badges/badge_registry.dart';

final visitorHostCountsProvider = Provider<VisitorHostCounts>((ref) {
  return VisitorHostCounts(
    pending: ref.watch(badgeFactProvider(BadgeFact.visitorHostPending)),
    ongoing: ref.watch(badgeFactProvider(BadgeFact.visitorHostOngoing)),
    hrReviewing: ref.watch(badgeFactProvider(BadgeFact.visitorHostHrReviewing)),
    awaitingVisit: ref.watch(
      badgeFactProvider(BadgeFact.visitorHostAwaitingVisit),
    ),
  );
});
