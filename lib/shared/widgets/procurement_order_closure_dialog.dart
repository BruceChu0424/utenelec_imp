import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show setEquals;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../components/feedback/uten_dialog_modules.dart';
import '../../components/inputs/uten_input_decoration.dart';
import '../../components/inputs/uten_field_message.dart';
import '../../core/l10n/gen/app_localizations.dart';
import '../../core/network/api_client.dart';
import '../../core/network/authenticated_request_scope.dart';
import '../../core/network/server_config.dart';
import '../../core/router/page_navigation_session.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import '../badges/badge_registry.dart';
import '../auth/permissions.dart';
import '../providers/authenticated_scope_provider.dart';
import '../models/procurement_order_closure.dart';
import 'procurement_order_closure_blocker_action.dart';
import 'procurement_order_closure_quantities.dart';

/// Reuse the same reviewable request from order detail and workbench entry points.
Future<bool?> showProcurementOrderClosureDialog(
  BuildContext context, {
  required String orderType,
  required String orderId,
  required bool Function() stillCurrent,
  Widget Function(BuildContext, Widget)? wrapDialog,
}) => showDialog<bool>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) {
    final dialog = _ProcurementOrderClosureDialog(
      orderType: orderType,
      orderId: orderId,
      stillCurrent: stillCurrent,
    );
    return wrapDialog?.call(dialogContext, dialog) ?? dialog;
  },
);

class _ProcurementOrderClosureDialog extends ConsumerStatefulWidget {
  const _ProcurementOrderClosureDialog({
    required this.orderType,
    required this.orderId,
    required this.stillCurrent,
  });

  final String orderType;
  final String orderId;
  final bool Function() stillCurrent;

  @override
  ConsumerState<_ProcurementOrderClosureDialog> createState() =>
      _ProcurementOrderClosureDialogState();
}

