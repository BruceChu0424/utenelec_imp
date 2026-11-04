import '../../../shared/formatters/exact_decimal.dart';
// 新建/编辑报销页（V608 合并：claimId 为空 = 新建，非空 = 编辑 DRAFT/REJECTED）
// 文档：docs/03-页面/新建报销页.md · docs/03-页面/报销列表页.md（编辑入口）
//
// 表单页口径：UtenContentContainer.narrow（保留兼容入口，正文随可用宽度铺满）；
// 结构：驳回事实 → 自适应多列表头 + 公共审批进度 → 全宽 UtenEditableGrid 多行费用；
// 原始金额/用途/扩展字段与行身份一起保存草稿，旧未完成弹窗仅用于兼容恢复。
// 右下悬浮组：新建=[保存并补充凭证]、编辑=[保存]；网络段挂 UtenBusyOverlay。
// 编辑 REJECTED 保存后仍在 REJECTED，重提在详情页（清驳回痕迹并重新通知审批人）。

import 'package:uten_imp/components/layout/uten_page_layout.dart';
import 'package:flutter/material.dart';
import '../../../core/performance/json_value_snapshot.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/router/route_names.dart';
import '../../../core/router/editor_resource_key.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../shared/widgets/editor_identity_notice.dart';
import '../../../shared/auth/sensitive_write.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/rmb_amount.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../providers/expense_providers.dart';
import 'expense_item_dialog.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/ai/guided/ai_guided_file_plan.dart';
import '../../../shared/ai/guided/ai_guided_file_banner.dart';
import '../../../shared/ai/chat/ai_chat_l10n.dart';
import '../../../shared/attachments/attachment_service.dart';
import '../models/expense_guided_values.dart';
import '../repositories/expense_repository.dart';
import '../widgets/expense_guided_invoice_preview.dart';
import '../widgets/expense_invoice_section.dart';
import '../widgets/expense_editable_items.dart';
import '../../finance/pages/finance_applications_page.dart'
    show pickFinanceApplicationSource;
import '../widgets/expense_approval_progress.dart';
import '../../../components/layout/uten_editable_grid.dart';

class ExpenseClaimEditPage extends ConsumerStatefulWidget {
  const ExpenseClaimEditPage({
    super.key,
    this.claimId,
    this.initialGuidedPlan,
    this.initialKind,
    this.applicationKind,
    this.travelApplicationId,
    this.travelApplicationSourceKind,
  });
  final String? applicationKind,
      travelApplicationId,
      travelApplicationSourceKind;

  /// 空 = 新建；非空 = 编辑（DRAFT/REJECTED）。
  final String? claimId;
  final AiGuidedFilePlan? initialGuidedPlan;
  final String? initialKind;

  @override
  ConsumerState<ExpenseClaimEditPage> createState() =>
      _ExpenseClaimEditPageState();
}

