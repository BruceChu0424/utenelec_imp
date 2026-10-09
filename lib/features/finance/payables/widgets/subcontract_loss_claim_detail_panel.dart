import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/data_display/uten_status_badge.dart';
import '../../../../components/data_display/uten_status_cell_color.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/layout/uten_floating_action_group.dart';
import '../../../basic_data/widgets/master_data_table_view.dart';
import '../../../../shared/platform_tables/platform_table_binding.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../../../../shared/auth/permissions.dart';
import '../../../../shared/attachments/business_attachment_section.dart';
import '../models/subcontract_loss_claim.dart';
import '../repositories/subcontract_loss_claim_repository.dart';
import 'subcontract_loss_claim_actions.dart';

class SubcontractLossClaimDetailPanel extends ConsumerStatefulWidget {
  const SubcontractLossClaimDetailPanel({
    super.key,
    required this.caseId,
    this.onChanged,
  });

  final String caseId;
  final VoidCallback? onChanged;

  @override
  ConsumerState<SubcontractLossClaimDetailPanel> createState() =>
      _SubcontractLossClaimDetailPanelState();
}

class _SubcontractLossClaimDetailPanelState
    extends ConsumerState<SubcontractLossClaimDetailPanel> {
  SubcontractLossClaimDetail? _detail;
  bool _loading = true;
  bool _writing = false;
  String? _error;

  Set<String> get _permissions => ref.read(currentPermissionsProvider);
  bool get _canReview => _permissions.contains(Perm.subcontractLossClaimReview);
  bool get _canFulfill =>
      _permissions.contains(Perm.subcontractLossClaimFulfill);
  bool get _canReverse =>
      _permissions.contains(Perm.subcontractLossClaimReverse);
  bool get _canReverseFulfillment => _canFulfill && _canReverse;
  bool get _canViewFinancialAmounts =>
      _permissions.contains(Perm.financeViewAll);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(subcontractLossClaimRepositoryProvider)
          .detail(widget.caseId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '加载责任单详情失败';
      });
    }
  }

  void _replace(SubcontractLossClaimDetail detail) {
    setState(() {
      _detail = detail;
      _writing = false;
    });
    widget.onChanged?.call();
  }

  Future<void> _decide() async {
    final current = _detail;
    if (current == null || _writing) return;
    final draft = await showSubcontractLossDecisionPanel(
      context: context,
      detail: current,
    );
    if (draft == null || !mounted) return;
    setState(() => _writing = true);
    try {
      final detail = await ref
          .read(subcontractLossClaimRepositoryProvider)
          .decide(
            current.summary.id,
            expectedVersion: current.summary.version,
            disputed: draft.disputed,
            reason: draft.reason,
            resolutions: draft.resolutions,
          );
      if (!mounted) return;
      _replace(detail);
      context.appSuccess(draft.disputed ? '已标记争议' : '责任决定已提交');
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError(error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError('提交责任决定失败，请稍后重试');
    }
  }

  Future<void> _fulfill(SubcontractLossResolution resolution) async {
    final current = _detail;
    if (current == null || _writing || resolution.usesDedicatedFinancialChain) {
      return;
    }
    final draft = await showSubcontractLossFulfillmentPanel(
      context: context,
      resolution: resolution,
      canViewFinancialAmounts: _canViewFinancialAmounts,
    );
    if (draft == null || !mounted) return;
    setState(() => _writing = true);
    try {
      final detail = await ref
          .read(subcontractLossClaimRepositoryProvider)
          .fulfill(
            current.summary.id,
            resolution.id,
            expectedCaseVersion: current.summary.version,
            fulfilledQuantity: draft.fulfilledQuantity,
            fulfilledAmountLocal: draft.fulfilledAmountLocal,
            evidenceReference: draft.evidenceReference,
            fulfillmentDocType: draft.fulfillmentDocType,
            fulfillmentDocId: draft.fulfillmentDocId,
            fulfillmentDocItemId: draft.fulfillmentDocItemId,
            fulfillmentDocNo: draft.fulfillmentDocNo,
            accountId: draft.accountId,
            cashReceiptDate: draft.cashReceiptDate,
            note: draft.note,
          );
      if (!mounted) return;
      _replace(detail);
      context.appSuccess('补偿履约已登记');
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError(error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError('登记履约失败，请稍后重试');
    }
  }

  Future<void> _reverseFulfillment(SubcontractLossResolution resolution) async {
    final current = _detail;
    if (current == null || _writing || !resolution.canReverseFulfillment) {
      return;
    }
    if (resolution.requiresPhysicalDocument) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('先红冲履约实物单'),
          content: Text(
            '服务端将核验 ${resolution.fulfillmentDocNo ?? resolution.fulfillmentDocId ?? '对应实物单'}'
            ' 已完成红冲。确认已先红冲，再继续反转履约。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('已红冲，继续'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    final reason = await showSubcontractLossReasonDialog(
      context: context,
      title: '反转补偿履约',
      label: '履约反转原因(必填)',
    );
    if (reason == null || !mounted) return;
    setState(() => _writing = true);
    try {
      final detail = await ref
          .read(subcontractLossClaimRepositoryProvider)
          .reverseFulfillment(
            current.summary.id,
            resolution.id,
            expectedCaseVersion: current.summary.version,
            reason: reason,
          );
      if (!mounted) return;
      _replace(detail);
      context.appSuccess('补偿履约已反转');
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError(error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError('履约反转失败，请稍后重试');
    }
  }

  Future<void> _reverse() async {
    final current = _detail;
    if (current == null || _writing) return;
    final reason = await showSubcontractLossReasonDialog(
      context: context,
      title: '反转超耗责任决定',
      label: '反转原因(必填)',
    );
    if (reason == null || !mounted) return;
    setState(() => _writing = true);
    try {
      final detail = await ref
          .read(subcontractLossClaimRepositoryProvider)
          .reverse(
            current.summary.id,
            expectedVersion: current.summary.version,
            reason: reason,
          );
      if (!mounted) return;
      _replace(detail);
      context.appSuccess('责任决定已反转');
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError(error.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _writing = false);
      context.appError('反转失败，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('委外超耗责任详情'),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          tooltip: '关闭',
          onPressed: _writing ? null : () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _loading || _writing ? null : _load,
          ),
        ],
      ),
      body: Stack(
        children: [
          _loading
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2.5))
              : _error != null
              ? _errorBody()
              : _detailBody(),
          // 履约登记/反转/责任判定提交期间的全屏居中遮罩（2026-09-25 统一
          // 口径：不再只有按钮内转圈）。
          if (_writing)
            const Positioned.fill(
              child: UtenBusyOverlay(title: '正在处理责任判定，请稍候'),
            ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: _detail == null ? null : _actions(),
    );
  }

  Widget _errorBody() => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(_error!),
        const SizedBox(height: UtenSpacing.s8),
        OutlinedButton.icon(
          onPressed: _load,
          icon: const Icon(Icons.refresh_rounded),
          label: const Text('重试'),
        ),
      ],
    ),
  );

  Widget _detailBody() {
    final detail = _detail!;
    final theme = Theme.of(context);
    final permissions = ref.watch(currentPermissionsProvider);
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        children: [
          _summaryCard(theme, detail.summary),
          const SizedBox(height: UtenSpacing.s12),
          _sectionTitle(theme, '超耗材料明细 (${detail.lines.length})'),
          _linesTable(detail.lines),
          const SizedBox(height: UtenSpacing.s12),
          _sectionTitle(theme, '责任方案 (${detail.resolutions.length})'),
          if (detail.resolutions.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: UtenSpacing.s8),
              child: Text('尚未形成责任处理方案'),
            )
          else
            for (final resolution in detail.resolutions)
              _resolutionCard(theme, detail, resolution),
          const SizedBox(height: UtenSpacing.s12),
          BusinessAttachmentSection(
            ownerType: 'SUBCONTRACT_LOSS_CASE',
            ownerId: detail.summary.id,
            title: '损耗和责任凭证',
            canView:
                !detail.summary.priceMasked &&
                permissions.contains(Perm.subcontractLossClaimView) &&
                permissions.contains(Perm.financeViewAll),
            canManage:
                permissions.contains(Perm.subcontractLossClaimReview) &&
                const {'OPEN', 'DISPUTED'}.contains(detail.summary.status),
            categories: const ['损耗说明', '责任确认', '图片', '其他'],
          ),
          const SizedBox(height: UtenSpacing.s12),
          _sectionTitle(theme, '处理事件 (${detail.events.length})'),
          if (detail.events.isEmpty)
            const Text('暂无事件')
          else
            for (final event in detail.events) _eventRow(theme, event),
        ],
      ),
    );
  }

  Widget _summaryCard(ThemeData theme, SubcontractLossClaimSummary summary) {
    final values = <(String, String?)>[
      ('损耗单号', summary.wasteBillNo),
      (
        '委外商',
        [
          summary.supplierCode,
          summary.supplierName,
        ].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
      ),
      ('责任状态', summary.statusLabel),
      ('实际损耗', summary.actualLossQty),
      ('允许损耗', summary.allowedLossQty),
      ('超耗数量', summary.excessLossQty),
      if (_canViewFinancialAmounts) ...[
        ('账面损失(本币)', summary.lossBookValueLocal),
        ('索赔额(本币)', summary.claimAmountLocal),
      ],
      ('版本', summary.version.toString()),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Wrap(
          spacing: UtenSpacing.s16,
          runSpacing: UtenSpacing.s8,
          children: [
            for (final (label, value) in values)
              SizedBox(
                width: 230,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    Text(
                      value?.isNotEmpty == true ? value! : '—',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _linesTable(List<SubcontractLossClaimLine> lines) =>
      MasterDataTableView<SubcontractLossClaimLine>(
        tableKey: 'finance.subcontractLoss.valuation',
        embedded: true,
        compactCards: true,
        platformBinding: PlatformTableBinding(
          tableKey: 'finance.subcontractLoss.valuation',
          scope: 'view_finance',
          recordIdOf: (_) => null,
          factValuesOf: (row) => {
            'actualLossQty': row.actualLossQty,
            'allowedLossQty': row.allowedLossQty,
            'excessLossQty': row.excessLossQty,
            if (_canViewFinancialAmounts)
              'unitBookValueLocal': row.unitBookValueLocal,
            if (_canViewFinancialAmounts)
              'lossBookValueLocal': row.lossBookValueLocal,
          },
        ),
        columns: [
          MasterColumnDef(
            key: 'valuationStatus',
            label: '估值状态',
            width: 72,
            value: (row) => _valuationStatusText(row.valuationStatus),
            cellBuilder: (_, row) => _ValuationStatusCell(row.valuationStatus),
          ),
          MasterColumnDef(
            key: 'goodsName',
            label: '材料名称',
            width: 180,
            value: (row) => row.goodsName,
            // 状态列前置后，卡片形态标题显式落在材料名称列。
            cardRole: MasterColumnCardRole.title,
          ),
          MasterColumnDef(
            key: 'goodsCode',
            label: '编号',
            width: 130,
            value: (row) => row.goodsCode,
          ),
          MasterColumnDef(
            key: 'colorName',
            label: '颜色',
            width: 90,
            value: (row) => row.colorName,
          ),
          MasterColumnDef(
            key: 'actualLossQty',
            label: '实际损耗',
            width: 120,
            type: 'number',
            value: (row) => row.actualLossQty,
          ),
          MasterColumnDef(
            key: 'allowedLossQty',
            label: '允许损耗',
            width: 120,
            type: 'number',
            value: (row) => row.allowedLossQty,
          ),
          MasterColumnDef(
            key: 'excessLossQty',
            label: '超耗',
            width: 110,
            type: 'number',
            value: (row) => row.excessLossQty,
          ),
          if (_canViewFinancialAmounts) ...[
            MasterColumnDef(
              key: 'unitBookValueLocal',
              label: '单位账面价值',
              width: 145,
              type: 'money',
              value: (row) => row.unitBookValueLocal,
            ),
            MasterColumnDef(
              key: 'lossBookValueLocal',
              label: '账面损失',
              width: 130,
              type: 'money',
              value: (row) => row.lossBookValueLocal,
            ),
          ],
        ],
        items: lines,
        facets: const {},
        nullCounts: const {},
        filters: const {},
        onFilterChanged: (_, _) {},
      );

  Widget _resolutionCard(
    ThemeData theme,
    SubcontractLossClaimDetail detail,
    SubcontractLossResolution resolution,
  ) {
    final line = detail.lines.where((item) => item.id == resolution.caseLineId);
    final goods = line.isEmpty ? '未知材料' : line.first.goodsLabel;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${resolution.typeLabel} · $goods',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(resolution.statusLabel),
              ],
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '数量 ${resolution.quantity ?? '—'}'
              '${_canViewFinancialAmounts ? ' · 金额 ¥${resolution.amountLocal ?? '0'}' : ''}'
              '${resolution.dueDate == null ? '' : ' · 到期 ${resolution.dueDate}'}',
            ),
            if (resolution.note?.isNotEmpty == true) Text(resolution.note!),
            if (resolution.evidenceReference?.isNotEmpty == true)
              Text('证据：${resolution.evidenceReference}'),
            if (resolution.fulfillmentDocId?.isNotEmpty == true)
              Text(
                '履约实物单：${resolution.fulfillmentDocType ?? ''} '
                '${resolution.fulfillmentDocNo ?? resolution.fulfillmentDocId}',
              ),
            if (resolution.isPending) ...[
              const SizedBox(height: UtenSpacing.s8),
              if (resolution.usesDedicatedFinancialChain)
                Text(
                  resolution.isCashCompensation
                      ? '等待专用资金到账，不可手工完成'
                      : '等待红字发票或供应商贷项凭证，不可手工完成',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                )
              else if (_canFulfill)
                Align(
                  alignment: Alignment.centerRight,
                  child: UtenButton(
                    type: UtenButtonType.tonal,
                    icon: Icons.verified_outlined,
                    onPressed: _writing ? null : () => _fulfill(resolution),
                    child: const Text('登记履约'),
                  ),
                ),
            ],
            if (resolution.canReverseFulfillment && _canReverseFulfillment) ...[
              const SizedBox(height: UtenSpacing.s8),
              Align(
                alignment: Alignment.centerRight,
                child: UtenButton(
                  type: UtenButtonType.danger,
                  icon: Icons.undo_outlined,
                  onPressed: _writing
                      ? null
                      : () => _reverseFulfillment(resolution),
                  child: const Text('反转履约'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _eventRow(ThemeData theme, SubcontractLossClaimEvent event) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.radio_button_checked,
            size: 14,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  event.type ?? '事件',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (event.reason?.isNotEmpty == true) Text(event.reason!),
                Text(
                  event.createdAt ?? '—',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
    child: Text(
      text,
      style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
    ),
  );

  Widget? _actions() {
    final detail = _detail!;
    final review = _canReview && detail.summary.canReview;
    final reverse = _canReverse && detail.summary.canReverse;
    if (!review && !reverse) return null;
    // 2026-09-14 UI 统一口径：吸底操作条改右下悬浮组，按钮统一 large。
    return UtenFloatingActionGroup(
      children: [
        if (reverse)
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.undo_outlined,
            onPressed: _writing ? null : _reverse,
            child: const Text('反转责任决定'),
          ),
        if (review)
          UtenButton(
            size: UtenButtonSize.large,
            icon: Icons.fact_check_outlined,
            onPressed: _writing ? null : _decide,
            child: const Text('责任决定'),
          ),
      ],
    );
  }
}

/// 估值状态格：服务端只出 VALUED / MISSING_COST 两档码（此前格内直显英文码）。
/// 2026-09-27 用户口径「格内胶囊改单元格背景色」：旧原生表无 cellColor 通道，
/// 用带 0.5 描边的实色块铺满格内容区（边框保留）；
/// ADR-169 档位：已估值=绿（估值数据就绪）/ 缺成本待估=橙（风险中间态：
/// 缺成本数据估不了、未死锁但需先补数，不是安静的等待外部）；
/// 未知码原样显示不铺色。
String _valuationStatusText(String? status) =>
    switch (status?.trim().toUpperCase()) {
      'VALUED' => '已估值',
      'MISSING_COST' => '缺成本待估',
      _ => status?.trim().isNotEmpty == true ? status!.trim() : '—',
    };

class _ValuationStatusCell extends StatelessWidget {
  const _ValuationStatusCell(this.status);

  final String? status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final code = status?.trim().toUpperCase();
    final type = switch (code) {
      'VALUED' => UtenStatusBadgeType.success,
      'MISSING_COST' => UtenStatusBadgeType.orange,
      _ => null,
    };
    if (type == null) {
      final text = status?.trim();
      return Text(text == null || text.isEmpty ? '—' : text);
    }
    final (bg, fg) = resolveStatusBadgeColors(type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: theme.colorScheme.outline, width: 0.5),
      ),
      child: Text(
        _valuationStatusText(status),
        style: theme.textTheme.bodySmall?.copyWith(
          color: fg,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
