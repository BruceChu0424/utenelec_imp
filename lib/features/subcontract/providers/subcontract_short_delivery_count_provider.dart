// ADR-098 委外回厂短交待判定计数(委外 hub「回厂短交判定」卡片徽章)。
//
// 随工作台徽章汇总一次带回(ADR-108, 原端点 /subcontract/short-deliveries/count 同一口径),
// 不单独轮询: pending = 待判定(含分批等待已过预计到齐日)、waiting = 分批等待中。
// 不登记进徽章入口: 委外任务中心已把「回厂短交待判定」的订货单计入委外红徽章,
// 这里只是同数展示(准则 14：同一件事只数一次)。判定页自己的分段计数随列表加载。
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/models/subcontract_short_delivery.dart';
import '../../../shared/badges/badge_registry.dart';

final subcontractShortDeliveryCountProvider =
    Provider<SubcontractShortDeliveryCounts>((ref) {
      return SubcontractShortDeliveryCounts(
        pending: ref.watch(
          badgeFactProvider(BadgeFact.subcontractShortDeliveryPending),
        ),
        tolerant: ref.watch(
          badgeFactProvider(BadgeFact.subcontractShortDeliveryTolerant),
        ),
        waiting: ref.watch(
          badgeFactProvider(BadgeFact.subcontractShortDeliveryWaiting),
        ),
      );
    });
