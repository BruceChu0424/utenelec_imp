// 新建/编辑报销页（V608 合并：claimId 为空 = 新建，非空 = 编辑 DRAFT/REJECTED）
// 文档：docs/03-页面/新建报销页.md · docs/03-页面/报销列表页.md（编辑入口）
//
// 表单页口径：UtenContentContainer.narrow（保留兼容入口，正文随可用宽度铺满）；
// 结构：驳回横幅（编辑模式）→ 表头卡（标题/事由）→ 明细区（弹窗添加/点击改）→
// 合计卡（小写 + 人民币大写，银发〔1997〕393 号）→ 发票提示卡；
// 右下悬浮组：新建=[存草稿/提交]、编辑=[保存]；纯网络段挂 UtenBusyOverlay。
// 编辑 REJECTED 保存后仍在 REJECTED，重提在详情页（清驳回痕迹并重新通知审批人）。

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/rmb_amount.dart';
import '../models/expense_claim.dart';
import '../models/expense_item.dart';
import '../providers/expense_providers.dart';
import 'expense_item_dialog.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/platform_tables/platform_table_binding.dart';
import '../../../shared/platform_tables/platform_row_draft.dart';
import '../widgets/expense_item_columns.dart';
import '../../../components/feedback/uten_context_menu.dart';

class ExpenseClaimEditPage extends ConsumerStatefulWidget {
  const ExpenseClaimEditPage({super.key, this.claimId});

  /// 空 = 新建；非空 = 编辑（DRAFT/REJECTED）。
  final String? claimId;

  @override
  ConsumerState<ExpenseClaimEditPage> createState() =>
      _ExpenseClaimEditPageState();
}

