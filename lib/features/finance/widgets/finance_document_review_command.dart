import '../../../components/feedback/uten_context_menu.dart';
import '../repositories/finance_repository.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../shared/documents/document_unapproval.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_dialog_modules.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../shared/finance_document_intent.dart';
import '../shared/finance_original_command.dart';
import '../pages/finance_doc_detail_page.dart';

/// Draft lists and the shared workspace use the same durable review owner as
/// the detail page. Leaving its dialog never means that a DELETE succeeded.
Future<void> reviewFinanceDraftDeletion(
  BuildContext context, {
  required FinanceDocType type,
  required FinanceDocDetail reviewedDetail,
  Future<void> Function()? beforeDispatch,
  String? confirmationMessage,
}) async {
  final result = await UtenBusyOverlay.yieldWhile(
    () => showFinanceDocumentReviewCommand(
      context,
      type: type,
      documentId: reviewedDetail.id,
      unapprove: false,
      deleteDraft: true,
      reviewedDetail: reviewedDetail,
      beforeDispatch: beforeDispatch,
      confirmationMessage:
          confirmationMessage ?? '删除当前所查看的草稿，原单据和明细保留审计历史；其他人后来修改的版本不会被此请求删除。',
    ),
  );
  if (result == null || result['outcome'] == 'CANCELLED_UNWRITTEN') {
    throw ApiException(
      'DRAFT_DELETE_STOPPED',
      '本次财务删除未完成，后续删除已停止；保留的原请求可通过草稿继续核对',
    );
  }
}

Future<Map<String, dynamic>?> showFinanceDocumentReviewCommand(
  BuildContext context, {
  required FinanceDocType type,
  required String documentId,
  required bool unapprove,
  bool glConfirm = false,
  bool deleteDraft = false,
  FinanceDocDetail? reviewedDetail,
  String? factsSnapshot,
  String? resumeDraftId,
  String? confirmationMessage,
  Future<void> Function()? beforeDispatch,
}) {
  if ([unapprove, glConfirm, deleteDraft].where((value) => value).length > 1 ||
      glConfirm && type != FinanceDocType.expense) {
    throw ArgumentError('财务操作与单据种类不一致');
  }
  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _FinanceDocumentReviewCommand(
      type: type,
      documentId: documentId,
      unapprove: unapprove,
      glConfirm: glConfirm,
      deleteDraft: deleteDraft,
      reviewedDetail: reviewedDetail,
      factsSnapshot: factsSnapshot,
      resumeDraftId: resumeDraftId,
      confirmationMessage: confirmationMessage,
      beforeDispatch: beforeDispatch,
    ),
  );
}

class _FinanceDocumentReviewCommand extends ConsumerStatefulWidget {
  const _FinanceDocumentReviewCommand({
    required this.type,
    required this.documentId,
    required this.unapprove,
    required this.glConfirm,
    required this.deleteDraft,
    this.reviewedDetail,
    this.factsSnapshot,
    this.resumeDraftId,
    this.confirmationMessage,
    this.beforeDispatch,
  });
  final FinanceDocType type;
  final String documentId;
  final bool unapprove;
  final bool glConfirm;
  final bool deleteDraft;
  final FinanceDocDetail? reviewedDetail;
  final String? factsSnapshot, resumeDraftId, confirmationMessage;
  final Future<void> Function()? beforeDispatch;
  @override
  ConsumerState<_FinanceDocumentReviewCommand> createState() =>
      _FinanceDocumentReviewCommandState();
}

