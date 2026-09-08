import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/providers/list_refresh_provider.dart';
import '../../dashboard/providers/dashboard_overview_provider.dart';
import '../../notice/providers/notice_providers.dart';
import '../../warehouse/providers/production_draw_count_provider.dart';
import 'production_pending_provider.dart';
import 'production_workshop_task_count_provider.dart';

const productionExecutionRefreshKey = 'production:execution';

/// Refresh confirmed plan effects without initializing unrelated badge queries.
/// Creating only a preparation child must not call this release refresh.
void refreshAfterProductionPlanGenerated(WidgetRef ref) {
  bumpListRefresh(ref, productionExecutionRefreshKey);
  if (ref.exists(productionWorkshopTaskCountProvider)) {
    ref.read(productionWorkshopTaskCountProvider.notifier).refresh();
  }
  if (ref.exists(productionPendingCountProvider)) {
    ref.read(productionPendingCountProvider.notifier).refresh();
  }
  if (ref.exists(unreadNoticeCountProvider)) {
    ref.read(unreadNoticeCountProvider.notifier).refresh();
  }
  ref.invalidate(warehouseProductionDrawPendingCountProvider);
  ref.invalidate(dashboardOverviewProvider);
  ref.invalidate(noticeListProvider);
}