class _ProcurementOrderClosureDialogState
    extends ConsumerState<_ProcurementOrderClosureDialog> {
  final _reason = TextEditingController();
  final _form = GlobalKey<FormState>();
  ProcurementOrderClosurePreview? _preview;
  AuthenticatedRequestScope? _requestScope;
  String _mode = 'CLOSE';
  String? _error;
  bool _loading = true;
  bool _submitting = false;
  bool _openingBlocker = false;
  final _navigation = PageNavigationSession();
  bool _invalidated = false;
  ModalRoute<dynamic>? _dialogRoute;

  String get _basePath =>
      '/finance/procurement-approvals/orders/'
      '${Uri.encodeComponent(widget.orderType)}/${Uri.encodeComponent(widget.orderId)}';

  bool get _current => mounted && !_invalidated && widget.stillCurrent();

  @override
  void initState() {
    super.initState();
    ref.listenManual(authenticatedScopeProvider, (previous, next) {
      if (previous != next) _retire();
    });
    ref.listenManual(apiBaseUrlProvider, (previous, next) {
      if (previous != next) _retire();
    });
    ref.listenManual(apiClientProvider, (previous, next) {
      if (!identical(previous, next)) _retire();
    });
    ref.listenManual(currentPermissionsProvider, (previous, next) {
      if (!setEquals(previous, next)) _retire();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _navigation.attach(context);
    _dialogRoute ??= ModalRoute.of(context);
  }

  void _retire() {
    if (!mounted || _invalidated) return;
    _invalidated = true;
    _preview = null;
    _reason.clear();
    // Remove this private dialog even when a department page is above it. Never
    // pop the current route, which may already belong to a different owner.
    final route = _dialogRoute;
    if (route?.isActive == true) route!.navigator?.removeRoute(route);
  }

  @override
  void dispose() {
    _navigation.dispose();
    _reason.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (!_current) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final scope = _requestScope ??= await api.captureRequestScope(
        isCurrent: () => _current,
      );
      final data = await scope.run(() => api.get('$_basePath/closure-preview'));
      if (!_current) return;
      setState(() {
        _preview = ProcurementOrderClosurePreview.fromJson(data);
        if (!_preview!.canReorder) _mode = 'CLOSE';
      });
    } catch (error) {
      if (mounted && _current) {
        setState(
          () => _error = AppLocalizations.of(context).orderClosureLoadFailed,
        );
        context.appApiError(error);
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    final preview = _preview;
    final scope = _requestScope;
    if (_submitting ||
        _openingBlocker ||
        !_current ||
        preview?.canSubmit != true ||
        (_mode == 'CLOSE_AND_REORDER' && preview?.canReorder != true) ||
        scope == null ||
        _form.currentState?.validate() != true) {
      return;
    }
    setState(() => _submitting = true);
    try {
      final result = await scope.run(
        () => ref
            .read(apiClientProvider)
            .post(
              '$_basePath/closure-requests',
              body: {
                'mode': _mode,
                'reason': _reason.text.trim(),
                'expectedFingerprint': preview!.fingerprint,
              },
            ),
      );
      if (!mounted || !_current) return;
      refreshBadges(ref);
      if (result['status'] != 'APPROVED') {
        setState(
          () => _error = AppLocalizations.of(
            context,
          ).orderClosureResultUnconfirmed,
        );
        return;
      }
      context.appSuccess(AppLocalizations.of(context).orderClosureSubmitted);
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted && _current) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _openBlocker(String route) async {
    if (_openingBlocker || _submitting || !_current) return;
    setState(() => _openingBlocker = true);
    try {
      await _requestScope?.verify();
      if (!mounted || !_current) return;
      await _navigation.push<void>(route);
      if (!mounted || !_current) return;
      await _load();
    } catch (error) {
      if (mounted && _current) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _openingBlocker = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final preview = _preview;
    return PopScope(
      canPop: !_submitting,
      child: UtenAlertDialog(
        key: const Key('procurement-order-closure-dialog'),
        maxWidth: 720,
        title: Text(
          preview == null || preview.billNo.isEmpty
              ? l10n.orderClosureAction
              : '${l10n.orderClosureAction} · ${preview.billNo}',
        ),
        content: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  UtenButton(onPressed: _load, child: Text(l10n.commonRetry)),
                ],
              )
            : Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(l10n.orderClosureWholeOrderHint),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(l10n.orderClosureApprovalHint),
                    const SizedBox(height: UtenSpacing.s8),
                    Text(l10n.orderClosureReceiptFinalityHint),
                    Text(l10n.orderClosureQuantityBasisHint),
                    if (preview?.unverifiedQuantity == true) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Text(
                        l10n.orderClosureUnverifiedQuantity,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                    if (preview?.canSubmit != true)
                      Text(
                        preview?.blockReason ?? l10n.orderClosureUnavailable,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (preview?.canSubmit != true && preview?.blocker != null)
                      ProcurementOrderClosureBlockerAction(
                        blocker: preview!.blocker!,
                        busy: _openingBlocker,
                        onOpen: _openBlocker,
                      ),
                    RadioGroup<String>(
                      groupValue: _mode,
                      onChanged: (value) {
                        if (value == 'CLOSE_AND_REORDER' &&
                            preview?.canReorder != true) {
                          return;
                        }
                        if (!_submitting && value != null) {
                          setState(() => _mode = value);
                        }
                      },
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          UtenDialogSettingTile(
                            canRequestFocus: false,
                            key: const Key(
                              'procurement-order-closure-mode-close',
                            ),
                            icon: Icons.task_alt_rounded,
                            title: Text(l10n.orderClosureAction),
                            subtitle: Text(l10n.orderClosureCloseHint),
                            selected: _mode == 'CLOSE',
                            trailing: Radio<String>(
                              value: 'CLOSE',
                              enabled: !_submitting,
                            ),
                            onTap: _submitting
                                ? null
                                : () => setState(() => _mode = 'CLOSE'),
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          UtenDialogSettingTile(
                            canRequestFocus: false,
                            key: const Key(
                              'procurement-order-closure-mode-reorder',
                            ),
                            icon: Icons.playlist_add_rounded,
                            title: Text(l10n.orderClosureReorder),
                            subtitle: Text(
                              preview?.canReorder == false
                                  ? (preview?.blockReorderReason ??
                                        l10n.orderClosureUnverifiedQuantity)
                                  : l10n.orderClosureReorderHint,
                            ),
                            selected: _mode == 'CLOSE_AND_REORDER',
                            trailing: Radio<String>(
                              value: 'CLOSE_AND_REORDER',
                              enabled:
                                  !_submitting && preview?.canReorder == true,
                            ),
                            onTap: !_submitting && preview?.canReorder == true
                                ? () => setState(
                                    () => _mode = 'CLOSE_AND_REORDER',
                                  )
                                : null,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    for (final line
                        in preview?.items ??
                            const <ProcurementOrderClosureLine>[])
                      Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                        child: ProcurementOrderClosureQuantities(line: line),
                      ),
                    TextFormField(
                      key: const Key('procurement-order-closure-reason'),
                      errorBuilder: utenTextFieldErrorBuilder,
                      controller: _reason,
                      enabled: !_submitting,
                      maxLength: 500,
                      minLines: 2,
                      maxLines: 4,
                      decoration: UtenInputDecoration(
                        InputDecoration(
                          labelText: l10n.orderClosureReason,
                          hintText: l10n.orderClosureReasonHint,
                        ),
                      ),
                      validator: (value) => value?.trim().isNotEmpty == true
                          ? null
                          : l10n.orderClosureReasonRequired,
                    ),
                  ],
                ),
              ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _submitting
                ? null
                : () => Navigator.of(context).pop(false),
            child: Text(l10n.commonCancel),
          ),
          UtenButton(
            key: const Key('procurement-order-closure-submit'),
            type: UtenButtonType.danger,
            isLoading: _submitting,
            onPressed:
                !_loading &&
                    _error == null &&
                    preview?.canSubmit == true &&
                    _current &&
                    !_openingBlocker
                ? _submit
                : null,
            child: Text(l10n.orderClosureSubmit),
          ),
        ],
      ),
    );
  }
}
