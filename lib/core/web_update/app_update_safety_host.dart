import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import '../../shared/drafts/form_draft_navigation.dart';
import '../router/route_names.dart';
import 'web_update_safety.dart';

/// Routes with local business input must attest to their saved state. Unknown
/// editors stay protected even after hours of inactivity. The common draft
/// mixin and master table editors attest for their whole mounted lifecycle.
bool canAutomaticallyUpdateRoute(String path) =>
    const {
      RouteName.dashboard,
      RouteName.accessDenied,
      RouteName.notFound,
      RouteName.adminAuditLogs,
      RouteName.adminServerStatus,
      RouteName.deviceAuditReceipts,
    }.contains(path) ||
    FormDraftNavigation.hasReloadSafetyForPath(path);

class AppUpdateSafetyHost extends StatefulWidget {
  const AppUpdateSafetyHost({super.key, required this.router});

  final GoRouter router;

  @override
  State<AppUpdateSafetyHost> createState() => _AppUpdateSafetyHostState();
}

class _AppUpdateSafetyHostState extends State<AppUpdateSafetyHost> {
  WebUpdateSafetyState _probe() => WebUpdateSafetyState(
    blocked: !canAutomaticallyUpdateRoute(
      widget.router.routeInformationProvider.value.uri.path,
    ),
  );

  @override
  void initState() {
    super.initState();
    webUpdateSafety.register(this, _probe);
    widget.router.routeInformationProvider.addListener(_changed);
  }

  void _changed() => webUpdateSafety.changed();

  @override
  void didUpdateWidget(covariant AppUpdateSafetyHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.router, widget.router)) {
      oldWidget.router.routeInformationProvider.removeListener(_changed);
      widget.router.routeInformationProvider.addListener(_changed);
      _changed();
    }
  }

  @override
  void dispose() {
    widget.router.routeInformationProvider.removeListener(_changed);
    webUpdateSafety.unregister(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
