import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/authenticated_request_scope.dart';
import '../providers/sensitive_read_boundary_provider.dart';

/// Retires private overlay content permanently after its captured identity or
/// permissions change, including A -> B -> A while the overlay remains open.
class SensitiveContentBoundary extends ConsumerStatefulWidget {
  const SensitiveContentBoundary({
    super.key,
    required this.boundary,
    required this.child,
    required this.invalidatedBuilder,
    this.scope,
    this.isCurrent,
  });

  final SensitiveReadBoundary boundary;
  final Widget child;
  final WidgetBuilder invalidatedBuilder;
  final AuthenticatedRequestScope? scope;
  final bool Function()? isCurrent;

  @override
  ConsumerState<SensitiveContentBoundary> createState() =>
      _SensitiveContentBoundaryState();
}

class _SensitiveContentBoundaryState
    extends ConsumerState<SensitiveContentBoundary> {
  bool _invalidated = false;

  @override
  void initState() {
    super.initState();
    ref.listenManual(sensitiveReadBoundaryProvider, (_, next) {
      if (next != widget.boundary && !_invalidated && mounted) {
        setState(() => _invalidated = true);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final current =
        !_invalidated &&
        ref.watch(sensitiveReadBoundaryProvider) == widget.boundary &&
        (widget.scope?.isCurrent ?? true) &&
        (widget.isCurrent?.call() ?? true);
    if (!current) _invalidated = true;
    return current ? widget.child : widget.invalidatedBuilder(context);
  }
}
