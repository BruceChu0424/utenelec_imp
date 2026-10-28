import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/l10n/table_read_status_text.dart';
import '../../core/responsive/scale.dart';
import '../../core/theme/uten_tokens.dart';
import '../buttons/uten_button.dart';
import '../feedback/uten_dialog.dart';

/// A bounded table-read notice. The table retains its rows and controls while
/// the full, selectable server explanation remains available on request.
/// This component performs no reads or writes; its owner supplies safe retry.
class UtenTableReadStatus extends StatefulWidget {
  const UtenTableReadStatus({
    super.key,
    required this.title,
    required this.reason,
    this.loadingTitle,
    this.guidance,
    this.impact,
    this.retry,
    this.loading = false,
    this.keyPrefix = 'table-read',
    this.detailsLabel,
    this.retryLabel,
    this.closeLabel,
    this.ownerIdentity,
  });

  final String title;
  final String reason;
  final String? loadingTitle;
  final String? guidance;
  final String? impact;
  final VoidCallback? retry;
  final bool loading;
  final String keyPrefix;
  final String? detailsLabel;
  final String? retryLabel;
  final String? closeLabel;

  /// The actor/server/table/query that owns this failure, excluding incidental
  /// rebuilds and fresh callback closures. A new owner retires open details.
  final Object? ownerIdentity;

  @override
  State<UtenTableReadStatus> createState() => _UtenTableReadStatusState();
}

class _UtenTableReadStatusState extends State<UtenTableReadStatus> {
  DialogRoute<void>? _dialog;
  NavigatorState? _navigator;
  int _revision = 0;

