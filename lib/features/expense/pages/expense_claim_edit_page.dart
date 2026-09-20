// 新建/编辑报销页（V608 合并：claimId 为空 = 新建，非空 = 编辑 DRAFT/REJECTED）
// 文档：docs/03-页面/新建报销页.md · docs/03-页面/报销列表页.md（编辑入口）
//
// 表单页口径：UtenContentContainer.narrow（1120 钳制居中）；
// 结构：驳回横幅（编辑模式）→ 表头卡（标题/事由）→ 明细区（弹窗添加/点击改）→
// 合计卡（小写 + 人民币大写，银发〔1997〕393 号）→ 发票提示卡；
// 右下悬浮组：新建=[存草稿/提交]、编辑=[保存]；纯网络段挂 UtenBusyOverlay。
// 编辑 REJECTED 保存后仍在 REJECTED，重提在详情页（清驳回痕迹并重新通知审批人）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/auth/permissions.dart';
import '../providers/expense_settings_provider.dart';
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

class ExpenseClaimEditPage extends ConsumerStatefulWidget {
  const ExpenseClaimEditPage({super.key, this.claimId});

  /// 空 = 新建；非空 = 编辑（DRAFT/REJECTED）。
  final String? claimId;

  @override
  ConsumerState<ExpenseClaimEditPage> createState() =>
      _ExpenseClaimEditPageState();
}

class _ExpenseClaimEditPageState extends ConsumerState<ExpenseClaimEditPage> {
  final _titleController = TextEditingController();
  final _remarkController = TextEditingController();
  final List<ExpenseItem> _items = [];
  bool _busy = false;
  bool _initialized = false;
  int? _editVersion;

  AppLocalizations get l10n => AppLocalizations.of(context);

  bool get _isEdit => widget.claimId != null;

  @override
  void dispose() {
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
  }

  Future<void> _addItem({ExpenseItem? existing}) async {
    final item = await showDialog<ExpenseItem>(
      context: context,
      builder: (_) => ExpenseItemDialog(initial: existing),
    );
    if (item == null || !mounted) return;
    setState(() {
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
          items: List.from(_items),
          remark: remark.isEmpty ? null : remark,
        );
        if (mounted) {
          context.appSuccess(l10n.expenseFlowSaved);
          context.go(RoutePath.expenseDetail(widget.claimId!));
        }
        return;
      }
      final claim = await createExpense(
        ref,
        title: title,
        items: List.from(_items),
        remark: remark.isEmpty ? null : remark,
      );
      if (mounted) {
        context.appSuccess(l10n.expenseFlowDraftSaved);
        context.go(RoutePath.expenseDetail(claim.id));
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
    final settings = ref.watch(expenseSettingsProvider).valueOrNull;

    final body = UtenContentContainer.narrow(
      child: ListView(
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

          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.expenseFlowFlowGuide,
                    style: theme.textTheme.bodyMedium,
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  Wrap(
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
                  if (settings != null) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Text(
                      '${settings.companyName}${settings.companyTaxNo.isEmpty ? '' : ' · ${settings.companyTaxNo}'}',
                    ),
                    if (settings.submissionGuide.isNotEmpty)
                      Text(settings.submissionGuide),
                    Text(
                      settings.requireInvoice
                          ? l10n.expenseFlowInvoiceRequiredGuide
                          : l10n.expenseFlowNoInvoiceGuide,
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          // 表头卡：标题 + 事由
          _headerCard(theme),
          const SizedBox(height: UtenSpacing.s16),

          // 明细
          _itemsSection(theme),
          const SizedBox(height: UtenSpacing.s16),

          // 合计：小写 + 大写
          _totalCard(theme),
          const SizedBox(height: UtenSpacing.s16),

          _invoiceHintCard(theme),
        ],
      ),
    );

    return Scaffold(
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

  Widget _itemsSection(ThemeData theme) {
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
              child: Text(l10n.expenseFlowAdd),
            ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        if (_items.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: UtenRadius.lgAll,
              border: Border.all(color: theme.colorScheme.outlineVariant),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.add_circle_outline_rounded,
                  size: 32,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  l10n.expenseFlowEmptyItems,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          )
        else
          ..._items.map(
            (item) => Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              child: _itemCard(theme, item),
            ),
          ),
      ],
    );
  }

  /// 明细行卡：类别徽标 + 日期/说明 + 金额；点击改、右侧删除。
  Widget _itemCard(ThemeData theme, ExpenseItem item) {
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        borderRadius: UtenRadius.lgAll,
        onTap: () => _addItem(existing: item),
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: item.category.color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  item.category.icon,
                  color: item.category.color,
                  size: 18,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      item.category.label,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      '${_fmtDate(item.date)}'
                      '${item.description != null ? '  ·  ${item.description}' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        '¥ ${item.amount.toStringAsFixed(2)}',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              IconButton(
                tooltip: l10n.expenseFlowDeleteItem,
                icon: const Icon(Icons.close_rounded, size: 18),
                splashRadius: 16,
                onPressed: () => setState(() => _items.remove(item)),
              ),
            ],
          ),
        ),
      ),
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

  Widget _invoiceHintCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.receipt_outlined,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.expenseFlowInvoiceGuide,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _fmtDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
