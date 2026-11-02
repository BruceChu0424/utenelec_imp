import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';

import 'diagnostic_log.dart';

/// Record committed route templates, never concrete IDs, queries or extras.
/// Each business window owns its router and its listener lifetime.
VoidCallback attachDiagnosticNavigation(GoRouter router) {
  String? previous;
  void changed() {
    final template = router.routerDelegate.currentConfiguration.fullPath;
    if (template.isEmpty || template == previous) return;
    previous = template;
    AppDiagnostics.record('navigation.route', fields: {'path': template});
  }

  router.routerDelegate.addListener(changed);
  changed();
  return () => router.routerDelegate.removeListener(changed);
}