class _ExpenseClaimEditPageState extends ConsumerState<ExpenseClaimEditPage>
    with FormDraftMixin<ExpenseClaimEditPage> {
  final _titleController = TextEditingController();
  final _remarkController = TextEditingController();
  final _grid = UtenEditableGridController<ExpenseGridRow>();
  List<ExpenseItem> get _items => [for (final row in _grid.rows) row.toItem()];
  bool _gridRefreshPending = false;
  void _gridChanged() {
    if (!mounted || _gridRefreshPending) return;
    _gridRefreshPending = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gridRefreshPending = false;
      if (mounted) setState(() {});
    });
  }

  bool _busy = false;
  late String? _applicationKind = widget.applicationKind;
  late String? _travelApplicationId = widget.travelApplicationId;
  late String? _travelApplicationSourceKind =
      widget.travelApplicationSourceKind;
  bool _networkBusy = false;
  String _expenseKind = 'GENERAL';
  String? _travelApplicationLabel;
  bool _choosingTravelSource = false;
  bool _initialized = false;
  bool _documentIdentityChanged = false;
  late final Key _openedDocumentIdentity;
  Key get _documentIdentity => editorResourceKey(
    Uri(path: 'expense-editor'),
    sourceIdentity: {
      'claimId': widget.claimId,
      'applicationKind': widget.applicationKind,
      'travelApplicationId': widget.travelApplicationId,
      'travelApplicationSourceKind': widget.travelApplicationSourceKind,
      'kind': widget.initialKind ?? 'GENERAL',
      'guidedFile': widget.initialGuidedPlan?.result.sha256Hex,
    },
  );
  @override
  bool get formDraftIdentityIsCurrent =>
      super.formDraftIdentityIsCurrent && !_documentIdentityChanged;
  int? _editVersion;
  Map<String, dynamic>? _pendingItemDraft;
  AiGuidedFilePlan? _guidedPlan;
  String _guidedStatus = 'documentReady';
  String? _createdGuidedClaimId;
  String? _guidedAttachmentId;
  bool _guidedUploadStarted = false;
  bool _guidedInitializing = false;
  bool _guidedValidated = false;
  String? _guidedError;

  AppLocalizations get l10n => AppLocalizations.of(context);

  bool get _isEdit => widget.claimId != null;

  @override
  bool get formDraftEnabled => !_isEdit;
  @override
  bool get formDraftBusy => _busy;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.expense.spec(
    title: '新建报销',
    route: '/expense/new',
    routeParameters: {
      'kind': _expenseKind,
      'applicationKind': ?_applicationKind,
      'travelApplicationId': ?_travelApplicationId,
      'travelApplicationSourceKind': ?_travelApplicationSourceKind,
    },
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _titleController,
    _remarkController,
    _grid.draftListenable,
    for (final row in _grid.rows) ...row.draftListenables,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'applicationKind': _applicationKind,
    'travelApplicationId': _travelApplicationId,
    'travelApplicationSourceKind': _travelApplicationSourceKind,
    'travelApplicationLabel': _travelApplicationLabel,
    'title': _titleController.text,
    'remark': _remarkController.text,
    'expenseKind': _expenseKind,
    'items': [for (final row in _grid.rows) row.exportDraft()],
    'pendingItem': _pendingItemDraft,
    'guidedPlan': _guidedPlan?.toLocalDraft(),
    'guidedStatus': _guidedStatus,
    'createdDocId': _createdGuidedClaimId,
    'guidedAttachmentId': _guidedAttachmentId,
    'guidedUploadStarted': _guidedUploadStarted,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (widget.applicationKind != null &&
        data['applicationKind'] != widget.applicationKind) {
      throw const FormatException('草稿对应不同申请类型，请从原草稿入口恢复');
    }
    _applicationKind =
        data['applicationKind']?.toString() ?? widget.applicationKind;
    _travelApplicationId =
        data['travelApplicationId']?.toString() ?? widget.travelApplicationId;
    _travelApplicationSourceKind =
        data['travelApplicationSourceKind']?.toString() ??
        widget.travelApplicationSourceKind;
    _travelApplicationLabel = data['travelApplicationLabel']?.toString();
    // Confirmed create/upload identities survive even when the source blob is
    // damaged. Never downgrade an already-created claim into a fresh create.
    _createdGuidedClaimId = data['createdDocId'] is String
        ? data['createdDocId'] as String
        : null;
    _guidedAttachmentId = data['guidedAttachmentId'] is String
        ? data['guidedAttachmentId'] as String
        : null;
    _guidedUploadStarted = data['guidedUploadStarted'] == true;
    final restoreIdentity = ref.read(aiGuidedFileIdentityProvider);
    final restoredPlan = await AiGuidedFilePlan.restoreLocalDraftResponsive(
      data['guidedPlan'],
      restoreIdentity,
      isCurrent: () =>
          formDraftIdentityIsCurrent &&
          ref.read(aiGuidedFileIdentityProvider) == restoreIdentity,
    );
    if (!mounted || !formDraftIdentityIsCurrent) return;
    if (data['guidedPlan'] != null &&
        (restoredPlan == null ||
            restoredPlan.workflow != AiGuidedWorkflow.expenseClaim)) {
      throw FormatException(aiChatText(context, 'documentSourceMismatch'));
    }
    if (restoredPlan != null) {
      _guidedPlan = restoredPlan;
      _guidedValidated = false;
    }
    _titleController.text = draftText(data, 'title');
    _remarkController.text = draftText(data, 'remark');
    _expenseKind =
        data['expenseKind'] == 'TRAVEL' ||
            data['expenseKind'] == null &&
                _applicationKind == 'TRAVEL_REIMBURSEMENT'
        ? 'TRAVEL'
        : 'GENERAL';
    final rows = <ExpenseGridRow>[];
    final localIds = <String>{};
    for (final raw in draftMaps(data['items'])) {
      final originalId = raw['id']?.toString().trim() ?? '';
      final reusedIdentity =
          originalId.isEmpty || localIds.contains(originalId);
      final id = reusedIdentity ? const Uuid().v4() : originalId;
      localIds.add(id);
      final row = ExpenseGridRow.restore(raw, id: id);
      rows.add(row);
      final fields = row.platformFields;
      if (reusedIdentity) {
        // Older local drafts omitted item IDs. A local identity is never proof
        // that this row already exists on the server.
        fields.sourceRecordId = null;
        fields.version = 0;
        fields.loaded = false;
        fields.canWrite = false;
        fields.dirty = fields.cells.isNotEmpty;
      }
    }
    _grid.replaceAll(rows);
    _pendingItemDraft = data['pendingItem'] == null
        ? null
        : draftMap(data['pendingItem']);
    if (restoredPlan != null &&
        restoredPlan.workflow == AiGuidedWorkflow.expenseClaim) {
      _guidedPlan = restoredPlan;
      _guidedStatus =
          const {
            'guidedFilled',
            'guidedWaiting',
            'guidedExpenseSaved',
            'guidedExisting',
            'documentReady',
          }.contains(data['guidedStatus'])
          ? data['guidedStatus'] as String
          : 'guidedWaiting';
    }
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    _openedDocumentIdentity = _documentIdentity;
    startFormDraftIdentityGuard();
    _grid.addListener(_gridChanged);
    _grid.totalListenable.addListener(_gridChanged);
    _expenseKind =
        widget.initialKind == 'TRAVEL' ||
            widget.initialKind == null &&
                widget.applicationKind == 'TRAVEL_REIMBURSEMENT'
        ? 'TRAVEL'
        : 'GENERAL';
    _guidedPlan = widget.initialGuidedPlan;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await initializeFormDraft();
      if (mounted) _applyGuidedPlan();
    });
  }

  @override
  void didUpdateWidget(covariant ExpenseClaimEditPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_documentIdentity != _openedDocumentIdentity) {
      _documentIdentityChanged = true;
    }
  }

  @override
  void dispose() {
    _grid.removeListener(_gridChanged);
    _grid.totalListenable.removeListener(_gridChanged);
    _grid.dispose();
    _titleController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  Future<void> _applyGuidedPlan() async {
    final plan = _guidedPlan;
    if (plan == null || _isEdit || !plan.matches(ref) || _guidedInitializing) {
      return;
    }
    setState(() {
      _guidedInitializing = true;
      _guidedValidated = false;
      _guidedStatus = 'guidedValidating';
    });
    try {
      final verified = await validateAiGuidedFilePlan(ref, plan);
      if (!mounted || !formDraftIdentityIsCurrent || !verified.matches(ref)) {
        return;
      }
      setState(() {
        _guidedPlan = verified;
        _guidedValidated = true;
      });
      if (_createdGuidedClaimId != null) {
        setState(() => _guidedStatus = 'guidedExpenseSaved');
        return;
      }
      if (_items.isNotEmpty ||
          _titleController.text.isNotEmpty ||
          _remarkController.text.isNotEmpty) {
        setState(() => _guidedStatus = 'guidedExisting');
        return;
      }
      final fields = verified.result.fields;
      final summary = verified.result.isHighConfidence('itemSummary')
          ? fields['itemSummary']
          : null;
      final title = summary?.trim().isNotEmpty == true
          ? summary!
          : verified.file.name;
      setState(() {
        _titleController.text = title.substring(
          0,
          title.length > 200 ? 200 : title.length,
        );
        _guidedStatus = 'guidedHeader';
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !formDraftIdentityIsCurrent || !verified.matches(ref)) {
        return;
      }
      final item = guidedExpenseItem(verified, const Uuid().v4());
      setState(() {
        if (item != null) _grid.addRow(ExpenseGridRow.fromItem(item));
        _guidedStatus = item != null ? 'guidedFilled' : 'guidedWaiting';
      });
      // Real durability is acknowledged only after the own-account local draft
      // store commits. Quota/disk failures remain actionable on this page.
      await saveFormDraftNow();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _guidedStatus = 'guidedWaiting';
        _guidedError = describeSubmitError(
          error,
          fallback: aiChatText(context, 'guidedLocalSaveFailed'),
        );
      });
    } finally {
      if (mounted) setState(() => _guidedInitializing = false);
    }
  }

  /// Explicit user action after they saved the claim. An unknown upload result
  /// is reconciled from persisted owner/file identity before any new write.
  Future<void> _registerGuidedInvoice() async {
    final plan = _guidedPlan;
    final claimId = _createdGuidedClaimId;
    if (_busy || plan == null || claimId == null || !plan.matches(ref)) return;
    setState(() {
      _busy = true;
      _networkBusy = true;
      _guidedError = null;
    });
    try {
      final verified = await validateAiGuidedFilePlan(ref, plan);
      if (!mounted || !formDraftIdentityIsCurrent || !verified.matches(ref)) {
        return;
      }
      final repository = ref.read(expenseRepositoryProvider);
      var claim = await repository.getById(claimId);
      if (!mounted || !formDraftIdentityIsCurrent || !verified.matches(ref)) {
        return;
      }
      final employeeId = ref.read(sessionProvider).user?.employeeId;
      if (claim.applicantId != employeeId ||
          (claim.status != ExpenseClaimStatus.draft &&
              claim.status != ExpenseClaimStatus.rejected)) {
        throw ApiException(
          'FORBIDDEN',
          aiChatText(context, 'permissionChanged'),
        );
      }
      final existing = claim.attachments
          .where(
            (attachment) =>
                !attachment.deleted &&
                attachment.ownerType == 'EXPENSE_CLAIM' &&
                attachment.ownerId == claimId &&
                attachment.sha256 == verified.result.sha256Hex &&
                attachment.sizeBytes == verified.file.bytes!.length &&
                attachment.uploadedBy == verified.identity.scope.userId,
          )
          .firstOrNull;
      if (existing != null) {
        _guidedAttachmentId = existing.id;
        _guidedUploadStarted = false;
      } else if (_guidedUploadStarted || _guidedAttachmentId != null) {
        throw ApiException(
          'UPLOAD_RESULT_UNKNOWN',
          aiChatText(context, 'guidedUploadUncertain'),
        );
      } else {
        _guidedUploadStarted = true;
        await saveFormDraftNow();
        if (!mounted || !formDraftIdentityIsCurrent || !verified.matches(ref)) {
          return;
        }
        final attachment = await ref
            .read(attachmentServiceProvider)
            .uploadGuarded(
              ownerType: 'EXPENSE_CLAIM',
              ownerId: claimId,
              fileName: verified.file.name,
              contentType:
                  aiGuidedContentTypes[verified.file.extension!.toLowerCase()]!,
              bytes: verified.file.bytes!,
              canContinue: () =>
                  mounted &&
                  formDraftIdentityIsCurrent &&
                  verified.matches(ref),
            );
        if (!mounted || !formDraftIdentityIsCurrent || !verified.matches(ref)) {
          return;
        }
        _guidedAttachmentId = attachment.id;
        _guidedUploadStarted = false;
      }
      await checkpointFormDraftAfterCreation();
      claim = await repository.getById(claimId);
      if (!mounted || !formDraftIdentityIsCurrent || !verified.matches(ref)) {
        return;
      }
      _guidedPlan = verified;
      setState(() => _networkBusy = false);
      final saved = await UtenBusyOverlay.yieldWhile(
        () => showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ExpenseInvoiceFormDialog(
            claimId: claimId,
            attachments: claim.attachments,
            expectedVersion: claim.version,
            guidedFields: verified.result.fields,
            guidedAttachmentId: _guidedAttachmentId,
            guidedPlan: verified,
          ),
        ),
      );
      if (!mounted || !formDraftIdentityIsCurrent || !verified.matches(ref)) {
        return;
      }
      if (saved == true) {
        await completeFormDraft();
        if (mounted) context.replace(RoutePath.expenseDetail(claimId));
      }
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _guidedError = describeSubmitError(
          error,
          fallback: aiChatText(context, 'guidedLocalSaveFailed'),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _networkBusy = false;
        });
      }
    }
  }

  String? get _totalText =>
      financeExactSumTexts(_grid.rows.map((row) => row.amount.text));

  /// 编辑模式：草稿就绪即预填一次（明细拷贝成可变副本，避免动到 provider 缓存）。
  void _prefillOnce(ExpenseClaim? claim) {
    if (_initialized || _isEdit == false || claim == null) return;
    if (claim.id != widget.claimId) return;
    _initialized = true;
    _editVersion = claim.version;
    _expenseKind = claim.expenseKind;
    _applicationKind = claim.applicationKind ?? _applicationKind;
    _travelApplicationId = claim.travelApplicationId ?? _travelApplicationId;
    _travelApplicationSourceKind =
        claim.travelApplicationSourceKind ?? _travelApplicationSourceKind;
    _titleController.text = claim.title;
    _remarkController.text = claim.remark ?? '';
    _grid.replaceAll(
      claim.items.map((item) => ExpenseGridRow.fromItem(item, persisted: true)),
    );
  }

  Future<void> _addItem({ExpenseItem? existing}) async {
    final pending = !_isEdit ? _pendingItemDraft : null;
    if (pending != null) {
      existing = _items
          .where((item) => item.id == pending['existingItemId'])
          .firstOrNull;
    }
    final item = await showDialog<ExpenseItem>(
      context: context,
      barrierDismissible: _isEdit,
      builder: (_) => ExpenseItemDialog(
        initial: existing,
        draft: pending,
        onDraftChanged: _isEdit
            ? null
            : (value) {
                setState(
                  () => _pendingItemDraft = {
                    ...value,
                    'existingItemId': existing?.id,
                  },
                );
              },
        onDiscardDraft: () => setState(() => _pendingItemDraft = null),
        onSaveDraft: _isEdit ? null : saveFormDraftNow,
      ),
    );
    if (item == null || !mounted) return;
    setState(() {
      _pendingItemDraft = null;
      if (existing != null) {
        final row = _grid.rows
            .where((row) => row.id == existing!.id)
            .firstOrNull;
        row?.applyItem(item);
      } else {
        _grid.addRow(ExpenseGridRow.fromItem(item));
      }
    });
  }

  Future<void> _save() async {
    if (!formDraftIdentityIsCurrent ||
        _busy ||
        _guidedInitializing ||
        _createdGuidedClaimId != null) {
      return;
    }
    if (_guidedPlan != null &&
        (!_guidedValidated || !_guidedPlan!.matches(ref))) {
      return;
    }
    if (_pendingItemDraft != null) {
      context.appWarning('还有未完成的报销明细，请先继续填写或放弃该明细');
      await _addItem();
      return;
    }
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      context.appWarning(l10n.expenseFlowMissingTitle);
      return;
    }
    if (title.length > 200) {
      context.appWarning(l10n.expenseFlowTitleLength);
      return;
    }
    if (_items.isEmpty) {
      context.appWarning(l10n.expenseFlowMissingItems);
      return;
    }
    if (_grid.length > 100) {
      context.appWarning('单张报销最多100条费用，请核对并拆分申请，现有明细已保留');
      return;
    }
    for (final row in _grid.rows) {
      final error = row.validationError;
      if (error != null) {
        row.flagged = true;
        context.appWarning(
          '第${_grid.rows.indexOf(row) + 1}条费用：${error.message}',
        );
        await _grid.revealError(row, columnKey: error.column);
        return;
      }
    }
    final totalUnits = financeAmountUnits(_totalText);
    if (totalUnits == null || totalUnits >= BigInt.from(10).pow(64)) {
      context.appWarning('报销合计超出可无损保存范围，请核对原数；明细已保留');
      return;
    }
    if (_applicationKind == 'TRAVEL_REIMBURSEMENT' &&
        _travelApplicationId == null) {
      context.appWarning('请选择本人已批准并由财务保管的出差申请');
      await _chooseTravelSource();
      return;
    }
    final remark = _remarkController.text.trim();
    final itemsSnapshot = [
      for (final row in _grid.rows)
        row.toItem().withPlatformFields(row.platformFields.savePayload()),
    ];

    setState(() {
      _busy = true;
      _networkBusy = true;
    });
    try {
      if (_guidedPlan case final plan?) {
        final before = JsonValueSnapshot.capture(captureFormDraftSnapshot());
        setState(() {
          _guidedValidated = false;
          _guidedStatus = 'guidedValidating';
        });
        final verified = await validateAiGuidedFilePlan(ref, plan);
        if (!mounted || !formDraftIdentityIsCurrent || !verified.matches(ref)) {
          return;
        }
        // Only the status label changes during this guard; fields must not.
        final after = {
          ...captureFormDraftSnapshot(),
          'guidedStatus': before.data['guidedStatus'],
        };
        if (!before.matches(after)) {
          setState(() {
            _guidedValidated = true;
            _guidedStatus = 'guidedExisting';
          });
          return;
        }
        setState(() {
          _guidedPlan = verified;
          _guidedValidated = true;
          _guidedStatus = 'guidedFilled';
        });
      }
      if (_isEdit) {
        final claimId = widget.claimId!;
        final updated = await runSensitiveWrite<ExpenseClaim>(
          ref,
          isCurrent: () => mounted && formDraftIdentityIsCurrent,
          write: () => updateExpense(
            ref,
            claimId,
            expectedVersion: _editVersion!,
            expenseKind: _expenseKind,
            applicationKind: _applicationKind,
            travelApplicationId: _travelApplicationId,
            travelApplicationSourceKind: _travelApplicationSourceKind,
            title: title,
            items: itemsSnapshot,
            remark: remark.isEmpty ? null : remark,
          ),
        );
        if (updated.id != claimId) {
          throw const FormatException('保存回执不属于原报销单，请保留输入并刷新核对');
        }
        if (mounted && formDraftIdentityIsCurrent) {
          setState(() => _networkBusy = false);
          context.appSuccess(l10n.expenseFlowSaved);
          // replace 落详情（2026-09-24）：从「列表→详情→编辑」push 进来时，
          // go 会整替导航栈，详情返回键落 default 而不是报销列表；replace 只换
          // 栈顶编辑页，返回链保持「详情→列表」。
          context.replace(RoutePath.expenseDetail(claimId));
        }
        return;
      }
      final claim = await runFormDraftSubmission(
        () => createExpense(
          ref,
          title: title,
          applicationKind: _applicationKind,
          travelApplicationId: _travelApplicationId,
          travelApplicationSourceKind: _travelApplicationSourceKind,
          expenseKind: _expenseKind,
          items: itemsSnapshot,
          remark: remark.isEmpty ? null : remark,
        ),
      );
      if (_guidedPlan != null) {
        _createdGuidedClaimId = claim.id;
        await checkpointFormDraftAfterCreation();
        if (mounted) setState(() => _guidedStatus = 'guidedExpenseSaved');
        return;
      }
      await completeFormDraft();
      if (mounted && formDraftIdentityIsCurrent) {
        setState(() => _networkBusy = false);
        context.appSuccess(l10n.expenseFlowDraftSaved);
        context.replace(RoutePath.expenseDetail(claim.id));
      }
    } catch (error) {
      if (mounted && formDraftIdentityIsCurrent) {
        setState(() => _networkBusy = false);
        if (_guidedPlan != null && !_guidedValidated) {
          setState(() {
            _guidedStatus = 'guidedWaiting';
            _guidedError = describeSubmitError(
              error,
              fallback: aiChatText(context, 'failed'),
            );
          });
        }
        if (error is ApiException) {
          context.appApiError(error);
        } else {
          context.appError(describeSubmitError(error, fallback: '操作失败，请稍后重试'));
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _networkBusy = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!formDraftIdentityIsCurrent) {
      return EditorIdentityNotice(
        title: _isEdit ? l10n.expenseFlowEdit : l10n.expenseFlowNew,
        documentChanged: _documentIdentityChanged,
        onBack: () => backTo(context, defaultPath: RouteName.expense),
      );
    }
    final plan = _guidedPlan;
    if (plan != null &&
        (ref.watch(aiGuidedFileIdentityProvider) != plan.identity ||
            plan.workflow != AiGuidedWorkflow.expenseClaim ||
            !plan.matches(ref))) {
      return Scaffold(
        body: Center(child: Text(aiChatText(context, 'permissionChanged'))),
      );
    }
    if (plan != null && !_guidedValidated) {
      return withFormDraft(
        Scaffold(
          appBar: UtenAppBar(title: l10n.expenseFlowNew, showBackButton: true),
          body: UtenPageEdgePadding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: AiGuidedFileBanner(
              plan: plan,
              status: _guidedStatus,
              detail: _guidedError,
              busy: _guidedInitializing || _busy,
              onRetry: _guidedInitializing || _busy ? null : _applyGuidedPlan,
            ),
          ),
        ),
      );
    }
    final theme = Theme.of(context);
    final detail = _isEdit
        ? ref.watch(expenseDetailProvider(widget.claimId!))
        : null;
    _prefillOnce(detail?.value);
    final me = ref.watch(sessionProvider).user;
    final permissions = ref.watch(currentPermissionsProvider);
    final scope = ref.watch(authenticatedScopeProvider);
    final claim = detail?.value;
    final canEdit =
        !_isEdit ||
        (claim != null &&
            !claim.abandoned &&
            claim.applicantId == me?.employeeId &&
            (claim.status == ExpenseClaimStatus.draft ||
                claim.status == ExpenseClaimStatus.rejected));
    final canSave =
        scope != null &&
        !scope.readOnly &&
        permissions.contains(Perm.expenseApply) &&
        canEdit &&
        (!_isEdit || claim != null);

    final body = UtenContentContainer.narrow(
      child: ListView(
        key: const Key('expense-edit-scroll'),
        padding: const EdgeInsets.fromLTRB(
          0,
          UtenSpacing.s16,
          0,
          UtenFloatingActionGroup.scrollClearance,
        ),
        children: [
          if (plan != null) ...[
            AiGuidedFileBanner(
              plan: plan,
              status: _guidedStatus,
              busy: _busy || _guidedInitializing,
              detail: _guidedError,
              onRetry: !_guidedValidated && !_guidedInitializing
                  ? _applyGuidedPlan
                  : null,
              completedStages: [
                'guidedParsing',
                if (_items.isNotEmpty) ...['guidedHeader', 'guidedRows'],
              ],
              activeStage: _createdGuidedClaimId != null
                  ? 'guidedInvoiceRegister'
                  : 'guidedManualSave',
              filledFields: [
                if (_titleController.text.isNotEmpty) _titleController.text,
                if (_items.isNotEmpty)
                  '${aiChatText(context, 'invoice_totalAmount')}: ${financeExactMoneyDisplay(_items.first.amountText)}',
              ],
            ),
            if (_guidedValidated) ExpenseGuidedInvoicePreview(plan: plan),
            const SizedBox(height: UtenSpacing.s16),
          ],
          if (detail != null)
            detail.when(
              loading: () =>
                  const Center(child: CircularProgressIndicator.adaptive()),
              error: (e, _) => Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Text(l10n.expenseFlowLoadFailed),
              ),
              data: (claim) => _rejectedBanner(theme, claim),
            ),
          if (detail != null) const SizedBox(height: UtenSpacing.s16),

          LayoutBuilder(
            builder: (context, constraints) {
              final document = _documentPanel(
                theme,
                applicant: claim?.applicantName ?? me?.name ?? '—',
                department: claim?.departmentName ?? me?.department ?? '—',
                date: claim?.createdAt ?? ChinaDateTime.today(),
                editable: canSave && !_busy,
              );
              final wide =
                  constraints.maxWidth >= 1080 &&
                  MediaQuery.textScalerOf(context).scale(14) < 20;
              if (!wide) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    document,
                    const SizedBox(height: UtenSpacing.s16),
                    _workflowPanel(theme, collapsed: true),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: document),
                  const SizedBox(width: UtenSpacing.s24),
                  SizedBox(width: 248, child: _workflowPanel(theme)),
                ],
              );
            },
          ),
          const SizedBox(height: UtenSpacing.s16),
          _itemsSection(theme, columnEditingEnabled: canSave && !_busy),
        ],
      ),
    );

    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: _isEdit ? l10n.expenseFlowEdit : l10n.expenseFlowNew,
          showBackButton: true,
        ),
        body: Stack(
          children: [
            Positioned.fill(
              child: !canEdit && detail?.hasValue == true
                  ? UtenEmpty(message: l10n.expenseFlowNotEditable)
                  : AbsorbPointer(
                      absorbing:
                          !canSave ||
                          _busy ||
                          _guidedInitializing ||
                          (_isEdit && claim == null) ||
                          _createdGuidedClaimId != null,
                      child: body,
                    ),
            ),
            if (_networkBusy || _guidedInitializing)
              const UtenBusyOverlay(
                title: '正在保存并核对报销资料',
                showDoNotLeaveHint: false,
              ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: UtenFloatingActionGroup(
          children: [
            if (_createdGuidedClaimId != null) ...[
              UtenButton(
                type: UtenButtonType.secondary,
                onPressed: _busy
                    ? null
                    : () => context.push(
                        RoutePath.expenseDetail(_createdGuidedClaimId!),
                      ),
                child: Text(aiChatText(context, 'guidedOpenSaved')),
              ),
              if (plan != null && _guidedValidated)
                UtenButton(
                  key: const ValueKey('expense-guided-register'),
                  isLoading: _busy,
                  onPressed: _busy ? null : _registerGuidedInvoice,
                  child: Text(aiChatText(context, 'guidedInvoiceRegister')),
                ),
            ] else if (canSave)
              UtenButton(
                size: UtenButtonSize.large,
                isLoading: _busy,
                icon: Icons.save_outlined,
                onPressed: _busy || _guidedInitializing || _items.isEmpty
                    ? null
                    : _save,
                onDisabledTap: _busy
                    ? null
                    : () => context.appWarning(l10n.expenseFlowMissingItems),
                child: Text(
                  _isEdit
                      ? l10n.expenseFlowSave
                      : l10n.expenseFlowSaveAndContinue,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _documentPanel(
    ThemeData theme, {
    required String applicant,
    required String department,
    required DateTime date,
    required bool editable,
  }) => DecoratedBox(
    key: const Key('expense-document-panel'),
    decoration: BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: UtenRadius.cardAll,
      border: Border.all(color: theme.colorScheme.outlineVariant),
    ),
    child: Padding(
      padding: const EdgeInsets.all(UtenSpacing.s20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.receipt_long_outlined,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                '报销信息',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const UtenFieldHintIcon(
                info: '先保存申请，再补充原始凭证并提交审批。出差报销和费用报销按同一条报销审批链流转；纸质材料可以在详情打印后签名。',
                compact: true,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s8,
            children: [
              _fact(theme, l10n.expenseFlowApplicant, applicant),
              _fact(theme, l10n.expenseFlowDepartment, department),
              _fact(theme, l10n.expenseFlowDate, _fmtDate(date)),
            ],
          ),
          const Divider(height: UtenSpacing.s32),
          Wrap(
            spacing: UtenSpacing.s8,
            children: [
              for (final kind in const {
                'GENERAL': '费用报销',
                'TRAVEL': '出差报销',
              }.entries)
                ChoiceChip(
                  label: Text(kind.value),
                  selected: _expenseKind == kind.key,
                  onSelected: editable
                      ? (_) => setState(() => _expenseKind = kind.key)
                      : null,
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          _headerCard(theme),
        ],
      ),
    ),
  );

  Widget _fact(ThemeData theme, String label, String value) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$label  ',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
        TextSpan(
          text: value,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ],
    ),
    style: theme.textTheme.bodySmall,
  );

  Widget _workflowPanel(ThemeData theme, {bool collapsed = false}) {
    const hint =
        '部门负责人只审核本部门申请；财务初核、财务复核、总经办批准分别授权。任一节点驳回后，申请人修订并重新提交，从部门负责人重新审核。最终批准后由出纳登记付款。';
    const steps = ExpenseApprovalProgress.preview(showHeader: false);
    final title = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '审批流程',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const UtenFieldHintIcon(info: hint, compact: true),
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: UtenRadius.cardAll,
      ),
      child: collapsed
          ? ExpansionTile(
              title: title,
              shape: const Border(),
              collapsedShape: const Border(),
              childrenPadding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                0,
                UtenSpacing.s16,
                UtenSpacing.s16,
              ),
              children: const [steps],
            )
          : Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  title,
                  const SizedBox(height: UtenSpacing.s8),
                  steps,
                ],
              ),
            ),
    );
  }

  /// 驳回横幅（编辑 REJECTED 时置顶；修订保存后仍为 REJECTED，详情页重提）。
  Widget _rejectedBanner(ThemeData theme, ExpenseClaim claim) {
    if (claim.status != ExpenseClaimStatus.rejected) {
      return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: UtenColors.error.withValues(alpha: 0.08),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: UtenColors.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 18,
            color: UtenColors.error,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        '已驳回 ${claim.rejectedByName ?? ''}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: UtenColors.error,
                        ),
                      ),
                    ),
                    const UtenFieldHintIcon(
                      info: '保存修订后仍需在详情重新提交，重新走完整审批链。',
                      compact: true,
                    ),
                  ],
                ),
                if (claim.rejectReason != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    '驳回原因：${claim.rejectReason}',
                    style: theme.textTheme.bodyMedium,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _chooseTravelSource() async {
    if (_busy || _choosingTravelSource) return;
    _choosingTravelSource = true;
    try {
      final source = await pickFinanceApplicationSource(
        context,
        kind: 'TRAVEL_APPLICATION',
      );
      if (source == null || !mounted || !formDraftIdentityIsCurrent) return;
      final kind = source['sourceKind']?.toString();
      if (!const {
            'BUSINESS_APPLICATION',
            'FINANCE_APPLICATION',
          }.contains(kind) ||
          source['id'] == null) {
        context.appWarning('出差来源类型尚未明确，请刷新来源后重新选择');
        return;
      }
      setState(() {
        _travelApplicationId = source['id'].toString();
        _travelApplicationSourceKind = kind;
        _travelApplicationLabel = [
          source['code'],
          source['name'],
        ].whereType<String>().where((text) => text.isNotEmpty).join(' ');
      });
      markFormDraftChanged();
    } finally {
      _choosingTravelSource = false;
    }
  }

  Widget _headerCard(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_applicationKind == 'TRAVEL_REIMBURSEMENT')
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
            child: UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _busy ? null : _chooseTravelSource,
              child: Text(
                _travelApplicationId == null
                    ? '选择已保管出差申请'
                    : (_travelApplicationLabel?.isNotEmpty == true
                          ? _travelApplicationLabel!
                          : '已关联出差申请'),
              ),
            ),
          ),
        UtenFormGrid(
          columns: 2,
          maxColumns: 2,
          minFieldWidth: 300,
          children: [
            TextField(
              controller: _titleController,
              textInputAction: TextInputAction.next,
              maxLength: 200,
              decoration: UtenInputDecoration(
                InputDecoration(
                  labelText: l10n.expenseFlowTitle,
                  hintText: l10n.expenseFlowTitleHint,
                ),
                info: l10n.expenseFlowTitleInfo,
              ),
            ),
            TextField(
              controller: _remarkController,
              maxLines: 2,
              maxLength: 2000,
              decoration: UtenInputDecoration(
                InputDecoration(
                  labelText: l10n.expenseFlowRemark,
                  hintText: l10n.expenseFlowRemarkHint,
                ),
                info: l10n.expenseFlowNoInvoiceGuide,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _itemsSection(
    ThemeData theme, {
    required bool columnEditingEnabled,
  }) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Text(
                  l10n.expenseFlowItems,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const UtenFieldHintIcon(
                  info:
                      '按费用逐行填写，支持添加多行、复制和批量删除。未完成的金额和用途会保留在草稿中；保存时校验全部明细，不会漏掉筛选隐藏的行。',
                  compact: true,
                ),
              ],
            ),
          ),
          if (_pendingItemDraft != null)
            UtenButton(
              type: UtenButtonType.tonal,
              onPressed: columnEditingEnabled ? _addItem : null,
              child: const Text('继续未完成明细'),
            ),
        ],
      ),
      const SizedBox(height: UtenSpacing.s8),
      ExpenseEditableItems(
        controller: _grid,
        editable: columnEditingEnabled,
        footer: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s16),
          child: _totalCard(theme),
        ),
      ),
    ],
  );

  /// 合计卡：小写（tabular）+ 人民币大写（打印报销单同款口径）。
  Widget _totalCard(ThemeData theme) {
    final capital = rmbCapital(_totalText ?? '');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: UtenSpacing.s16,
          runSpacing: UtenSpacing.s8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${l10n.expenseFlowTotal} (${_items.length})',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            Text(
              '${financeExactMoneyDisplay(_totalText)} 元',
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                color: theme.colorScheme.primary,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          '${l10n.expenseFlowCapital}: $capital',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
