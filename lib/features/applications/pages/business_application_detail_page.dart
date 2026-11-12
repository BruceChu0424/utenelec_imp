import 'package:uten_imp/shared/paging/read_view_activity.dart';
import 'package:flutter/material.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/attachments/attachment_section.dart';
import '../../../shared/attachments/attachment_service.dart';
import '../../finance/widgets/finance_native_original_section.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/badges/badge_registry.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../core/network/read_scope_revision.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../../../shared/providers/session_provider.dart';
import '../../../shared/widgets/sensitive_content_boundary.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../finance/models/finance_doc.dart';
import '../../finance/repositories/finance_repository.dart';
import '../models/business_application.dart';
import '../providers/business_application_providers.dart';
import '../repositories/business_application_repository.dart';
import '../widgets/business_application_print.dart';
import '../widgets/business_application_progress.dart';

final _applicationAttachmentsProvider = FutureProvider.autoDispose.family((
  ref,
  String id,
) {
  ref.watch(masterDataSessionKeyProvider);
  ref.watch(sensitiveReadBoundaryProvider);
  ref.watch(readScopeRevisionProvider);
  return ref
      .watch(attachmentServiceProvider)
      .list(ownerType: 'BUSINESS_APPLICATION', ownerId: id);
});

final _applicationPaymentProofsProvider = FutureProvider.autoDispose.family((
  ref,
  String id,
) {
  ref.watch(sensitiveReadBoundaryProvider);
  ref.watch(readScopeRevisionProvider);
  return ref
      .watch(attachmentServiceProvider)
      .list(ownerType: 'BUSINESS_APPLICATION_PAYMENT', ownerId: id);
});

class BusinessApplicationDetailPage extends ConsumerStatefulWidget {
  const BusinessApplicationDetailPage({super.key, required this.applicationId});
  final String applicationId;
  @override
  ConsumerState<BusinessApplicationDetailPage> createState() =>
      _BusinessApplicationDetailPageState();
}

