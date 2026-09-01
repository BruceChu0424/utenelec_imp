import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../models/procurement_iqc_rejection.dart';
import '../repositories/procurement_iqc_rejection_repository.dart';
import '../widgets/procurement_iqc_rejection_action_dialog.dart';
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
    if (detail == null) return;
    final result = await showDialog<ProcurementIqcRejectionDetail>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProcurementIqcRejectionActionDialog(
        caseItem: detail.caseItem,
        kind: kind,
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
              if (detail.replacementAllocations.isNotEmpty) ...[
                const SizedBox(height: UtenSpacing.s12),
                _buildAllocations(detail),
              ],
            ];
            final workflow = <Widget>[
              _buildActions(detail.caseItem),
              const SizedBox(height: UtenSpacing.s12),
              _buildEvents(detail),
            ];
            if (!expanded) {
              return ListView(children: [...facts, ...workflow]);
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  flex: 3,
                  child: ListView(
                    padding: const EdgeInsets.only(right: UtenSpacing.s8),
                    children: facts,
                  ),
                ),
                const VerticalDivider(width: UtenSpacing.s16),
                Expanded(
                  flex: 2,
                  child: ListView(
                    padding: const EdgeInsets.only(left: UtenSpacing.s8),
                    children: workflow,
                  ),
                ),
              ],
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
    title: '拒收数量与冻结金额',
    icon: Icons.rule_folder_outlined,
    description: item.priceMasked
        ? '金额已由服务端按权限脱敏；view_all 不自动授予金额。'
        : '金额来自服务器冻结快照，只读，不接受客户端修改。',
    children: [
      _Fact('不合格基础量', item.failedBaseQty ?? '—'),
      _Fact('不合格单据量', '${item.failedQty ?? '—'} ${item.unitName ?? ''}'.trim()),
      _Fact('原币金额', item.amountLabel(item.failedAmountOriginal)),
      _Fact('本币金额', item.amountLabel(item.failedAmountLocal)),
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
      description: '按服务器冻结金额确认供应商贷项',
      icon: Icons.receipt_long_outlined,
      extraEnabled: !item.priceMasked,
      extraReason: item.priceMasked ? '金额仍被服务端脱敏，不能确认贷项' : null,
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
          (item.status != ProcurementIqcRejectionStatus.creditConfirmed ||
              _has(Perm.procurementIqcRejectionAmountView)),
      relevant:
          item.status == ProcurementIqcRejectionStatus.returnRecorded ||
          item.status == ProcurementIqcRejectionStatus.creditConfirmed ||
          item.status == ProcurementIqcRejectionStatus.closedNoCredit ||
          item.status == ProcurementIqcRejectionStatus.financeException,
      serverAction: ProcurementIqcRejectionAction.reverse,
      kind: ProcurementIqcRejectionActionKind.reverse,
      label: '反向当前处理',
      description: '按当前服务端状态执行唯一合法反向，不由客户端猜路径',
      icon: Icons.undo_rounded,
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