class _ExpenseClaimEditPageState extends ConsumerState<ExpenseClaimEditPage>
    with FormDraftMixin<ExpenseClaimEditPage> {
  final _titleController = TextEditingController();
  final _remarkController = TextEditingController();
  final List<ExpenseItem> _items = [];
  final _platformDrafts = <String, PlatformRowDraft>{};
  final _persistedItemIds = <String>{};
  PlatformRowDraft _fields(ExpenseItem item) => _platformDrafts.putIfAbsent(
    item.id,
    () => PlatformRowDraft()
      ..sourceRecordId = _persistedItemIds.contains(item.id) ? item.id : null,
  );
  bool _busy = false;
  bool _initialized = false;
  int? _editVersion;
  Map<String, dynamic>? _pendingItemDraft;

  AppLocalizations get l10n => AppLocalizations.of(context);

  bool get _isEdit => widget.claimId != null;

  @override
  bool get formDraftEnabled => !_isEdit;
  @override
  bool get formDraftBusy => _busy;
  @override
  FormDraftSpec get formDraftSpec =>
      FormDraftCatalog.expense.spec(title: '新建报销', route: '/expense/new');
  @override
  Iterable<Listenable> get formDraftListenables => [
    _titleController,
    _remarkController,
    ..._platformDrafts.values,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'title': _titleController.text,
    'remark': _remarkController.text,
    'items': [
      for (final item in _items)
        {
          ...item.toCreateJson(),
          'id': item.id,
          'platformFieldDraft': _fields(item).exportDraft(),
        },
    ],
    'pendingItem': _pendingItemDraft,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    _titleController.text = draftText(data, 'title');
    _remarkController.text = draftText(data, 'remark');
    _items.clear();
    final localIds = <String>{};
    for (final raw in draftMaps(data['items'])) {
      final originalId = raw['id']?.toString().trim() ?? '';
      final reusedIdentity =
          originalId.isEmpty || localIds.contains(originalId);
      final id = reusedIdentity ? const Uuid().v4() : originalId;
      localIds.add(id);
      final item = ExpenseItem.fromJson({...raw, 'id': id});
      _items.add(item);
      final fields = _fields(item)..restoreDraft(raw['platformFieldDraft']);
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
    _pendingItemDraft = data['pendingItem'] == null
        ? null
        : draftMap(data['pendingItem']);
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => initializeFormDraft());
  }

  @override
  void dispose() {
    for (final draft in _platformDrafts.values) {
      draft.dispose();
    }
    _titleController.dispose();
    _remarkController.dispose();
    super.dispose();
  }

  double get _total =>
      _items.fold<int>(0, (s, i) => s + (i.amount * 100).round()) / 100;

  /// 编辑模式：草稿就绪即预填一次（明细拷贝成可变副本，避免动到 provider 缓存）。
  void _prefillOnce(ExpenseClaim? claim) {
    if (_initialized || _isEdit == false || claim == null) return;
    if (claim.id != widget.claimId) return;
    _initialized = true;
    _editVersion = claim.version;
    _titleController.text = claim.title;
    _remarkController.text = claim.remark ?? '';
    _items
      ..clear()
      ..addAll(claim.items);
    _persistedItemIds.addAll(claim.items.map((item) => item.id));
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
        final index = _items.indexOf(existing);
        if (index >= 0) _items[index] = item;
      } else {
        _items.add(item);
      }
    });
  }

  Future<void> _save() async {
    if (_busy) return;
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
    final remark = _remarkController.text.trim();

    setState(() => _busy = true);
    try {
      if (_isEdit) {
        await updateExpense(
          ref,
          widget.claimId!,
          expectedVersion: _editVersion!,
          title: title,
          items: [
            for (final item in _items)
              item.withPlatformFields(_fields(item).savePayload()),
          ],
          remark: remark.isEmpty ? null : remark,
        );
        if (mounted) {
          context.appSuccess(l10n.expenseFlowSaved);
          // replace 落详情（2026-09-24）：从「列表→详情→编辑」push 进来时，
          // go 会整替导航栈，详情返回键落 default 而不是报销列表；replace 只换
          // 栈顶编辑页，返回链保持「详情→列表」。
          context.replace(RoutePath.expenseDetail(widget.claimId!));
        }
        return;
      }
      final claim = await runFormDraftSubmission(
        () => createExpense(
          ref,
          title: title,
          items: [
            for (final item in _items)
              item.withPlatformFields(_fields(item).savePayload()),
          ],
          remark: remark.isEmpty ? null : remark,
        ),
      );
      await completeFormDraft();
      if (mounted) {
        context.appSuccess(l10n.expenseFlowDraftSaved);
        context.replace(RoutePath.expenseDetail(claim.id));
      }
    } catch (error) {
      if (mounted) context.appApiError(error);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _isEdit
        ? ref.watch(expenseDetailProvider(widget.claimId!))
        : null;
    _prefillOnce(detail?.valueOrNull);
    final me = ref.watch(sessionProvider).user;
    final permissions = ref.watch(currentPermissionsProvider);
    final claim = detail?.valueOrNull;
    final canEdit =
        !_isEdit ||
        (claim != null &&
            claim.applicantId == me?.employeeId &&
            (claim.status == ExpenseClaimStatus.draft ||
                claim.status == ExpenseClaimStatus.rejected));
    final canSave =
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

          // 2026-09-24 简洁口径：撤掉顶部流程教学文案，只留申请人/部门/日期事实行。
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Wrap(
                spacing: UtenSpacing.s24,
                runSpacing: UtenSpacing.s8,
                children: [
                  Text(
                    '${l10n.expenseFlowApplicant}: ${claim?.applicantName ?? (me == null ? '—' : '${me.name}(${me.code})')}',
                  ),
                  Text(
                    '${l10n.expenseFlowDepartment}: ${claim?.departmentName ?? me?.department ?? '—'}',
                  ),
                  Text(
                    '${l10n.expenseFlowDate}: ${_fmtDate(claim?.createdAt ?? ChinaDateTime.today())}',
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          // 表头卡：标题 + 事由
          _headerCard(theme),
          const SizedBox(height: UtenSpacing.s16),

          // 明细
          _itemsSection(theme, columnEditingEnabled: canSave && !_busy),
          const SizedBox(height: UtenSpacing.s16),

          // 合计：小写 + 大写
          _totalCard(theme),
        ],
      ),
    );

    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: _isEdit ? l10n.expenseFlowEdit : l10n.expenseFlowNew,
          showBackButton: true,
        ),
        body: !canEdit && detail?.hasValue == true
            ? UtenEmpty(message: l10n.expenseFlowNotEditable)
            : AbsorbPointer(
                absorbing: _busy || (_isEdit && claim == null),
                child: body,
              ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: UtenFloatingActionGroup(
          children: [
            if (canSave)
              UtenButton(
                size: UtenButtonSize.large,
                isLoading: _busy,
                icon: Icons.save_outlined,
                onPressed: _busy || _items.isEmpty ? null : _save,
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
                Text(
                  '${l10n.expenseFlowRejectedGuide} ${claim.rejectedByName ?? ''}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: UtenColors.error,
                  ),
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

  Widget _headerCard(ThemeData theme) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
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
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _remarkController,
              maxLines: 3,
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
      ),
    );
  }

  Widget _itemsSection(ThemeData theme, {required bool columnEditingEnabled}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.expenseFlowItems,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            UtenButton(
              type: UtenButtonType.tonal,
              size: UtenButtonSize.small,
              icon: Icons.add_rounded,
              onPressed: () => _addItem(),
              child: Text(
                _pendingItemDraft == null ? l10n.expenseFlowAdd : '继续未完成明细',
              ),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        MasterDataTableView<ExpenseItem>(
          columnEditingEnabled: columnEditingEnabled,
          tableKey: 'expense.claim.items',
          platformBinding: PlatformTableBinding<ExpenseItem>(
            tableKey: 'expense.claim.items',
            scope: 'expense_claim_item',
            recordIdOf: (item) => _fields(item).sourceRecordId,
            canEditValues: true,
            draftOf: _fields,
          ),
          columns: expenseItemColumns,
          items: _items,
          facets: const {},
          nullCounts: const {},
          filters: const {},
          onFilterChanged: (_, _) {},
          onRowTap: (item) => _addItem(existing: item),
          embedded: true,
          rowMenuBuilder: (item) => [
            UtenMenuItem(
              label: l10n.expenseFlowDeleteItem,
              icon: Icons.delete_outline,
              destructive: true,
              onTap: () => setState(() => _items.remove(item)),
            ),
          ],
        ),
      ],
    );
  }

  /// 合计卡：小写（tabular）+ 人民币大写（打印报销单同款口径）。
  Widget _totalCard(ThemeData theme) {
    final capital = rmbCapital(_total);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
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
                  '¥ ${_total.toStringAsFixed(2)}',
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
        ),
      ),
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
