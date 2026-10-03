import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/server_config.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';

/// A file operation remains attached to the user and server that started it.
class SalesQuoteTemplateScope {
  SalesQuoteTemplateScope(WidgetRef ref)
    : identity = ref.read(authenticatedScopeProvider),
      server = ref.read(apiBaseUrlProvider),
      epoch = ref.read(exportContextEpochProvider);

  final AuthenticatedScope? identity;
  final String server;
  final int epoch;

  bool current(WidgetRef ref, {bool learning = false}) {
    if (identity == null ||
        epoch != ref.read(exportContextEpochProvider) ||
        identity != ref.read(authenticatedScopeProvider) ||
        server != ref.read(apiBaseUrlProvider)) {
      return false;
    }
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.salesQuoteView) &&
        permissions.contains(Perm.salesQuoteExport) &&
        permissions.contains(Perm.salesOrderPriceView) &&
        (!learning ||
            (!identity!.readOnly &&
                (permissions.contains(Perm.salesQuoteCreate) ||
                    permissions.contains(Perm.salesQuoteEdit))));
  }
}

/// Clear an open customer mapping immediately when its account/server scope disappears.
class SalesQuoteTemplateScopeDialog extends ConsumerWidget {
  const SalesQuoteTemplateScopeDialog({
    super.key,
    required this.stillCurrent,
    required this.child,
  });
  final bool Function() stillCurrent;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(authenticatedScopeProvider);
    ref.watch(apiBaseUrlProvider);
    ref.watch(currentPermissionsProvider);
    ref.watch(exportContextEpochProvider);
    if (stillCurrent()) return child;
    final route = ModalRoute.of(context);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!context.mounted || route == null || !route.isActive) return;
      Navigator.of(context).removeRoute(route);
    });
    return const SizedBox.shrink();
  }
}
