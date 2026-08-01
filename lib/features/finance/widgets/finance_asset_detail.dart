import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/inputs/uten_date_field.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_employee_picker.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/network/latest_request_guard.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../department/widgets/uten_department_picker.dart';
import '../../employee/repositories/employee_repository.dart';
import '../models/finance_asset_models.dart';
import '../repositories/finance_asset_workbench_repository.dart';
import 'finance_asset_ui.dart';

Future<bool> showFinanceAssetDetail(
  BuildContext context, {
  required FinanceAssetLedger ledger,
  required String id,
  required FinanceAssetCapabilities capabilities,
  VoidCallback? onEdit,
  VoidCallback? onDelete,
}) async {
  final compact =
      MediaQuery.sizeOf(context).width < UtenBreakpoints.mediumStart;
  final content = FinanceAssetDetailSurface(
    ledger: ledger,
    id: id,
    capabilities: capabilities,
    onEdit: onEdit,
    onDelete: onDelete,
  );
  if (compact) {
    return await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(
              top: Radius.circular(UtenRadius.xxl),
            ),
          ),
          builder: (_) =>
              FractionallySizedBox(heightFactor: 0.96, child: content),
        ) ??
        false;
  }
  return await showDialog<bool>(
        context: context,
        builder: (_) => Dialog(
          clipBehavior: Clip.antiAlias,
          shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
          child: SizedBox(
            width: 1040,
            height: MediaQuery.sizeOf(context).height * 0.9,
            child: content,
          ),
        ),
      ) ??
      false;
}

class FinanceAssetDetailSurface extends ConsumerStatefulWidget {
  const FinanceAssetDetailSurface({
    super.key,
    required this.ledger,
    required this.id,
    required this.capabilities,
    this.onEdit,
    this.onDelete,
    this.showClose = true,
  });

  final FinanceAssetLedger ledger;
  final String id;
  final FinanceAssetCapabilities capabilities;
  final VoidCallback? onEdit;
  final VoidCallback? onDelete;
  final bool showClose;

  @override
  ConsumerState<FinanceAssetDetailSurface> createState() =>
      _FinanceAssetDetailSurfaceState();
}

