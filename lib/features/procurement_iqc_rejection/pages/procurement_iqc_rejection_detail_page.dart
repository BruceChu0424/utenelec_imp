import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_split_view.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../models/procurement_iqc_rejection.dart';
import '../repositories/procurement_iqc_rejection_repository.dart';
import '../widgets/procurement_iqc_rejection_action_dialog.dart';
import '../widgets/procurement_iqc_actual_credit_dialog.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../widgets/procurement_iqc_rejection_status_badge.dart';

class ProcurementIqcRejectionDetailPage extends ConsumerStatefulWidget {
  const ProcurementIqcRejectionDetailPage({
    super.key,
    required this.id,
    this.source,
    this.repository,
  });

  final String id;
  final String? source;
  final ProcurementIqcRejectionGateway? repository;

  @override
  ConsumerState<ProcurementIqcRejectionDetailPage> createState() =>
      _ProcurementIqcRejectionDetailPageState();
}

class _ProcurementIqcRejectionDetailPageState
    extends ConsumerState<ProcurementIqcRejectionDetailPage> {
  ProcurementIqcRejectionDetail? _detail;
  bool _loading = true;
  String? _error;
  int _requestId = 0;

  ProcurementIqcRejectionGateway get _repository =>
      widget.repository ?? ref.read(procurementIqcRejectionRepositoryProvider);

  String get _defaultBackPath =>
      RoutePath.procurementIqcRejections(source: widget.source);

  @override
  void initState() {
    super.initState();
    Future<void>.microtask(_load);
  }

  Future<void> _load() async {
    final requestId = ++_requestId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final value = await _repository.detail(widget.id);
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _detail = value;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || requestId != _requestId) return;
      setState(() {
        _error = 'IQC 不合格任务详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  bool _has(String permission) =>
      ref.read(isSuperAdminProvider) ||
      ref.read(currentPermissionsProvider).contains(permission);

  Future<void> _openAction(ProcurementIqcRejectionActionKind kind) async {
    final detail = _detail;
    if (detail == null || _loading) return;
    final allowed = _actionSpecs(
      detail.caseItem,
    ).where((spec) => spec.kind == kind).firstOrNull;
    if (allowed == null || !allowed.enabled) {
      context.appInfo(allowed?.blockedReason ?? '当前账号或任务状态不允许此操作，请刷新');
      return;
    }
    final result = await showDialog<ProcurementIqcRejectionDetail>(
      context: context,
      barrierDismissible: false,
      builder: (_) => kind == ProcurementIqcRejectionActionKind.confirmCredit
          ? ProcurementIqcActualCreditDialog(
              detail: detail,
              onPreview: (command) =>
                  _repository.previewCredit(widget.id, command),
              onConfirm: (command) =>
                  _repository.confirmCredit(widget.id, command),
              onRefresh: () async {
                final next = await _repository.detail(widget.id);
                if (mounted) setState(() => _detail = next);
                return next;
              },
            )
          : ProcurementIqcRejectionActionDialog(
              caseItem: detail.caseItem,
              kind: kind,
              creditDocuments: detail.creditDocuments,
              onSubmit: (command) => _submit(kind, command),
            ),
    );
    if (!mounted || result == null) return;
    setState(() {
      _detail = result;
      _error = null;
    });
    ref.invalidate(procurementIqcRejectionOpenCountProvider);
    context.appSuccess(_successMessage(kind));
  }

  Future<ProcurementIqcRejectionDetail> _submit(
    ProcurementIqcRejectionActionKind kind,
    Object command,
  ) => switch (kind) {
    ProcurementIqcRejectionActionKind.recordReturn => _repository.recordReturn(
      widget.id,
      command as ProcurementIqcRecordReturnCommand,
    ),
    ProcurementIqcRejectionActionKind.confirmCredit =>
      _repository.confirmCredit(
        widget.id,
        command as ProcurementIqcConfirmCreditCommand,
      ),
    ProcurementIqcRejectionActionKind.closeNoCredit =>
      _repository.closeNoCredit(
        widget.id,
        command as ProcurementIqcReasonCommand,
      ),
    ProcurementIqcRejectionActionKind.reverse => _repository.reverse(
      widget.id,
      command as ProcurementIqcReasonCommand,
    ),
    ProcurementIqcRejectionActionKind.retryFinanceProjection =>
      _repository.retryFinanceProjection(
        widget.id,
        command as ProcurementIqcReasonCommand,
      ),
  };

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: UtenAppBar(
        title: 'IQC 不合格任务详情',
        subtitle: detail == null
            ? null
            : '${detail.caseItem.receiptType?.label ?? '未知'} · '
                  '${detail.caseItem.receiptBillNo ?? '—'}',
        leading: UtenBackButton(
          onPressed: () => popOrBackTo(context, defaultPath: _defaultBackPath),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && detail != null,
              onPressed: _loading ? null : _load,
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && detail == null
            ? Center(
                child: Semantics(
                  label: '正在加载 IQC 不合格任务详情',
                  child: const CircularProgressIndicator(strokeWidth: 2.5),
                ),
              )
            : _error != null && detail == null
            ? UtenEmpty.error(
                message: '无法加载 IQC 不合格任务',
                description: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : _buildDetail(),
      ),
    );
  }

  Widget _buildDetail() {
    final detail = _detail!;
    final permissions = ref.watch(currentPermissionsProvider);
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s12),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final expanded = constraints.maxWidth >= 960;
            final facts = <Widget>[
              _buildStatusHeader(detail.caseItem),
              const SizedBox(height: UtenSpacing.s12),
              _buildSourceFacts(detail.caseItem),
              const SizedBox(height: UtenSpacing.s12),
              _buildQuantityAndAmount(detail.caseItem),
              const SizedBox(height: UtenSpacing.s12),
              _buildReturnAndCredit(detail.caseItem),
              if (detail.resolution != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                _buildResolution(detail),
              ],
              if (detail.creditDocuments.isNotEmpty) ...[
                const SizedBox(height: UtenSpacing.s12),
                _buildCreditDocuments(detail),
              ],
              if (detail.replacementAllocations.isNotEmpty) ...[
                const SizedBox(height: UtenSpacing.s12),
                _buildAllocations(detail),
              ],
            ];
            final workflow = <Widget>[
              _buildActions(detail.caseItem),
              const SizedBox(height: UtenSpacing.s12),
              BusinessAttachmentSection(
                ownerType: 'PROCUREMENT_IQC_REJECTION',
                ownerId: detail.caseItem.id,
                title: '退回和贷项凭证',
                canView:
                    !detail.caseItem.priceMasked &&
                    permissions.contains(Perm.procurementIqcRejectionView) &&
                    permissions.contains(
                      Perm.procurementIqcRejectionAmountView,
                    ),
                canManage: detail.caseItem.allowedActions.any(
                  (action) =>
                      action == ProcurementIqcRejectionAction.recordReturn ||
                      action == ProcurementIqcRejectionAction.confirmCredit,
                ),
                categories: const ['退回凭证', '供应商确认', '其他'],
              ),
              const SizedBox(height: UtenSpacing.s12),
              _buildEvents(detail),
            ];
            if (!expanded) {
              return ListView(children: [...facts, ...workflow]);
            }
            // 大屏双栏（原 3:2 定比）统一接入可拖拽分栏（2026-09-03）：左事实区
            // 可拖宽，初始/复位宽取布局宽的 58% 对齐旧 flex 3:2 观感。
            return LayoutBuilder(
              builder: (context, constraints) => UtenSplitView(
                persistenceKey: 'procurementIqc.rejectionDetail',
                initialLeadingWidth: constraints.maxWidth * 0.58,
                minLeadingWidth: 320,
                leading: ListView(
                  padding: const EdgeInsets.only(right: UtenSpacing.s8),
                  children: facts,
                ),
                trailing: ListView(
                  padding: const EdgeInsets.only(left: UtenSpacing.s8),
                  children: workflow,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildStatusHeader(ProcurementIqcRejectionCase item) {
    final theme = Theme.of(context);
    final error = item.financeExceptionMessage?.trim();
    return Semantics(
      container: true,
      label: '任务状态 ${item.status.label}，版本 ${item.version}',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: item.status == ProcurementIqcRejectionStatus.financeException
              ? theme.colorScheme.errorContainer.withValues(alpha: 0.46)
              : theme.colorScheme.surfaceContainerLow,
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${item.goodsLabel} · ${item.receiptBillNo ?? '—'}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                ProcurementIqcRejectionStatusBadge(status: item.status),
              ],
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              error?.isNotEmpty == true
                  ? '${item.financeExceptionCode ?? 'FINANCE_EXCEPTION'} · $error'
                  : _detail?.resolution?.state == 'SETTLED'
                  ? '退回份额已通过合格补回入库或实际贷项完成结清。'
                  : item.holdReason ?? _detailNextStep(item.status),
              style: theme.textTheme.bodySmall?.copyWith(
                color: error?.isNotEmpty == true
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
                fontWeight: error?.isNotEmpty == true ? FontWeight.w600 : null,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSourceFacts(ProcurementIqcRejectionCase item) => _section(
    title: '来源与责任对象',
    icon: Icons.account_tree_outlined,
    children: [
      _Fact('来源类型', item.receiptType?.label ?? '—'),
      _Fact('收货 / 回厂单', item.receiptBillNo ?? '—'),
      _Fact('订货单', item.orderBillNo ?? '—'),
      _Fact('供应商 / 委外商', item.supplierName ?? '—'),
      _Fact('货品', item.goodsLabel.isEmpty ? '—' : item.goodsLabel),
      _Fact('任务版本', item.version.toString()),
    ],
  );

  Widget _buildQuantityAndAmount(ProcurementIqcRejectionCase item) => _section(
    title: '不合格数量与来源金额',
    icon: Icons.rule_folder_outlined,
    description: item.priceMasked
        ? '金额已由服务端按权限脱敏；view_all 不自动授予金额。'
        : '来源金额保留品质记录中的名义份额。供应商实际贷项按原始凭证另行填写和确认。',
    children: [
      _Fact('不合格基础量', item.failedBaseQty ?? '—'),
      _Fact('不合格单据量', '${item.failedQty ?? '—'} ${item.unitName ?? ''}'.trim()),
      _Fact('原币金额', item.amountLabel(item.failedAmountOriginal)),
      _Fact(
        '本币金额',
        item.priceMasked ? '***' : item.failedAmountLocal ?? '无有限金额投影，保留来源份额',
      ),
    ],
  );

  Widget _buildReturnAndCredit(ProcurementIqcRejectionCase item) => _section(
    title: '实物退回与财务闭环',
    icon: Icons.assignment_turned_in_outlined,
    children: [
      _Fact('退回凭证', item.returnReference ?? '—'),
      _Fact('退回日期', item.returnDate ?? '—'),
      _Fact('退回说明', item.returnNote ?? '—'),
      _Fact('退回记录时间', item.returnedAt ?? '—'),
      _Fact('贷项凭证', item.creditReference ?? '—'),
      _Fact('贷项日期', item.creditDate ?? '—'),
      _Fact('贷项确认时间', item.creditConfirmedAt ?? '—'),
      _Fact('零金额结案原因', item.closedNoCreditReason ?? '—'),
      _Fact('零金额结案时间', item.closedNoCreditAt ?? '—'),
    ],
  );

  Widget _buildActions(ProcurementIqcRejectionCase item) {
    final specs = _actionSpecs(item);
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '当前责任动作',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              specs.isEmpty
                  ? '当前账号没有该状态的业务动作；可继续只读查看审计事实。'
                  : '动作同时要求本地权限与服务端 allowedActions；状态阻断时保留禁用说明。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (specs.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s12),
              for (var index = 0; index < specs.length; index++) ...[
                _buildActionButton(specs[index], primary: index == 0),
                if (index != specs.length - 1)
                  const SizedBox(height: UtenSpacing.s8),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildActionButton(_ActionSpec spec, {required bool primary}) {
    final blocked = spec.blockedReason ?? '当前状态不允许执行此操作，请刷新任务';
    return Tooltip(
      message: spec.enabled ? spec.description : blocked,
      child: UtenButton(
        key: Key('iqc-detail-action-${spec.kind.name}'),
        size: UtenButtonSize.large,
        isExpanded: true,
        type: spec.kind == ProcurementIqcRejectionActionKind.reverse
            ? UtenButtonType.danger
            : primary
            ? UtenButtonType.primary
            : UtenButtonType.secondary,
        icon: spec.icon,
        onPressed: spec.enabled ? () => _openAction(spec.kind) : null,
        onDisabledTap: spec.enabled ? null : () => context.appInfo(blocked),
        child: Text(spec.label),
      ),
    );
  }

  List<_ActionSpec> _actionSpecs(ProcurementIqcRejectionCase item) {
    final specs = <_ActionSpec>[];
    final blocked = item.financeExceptionMessage ?? item.holdReason;
    final activeCredits =
        _detail?.creditDocuments.where((d) => d.status == 'ACTIVE').toList() ??
        <ProcurementIqcCreditDocument>[];
    final resolution = _detail?.resolution;
    final hasCreditSource =
        (_detail?.creditSources.isNotEmpty ?? false) &&
        resolution?.legacyUnclassified != true &&
        (financeExactDecimalUnits(resolution?.creditableBaseQty) ??
                BigInt.zero) >
            BigInt.zero;
    void add({
      required bool localPermission,
      required bool relevant,
      required String serverAction,
      required ProcurementIqcRejectionActionKind kind,
      required String label,
      required String description,
      required IconData icon,
      bool extraEnabled = true,
      String? extraReason,
    }) {
      if (!localPermission || !relevant) return;
      final allowed = item.allows(serverAction) && extraEnabled;
      specs.add(
        _ActionSpec(
          kind: kind,
          label: label,
          description: description,
          icon: icon,
          enabled: allowed,
          blockedReason: allowed ? null : extraReason ?? blocked,
        ),
      );
    }

    add(
      localPermission: _has(Perm.procurementIqcRejectionRecordReturn),
      relevant: item.status == ProcurementIqcRejectionStatus.pendingReturn,
      serverAction: ProcurementIqcRejectionAction.recordReturn,
      kind: ProcurementIqcRejectionActionKind.recordReturn,
      label: '登记实物退回',
      description: '记录可审计的退回凭证、日期和说明',
      icon: Icons.assignment_return_outlined,
    );
    add(
      localPermission:
          _has(Perm.procurementIqcRejectionConfirmCredit) &&
          _has(Perm.procurementIqcRejectionAmountView),
      relevant: item.status == ProcurementIqcRejectionStatus.returnRecorded,
      serverAction: ProcurementIqcRejectionAction.confirmCredit,
      kind: ProcurementIqcRejectionActionKind.confirmCredit,
      label: '确认供应商贷项',
      description: '填写实际凭证金额与案件分项，核对账面分配后确认',
      icon: Icons.receipt_long_outlined,
      extraEnabled: !item.priceMasked && hasCreditSource,
      extraReason: item.priceMasked
          ? '金额仍被服务端脱敏，不能确认贷项'
          : resolution?.legacyUnclassified == true
          ? '历史案件需先核对原应付与资金来源，不能按旧派生金额新建贷项'
          : !hasCreditSource
          ? '没有未被补回或贷项占用的明确退回份额'
          : null,
    );
    add(
      localPermission: _has(Perm.procurementIqcRejectionCloseNoCredit),
      relevant: item.status == ProcurementIqcRejectionStatus.returnRecorded,
      serverAction: ProcurementIqcRejectionAction.closeNoCredit,
      kind: ProcurementIqcRejectionActionKind.closeNoCredit,
      label: '零金额无需贷项结案',
      description: '仅服务器权威金额为零时可说明原因并结案',
      icon: Icons.money_off_csred_outlined,
    );
    add(
      localPermission:
          _has(Perm.procurementIqcRejectionConfirmCredit) &&
          _has(Perm.procurementIqcRejectionAmountView),
      relevant: item.status == ProcurementIqcRejectionStatus.financeException,
      serverAction: ProcurementIqcRejectionAction.retryFinanceProjection,
      kind: ProcurementIqcRejectionActionKind.retryFinanceProjection,
      label: '重试财务投影',
      description: '修复异常原因后使用同一冻结事实重试',
      icon: Icons.sync_rounded,
    );
    add(
      localPermission:
          _has(Perm.procurementIqcRejectionReverse) &&
          (activeCredits.isEmpty &&
                  item.status !=
                      ProcurementIqcRejectionStatus.creditConfirmed ||
              _has(Perm.procurementIqcRejectionAmountView)),
      relevant:
          item.status == ProcurementIqcRejectionStatus.returnRecorded ||
          item.status == ProcurementIqcRejectionStatus.creditConfirmed ||
          item.status == ProcurementIqcRejectionStatus.closedNoCredit ||
          item.status == ProcurementIqcRejectionStatus.financeException,
      serverAction: ProcurementIqcRejectionAction.reverse,
      kind: ProcurementIqcRejectionActionKind.reverse,
      label: activeCredits.isNotEmpty ? '反向实际贷项凭证' : '反向当前处理',
      description: activeCredits.isNotEmpty
          ? '选择实际凭证，连同其全部案件分项一并反向'
          : '按当前服务端状态执行合法反向',
      icon: Icons.undo_rounded,
      extraEnabled:
          activeCredits.isEmpty || activeCredits.any((d) => d.canReverse),
      extraReason:
          activeCredits.isNotEmpty && !activeCredits.any((d) => d.canReverse)
          ? '贷项份额已用于重新计款补回，请先反向对应后续收货'
          : null,
    );
    return specs;
  }

  Widget _buildEvents(ProcurementIqcRejectionDetail detail) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '追加式审计事件',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            if (detail.events.isEmpty)
              Text(
                '暂无可见事件',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              )
            else
              for (var index = 0; index < detail.events.length; index++) ...[
                _EventTile(event: detail.events[index]),
                if (index != detail.events.length - 1)
                  const Divider(height: UtenSpacing.s16),
              ],
          ],
        ),
      ),
    );
  }

  Widget _buildAllocations(ProcurementIqcRejectionDetail detail) {
    final item = detail.caseItem;
    return _section(
      title: '替换收货分配',
      icon: Icons.swap_horiz_rounded,
      description: '分配金额继续服从本任务 priceMasked；替换收货不是供应商贷项。',
      children: [
        for (final allocation in detail.replacementAllocations)
          _Fact(
            allocation.replacementReceiptType ?? '替换收货',
            '单据量 ${allocation.allocatedQty ?? '—'} · '
            '基本量 ${allocation.allocatedBaseQty ?? '—'} · '
            '${item.amountLabel(allocation.allocatedAmountLocal)} · '
            '${allocation.status}',
          ),
      ],
    );
  }

  Widget _buildResolution(ProcurementIqcRejectionDetail detail) {
    final r = detail.resolution!;
    final unit = r.baseUnitName ?? '基本单位';
    return _section(
      title: '退回份额处理进度',
      icon: Icons.fact_check_outlined,
      description: r.legacyUnclassified
          ? '历史资金份额待核对，保留原始单据和已发生记录。'
          : '免费补回在合格实收入库后结清；未入库补回与已确认贷项分别记录。',
      children: [
        _Fact('可确认贷项基本量', '${r.creditableBaseQty ?? '—'} $unit'),
        _Fact('补回待合格入库', '${r.replacementPendingBaseQty ?? '—'} $unit'),
        _Fact('补回已合格入库', '${r.replacementStockedBaseQty ?? '—'} $unit'),
        _Fact('已确认贷项基本量', '${r.creditedBaseQty ?? '—'} $unit'),
        _Fact('仍未结清基本量', '${r.unresolvedBaseQty ?? '—'} $unit'),
        _Fact(
          '处理状态',
          r.legacyUnclassified
              ? '待核对'
              : r.state == 'SETTLED'
              ? '已结清'
              : r.state == 'PARTIAL'
              ? '部分完成'
              : '处理中',
        ),
      ],
    );
  }

  Widget _buildCreditDocuments(
    ProcurementIqcRejectionDetail detail,
  ) => _section(
    title: '实际供应商贷项凭证',
    icon: Icons.receipt_long_outlined,
    description: '保留每次实际凭证、明确案件分项及账面分配。反向将覆盖所选凭证的全部案件。',
    children: [
      for (final doc in detail.creditDocuments) ...[
        _Fact(
          '${doc.creditReference ?? '贷项凭证'} · ${doc.status == 'ACTIVE' ? '有效' : '已反向'}',
          '${doc.creditDate ?? '—'}\n原币 ${detail.caseItem.amountLabel(doc.amountOriginal)}\n本币 ${detail.caseItem.priceMasked ? '***' : doc.amountLocal ?? '待核对'}',
        ),
        if (!detail.caseItem.priceMasked)
          for (final part in doc.caseAllocations)
            _Fact(
              part.caseId == detail.caseItem.id ? '当前案件分项' : '同凭证关联案件分项',
              '基本量 ${part.baseQty ?? '—'} · 原币 ${part.amountOriginal ?? '—'}\n本币 ${part.amountLocal ?? '—'}\n凭证待分原币 ${part.afterOriginal ?? '—'} / 本币 ${part.afterLocal ?? '—'}',
            ),
      ],
    ],
  );

  Widget _section({
    required String title,
    required IconData icon,
    required List<_Fact> children,
    String? description,
  }) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 20, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            if (description != null) ...[
              const SizedBox(height: UtenSpacing.s4),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth;
                final columns = width >= 900
                    ? 3
                    : width >= 520
                    ? 2
                    : 1;
                final itemWidth =
                    (width - (columns - 1) * UtenSpacing.s8) / columns;
                return Wrap(
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    for (final fact in children)
                      SizedBox(
                        width: itemWidth,
                        child: _FactTile(fact: fact),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static String _successMessage(ProcurementIqcRejectionActionKind kind) =>
      switch (kind) {
        ProcurementIqcRejectionActionKind.recordReturn => '实物退回凭证已登记',
        ProcurementIqcRejectionActionKind.confirmCredit => '供应商贷项已确认',
        ProcurementIqcRejectionActionKind.closeNoCredit => '零金额无需贷项任务已结案',
        ProcurementIqcRejectionActionKind.reverse => '当前处理已反向',
        ProcurementIqcRejectionActionKind.retryFinanceProjection => '财务投影已重试',
      };
}

class _ActionSpec {
  const _ActionSpec({
    required this.kind,
    required this.label,
    required this.description,
    required this.icon,
    required this.enabled,
    this.blockedReason,
  });

  final ProcurementIqcRejectionActionKind kind;
  final String label;
  final String description;
  final IconData icon;
  final bool enabled;
  final String? blockedReason;
}

class _Fact {
  const _Fact(this.label, this.value);
  final String label;
  final String value;
}

class _FactTile extends StatelessWidget {
  const _FactTile({required this.fact});
  final _Fact fact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.all(UtenSpacing.s8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLowest,
        borderRadius: UtenRadius.smAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            fact.label,
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: UtenSpacing.s4),
          SelectableText(fact.value, style: theme.textTheme.bodyMedium),
        ],
      ),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event});
  final ProcurementIqcRejectionEvent event;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: '${_eventLabel(event.eventType)}，${event.createdAt ?? '时间未知'}',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(top: 5),
            decoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _eventLabel(event.eventType),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  [
                        event.reference,
                        event.eventDate,
                        event.reason,
                        event.createdAt,
                      ]
                      .where((value) => value?.trim().isNotEmpty == true)
                      .join(' · '),
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
}

String _detailNextStep(ProcurementIqcRejectionStatus status) =>
    switch (status) {
      ProcurementIqcRejectionStatus.pendingReturn => '等待订单负责人登记真实实物退回',
      ProcurementIqcRejectionStatus.returnRecorded => '等待财务确认贷项或零金额结案',
      ProcurementIqcRejectionStatus.financeException => '财务投影异常，修复后可重试',
      ProcurementIqcRejectionStatus.creditConfirmed => '供应商贷项与原应付反向已闭环',
      ProcurementIqcRejectionStatus.closedNoCredit => '服务器确认金额为零，无需贷项',
      ProcurementIqcRejectionStatus.reversed => '当前下游处理已反向',
      ProcurementIqcRejectionStatus.unknown => '未知状态，禁止猜测动作',
    };

String _eventLabel(String eventType) => switch (eventType) {
  'FAIL_RECORDED' => 'IQC 不合格数量已冻结',
  'RETURN_RECORDED' => '实物退回已登记',
  'CREDIT_CONFIRMED' => '供应商贷项已确认',
  'CLOSED_NO_CREDIT' => '零金额无需贷项结案',
  'FINANCE_PROJECTION_FAILED' => '财务投影失败',
  'FINANCE_PROJECTION_RETRIED' => '财务投影已重试',
  'REVERSED' || 'RETURN_REVERSED' || 'CREDIT_REVERSED' => '处理已反向',
  _ => eventType,
};