class _BusinessApplicationDetailPageState
    extends ConsumerState<BusinessApplicationDetailPage> {
  bool _busy = false;
  bool _networkBusy = false;
  bool _uncertain = false;
  int _operation = 0;
  String? _paymentDraftId;
  String? _paymentDraftRevision;
  int? _paymentCommandVersion;
  String? _paymentDraftAction;
  bool _resumedPaymentOpened = false;

  @override
  void didUpdateWidget(covariant BusinessApplicationDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.applicationId != widget.applicationId) {
      _operation++;
      _busy = false;
      _networkBusy = false;
      _uncertain = false;
      _paymentDraftId = null;
      _paymentDraftRevision = null;
      _paymentCommandVersion = null;
      _paymentDraftAction = null;
      _resumedPaymentOpened = false;
    }
  }

  Future<void> _reload() async {
    if (_busy) return;
    final recordId = widget.applicationId;
    final operation = ++_operation;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    bool current() =>
        mounted &&
        operation == _operation &&
        widget.applicationId == recordId &&
        ref.read(sensitiveReadBoundaryProvider) == boundary;
    setState(() {
      _busy = true;
      _networkBusy = true;
    });
    try {
      ref.invalidate(businessApplicationDetailProvider(widget.applicationId));
      await ref.read(
        businessApplicationDetailProvider(widget.applicationId).future,
      );
      if (!current()) return;
      ref.invalidate(_applicationAttachmentsProvider(widget.applicationId));
      ref.invalidate(businessApplicationCountsProvider);
      refreshBadges(ref);
      if (mounted && current()) setState(() => _uncertain = false);
    } catch (error) {
      if (mounted && current()) {
        setState(() {
          _busy = false;
          _networkBusy = false;
        });
        context.appApiError(error);
      }
    } finally {
      if (mounted &&
          operation == _operation &&
          widget.applicationId == recordId) {
        setState(() {
          _busy = false;
          _networkBusy = false;
        });
      }
    }
  }

  Future<void> _act(
    BusinessApplication application,
    String action, {
    String? reason,
    Map<String, dynamic>? fields,
    Future<bool?> Function()? confirm,
    Future<String?> Function()? askReason,
    Future<Map<String, dynamic>?> Function()? pickPayment,
  }) async {
    if (_busy || _uncertain) return;
    final scope = ref.read(authenticatedScopeProvider);
    if (scope == null || scope.readOnly) return;
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final session = ref.read(sessionProvider.notifier);
    final intent = session.requestIntentEpoch;
    final revision = ref.read(readScopeRevisionProvider);
    final operation = ++_operation;
    var invalidated = false;
    final subscription = ref.listenManual(sensitiveReadBoundaryProvider, (
      _,
      next,
    ) {
      if (next != boundary) invalidated = true;
    });
    bool current() =>
        mounted &&
        widget.applicationId == application.id &&
        operation == _operation &&
        !invalidated &&
        ref.read(sensitiveReadBoundaryProvider) == boundary &&
        identical(ref.read(sessionProvider.notifier), session) &&
        session.requestIntentEpoch == intent &&
        ref.read(readScopeRevisionProvider) == revision;
    var sent = false;
    var paymentWasUnknown = false;
    setState(() {
      _busy = true;
      _networkBusy = true;
    });
    Future<T?> interact<T>(Future<T?> Function() body) async {
      if (!current()) return null;
      setState(() => _networkBusy = false);
      await WidgetsBinding.instance.endOfFrame;
      if (!current()) return null;
      final value = await body();
      if (current()) setState(() => _networkBusy = true);
      return value;
    }

    try {
      final completed = await runSensitiveWrite<bool>(
        ref,
        isCurrent: current,
        write: () async {
          if (confirm != null && await interact(confirm) != true) {
            return false;
          }
          if (askReason != null) {
            reason = await interact(askReason);
            if (reason == null) return false;
          }
          if (pickPayment != null) {
            fields = await interact(pickPayment);
            if (fields == null) return false;
          }
          if (!current()) return false;
          if (action == 'pay' || action == 'link-finance') {
            final authoritative = await ref
                .read(businessApplicationRepositoryProvider)
                .get(application.id);
            if (!current()) return false;
            if (!(action == 'link-finance'
                    ? authoritative.canLinkFinance &&
                          authoritative.status == 'PAID'
                    : authoritative.canPay &&
                          authoritative.status == 'APPROVED') ||
                authoritative.version !=
                    (_paymentCommandVersion ?? application.version)) {
              throw StateError('申请状态或可付款版本已变化，请保留付款输入并刷新核对');
            }
            final draft = ref
                .read(formDraftsProvider)
                .where((draft) => draft.id == _paymentDraftId)
                .firstOrNull;
            if (draft == null ||
                draft.revision != _paymentDraftRevision ||
                draft.data['applicationId'] != application.id) {
              throw StateError('付款输入的保存版本已变化，请保留原输入并重新核对');
            }
            paymentWasUnknown = draft.hasUnknownSubmission;
            final command = <String, dynamic>{
              'applicationId': application.id,
              'action': action,
              'expectedVersion': _paymentCommandVersion ?? application.version,
              'fields': Map<String, dynamic>.of(fields!),
            };
            final saved = await ref
                .read(formDraftsProvider.notifier)
                .save(
                  FormDraft.fromJson({
                    ...draft.toJson(),
                    'data': {
                      ...draft.data,
                      formDraftUnknownSubmissionKey: true,
                      '_applicationPaymentCommand': command,
                    },
                  }),
                  expectedRevision: draft.revision,
                );
            _paymentDraftRevision = saved.revision;
            if (!current()) return false;
          }
          sent = true;
          await ref
              .read(businessApplicationRepositoryProvider)
              .act(
                application.id,
                action,
                version: action == 'pay' || action == 'link-finance'
                    ? _paymentCommandVersion ?? application.version
                    : application.version,
                reason: reason,
                fields: fields,
              );
          return true;
        },
      );
      if (!mounted || !completed || !current()) return;
      if ((action == 'pay' || action == 'link-finance') &&
          _paymentDraftId != null) {
        // Business success remains success even if local cleanup needs another
        // attempt. The confirmed parent record prevents duplicate badge counts.
        try {
          await ref
              .read(formDraftsProvider.notifier)
              .complete(
                _paymentDraftId!,
                expectedRevision: _paymentDraftRevision,
              );
        } catch (_) {
          /* Keep the original local checkpoint for review. */
        }
        if (!mounted || !current()) return;
      }
      ref.invalidate(businessApplicationDetailProvider(application.id));
      ref.invalidate(businessApplicationCountsProvider);
      refreshBadges(ref);
      ref.invalidate(_applicationAttachmentsProvider(application.id));
      ref.invalidate(_applicationPaymentProofsProvider(application.id));
      setState(() {
        _busy = false;
        _networkBusy = false;
      });
      context.appSuccess(switch (action) {
        'submit' => '已提交审批',
        'withdraw' => '已撤回申请',
        'approve' => '本节点审核已通过',
        'reject' => '已驳回申请',
        'receive' => '已接收保管',
        'pay' =>
          application.kind == 'PREPAYMENT' ? '已登记供应商预付款，待财务入账' : '已关联财务付款记录',
        'link-finance' => '已关联供应商预付账务',
        'cancel' => '申请已作废并保留历史记录',
        _ => '操作已完成',
      });
    } catch (error) {
      if (mounted && current()) {
        var uncertain = sent;
        if ((action == 'pay' || action == 'link-finance') &&
            sent &&
            !paymentWasUnknown &&
            error is ApiException &&
            error.hasResponseCode &&
            (error.httpStatus == 400 ||
                error.httpStatus == 422 ||
                (error.httpStatus == 409 && error.code == 'CONFLICT'))) {
          try {
            final draft = ref
                .read(formDraftsProvider)
                .firstWhere((draft) => draft.id == _paymentDraftId);
            final data = {...draft.data, formDraftUnknownSubmissionKey: false}
              ..remove('_applicationPaymentCommand');
            final saved = await ref
                .read(formDraftsProvider.notifier)
                .save(
                  FormDraft.fromJson({...draft.toJson(), 'data': data}),
                  expectedRevision: _paymentDraftRevision,
                );
            _paymentDraftRevision = saved.revision;
            uncertain = false;
          } catch (_) {
            /* Keep the durable unknown marker if local cleanup fails. */
          }
          if (!mounted || !current()) return;
        }
        setState(() {
          _busy = false;
          _networkBusy = false;
          _uncertain = uncertain;
        });
        context.appApiError(error, fallback: '操作结果待核对，请刷新确认当前状态');
      }
    } finally {
      subscription.close();
      if (mounted && operation == _operation) {
        setState(() {
          _busy = false;
          _networkBusy = false;
        });
      }
    }
  }

  Future<void> _confirm(
    BusinessApplication application,
    String action,
    String label,
  ) async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    await _act(
      application,
      action,
      confirm: () => UtenDialog.show(
        context,
        title: label,
        content: Text(
          '申请单：${application.applicationNo}\n${application.title}${action == 'cancel' ? '\n作废后不可再次提交，原单号、凭证与流转历史会保留。' : ''}',
        ),
        confirmLabel: label,
        waitForExit: true,
        scopeBuilder: (_, child) => _protect(boundary, child),
      ),
    );
  }

  Future<void> _reject(
    BusinessApplication application, {
    bool cancelPayment = false,
  }) async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    await _act(
      application,
      cancelPayment ? 'cancel-payment' : 'reject',
      askReason: () async {
        final controller = TextEditingController();
        final reason = await showDialog<String>(
          context: context,
          builder: (dialogContext) => _protect(
            boundary,
            UtenAlertDialog(
              title: Text(cancelPayment ? '撤销付款登记' : '驳回申请'),
              content: TextField(
                controller: controller,
                maxLength: 1000,
                maxLines: 4,
                decoration: InputDecoration(
                  labelText: cancelPayment ? '撤销原因（选填）' : '驳回原因（选填）',
                ),
              ),
              actions: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                UtenButton(
                  type: UtenButtonType.danger,
                  onPressed: () {
                    // 原因选填：空原因确认返回空串（_act 视为已确认），取消返回 null。
                    Navigator.of(dialogContext).pop(controller.text.trim());
                  },
                  child: Text(cancelPayment ? '撤销付款登记' : '驳回申请'),
                ),
              ],
            ),
          ),
        );
        // Dispose after the closing route has stopped reading the controller.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => controller.dispose(),
        );
        return reason;
      },
    );
  }

  Future<void> _pay(
    BusinessApplication application, {
    bool linkFinance = false,
  }) async {
    final boundary = ref.read(sensitiveReadBoundaryProvider);
    final expectedOperation = _operation + 1;
    final action = linkFinance ? 'link-finance' : 'pay';
    final form = linkFinance
        ? 'applicationPrepaymentFinance'
        : 'applicationPayment';
    final query =
        goRouterPageStateOrNull(context)?.uri.queryParameters ??
        const <String, String>{};
    final activeDrafts = ref.read(formDraftsProvider);
    final activeMemo = activeDrafts.any(
      (draft) =>
          draft.id == _paymentDraftId &&
          draft.data['applicationId'] == application.id,
    );
    final draftId =
        (query['draftForm'] == form ? query['draftId'] : null) ??
        (_paymentDraftAction == action && activeMemo ? _paymentDraftId : null);
    await _act(
      application,
      action,
      pickPayment: () async {
        final selected = await showUtenAdaptivePanel<Map<String, dynamic>>(
          context: context,
          drawerWidth: 620,
          widthFraction: UtenPanelWidth.content,
          builder: (_) => _protect(
            boundary,
            _PaymentRecordPicker(
              application: application,
              draftId: draftId,
              action: action,
            ),
          ),
        );
        if (!mounted ||
            widget.applicationId != application.id ||
            _operation != expectedOperation ||
            ref.read(sensitiveReadBoundaryProvider) != boundary ||
            selected == null) {
          return null;
        }
        _paymentDraftId = selected.remove('_localDraftId') as String?;
        _paymentDraftRevision =
            selected.remove('_localDraftRevision') as String?;
        _paymentCommandVersion =
            selected.remove('_localExpectedVersion') as int?;
        _paymentDraftAction = action;
        return selected;
      },
    );
  }

  Widget _protect(SensitiveReadBoundary boundary, Widget child) =>
      SensitiveContentBoundary(
        boundary: boundary,
        child: child,
        invalidatedBuilder: (dialogContext) => UtenAlertDialog(
          showCloseButton: true,
          onClose: () => Navigator.of(dialogContext).pop(),

          title: const Text('登录身份或权限已变化'),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(
      businessApplicationDetailProvider(widget.applicationId),
    );
    final application = detail.value;
    final attachments = ref.watch(
      _applicationAttachmentsProvider(widget.applicationId),
    );
    final perms = ref.watch(currentPermissionsProvider);
    final scope = ref.watch(authenticatedScopeProvider);
    final writable = scope != null && !scope.readOnly;
    final canApply =
        writable &&
        (perms.contains(Perm.applicationApply) ||
            perms.contains(
              Perm.applicationKindApplyPermissions[application?.kind],
            ));
    final stagePermission = switch (application?.approvalStage) {
      'DEPARTMENT' => Perm.applicationApproveDepartment,
      'FINANCE_INITIAL' => Perm.applicationApproveFinanceInitial,
      'FINANCE_REVIEW' => Perm.applicationApproveFinanceReview,
      'EXECUTIVE' => Perm.applicationApproveExecutive,
      'VICE_EXECUTIVE' => Perm.applicationApproveViceExecutive,
      'PROCUREMENT' => Perm.applicationApproveProcurement,
      'FINANCE_RECEIVE' => Perm.applicationReceive,
      'PAYMENT' => Perm.applicationPay,
      _ => '',
    };
    final canApprove =
        writable &&
        application?.canApprove == true &&
        perms.contains(stagePermission);
    final canReject =
        writable &&
        application?.canReject == true &&
        perms.contains(stagePermission);
    final canReceive =
        writable &&
        application?.canReceive == true &&
        perms.contains(Perm.applicationReceive);
    final canPay =
        writable &&
        application?.canPay == true &&
        perms.contains(Perm.applicationPay);
    final canCancelPayment =
        writable &&
        application?.canCancelPayment == true &&
        perms.contains(Perm.applicationPay);
    final canLinkFinance =
        writable &&
        application?.canLinkFinance == true &&
        perms.contains(Perm.applicationPrepaymentLinkFinance);
    final resumedDraftForm = goRouterPageStateOrNull(
      context,
    )?.uri.queryParameters['draftForm'];
    if (!_resumedPaymentOpened &&
        writable &&
        (perms.contains(Perm.applicationPay) ||
            perms.contains(Perm.applicationPrepaymentLinkFinance)) &&
        application != null &&
        const {
          'applicationPayment',
          'applicationPrepaymentFinance',
        }.contains(resumedDraftForm)) {
      _resumedPaymentOpened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _pay(
            application,
            linkFinance: resumedDraftForm == 'applicationPrepaymentFinance',
          );
        }
      });
    }
    final paymentProofs = application != null && application.kind != 'TRAVEL'
        ? ref.watch(_applicationPaymentProofsProvider(application.id))
        : null;
    final owner =
        application?.applicantId == ref.watch(sessionProvider).user?.employeeId;
    final editable = owner && application?.editable == true && canApply;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(
        title: application?.kindLabel ?? '申请详情',
        showBackButton: true,
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            icon: Icons.refresh,
            onPressed: _busy ? null : _reload,
            child: const Text('刷新'),
          ),
          if (application != null)
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.print_outlined,
              onPressed: _busy
                  ? null
                  : () {
                      showBusinessApplicationPrintPreview(context, application);
                    },
              child: const Text('打印'),
            ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: UtenContentContainer(
              child: detail.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, stack) => Center(
                  child: UtenButton(
                    onPressed: _reload,
                    child: const Text('重新读取申请'),
                  ),
                ),
                data: (value) => ListView(
                  padding: const EdgeInsets.only(
                    top: UtenSpacing.s16,
                    bottom: UtenFloatingActionGroup.scrollClearance,
                  ),
                  children: [
                    if (_uncertain)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
                        child: Row(
                          children: [
                            const Expanded(child: Text('操作结果待核对')),
                            UtenButton(
                              onPressed: _reload,
                              child: const Text('刷新核对'),
                            ),
                          ],
                        ),
                      ),
                    _panel(
                      theme,
                      '申请信息',
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _fact('申请单号', value.applicationNo),
                          _fact('申请标题', value.title),
                          _fact('申请人', value.applicantName),
                          _fact('申请部门', value.departmentName ?? '—'),
                          _fact(
                            '状态',
                            value.statusLabel,
                            info: value.approvalRoutingStale
                                ? '审批设置已调整，请先撤回申请，再重新提交审批。原审批历史保留。'
                                : null,
                          ),
                          if (value.kind == 'PREPAYMENT' &&
                              value.status == 'PAID')
                            _fact(
                              '账务状态',
                              value.postingStatus == 'POSTED'
                                  ? '已关联预付账务'
                                  : '待财务入账',
                              info:
                                  '实际付款登记与财务入账分别记录。此处不会将预付当作费用，也不会再次扣款。只有同供应商、金额和日期的合法已审核预付财务记录可以关联。',
                            ),
                          _fact(
                            value.kind == 'TRAVEL' ? '预计费用' : '申请金额',
                            value.amountLabel,
                          ),
                          if (value.rejectReason != null)
                            _fact('驳回原因', value.rejectReason!),
                          for (final entry
                              in businessApplicationFieldLabels.entries)
                            if (value.fields[entry.key]
                                    ?.toString()
                                    .trim()
                                    .isNotEmpty ==
                                true)
                              _fact(
                                entry.value,
                                value.fields[entry.key].toString(),
                              ),
                          if (value.financeDocumentId != null)
                            Row(
                              children: [
                                const Expanded(child: Text('已关联财务付款记录')),
                                UtenButton(
                                  type: UtenButtonType.secondary,
                                  onPressed: () {
                                    final type =
                                        value.fields['financeDocumentType'] ==
                                            'EXPENSE'
                                        ? 'expenses'
                                        : 'payments';
                                    context.push(
                                      '/finance/$type/${value.financeDocumentId}',
                                    );
                                  },
                                  child: const Text('查看财务单'),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    if (value.continuedOriginal) ...[
                      FinanceNativeOriginalSection(
                        ownerType: 'BUSINESS_APPLICATION',
                        ownerId: value.id,
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                    ],
                    attachments.when(
                      loading: () => const LinearProgressIndicator(),
                      error: (e, s) => UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: () async {
                          await UtenBusyOverlay.run(
                            context,
                            title: '正在读取附件',
                            action: () async {
                              ref.invalidate(
                                _applicationAttachmentsProvider(value.id),
                              );
                              await ref.read(
                                _applicationAttachmentsProvider(
                                  value.id,
                                ).future,
                              );
                            },
                          );
                        },
                        child: const Text('重新读取凭证'),
                      ),
                      data: (files) => AttachmentSection(
                        ownerType: 'BUSINESS_APPLICATION',
                        ownerId: value.id,
                        title: '相关凭证',
                        attachments: files,
                        ownerCanUpload: editable && !_busy,
                        ownerCanDelete: editable && !_busy,
                        onChanged: () {
                          ref.invalidate(
                            _applicationAttachmentsProvider(value.id),
                          );
                          ref.invalidate(
                            businessApplicationDetailProvider(value.id),
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    if (paymentProofs != null) ...[
                      paymentProofs.when(
                        loading: () => const LinearProgressIndicator(),
                        error: (e, s) => UtenButton(
                          type: UtenButtonType.secondary,
                          onPressed: () async {
                            try {
                              await UtenBusyOverlay.run(
                                context,
                                title: '正在读取付款证明',
                                action: () async {
                                  ref.invalidate(
                                    _applicationPaymentProofsProvider(value.id),
                                  );
                                  await ref.read(
                                    _applicationPaymentProofsProvider(
                                      value.id,
                                    ).future,
                                  );
                                },
                              );
                            } catch (error) {
                              if (context.mounted) context.appApiError(error);
                            }
                          },
                          child: const Text('重新读取付款证明'),
                        ),
                        data: (files) => AttachmentSection(
                          ownerType: 'BUSINESS_APPLICATION_PAYMENT',
                          ownerId: value.id,
                          title: '付款证明',
                          attachments: files,
                          ownerCanUpload: canPay && !_busy && !_uncertain,
                          ownerCanDelete: canPay && !_busy && !_uncertain,
                          onChanged: () {
                            ref.invalidate(
                              _applicationPaymentProofsProvider(value.id),
                            );
                            ref.invalidate(
                              businessApplicationDetailProvider(value.id),
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s16),
                    ],
                    _panel(
                      theme,
                      '审批流程',
                      BusinessApplicationProgress(application: value),
                      hint: '按岗位权限逐级处理；驳回后可修订重提，已完成的意见保留在历史中。付款申请与实际财务记账分别记录。',
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                    _panel(
                      theme,
                      '流转记录',
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final line in businessApplicationAuditLines(
                            value,
                          ))
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: UtenSpacing.s8,
                              ),
                              child: Text(line),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_networkBusy)
            const UtenBusyOverlay(title: '正在处理申请', showDoNotLeaveHint: false),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: application == null
          ? null
          : UtenFloatingActionGroup(
              children: [
                if (editable) ...[
                  UtenButton(
                    type: UtenButtonType.danger,
                    onPressed: _busy || _uncertain
                        ? null
                        : () => _confirm(application, 'cancel', '作废申请'),
                    child: const Text('作废申请'),
                  ),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _busy || _uncertain
                        ? null
                        : () {
                            context.push(
                              '/applications/${application.id}/edit',
                            );
                          },
                    child: const Text('修改申请'),
                  ),
                  UtenButton(
                    onPressed: _busy || _uncertain
                        ? null
                        : () => _confirm(
                            application,
                            'submit',
                            application.status == 'REJECTED'
                                ? '重新提交审批'
                                : '提交审批',
                          ),
                    child: const Text('提交审批'),
                  ),
                ],
                if (owner &&
                    canApply &&
                    (application.status == 'SUBMITTED' ||
                        application.status == 'REVIEWING'))
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _busy || _uncertain
                        ? null
                        : () => _confirm(application, 'withdraw', '撤回申请'),
                    child: const Text('撤回申请'),
                  ),
                if (canReject)
                  UtenButton(
                    type: UtenButtonType.danger,
                    onPressed: _busy || _uncertain
                        ? null
                        : () => _reject(application),
                    child: const Text('驳回'),
                  ),
                if (canApprove)
                  UtenButton(
                    onPressed: _busy || _uncertain
                        ? null
                        : () => _confirm(application, 'approve', '通过本节点审核'),
                    child: const Text('审核通过'),
                  ),
                if (canReceive)
                  UtenButton(
                    onPressed: _busy || _uncertain
                        ? null
                        : () => _confirm(application, 'receive', '接收保管'),
                    child: const Text('接收保管'),
                  ),
                if (canPay)
                  UtenButton(
                    onPressed: _busy || _uncertain
                        ? null
                        : () => _pay(application),
                    child: const Text('登记付款'),
                  ),
                if (canLinkFinance)
                  UtenButton(
                    onPressed: _busy || _uncertain
                        ? null
                        : () => _pay(application, linkFinance: true),
                    child: const Text('关联预付账务'),
                  ),
                if (canCancelPayment)
                  UtenButton(
                    type: UtenButtonType.danger,
                    onPressed: _busy || _uncertain
                        ? null
                        : () => _reject(application, cancelPayment: true),
                    child: const Text('撤销付款登记'),
                  ),
              ],
            ),
    );
  }

  Widget _fact(String label, String value, {String? info}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
    child: Text.rich(
      TextSpan(
        children: [
          TextSpan(
            text: '$label  ',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          if (info != null)
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: UtenFieldHintIcon(info: info, compact: true),
            ),
          TextSpan(text: value),
        ],
      ),
    ),
  );
  Widget _panel(ThemeData theme, String title, Widget child, {String? hint}) =>
      DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: UtenRadius.cardAll,
        ),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  if (hint != null)
                    UtenFieldHintIcon(info: hint, compact: true),
                ],
              ),
              const SizedBox(height: UtenSpacing.s12),
              child,
            ],
          ),
        ),
      );
}

