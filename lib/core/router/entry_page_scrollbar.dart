import 'package:flutter/material.dart';

import '../../components/layout/uten_page_layout.dart';
import '../responsive/breakpoint.dart';
import 'route_names.dart';

/// Workbench tabs and browsing/management cards use touch scrolling on narrow
/// windows. Editors and detail pages deliberately keep the normal page rail.
abstract final class UtenEntryPageScrollbarPolicy {
  static const entries = <String>{
    RouteName.dashboard,
    RouteName.notice,
    RouteName.profile,
    RouteName.settings,
    RouteName.basicinfo,
    RouteName.companyFiles,
    RouteName.expense,
    RouteName.payrollSlipList,
    RouteName.suggestion,
    RouteName.myVisitors,
    RouteName.hrTaskCenter,
    RouteName.employee,
    RouteName.department,
    RouteName.visitorApproval,
    RouteName.hrProfileChanges,
    RouteName.finance,
    '/payroll/review',
    RouteName.productionWorkshopTasks,
    RouteName.workshopMaterialBin,
    RouteName.production,
    RouteName.productionWhereUsed,
    RouteName.rdTaskCenter,
    RouteName.warehouse,
    RouteName.purchase,
    RouteName.subcontract,
    RouteName.qualityTaskCenter,
    RouteName.salesManagerReview,
    RouteName.sales,
    RouteName.websiteInquiry,
    RouteName.websiteManagement,
    RouteName.securityScan,
    RouteName.adminServerStatus,
    RouteName.adminPermissions,
    RouteName.adminAuditLogs,
    RouteName.adminSystemSettings,
  };

  static bool hidesRail(String location, double width) =>
      width < UtenBreakpoints.desktopStart &&
      entries.contains(Uri.tryParse(location)?.path);
}

/// The wrapper stays mounted when window size changes. Scroll positions,
/// focus and form state therefore survive a rail visibility change.
class UtenEntryPageScrollbar extends StatelessWidget {
  const UtenEntryPageScrollbar({
    super.key,
    required this.location,
    required this.child,
  });

  final String location;
  final Widget child;

  @override
  Widget build(BuildContext context) => UtenPageScrollbarVisibilityScope(
    hidden: UtenEntryPageScrollbarPolicy.hidesRail(
      location,
      MediaQuery.sizeOf(context).width,
    ),
    route: ModalRoute.of(context),
    child: child,
  );
}
