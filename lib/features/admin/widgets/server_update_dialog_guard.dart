import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/server_operations_access.dart';
import '../../../core/responsive/dialog_size.dart';

/// Match the shared dialog shell before building intrinsically measured form
/// content. LayoutBuilder must not live inside an AlertDialog's intrinsic body.
double serverUpdateDialogContentWidth(
  BuildContext context, {
  double maxWidth = 560,
  double designWidth = 480,
}) {
  final whole = utenDialogWidth(context, maxWidth);
  return math.max(0, math.min(designWidth, whole - (whole < 360 ? 24 : 48)));
}

/// A server-update dialog belongs to the company/session that opened it.
/// Retiring it removes only that route, including if another dialog is above it.
class ServerUpdateDialogGuard extends ConsumerStatefulWidget {
  const ServerUpdateDialogGuard({
    super.key,
    required this.child,
    this.source = false,
  });
  final Widget child;
  final bool source;

  @override
  ConsumerState<ServerUpdateDialogGuard> createState() => _DialogGuardState();
}

class _DialogGuardState extends ConsumerState<ServerUpdateDialogGuard> {
  late final Object? _owner;
  bool _retired = false, _closing = false;

  @override
  void initState() {
    super.initState();
    _owner = ref.read(serverOperationsOwnerProvider);
    ref.listenManual(serverOperationsOwnerProvider, (_, next) {
      if (next != _owner) _retire();
    });
    ref.listenManual(serverOperationsWritableProvider, (_, next) {
      if (!next) _retire();
    });
    ref.listenManual(serverOperationsVisibleProvider, (_, next) {
      if (!next) _retire();
    });
    if (widget.source) {
      ref.listenManual(serverSourceVisibleProvider, (_, next) {
        if (!next) _retire();
      });
    }
  }

  void _retire() {
    if (!mounted || _retired) return;
    setState(() => _retired = true);
  }

  @override
  Widget build(BuildContext context) {
    final valid =
        !_retired &&
        _owner != null &&
        ref.watch(serverOperationsOwnerProvider) == _owner &&
        ref.watch(serverOperationsWritableProvider) &&
        ref.watch(serverOperationsVisibleProvider) &&
        (!widget.source || ref.watch(serverSourceVisibleProvider));
    if (valid) return widget.child;
    if (!_closing) {
      _closing = true;
      final route = ModalRoute.of(context);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final navigator = route?.navigator;
        if (route == null || navigator == null || !route.isActive) return;
        if (route.isCurrent) {
          navigator.pop();
        } else {
          navigator.removeRoute(route);
        }
      });
    }
    return const SizedBox.shrink();
  }
}