class _FinanceDocumentReviewCommandState
    extends ConsumerState<_FinanceDocumentReviewCommand>
    with FormDraftMixin<_FinanceDocumentReviewCommand> {
  late FinanceDocDetail? _reviewed = widget.reviewedDetail;
  FinanceDocumentIntent? _intent;
  late String? _facts = widget.factsSnapshot;
  late String? _message = widget.confirmationMessage;
  Map<String, dynamic>? _retired;
  bool _ready = false, _busy = false, _menu = false;
  String? _error;
  FinanceDocConfig get _cfg => FinanceDocConfig.by(widget.type);
  String get _label => widget.deleteDraft
      ? '删除'
      : widget.glConfirm
      ? '财务确认'
      : widget.unapprove
      ? '反审'
      : '审核';
  String get _expectedOperation => widget.deleteDraft
      ? 'FINANCE_DOCUMENT_DELETE'
      : widget.glConfirm
      ? 'FINANCE_DOCUMENT_GL_CONFIRM'
      : widget.unapprove
      ? 'FINANCE_DOCUMENT_UNAPPROVE'
      : 'FINANCE_DOCUMENT_APPROVE';
  // Existing payment-v2 drafts saved four labeled settlement facts followed
  // by one impact sentence. Retain those original fact strings visibly; only
  // their final guidance sentence belongs in the title hint.
  String? get _settlementFacts {
    final message = _message;
    if (widget.type != FinanceDocType.payment ||
        (_reviewed?.settlementAuthorityVersion ?? 0) < 2 ||
        message == null) {
      return null;
    }
    final boundary = message.lastIndexOf('\n');
    return boundary < 0 ? null : message.substring(0, boundary);
  }

  String? get _confirmationInfo {
    final message = _message;
    return message == null || _settlementFacts == null
        ? message
        : message.substring(message.lastIndexOf('\n') + 1);
  }

  bool get _read =>
      ref.read(currentPermissionsProvider).contains(_cfg.listPerm);
  bool get _staff {
    final s = ref.read(authenticatedScopeProvider);
    return s != null && !s.readOnly && s.actorId == null;
  }

  bool get _write =>
      _read &&
      _staff &&
      ref
          .read(currentPermissionsProvider)
          .contains(
            widget.deleteDraft
                ? _cfg.deletePerm
                : widget.glConfirm
                ? Perm.financeExpenseGlConfirm
                : widget.unapprove
                ? _cfg.reversePerm
                : _cfg.approvePerm,
          );
  @override
  FormDraftSpec get formDraftSpec => FormDraftSpec(
    title: '${_cfg.label}$_label',
    module: BadgeModule.finance,
    route:
        '/finance/${widget.type.pathSegment}/${widget.documentId}?draftForm=financeDocumentReview&reviewOperation=${widget.deleteDraft
            ? 'delete'
            : widget.glConfirm
            ? 'gl-confirm'
            : widget.unapprove
            ? 'unapprove'
            : 'approve'}',
    permission: _cfg.listPerm,
    draftKind: 'finance_document_review',
  );
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  bool get formDraftBusy => _busy;
  @override
  bool get formDraftCanReplaySubmission => _intent != null;
  @override
  bool get formDraftRequiresOriginalReceipt => _intent != null;
  @override
  Object formDraftReadBoundaryIdentity(SensitiveReadBoundary b) =>
      SensitiveReadBoundary(
        identity: b.identity,
        api: b.api,
        permissions: {...b.permissions}
          ..removeAll({
            _cfg.approvePerm,
            _cfg.reversePerm,
            if (widget.glConfirm) Perm.financeExpenseGlConfirm,
            if (widget.deleteDraft) _cfg.deletePerm,
          }),
        superAdmin: b.superAdmin,
      );
  @override
  Map<String, dynamic> captureFormDraft() {
    _intent?.precisionChoices = formDraftPrecisionChoices;
    return {
      'schema': 1,
      'segment': widget.type.pathSegment,
      'documentId': widget.documentId,
      'unapprove': widget.unapprove,
      if (widget.glConfirm) 'glConfirm': true,
      if (widget.deleteDraft) 'deleteDraft': true,
      'reviewed': _reviewed?.sourceJson,
      'factsSnapshot': _facts,
      'confirmationMessage': _message,
      'intent': _intent?.toJson(),
      'retired': _retired,
    };
  }

  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['schema'] != 1 ||
        data['segment'] != widget.type.pathSegment ||
        data['documentId'] != widget.documentId ||
        data['unapprove'] != widget.unapprove ||
        (data['glConfirm'] == true) != widget.glConfirm ||
        (data['deleteDraft'] == true) != widget.deleteDraft ||
        data['reviewed'] is! Map) {
      throw const FormatException('原财务审批草稿不完整');
    }
    _facts = data['factsSnapshot'] as String?;
    _message = data['confirmationMessage'] as String?;
    _reviewed = FinanceDocDetail.fromJson(
      Map<String, dynamic>.from(data['reviewed'] as Map),
    );
    if (!financeDocumentHasReviewSnapshot(_reviewed!, type: widget.type) ||
        _reviewed!.id != widget.documentId) {
      throw const FormatException('原审核版本依据不完整');
    }
    if (data['intent'] != null) {
      _intent = FinanceDocumentIntent.restore(
        data['intent'],
        type: widget.type,
        documentId: widget.documentId,
        actorId: ref.read(authenticatedScopeProvider)!.userId,
        choices: formDraftPrecisionChoices,
        expectedOperation: _expectedOperation,
      );
    }
    _intent?.validateReviewedDetail(_reviewed!, factsSnapshot: _facts);
    if (data['retired'] is Map) {
      final r = Map<String, dynamic>.from(data['retired'] as Map);
      final original = FinanceDocumentIntent.restore(
        r['intent'],
        type: widget.type,
        documentId: widget.documentId,
        actorId: ref.read(authenticatedScopeProvider)!.userId,
        choices: formDraftPrecisionChoices,
        expectedOperation: _expectedOperation,
      );
      original.validateReviewedDetail(_reviewed!, factsSnapshot: _facts);
      await original.original.verifyResponsive(
        Map<String, dynamic>.from(r['receipt'] as Map),
      );
      if ((r['receipt'] as Map)['outcome'] != 'CANCELLED_UNWRITTEN') {
        throw const FormatException('原请求尚未确认停止');
      }
      _retired = r;
    }
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await initializeFormDraft();
      if (mounted) {
        setState(() {
          _ready = true;
          if (formDraftRestorationBlocked) {
            _error = describeFormSaveError(
              formDraftRecoveryError ?? StateError('原草稿尚未完整恢复'),
            );
          }
        });
      }
    });
  }

  Future<void> _accept(Map<String, dynamic> envelope) async {
    final intent = _intent!;
    await intent.original.verifyResponsive(
      envelope,
      isCurrent: () => mounted && formDraftIdentityIsCurrent,
    );
    if (envelope['outcome'] == 'CANCELLED_UNWRITTEN') {
      _retired = {'intent': intent.toJson(), 'receipt': envelope};
      _intent = null;
      await checkpointFormDraftAfterConfirmedMutation(
        originalReceiptAcknowledged: true,
      );
      if (mounted) setState(() => _error = null);
      return;
    }
    final result = Map<String, dynamic>.from(envelope['result'] as Map);
    if (widget.unapprove) {
      requireUnapprovalEvidence(widget.documentId, result);
    } else if (result['id'] != widget.documentId ||
        result['status'] != (widget.deleteDraft ? 0 : 1) ||
        widget.glConfirm && result['glStatus'] != 2 ||
        widget.deleteDraft && result['deleted'] != true) {
      throw StateError('原$_label回执缺少对应单据及预期结果');
    }
    await completeFormDraft();
    if (mounted) Navigator.pop(context, envelope);
  }

  Future<void> _submit() async {
    if (!_ready ||
        formDraftRestorationBlocked ||
        _busy ||
        !_write ||
        !formDraftIdentityIsCurrent ||
        _retired != null) {
      return;
    }
    final hadPending = _intent != null;
    bool dispatched = false;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_intent == null) {
        final d = _reviewed;
        if (d == null ||
            !financeDocumentHasReviewSnapshot(d, type: widget.type)) {
          throw StateError('原审核版本未完整展示，请重新打开详情');
        }
        final requestId = const Uuid().v4();
        _intent = FinanceDocumentIntent(
          type: widget.type,
          documentId: widget.documentId,
          actorId: ref.read(authenticatedScopeProvider)!.userId,
          operation: _expectedOperation,
          body: widget.unapprove
              ? {
                  'requestId': requestId,
                  'idempotencyKey': requestId,
                  'reason': '反审后修订并重新审核',
                  'expectedSnapshot': _facts,
                }
              : {
                  'requestId': requestId,
                  'expectedVersion': d.approvalVersion,
                  'expectedSnapshot': d.approvalSnapshot,
                },
          precisionChoices: formDraftPrecisionChoices,
        );
        if (widget.unapprove &&
            !RegExp(r'^[a-f0-9]{64}$').hasMatch(_facts ?? '')) {
          throw StateError('原反审条件未核实');
        }
      }
      _intent!.validateReviewedDetail(_reviewed!, factsSnapshot: _facts);
      final completed =
          await UtenBusyOverlay.run<
            ({AuthenticatedRequestScope scope, Map<String, dynamic> response})?
          >(
            context,
            title: '正在$_label',
            action: () async {
              await saveFormDraftNow();
              final scope = await captureFormDraftRequestScope();
              if (!mounted || !scope.isCurrent) return null;
              if (widget.beforeDispatch != null) {
                await widget.beforeDispatch!();
                if (!mounted || !scope.isCurrent) return null;
              }
              final response = await runFormDraftSubmission(
                () => scope.run(() {
                  dispatched = true;
                  return ref
                      .read(financeRepositoryProvider(widget.type))
                      .executeDocumentIntent(_intent!);
                }),
                isDefiniteRejection: (_) => false,
              );
              return (scope: scope, response: response);
            },
          );
      if (completed == null || !mounted || !completed.scope.isCurrent) return;
      _intent!.precisionChoices = formDraftPrecisionChoices;
      await _accept(completed.response);
    } catch (e) {
      if (!hadPending && !dispatched) {
        _intent = null;
        await releaseFormDraftBeforeDispatch();
      }
      if (mounted && formDraftIdentityIsCurrent) {
        await saveFormDraftNow();
        setState(
          () => _error = describeSubmitError(
            e,
            fallback: '原$_label结果待核对，原请求和精度已保留',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recover(bool cancel) async {
    if (_busy ||
        _intent == null ||
        formDraftRestorationBlocked ||
        !_read ||
        cancel && !_staff ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await captureFormDraftRequestScope();
      if (!mounted || !scope.isCurrent) return;
      final response = await UtenBusyOverlay.run(
        context,
        title: cancel ? '正在核实原请求是否写入' : '正在核对原$_label结果',
        action: () => scope.run(
          () => cancel
              ? _intent!.cancel(
                  ref.read(apiClientProvider),
                  isCurrent: () => mounted && scope.isCurrent,
                )
              : _intent!.receipt(
                  ref.read(apiClientProvider),
                  isCurrent: () => mounted && scope.isCurrent,
                ),
        ),
      );
      if (!mounted || !scope.isCurrent) return;
      if (response['found'] != true) {
        setState(() => _error = '尚未取得原请求回执，不能据此认定未写入');
        return;
      }
      await _accept(response);
    } catch (e) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(() => _error = describeSubmitError(e, fallback: '原结果仍待核对'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _original() async {
    if (_busy || _reviewed == null || !_read) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FinanceDocDetailPage(
          docType: widget.type,
          id: widget.documentId,
          reviewSnapshot: _reviewed,
        ),
      ),
    );
  }

  Future<void> _close() async {
    if (_busy || _menu) return;
    if (_intent != null) {
      await saveFormDraftNow();
      if (mounted) Navigator.pop(context);
    } else if (await confirmFormDraftExit() && mounted) {
      Navigator.pop(context);
    }
  }

  Future<void> _reviewCurrent() async {
    if (_busy || _retired == null) return;
    await completeFormDraft();
    if (mounted) Navigator.pop(context, {'outcome': 'CANCELLED_UNWRITTEN'});
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    if (!formDraftIdentityIsCurrent || !_read) {
      return UtenAlertDialog(
        showCloseButton: true,
        onClose: () => Navigator.pop(context),
        title: const Text('访问范围已变化'),
        content: const Text('原请求和草稿已保留，请恢复原身份及读取权限后核对。'),
      );
    }
    return withFormDraft(
      UtenAlertDialog(
        maxWidth: 700,
        title: UtenDialogTitleWithHint(
          title: Text('${_cfg.label}$_label'),
          info: _intent != null
              ? '待核对的是原账号、原单据版本、原请求及原精度；稍后关闭会持久保留。'
              : _retired != null
              ? '原请求已证明未写入。请重新查看当前单据后，由你再次点击$_label。'
              : _confirmationInfo ??
                    (widget.unapprove
                        ? '反审会撤回这次审核的业务影响，保留原审核记录，并返回可编辑草稿。确认反审所查看的单据？'
                        : '审核将按当前所查看的单据版本核销、登记账户流水并生成对应财务记录。确认审核？'),
        ),
        content: !_ready
            ? const SizedBox(
                height: 80,
                child: UtenBusyOverlay(
                  title: '正在恢复原单据请求',
                  showDoNotLeaveHint: false,
                ),
              )
            : Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UtenDialogField(
                    label: const Text('单据号'),
                    child: SelectableText(
                      _reviewed?.billNo ?? widget.documentId,
                    ),
                  ),
                  if (_reviewed?.amountLocalText case final String amount
                      when _settlementFacts == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: UtenDialogField(
                        label: const Text('单据本币金额'),
                        child: SelectableText(amount),
                      ),
                    ),
                  if (_settlementFacts case final String facts)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: UtenDialogField(
                        label: const Text('结算核对'),
                        child: SelectableText(facts),
                      ),
                    ),
                  if (!widget.unapprove &&
                      !widget.deleteDraft &&
                      _intent == null &&
                      _retired == null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: UtenReviewerResponsibilityNotice(
                        compact: true,
                        actionLabel: _label,
                        reviewerLabel: widget.glConfirm ? '财务确认人' : '审核员',
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                ],
              ),
        actions: [
          if (_intent != null)
            ...financeOriginalRequestActions(
              context,
              busy: _busy,
              receiptLabel: '核对原$_label结果',
              extraMenuActions: [
                UtenMenuItem(
                  label: '查看原单据',
                  icon: Icons.description_outlined,
                  onTap: _original,
                ),
              ],
              receipt: () => _recover(false),
              cancel: () => _recover(true),
              onMenuChanged: (v) {
                if (mounted) setState(() => _menu = v);
              },
            ),
          if (_intent == null)
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _busy ? null : _original,
              child: const Text('查看原单据'),
            ),
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: _busy ? null : _close,
            child: Text(_intent != null ? '稍后核对' : '取消'),
          ),
          if (_retired != null)
            UtenButton(
              onPressed: _busy ? null : _reviewCurrent,
              child: const Text('重新核对当前单据'),
            )
          else
            UtenButton(
              type: widget.deleteDraft
                  ? UtenButtonType.danger
                  : UtenButtonType.primary,
              onPressed:
                  _busy || !_ready || formDraftRestorationBlocked || !_write
                  ? null
                  : _submit,
              child: Text(_intent != null ? '重试原$_label' : '确认$_label'),
            ),
        ],
      ),
    );
  }
}