class _FinanceAssetDetailSurfaceState
    extends ConsumerState<FinanceAssetDetailSurface> {
  final _requestGuard = LatestRequestGuard();
  FinanceAssetDetail? _detail;
  bool _loading = true;
  String? _error;
  bool _changed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = _requestGuard.begin();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .detail(widget.ledger, widget.id);
      if (!mounted || !_requestGuard.isCurrent(generation)) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || !_requestGuard.isCurrent(generation)) return;
      setState(() {
        _loading = false;
        _error = '详情加载失败，请检查网络后重试';
      });
    }
  }

  bool _permitted(String action) {
    final normalized = action.toUpperCase().replaceAll('-', '_');
    final allowed = _detail?.summary.allowedActions ?? const <String>{};
    final serverAllowed =
        allowed.contains(normalized) ||
        allowed.contains(normalized.replaceAll('_', '-'));
    if (!serverAllowed) return false;
    return switch (normalized) {
      'APPROVE' || 'REJECT' => widget.capabilities.canApprove,
      'ACTIVATE' => widget.capabilities.canPost,
      'DISPOSE' ||
      'TERMINATE' ||
      'APPROVE_DISPOSAL' ||
      'APPROVE_TERMINATION' ||
      'REJECT_DISPOSAL' ||
      'REJECT_TERMINATION' => widget.capabilities.canDispose,
      _ => widget.capabilities.canEdit,
    };
  }

  Future<void> _runAction(String action) async {
    final detail = _detail;
    if (detail == null) return;
    FinanceAssetWorkflowRequest? request;
    final normalized = action.toUpperCase().replaceAll('-', '_');
    if (const {
      'REJECT',
      'TRANSFER',
      'OPERATING_STATUS',
      'DISPOSE',
      'TERMINATE',
      'APPROVE_DISPOSAL',
      'APPROVE_TERMINATION',
      'REJECT_DISPOSAL',
      'REJECT_TERMINATION',
    }.contains(normalized)) {
      request = await showFinanceAssetActionInput(
        context,
        action: normalized,
        ledger: widget.ledger,
        expectedVersion: detail.summary.version,
      );
      if (request == null) return;
    } else {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('${_actionLabel(normalized)}确认'),
          content: Text(
            '确认对 ${detail.summary.code} ${detail.summary.name} 执行“${_actionLabel(normalized)}”？',
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            UtenButton(
              type: UtenButtonType.ghost,
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('取消'),
            ),
            UtenButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('确认'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
      request = FinanceAssetWorkflowRequest(
        expectedVersion: detail.summary.version,
      );
    }
    try {
      final apiAction = normalized.toLowerCase().replaceAll('_', '-');
      await ref
          .read(financeAssetWorkbenchRepositoryProvider)
          .assetAction(widget.ledger, widget.id, apiAction, request);
      if (!mounted) return;
      context.appSuccess('${_actionLabel(normalized)}成功');
      _changed = true;
      await _load();
    } catch (error) {
      if (mounted) {
        context.appApiError(
          error,
          fallback: '${_actionLabel(normalized)}失败，请刷新后重试',
        );
      }
    }
  }

  Future<void> _copyVoucher(String voucherNo) async {
    await Clipboard.setData(ClipboardData(text: voucherNo));
    if (mounted) context.appSuccess('凭证号已复制');
  }

  void _close() => Navigator.of(context).pop(_changed);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          _header(theme),
          const Divider(height: 1),
          Expanded(child: _content(theme)),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme) {
    final summary = _detail?.summary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s20,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: UtenRadius.lgAll,
            ),
            child: Icon(
              widget.ledger == FinanceAssetLedger.fixedAsset
                  ? Icons.apartment_outlined
                  : Icons.calendar_month_outlined,
              color: theme.colorScheme.onPrimaryContainer,
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  summary?.name ?? '${widget.ledger.label}详情',
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (summary != null)
                  Wrap(
                    spacing: UtenSpacing.s8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        summary.code,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                      financeAssetStatusBadge(summary.status),
                    ],
                  ),
              ],
            ),
          ),
          if (summary != null &&
              widget.capabilities.canEdit &&
              widget.onEdit != null &&
              summary.status.toUpperCase() == 'DRAFT')
            UtenButton(
              type: UtenButtonType.secondary,
              icon: Icons.edit_outlined,
              onPressed: widget.onEdit,
              child: const Text('编辑'),
            ),
          if (summary != null &&
              widget.capabilities.canEdit &&
              widget.onDelete != null &&
              summary.status.toUpperCase() == 'DRAFT')
            IconButton(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              tooltip: '删除草稿',
              color: theme.colorScheme.error,
              onPressed: widget.onDelete,
              icon: const Icon(Icons.delete_outline_rounded),
            ),
          if (widget.showClose)
            IconButton(
              constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
              tooltip: '关闭',
              onPressed: _close,
              icon: const Icon(Icons.close_rounded),
            ),
        ],
      ),
    );
  }

  Widget _content(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off_outlined,
              size: 40,
              color: theme.colorScheme.error,
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(_error!),
            const SizedBox(height: UtenSpacing.s12),
            UtenButton(
              key: const Key('finance-asset-detail-retry'),
              type: UtenButtonType.secondary,
              onPressed: _load,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }
    final detail = _detail!;
    return SingleChildScrollView(
      padding: EdgeInsets.all(
        context.breakpoint.isCompact ? UtenSpacing.s16 : UtenSpacing.s24,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _actionBar(detail),
          if (detail.summary.allowedActions.isNotEmpty)
            const SizedBox(height: UtenSpacing.s20),
          _section(
            theme,
            '概要',
            Icons.info_outline_rounded,
            _summaryGrid(detail.summary),
          ),
          const SizedBox(height: UtenSpacing.s20),
          _section(
            theme,
            '账簿与计划',
            Icons.menu_book_outlined,
            _booksAndSchedule(theme, detail),
          ),
          const SizedBox(height: UtenSpacing.s20),
          _section(
            theme,
            '审批轨迹',
            Icons.fact_check_outlined,
            _approvalTrail(theme, detail.approvalSteps),
          ),
          const SizedBox(height: UtenSpacing.s20),
          _section(
            theme,
            '事件时间线',
            Icons.timeline_outlined,
            _eventTimeline(theme, detail.events),
          ),
          const SizedBox(height: UtenSpacing.s20),
          _section(
            theme,
            '凭证与文档引用',
            Icons.description_outlined,
            _references(theme, detail),
          ),
        ],
      ),
    );
  }

  Widget _actionBar(FinanceAssetDetail detail) {
    const ordered = [
      'SUBMIT',
      'APPROVE',
      'REJECT',
      'ACTIVATE',
      'TRANSFER',
      'OPERATING_STATUS',
      'DISPOSE',
      'TERMINATE',
      'APPROVE_DISPOSAL',
      'APPROVE_TERMINATION',
      'REJECT_DISPOSAL',
      'REJECT_TERMINATION',
    ];
    final actions = ordered.where(_permitted).toList(growable: false);
    if (actions.isEmpty) return const SizedBox.shrink();
    return Semantics(
      label: '可执行资产流程动作',
      child: Wrap(
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s8,
        children: [
          for (final action in actions)
            UtenActionButton(
              key: Key('finance-asset-action-${action.toLowerCase()}'),
              type:
                  const {
                    'REJECT',
                    'DISPOSE',
                    'TERMINATE',
                    'REJECT_DISPOSAL',
                    'REJECT_TERMINATION',
                  }.contains(action)
                  ? UtenActionButtonType.danger
                  : action == 'APPROVE' || action == 'ACTIVATE'
                  ? UtenActionButtonType.primary
                  : UtenActionButtonType.secondary,
              onAction: () => _runAction(action),
              label: Text(_actionLabel(action)),
            ),
        ],
      ),
    );
  }

  Widget _section(ThemeData theme, String title, IconData icon, Widget child) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: UtenRadius.xlAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          child,
        ],
      ),
    );
  }

  Widget _summaryGrid(FinanceAssetSummary item) {
    return UtenFormGrid(
      children: [
        _info('分类', item.categoryName ?? item.categoryId ?? '—'),
        _info('归属部门', item.departmentName ?? item.departmentId ?? '—'),
        _info(
          widget.ledger.amountLabel,
          '¥ ${formatFinanceDecimal(widget.ledger == FinanceAssetLedger.fixedAsset ? item.originalValue : item.totalAmount)}',
          money: true,
        ),
        _info(
          widget.ledger == FinanceAssetLedger.fixedAsset ? '账面净值' : '待摊余额',
          '¥ ${formatFinanceDecimal(item.displayedBalance)}',
          money: true,
        ),
        _info('政策月份', item.usefulMonths?.toString() ?? '—'),
        _info('开始期间', item.startPeriod ?? '—'),
        _info(
          widget.ledger == FinanceAssetLedger.fixedAsset
              ? '达到预定可使用日期'
              : '受益开始日期',
          widget.ledger == FinanceAssetLedger.fixedAsset
              ? item.readyForUseDate ?? '—'
              : item.benefitStartDate ?? '—',
        ),
        _info('地点', item.location ?? '—'),
        _info('保管人', item.custodianName ?? item.custodianId ?? '—'),
        _info(
          '来源',
          [item.sourceType, item.sourceRef]
                  .whereType<String>()
                  .where((value) => value.isNotEmpty)
                  .join(' / ')
                  .isEmpty
              ? '—'
              : [item.sourceType, item.sourceRef]
                    .whereType<String>()
                    .where((value) => value.isNotEmpty)
                    .join(' / '),
        ),
        _info('备注', item.remark ?? '—'),
      ],
    );
  }

  Widget _info(String label, String value, {bool money = false}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: money
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        SelectableText(
          value,
          textAlign: money ? TextAlign.right : TextAlign.left,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            fontFeatures: money ? const [FontFeature.tabularFigures()] : null,
          ),
        ),
      ],
    );
  }

  Widget _booksAndSchedule(ThemeData theme, FinanceAssetDetail detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detail.books.isEmpty)
          const Text('暂无账簿快照')
        else
          Wrap(
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s12,
            children: [
              for (final book in detail.books)
                Container(
                  width: context.breakpoint.isCompact ? double.infinity : 280,
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerLow,
                    borderRadius: UtenRadius.lgAll,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        book.bookType,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s8),
                      _amountRow('原值/总额', book.originalValue),
                      _amountRow('累计计提', book.accumulatedAmount),
                      _amountRow('净值/余额', book.netValue),
                      if (book.monthlyAmount != null)
                        _amountRow('月计提', book.monthlyAmount!),
                    ],
                  ),
                ),
            ],
          ),
        if (detail.schedule.isNotEmpty) ...[
          const SizedBox(height: UtenSpacing.s16),
          Text(
            '计提计划',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              columns: const [
                DataColumn(label: Text('期间')),
                DataColumn(label: Text('期初'), numeric: true),
                DataColumn(label: Text('本期计提'), numeric: true),
                DataColumn(label: Text('累计'), numeric: true),
                DataColumn(label: Text('期末'), numeric: true),
                DataColumn(label: Text('状态')),
              ],
              rows: [
                for (final line in detail.schedule)
                  DataRow(
                    cells: [
                      DataCell(Text(line.period)),
                      DataCell(Text(formatFinanceDecimal(line.openingBalance))),
                      DataCell(Text(formatFinanceDecimal(line.amount))),
                      DataCell(
                        Text(formatFinanceDecimal(line.accumulatedAmount)),
                      ),
                      DataCell(Text(formatFinanceDecimal(line.closingBalance))),
                      DataCell(financeAssetStatusBadge(line.status)),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _amountRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
      child: Row(
        children: [
          Expanded(child: Text(label)),
          Text(
            formatFinanceDecimal(value),
            style: const TextStyle(
              fontFeatures: [FontFeature.tabularFigures()],
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _approvalTrail(ThemeData theme, List<FinanceAssetTrailStep> steps) {
    if (steps.isEmpty) return const Text('暂无审批记录');
    return Column(
      children: [
        for (final step in steps)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(
              Icons.check_circle_outline_rounded,
              color:
                  financeAssetStatusType(step.status) ==
                      UtenStatusBadgeType.danger
                  ? theme.colorScheme.error
                  : theme.colorScheme.primary,
            ),
            title: Text(step.action),
            subtitle: Text(
              [step.actorName, step.at, step.comment]
                  .whereType<String>()
                  .where((value) => value.isNotEmpty)
                  .join(' · '),
            ),
            trailing: financeAssetStatusBadge(step.status),
          ),
      ],
    );
  }

  Widget _eventTimeline(ThemeData theme, List<FinanceAssetEvent> events) {
    if (events.isEmpty) return const Text('暂无资产事件');
    return Column(
      children: [
        for (final event in events)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
            ),
            title: Text(event.title),
            subtitle: Text(
              [event.operatorName, event.at, event.description]
                  .whereType<String>()
                  .where((value) => value.isNotEmpty)
                  .join(' · '),
            ),
          ),
      ],
    );
  }

  Widget _references(ThemeData theme, FinanceAssetDetail detail) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (detail.voucherNumbers.isEmpty)
          const Text('尚未关联总账凭证')
        else ...[
          Text(
            '总账凭证号',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          for (final voucher in detail.voucherNumbers)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: SelectableText(voucher),
              subtitle: const Text('当前总账未提供凭证详情路由，可复制凭证号查询'),
              trailing: IconButton(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                tooltip: '复制凭证号',
                onPressed: () => _copyVoucher(voucher),
                icon: const Icon(Icons.copy_rounded),
              ),
            ),
        ],
        const SizedBox(height: UtenSpacing.s12),
        Text(
          '文档引用',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        if (detail.documentReferences.isEmpty)
          const Text('暂无文档引用；附件服务未启用，本页不提供上传入口。')
        else
          for (final reference in detail.documentReferences)
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.description_outlined),
              title: SelectableText(reference),
            ),
      ],
    );
  }
}

String _actionLabel(String action) {
  return switch (action.toUpperCase().replaceAll('-', '_')) {
    'SUBMIT' => '提交审批',
    'APPROVE' => '审批通过',
    'REJECT' => '驳回',
    'ACTIVATE' => '确认启用',
    'TRANSFER' => '调拨',
    'OPERATING_STATUS' => '变更使用状态',
    'DISPOSE' => '处置',
    'TERMINATE' => '终止待摊',
    'APPROVE_DISPOSAL' => '批准处置',
    'APPROVE_TERMINATION' => '批准终止',
    'REJECT_DISPOSAL' => '驳回处置',
    'REJECT_TERMINATION' => '驳回终止',
    final value => value,
  };
}

Future<FinanceAssetWorkflowRequest?> showFinanceAssetActionInput(
  BuildContext context, {
  required String action,
  required FinanceAssetLedger ledger,
  required int? expectedVersion,
}) async {
  final compact =
      MediaQuery.sizeOf(context).width < UtenBreakpoints.mediumStart;
  final content = _FinanceAssetActionInput(
    action: action,
    ledger: ledger,
    expectedVersion: expectedVersion,
  );
  if (compact) {
    return showModalBottomSheet<FinanceAssetWorkflowRequest>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: content,
      ),
    );
  }
  return showDialog<FinanceAssetWorkflowRequest>(
    context: context,
    builder: (_) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 680, maxHeight: 720),
        child: content,
      ),
    ),
  );
}