  @override
  void didUpdateWidget(UtenTableReadStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.ownerIdentity != widget.ownerIdentity ||
        oldWidget.keyPrefix != widget.keyPrefix ||
        oldWidget.title != widget.title ||
        oldWidget.reason != widget.reason ||
        oldWidget.impact != widget.impact ||
        oldWidget.guidance != widget.guidance ||
        oldWidget.loading != widget.loading ||
        (oldWidget.retry == null) != (widget.retry == null) ||
        oldWidget.detailsLabel != widget.detailsLabel ||
        oldWidget.retryLabel != widget.retryLabel ||
        oldWidget.closeLabel != widget.closeLabel) {
      _retireDialog();
    }
  }

  void _retireDialog() {
    _revision++;
    final route = _dialog;
    final navigator = _navigator;
    _dialog = null;
    _navigator = null;
    if (route == null || navigator == null) return;
    // Updates and disposal can happen during build. Invalidate callbacks now,
    // then remove exactly our route once navigation mutations are safe. A
    // different modal above it must remain open.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (navigator.mounted && route.navigator == navigator && route.isActive) {
        navigator.removeRoute(route);
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  bool _ownsDialog(DialogRoute<void> route, int revision) =>
      mounted &&
      revision == _revision &&
      identical(_dialog, route) &&
      route.isActive &&
      route.isCurrent;

  void _closeDialog(DialogRoute<void> route) {
    final navigator = _navigator;
    if (!identical(_dialog, route) || navigator == null) return;
    _dialog = null;
    _navigator = null;
    navigator.pop();
  }

  @override
  void dispose() {
    _retireDialog();
    super.dispose();
  }

  String _details(BuildContext context) =>
      widget.detailsLabel ?? tableReadStatusText(context, 'details');
  String _retry(BuildContext context) =>
      widget.retryLabel ?? tableReadStatusText(context, 'retry');
  String _close(BuildContext context) =>
      widget.closeLabel ?? tableReadStatusText(context, 'close');

  void _showDetails(BuildContext context) {
    if (_dialog != null) return;
    // A retry can remove this status immediately. The closing dialog must not
    // consult the deactivated table context during its remaining animation.
    final close = _close(context);
    final retryText = _retry(context);
    final snapshot = widget;
    final revision = _revision;
    final navigator = Navigator.of(context, rootNavigator: true);
    late final DialogRoute<void> route;
    route = DialogRoute<void>(
      context: context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (dialogContext) => UtenAlertDialog(
        title: Text(snapshot.title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snapshot.impact case final text? when text.isNotEmpty) ...[
              Text(text),
              const SizedBox(height: UtenSpacing.s16),
            ],
            SelectableText(snapshot.reason),
            if (snapshot.guidance case final text? when text.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(text),
            ],
          ],
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.ghost,
            onPressed: () {
              if (_ownsDialog(route, revision)) _closeDialog(route);
            },
            child: Text(close),
          ),
          if (snapshot.retry != null)
            UtenButton(
              icon: Icons.refresh_rounded,
              isLoading: snapshot.loading,
              onPressed: snapshot.loading
                  ? null
                  : () {
                      if (!_ownsDialog(route, revision) || widget.loading) {
                        return;
                      }
                      final retry = widget.retry;
                      if (retry == null) return;
                      _closeDialog(route);
                      retry();
                    },
              child: Text(retryText),
            ),
        ],
      ),
    );
    _dialog = route;
    _navigator = navigator;
    unawaited(
      navigator.push(route).whenComplete(() {
        if (identical(_dialog, route)) {
          _dialog = null;
          _navigator = null;
        }
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final summary = widget.loading
        ? widget.loadingTitle ?? widget.title
        : widget.title;
    final details = _details(context);
    final retryText = _retry(context);
    final hitExtent = UtenControlMetrics.minimumHitExtent(context, desktop: 36);
    final retryPainter = TextPainter(
      text: TextSpan(
        text: retryText,
        style: DefaultTextStyle.of(context).style.copyWith(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
      textScaler: MediaQuery.textScalerOf(context),
      textDirection: Directionality.of(context),
    )..layout();
    // Match the compact UtenButton label, icon, gap and horizontal padding.
    final retryLabelWidth = retryPainter.width + context.scaled(16) + 8 + 24;
    final retryControlMinimum = context.scaled(
      UtenControlMetrics.compactHeight,
    );
    final retryMinimumWidth = retryLabelWidth > retryControlMinimum
        ? retryLabelWidth
        : retryControlMinimum;
    retryPainter.dispose();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Very narrow containers retain one reachable details action; its
          // dialog carries retry instead of overflowing two touch targets.
          final inlineRetry =
              widget.retry != null && constraints.maxWidth >= hitExtent * 2;
          final labelledRetry =
              constraints.maxWidth >= 200 &&
              constraints.maxWidth >= retryMinimumWidth + hitExtent;
          return Semantics(
            key: ValueKey('${widget.keyPrefix}-error'),
            liveRegion: true,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Tooltip(
                    message: '$summary · $details',
                    child: TextButton(
                      key: ValueKey('${widget.keyPrefix}-details'),
                      onPressed: () => _showDetails(context),
                      style: TextButton.styleFrom(
                        foregroundColor: theme.colorScheme.onSurfaceVariant,
                        minimumSize: Size(hitExtent, hitExtent),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        textStyle: theme.textTheme.labelMedium,
                      ),
                      child: Semantics(
                        label: '$summary，$details',
                        excludeSemantics: true,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.info_outline_rounded, size: 16),
                            if (constraints.maxWidth >= 200) ...[
                              const SizedBox(width: 6),
                              Flexible(
                                child: Text(
                                  summary,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                if (inlineRetry && !labelledRetry)
                  IconButton(
                    key: ValueKey('${widget.keyPrefix}-retry'),
                    tooltip: retryText,
                    onPressed: widget.loading ? null : widget.retry,
                    constraints: BoxConstraints.tightFor(
                      width: hitExtent,
                      height: hitExtent,
                    ),
                    icon: widget.loading
                        ? const SizedBox.square(
                            dimension: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded, size: 18),
                  )
                else if (inlineRetry)
                  UtenButton(
                    key: ValueKey('${widget.keyPrefix}-retry'),
                    type: UtenButtonType.ghost,
                    size: UtenButtonSize.small,
                    icon: Icons.refresh_rounded,
                    isLoading: widget.loading,
                    onPressed: widget.loading ? null : widget.retry,
                    child: Text(retryText),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
