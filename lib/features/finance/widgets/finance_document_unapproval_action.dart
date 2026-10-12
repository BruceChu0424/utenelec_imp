import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/documents/document_unapproval.dart';
import '../../../shared/documents/document_unapproval_action.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/badges/badge_registry.dart';

/// Approval history reuses the document family's authoritative reversal and successor flow.
class FinanceDocumentUnapprovalAction extends ConsumerStatefulWidget {
  const FinanceDocumentUnapprovalAction({
    super.key,
    required this.family,
    required this.documentId,
    required this.revision,
    required this.onCompleted,
    this.validateReview,
  });

  final String family;
  final String documentId;
  final Object revision;
  final VoidCallback onCompleted;
  final Future<bool> Function()? validateReview;

  @override
  ConsumerState<FinanceDocumentUnapprovalAction> createState() =>
      _FinanceDocumentUnapprovalActionState();
}

class _FinanceDocumentUnapprovalActionState
    extends ConsumerState<FinanceDocumentUnapprovalAction> {
  bool _busy = false;

  Future<void> _unapprove() async {
    if (_busy) return;
    final identity = ref.read(authenticatedScopeProvider);
    if (identity == null || identity.readOnly) return;
    final id = widget.documentId;
    final family = widget.family;
    final revision = widget.revision;
    bool isCurrent() =>
        mounted &&
        identity == ref.read(authenticatedScopeProvider) &&
        id == widget.documentId &&
        family == widget.family &&
        revision == widget.revision;
    final api = ref.read(apiClientProvider);
    setState(() => _busy = true);
    try {
      final scope = await api.captureRequestScope(isCurrent: isCurrent);
      if (widget.validateReview != null &&
          !await scope.run(widget.validateReview!)) {
        if (mounted && isCurrent()) context.appWarning('审批版本已变化，请刷新详情后再反审');
        return;
      }
      if (!mounted || !isCurrent()) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认反审'),
          content: const Text(documentUnapprovalConfirmation),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认反审'),
            ),
          ],
        ),
      );
      if (confirmed != true || !isCurrent()) return;
      if (widget.validateReview != null &&
          !await scope.run(widget.validateReview!)) {
        if (mounted && isCurrent()) context.appWarning('审批版本已变化，请刷新详情后再反审');
        return;
      }
      final result = await scope.run(() => unapproveDocument(api, family, id));
      if (!mounted || !isCurrent()) return;
      final evidence = requireUnapprovalEvidence(id, result);
      showDocumentUnapprovalResult(context, evidence.status);
      refreshBadges(ref);
      widget.onCompleted();
    } on ApiException catch (error) {
      if (mounted && isCurrent()) context.appError(error.message);
    } catch (_) {
      if (mounted && isCurrent()) context.appError('反审结果尚未确认，请刷新后核对');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => DocumentUnapprovalAction(
    family: widget.family,
    documentId: widget.documentId,
    revision: widget.revision,
    onPressed: _busy ? null : _unapprove,
  );
}