class _FinanceAssetActionInput extends ConsumerStatefulWidget {
  const _FinanceAssetActionInput({
    required this.action,
    required this.ledger,
    required this.expectedVersion,
  });
  final String action;
  final FinanceAssetLedger ledger;
  final int? expectedVersion;

  @override
  ConsumerState<_FinanceAssetActionInput> createState() =>
      _FinanceAssetActionInputState();
}

class _FinanceAssetActionInputState
    extends ConsumerState<_FinanceAssetActionInput> {
  final _formKey = GlobalKey<FormState>();
  final _reason = TextEditingController();
  final _location = TextEditingController();
  final _proceedsAmount = TextEditingController(text: '0.00');
  final _evidenceReference = TextEditingController();
  DeptSelection? _department;
  UtenEmployeePickerItem? _custodian;
  DateTime? _effectiveDate;
  String? _operatingStatus;
  String? _selectionError;

  @override
  void dispose() {
    _reason.dispose();
    _location.dispose();
    _proceedsAmount.dispose();
    _evidenceReference.dispose();
    super.dispose();
  }

  String? _iso(DateTime? value) {
    if (value == null) return null;
    return '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}';
  }

  Future<List<UtenEmployeePickerItem>> _loadEmployees(String? keyword) async {
    final result = await ref
        .read(employeeRepositoryProvider)
        .list(
          size: 30,
          search: keyword,
          departmentId: _department?.id,
          includeSubtree: true,
        );
    return [
      for (final employee in result.items)
        UtenEmployeePickerItem(
          id: employee.id,
          name: employee.fullName,
          departmentName: employee.departmentName,
        ),
    ];
  }

  void _submit() {
    final transfer = widget.action == 'TRANSFER';
    final operating = widget.action == 'OPERATING_STATUS';
    final needsDate =
        transfer ||
        operating ||
        widget.action == 'DISPOSE' ||
        widget.action == 'TERMINATE';
    final selectionsValid =
        (!transfer || _department != null) &&
        (!operating || _operatingStatus != null) &&
        (!needsDate || _effectiveDate != null);
    setState(() {
      _selectionError = selectionsValid ? null : '请补齐部门、使用状态或生效日期';
    });
    if (!(_formKey.currentState?.validate() ?? false) || !selectionsValid) {
      return;
    }
    Navigator.of(context).pop(
      FinanceAssetWorkflowRequest(
        reason: _reason.text,
        expectedVersion: widget.expectedVersion,
        targetDepartmentId: _department?.id,
        location: _location.text,
        custodianId: _custodian?.id,
        effectiveDate: _iso(_effectiveDate),
        operatingStatus: _operatingStatus,
        proceedsAmount: _proceedsAmount.text,
        evidenceReference: _evidenceReference.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final transfer = widget.action == 'TRANSFER';
    final operating = widget.action == 'OPERATING_STATUS';
    final disposal = widget.action == 'DISPOSE';
    final needsDate =
        transfer || operating || disposal || widget.action == 'TERMINATE';
    return Material(
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s20),
        child: Form(
          key: _formKey,
          autovalidateMode: AutovalidateMode.onUserInteraction,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        _actionLabel(widget.action),
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      constraints: const BoxConstraints(
                        minWidth: 48,
                        minHeight: 48,
                      ),
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close_rounded),
                      tooltip: '关闭',
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s16),
                UtenFormGrid(
                  children: [
                    if (transfer)
                      UtenDepartmentPicker(
                        key: ValueKey(
                          'asset-transfer-department-${_department?.id}',
                        ),
                        mode: UtenDepartmentPickerMode.single,
                        label: '转入部门 *',
                        hint: '请选择转入部门',
                        initialSelection: _department == null
                            ? const []
                            : [_department!],
                        validator: (selection) =>
                            selection.isEmpty ? '请选择转入部门' : null,
                        onChanged: (selection) => setState(() {
                          _department = selection.firstOrNull;
                          _custodian = null;
                          _selectionError = null;
                        }),
                      ),
                    if (transfer)
                      UtenInput(label: '新地点', controller: _location),
                    if (transfer)
                      UtenEmployeePicker(
                        key: ValueKey(
                          'asset-transfer-employee-${_department?.id}',
                        ),
                        label: widget.ledger == FinanceAssetLedger.fixedAsset
                            ? '新保管人'
                            : '新责任人',
                        hint: '请选择人员',
                        sheetTitle: '选择接收人员',
                        allowClear: true,
                        initial: _custodian,
                        departmentName: _department?.fullPath,
                        loader: _loadEmployees,
                        onChanged: (value) => setState(() {
                          _custodian = value;
                        }),
                      ),
                    if (operating)
                      UtenDropdownField(
                        key: ValueKey(
                          'asset-operating-status-$_operatingStatus',
                        ),
                        label: '目标使用状态',
                        required: true,
                        value: _operatingStatus,
                        hintText: '请选择目标使用状态',
                        items: const [
                          UtenDropdownItem(
                            value: 'PENDING_ACCEPTANCE',
                            label: '待验收',
                          ),
                          UtenDropdownItem(value: 'IN_USE', label: '在用'),
                          UtenDropdownItem(value: 'IDLE', label: '闲置'),
                          UtenDropdownItem(value: 'UNDER_REPAIR', label: '维修中'),
                          UtenDropdownItem(value: 'LOANED', label: '借出'),
                          UtenDropdownItem(
                            value: 'LOST_PENDING',
                            label: '盘亏待处理',
                          ),
                        ],
                        onChanged: (value) => setState(() {
                          _operatingStatus = value;
                          _selectionError = null;
                        }),
                      ),
                    if (needsDate)
                      UtenDateField(
                        label: '生效日期',
                        required: true,
                        value: _effectiveDate,
                        errorText:
                            _selectionError != null && _effectiveDate == null
                            ? '请选择生效日期'
                            : null,
                        onChanged: (value) => setState(() {
                          _effectiveDate = value;
                          _selectionError = null;
                        }),
                      ),
                    if (disposal)
                      UtenInput(
                        label: '处置收入 *',
                        hint: '没有收入请输入 0.00',
                        controller: _proceedsAmount,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        validator: (value) => validateNonNegativeFinanceAmount(
                          value,
                          label: '处置收入',
                        ),
                      ),
                    if (disposal || widget.action == 'TERMINATE')
                      UtenInput(
                        label: '依据引用',
                        hint: '处置单、会议决议或合同引用',
                        controller: _evidenceReference,
                      ),
                  ],
                ),
                if (_selectionError != null) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    _selectionError!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                const SizedBox(height: UtenSpacing.s12),
                UtenInput(
                  label: '原因 *',
                  controller: _reason,
                  maxLines: 3,
                  validator: (value) => validateRequired(value, '原因'),
                ),
                const SizedBox(height: UtenSpacing.s20),
                Align(
                  alignment: Alignment.centerRight,
                  child: UtenButton(
                    type:
                        const {
                          'REJECT',
                          'DISPOSE',
                          'TERMINATE',
                          'REJECT_DISPOSAL',
                          'REJECT_TERMINATION',
                        }.contains(widget.action)
                        ? UtenButtonType.danger
                        : UtenButtonType.primary,
                    onPressed: _submit,
                    child: Text('确认${_actionLabel(widget.action)}'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