class _PaymentRecordPicker extends ConsumerStatefulWidget {
  const _PaymentRecordPicker({
    required this.application,
    this.draftId,
    this.action = 'pay',
  });
  final BusinessApplication application;
  final String? draftId;
  final String action;
  @override
  ConsumerState<_PaymentRecordPicker> createState() =>
      _PaymentRecordPickerState();
}

class _PaymentRecordPickerState extends ConsumerState<_PaymentRecordPicker>
    with
        FormDraftMixin<_PaymentRecordPicker>,
        ReadViewActivityMixin<_PaymentRecordPicker> {
  @override
  Future<void> onReadViewResumed() async {
    if (_selected != null) _selectionToRestore = _selected!.id;
    await _load();
  }

  final _search = TextEditingController();
  final _reference = TextEditingController();
  FinanceDocType _type = FinanceDocType.payment;
  List<FinanceDocListItem> _rows = [];
  FinanceDocListItem? _selected;
  bool _loading = false;
  String? _error;
  int _generation = 0;
  int? _activeSearchGeneration;
  String? _activeSearchKeyword;
  bool _isQueryPending(String value) =>
      _activeSearchGeneration == _generation &&
      _activeSearchKeyword == value.trim();
  String? _selectionToRestore;
  bool _confirming = false;
  bool _checkpointed = false;
  Map<String, dynamic>? _unknownCommand;
  late int _activeVersion = widget.application.version;
  DateTime _paymentDate = ChinaDateTime.today();
  bool get _cashPrepayment =>
      widget.application.kind == 'PREPAYMENT' && widget.action == 'pay';
  bool get _linkFinance => widget.action == 'link-finance';
  bool get _canSubmit => _linkFinance
      ? widget.application.canLinkFinance
      : widget.application.canPay;
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  String? get formDraftResumeId => widget.draftId;
  @override
  bool get formDraftBusy => _loading || _confirming;
  @override
  bool get formDraftHasConfirmedExternalRecovery => _checkpointed;
  @override
  Widget? get formDraftSubmissionRecoveryAction => _unknownCommand == null
      ? null
      : Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            UtenButton(
              onPressed: _confirming || _loading
                  ? null
                  : () => _recoverPayment(continueOriginal: false),
              child: Text(_linkFinance ? '核对账务关联结果' : '核对付款结果'),
            ),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _confirming || _loading
                  ? null
                  : () => _recoverPayment(continueOriginal: true),
              child: Text(_linkFinance ? '继续原账务关联' : '继续原付款登记'),
            ),
          ],
        );
  @override
  FormDraftSpec get formDraftSpec =>
      (_linkFinance
              ? FormDraftCatalog.businessApplicationPrepaymentFinance
              : FormDraftCatalog.businessApplicationPayment)
          .spec(
            route: '/applications/${widget.application.id}',
            title: '付款登记 ${widget.application.applicationNo}',
          );
  @override
  Iterable<Listenable> get formDraftListenables => [_search, _reference];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'createdDocId': widget.application.id,
    'applicationId': widget.application.id,
    'expectedVersion': _activeVersion,
    'action': widget.action,
    'paymentDate': _date(_paymentDate),
    formDraftUnknownSubmissionKey: _unknownCommand != null,
    if (_unknownCommand != null) '_applicationPaymentCommand': _unknownCommand,
    'financeDocumentType': _type == FinanceDocType.expense
        ? 'EXPENSE'
        : 'PAYMENT',
    'selectedId': _selected?.id ?? _selectionToRestore,
    'search': _search.text,
    'paymentReference': _reference.text,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['applicationId'] != widget.application.id) {
      throw const FormatException('付款草稿不属于当前申请');
    }
    if ((data['action'] ?? 'pay') != widget.action) {
      throw const FormatException('原草稿的付款操作类型不一致，请保留记录');
    }
    _paymentDate =
        DateTime.tryParse(data['paymentDate']?.toString() ?? '') ??
        ChinaDateTime.today();
    _type = data['financeDocumentType'] == 'EXPENSE'
        ? FinanceDocType.expense
        : FinanceDocType.payment;
    _selectionToRestore = data['selectedId'] as String?;
    _search.text = data['search'] as String? ?? '';
    _reference.text = data['paymentReference'] as String? ?? '';
    _activeVersion = data[formDraftUnknownSubmissionKey] == true
        ? (data['expectedVersion'] as num?)?.toInt() ??
              widget.application.version
        : widget.application.version;
    if (data[formDraftUnknownSubmissionKey] == true) {
      final command = data['_applicationPaymentCommand'];
      if (command is! Map ||
          command['fields'] is! Map ||
          command['expectedVersion'] is! num ||
          (command['action'] ?? 'pay') != widget.action ||
          command['applicationId'] != widget.application.id) {
        throw const FormatException('原付款提交信息无法完整恢复，请保留草稿');
      }
      _unknownCommand = Map<String, dynamic>.from(command);
    }
    if (mounted) setState(() {});
  }

  Future<void> _confirmSelection() async {
    if ((!_cashPrepayment && _selected == null) || _loading || _confirming) {
      return;
    }
    if (!_linkFinance && _reference.text.trim().isEmpty) {
      context.appWarning('请填写付款凭证号或交易流水号');
      return;
    }
    final selected = _selected;
    final type = _type;
    final reference = _reference.text;
    final generation = _generation;
    final paymentDate = _paymentDate;
    setState(() => _confirming = true);
    try {
      await saveFormDraftNow();
      if (!mounted || !formDraftIdentityIsCurrent) return;
      if (!identical(selected, _selected) ||
          type != _type ||
          reference != _reference.text ||
          generation != _generation ||
          paymentDate != _paymentDate) {
        context.appWarning('付款输入发生变化，请重新核对后确认');
        return;
      }
      setState(() {
        _checkpointed = true;
        _confirming = false;
      });
      Navigator.of(context).pop(<String, dynamic>{
        if (!_cashPrepayment)
          'financeDocumentType': type == FinanceDocType.expense
              ? 'EXPENSE'
              : 'PAYMENT',
        if (!_cashPrepayment) 'financeDocumentId': selected!.id,
        if (!_linkFinance)
          'paymentDate': _cashPrepayment
              ? _date(paymentDate)
              : selected!.billDate,
        if (!_linkFinance) 'paymentReference': reference.trim(),
        '_localDraftId': formDraftRecoveryId,
        '_localDraftRevision': formDraftRecoveryRevision,
        '_localExpectedVersion': _activeVersion,
      });
    } catch (error) {
      if (mounted) {
        setState(() => _confirming = false);
        context.appApiError(error, fallback: '付款输入尚未保存，请保留页面重试');
      }
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  Future<void> _recoverPayment({required bool continueOriginal}) async {
    if (_confirming || _loading || _unknownCommand == null) return;
    final command = _unknownCommand!;
    final fields = Map<String, dynamic>.from(command['fields'] as Map);
    final expectedVersion = (command['expectedVersion'] as num).toInt();
    setState(() => _confirming = true);
    try {
      final current = await ref
          .read(businessApplicationRepositoryProvider)
          .get(widget.application.id);
      if (!mounted || !formDraftIdentityIsCurrent) return;
      final receiptMatches = _linkFinance
          ? current.postingStatus == 'POSTED' &&
                current.financeDocumentId == fields['financeDocumentId']
          : current.status == 'PAID' &&
                (_cashPrepayment ||
                    current.financeDocumentId == fields['financeDocumentId']) &&
                current.fields['paymentReference'] ==
                    fields['paymentReference'] &&
                (current.fields['paymentDate'] == null ||
                    current.fields['paymentDate'] == fields['paymentDate']);
      final canContinue = _linkFinance
          ? current.status == 'PAID' && current.canLinkFinance
          : current.status == 'APPROVED' && current.canPay;
      if (receiptMatches) {
        await completeFormDraft();
        if (!mounted) return;
        ref.invalidate(businessApplicationDetailProvider(current.id));
        ref.invalidate(businessApplicationCountsProvider);
        refreshBadges(ref);
        Navigator.of(context).pop();
      } else if (continueOriginal &&
          canContinue &&
          current.version == expectedVersion) {
        // Explicit continuation of the exact frozen (id, action, version).
        // The row lock and expectedVersion permit at most one registration.
        setState(() {
          _checkpointed = true;
          _confirming = false;
        });
        Navigator.of(context).pop(<String, dynamic>{
          ...fields,
          '_localDraftId': formDraftRecoveryId,
          '_localDraftRevision': formDraftRecoveryRevision,
          '_localExpectedVersion': expectedVersion,
        });
      } else if (continueOriginal &&
          canContinue &&
          current.version > expectedVersion) {
        // An older version cannot commit after a newer authoritative version.
        // Keep the original inputs, release only the superseded send marker.
        final original = ref
            .read(formDraftsProvider)
            .firstWhere((draft) => draft.id == formDraftRecoveryId);
        final data = {
          ...original.data,
          formDraftUnknownSubmissionKey: false,
          'expectedVersion': current.version,
        }..remove('_applicationPaymentCommand');
        final saved = await ref
            .read(formDraftsProvider.notifier)
            .save(
              FormDraft.fromJson({...original.toJson(), 'data': data}),
              expectedRevision: formDraftRecoveryRevision,
            );
        if (!mounted || !formDraftIdentityIsCurrent) return;
        _unknownCommand = null;
        _activeVersion = current.version;
        adoptFormDraftRecoveryCheckpoint(saved);
        context.appWarning('申请版本已变化，原登记不会再提交。请重新核对这些输入后确认。');
      } else {
        context.appWarning('原付款结果仍需核对，输入已保留。请查看申请最新状态和流转记录。');
      }
    } catch (error) {
      if (mounted) context.appApiError(error, fallback: '付款结果暂时无法确认，原输入已保留');
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
  }

  @override
  void initState() {
    super.initState();
    final permissions = ref.read(currentPermissionsProvider);
    if (!const {
          'SUPPLIER_PAYMENT',
          'PREPAYMENT',
        }.contains(widget.application.kind) &&
        !permissions.contains(Perm.financePaymentView) &&
        permissions.contains(Perm.financeExpenseView)) {
      _type = FinanceDocType.expense;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await initializeFormDraft();
      if (mounted && formDraftIdentityIsCurrent) await _load();
    });
  }

  @override
  void dispose() {
    _generation++;
    _search.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (_confirming || _cashPrepayment) return;
    final generation = ++_generation;
    final scope = ref.read(authenticatedScopeProvider);
    final keyword = _search.text.trim();
    bool current() =>
        mounted &&
        formDraftIdentityIsCurrent &&
        generation == _generation &&
        scope == ref.read(authenticatedScopeProvider);
    _activeSearchGeneration = generation;
    _activeSearchKeyword = keyword;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await readViewActivity.runRead(
        current,
        () => loadCompletePagedResult<FinanceDocListItem>(
          isCurrent: current,
          idOf: (row) => row.id,
          loadPage: (page, size) async {
            final PagedResult<FinanceDocListItem> result;
            if (_linkFinance) {
              final json = await ref
                  .read(businessApplicationRepositoryProvider)
                  .prepaymentFinanceCandidates(
                    widget.application.id,
                    page: page,
                    size: size,
                    keyword: keyword,
                  );
              result = await PagedResult.fromJsonResponsive(json, (row) {
                // The neutral application candidate DTO supplies an exact text
                // amount; adapt it to the existing finance row without a double.
                final value = FinanceDocListItem.fromJson({
                  ...row,
                  if (row['amountBasis'] == 'ORIGINAL')
                    'amountOriginalExact': row['amountText']
                  else
                    'amountLocalExact':
                        row['amountText'] ??
                        row['amountLocalExact'] ??
                        row['amountLocalText'],
                });
                if ((widget.application.originalAmount
                            ? value.amountOriginalText
                            : value.amountLocalText)
                        ?.isNotEmpty !=
                    true) {
                  throw const FormatException('预付账务候选金额未完整返回，暂不能选择');
                }
                return value;
              });
            } else {
              result = await ref
                  .read(financeRepositoryProvider(_type))
                  .list(
                    page: page,
                    size: size,
                    filter: FinanceDocFilter(
                      status: 1,
                      keyword: keyword,
                      partyId: _type == FinanceDocType.payment
                          ? widget.application.fields['supplierId'] as String?
                          : null,
                    ),
                  );
            }
            return result;
          },
        ),
      );
      if (!current()) {
        return;
      }
      setState(() {
        _rows = result.items;
        _selected = _rows
            .where((row) => row.id == _selectionToRestore)
            .firstOrNull;
      });
    } catch (error) {
      if (isRetiredViewRead(error)) return;
      if (current()) {
        setState(() => _error = '财务单据读取失败，请重试');
      }
    } finally {
      if (_activeSearchGeneration == generation) {
        _activeSearchGeneration = null;
        _activeSearchKeyword = null;
      }
      if (current()) {
        setState(() => _loading = false);
      }
    }
  }

  Widget _prepaymentForm() => ListView(
    padding: const EdgeInsets.all(UtenSpacing.s16),
    children: [
      Text(
        '收款供应商  ${widget.application.fields['supplierName'] ?? widget.application.fields['payee'] ?? '—'}',
      ),
      const SizedBox(height: UtenSpacing.s16),
      Text('预付金额  ${widget.application.amountLabel}'),
      const SizedBox(height: UtenSpacing.s16),
      UtenDateField(
        label: '实际付款日期',
        required: true,
        value: _paymentDate,
        enabled: !_confirming,
        firstDate: DateTime.utc(2000),
        lastDate: ChinaDateTime.today(),
        onChanged: (value) {
          if (!_confirming) setState(() => _paymentDate = value);
        },
      ),
    ],
  );

  @override
  Widget build(BuildContext context) {
    final perms = ref.watch(currentPermissionsProvider);
    return withFormDraft(
      Material(
        child: SafeArea(
          child: Stack(
            children: [
              Column(
                children: [
                  UtenDialogHeader(
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            _cashPrepayment
                                ? '登记供应商预付款'
                                : _linkFinance
                                ? '关联合法预付账务'
                                : '选择已审核付款记录',
                          ),
                        ),
                        if (_cashPrepayment || _linkFinance)
                          UtenFieldHintIcon(
                            compact: true,
                            info: _cashPrepayment
                                ? '请先在申请详情上传实际付款证明。此处登记真实付款日期与流水号，不会生成费用单或自动入账；后续单独关联合法预付账务。'
                                : '这里只列出同供应商、金额和实际付款日期的合法已审核预付记录。不会重复扣款，也不会将待核历史余额当作预付入账。',
                          ),
                      ],
                    ),
                    showCloseButton: true,
                    onClose: () => Navigator.of(context).pop(),
                  ),
                  if (!_cashPrepayment)
                    Padding(
                      padding: const EdgeInsets.all(UtenSpacing.s16),
                      child: Column(
                        children: [
                          if (!_linkFinance)
                            Wrap(
                              spacing: UtenSpacing.s8,
                              children: [
                                if (perms.contains(Perm.financePaymentView))
                                  ChoiceChip(
                                    label: const Text('付款单'),
                                    selected: _type == FinanceDocType.payment,
                                    onSelected: _loading || _confirming
                                        ? null
                                        : (_) {
                                            if (_confirming || _loading) return;
                                            setState(
                                              () => _type =
                                                  FinanceDocType.payment,
                                            );
                                            _load();
                                          },
                                  ),
                                if (!const {
                                      'SUPPLIER_PAYMENT',
                                      'PREPAYMENT',
                                    }.contains(widget.application.kind) &&
                                    perms.contains(Perm.financeExpenseView))
                                  ChoiceChip(
                                    label: const Text('费用单'),
                                    selected: _type == FinanceDocType.expense,
                                    onSelected: _loading || _confirming
                                        ? null
                                        : (_) {
                                            if (_confirming || _loading) return;
                                            setState(
                                              () => _type =
                                                  FinanceDocType.expense,
                                            );
                                            _load();
                                          },
                                  ),
                              ],
                            ),
                          const SizedBox(height: UtenSpacing.s12),
                          Row(
                            children: [
                              Expanded(
                                child: AbsorbPointer(
                                  absorbing: _confirming,
                                  child: ExcludeFocus(
                                    excluding: _confirming,
                                    child: UtenSearchBar(
                                      key: const Key(
                                        'application-finance-candidate-search',
                                      ),
                                      controller: _search,
                                      hint: '搜索财务单号',
                                      isQueryPending: _isQueryPending,
                                      onSubmitted: (_) {
                                        if (!_confirming) _load();
                                      },
                                    ),
                                  ),
                                ),
                              ),
                              const UtenFieldHintIcon(
                                info:
                                    '仅关联已经审核入账且金额一致的财务记录，不会再次扣款。同一财务单不能重复关联多个申请。',
                              ),
                            ],
                          ),
                          const SizedBox(height: UtenSpacing.s8),
                          UtenButton(
                            onPressed: _loading ? null : _load,
                            child: const Text('查询'),
                          ),
                        ],
                      ),
                    ),
                  if (_error != null) Text(_error!),
                  Expanded(
                    child: _cashPrepayment
                        ? _prepaymentForm()
                        : ListView.builder(
                            itemCount: _rows.length,
                            itemBuilder: (context, index) {
                              final row = _rows[index];
                              return ListTile(
                                selected: _selected?.id == row.id,
                                leading: Icon(
                                  _selected?.id == row.id
                                      ? Icons.radio_button_checked
                                      : Icons.radio_button_off,
                                ),
                                title: Text(
                                  '${row.billNo ?? '未编号财务单'}  ${row.billDate ?? ''}',
                                ),
                                trailing: Text(
                                  '${widget.application.originalAmount ? row.amountOriginalText ?? '—' : row.amountLocalText ?? '—'} ${widget.application.amountUnit}',
                                ),
                                onTap: () {
                                  if (!_confirming) {
                                    setState(() => _selected = row);
                                  }
                                },
                              );
                            },
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: Column(
                      children: [
                        if (!_linkFinance)
                          const SizedBox(height: UtenSpacing.s12),
                        if (!_linkFinance)
                          TextField(
                            controller: _reference,
                            enabled: !_confirming,
                            maxLength: 2000,
                            decoration: const InputDecoration(
                              labelText: '付款凭证号 / 交易流水号 *',
                            ),
                          ),
                      ],
                    ),
                  ),
                  UtenDialogActions(
                    children: [
                      UtenButton(
                        onPressed:
                            !_canSubmit ||
                                (!_cashPrepayment && _selected == null) ||
                                _loading ||
                                _confirming
                            ? null
                            : _confirmSelection,
                        child: Text(
                          _cashPrepayment
                              ? '确认登记预付款'
                              : _linkFinance
                              ? '确认关联预付账务'
                              : '关联并登记付款',
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              if (_loading || _confirming)
                UtenBusyOverlay(
                  title: _confirming ? '正在核对登记资料' : '正在读取财务单据',
                  showDoNotLeaveHint: false,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _date(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
