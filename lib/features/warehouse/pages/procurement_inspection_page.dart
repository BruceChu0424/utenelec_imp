import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../shared/auth/permissions.dart';
import '../repositories/procurement_inspection_repository.dart';

/// 采购/委外收货 IQC 待检处置工作台（待检 sidecar 的前端入口）。
///
/// 收货审核后明细冻结在待检隔离（不进可用库存）；本页按收货单聚合展示
/// 仍有 PENDING/PARTIAL 的明细，质检员逐行 PASS（合格放行进可用库存，整单
/// 结案后唤醒生产）/ FAIL（只记质量事实，不入可用）。行内展示货品与来源
/// 订货单号（溯源）。部分 PASS 支持：数量留空 = 全部剩余待检量。
class ProcurementInspectionPage extends ConsumerStatefulWidget {
  const ProcurementInspectionPage({super.key});

  @override
  ConsumerState<ProcurementInspectionPage> createState() =>
      _ProcurementInspectionPageState();
}

class _ProcurementInspectionPageState
    extends ConsumerState<ProcurementInspectionPage> {
  bool _loading = true;
  String? _error;
  List<PendingInspectionReceipt> _receipts = const [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rows = await ref
          .read(procurementInspectionRepositoryProvider)
          .pendingReceipts();
      if (!mounted) return;
      setState(() {
        _receipts = rows;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: UtenAppBar(
        title: '待检处置（IQC）',
        leading: UtenBackButton(
          onPressed: () =>
              backTo(context, defaultPath: RouteName.qualityTaskCenter),
        ),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh),
            onPressed: _reload,
          ),
          const SizedBox(width: UtenSpacing.s8),
        ],
      ),
      body: UtenContentContainer(
        child: _loading
            ? ListView(
                children: const [
                  SizedBox(height: UtenSpacing.s12),
                  UtenSkeleton(height: 96),
                  SizedBox(height: UtenSpacing.s12),
                  UtenSkeleton(height: 96),
                ],
              )
            : _error != null
            ? UtenEmpty(
                icon: Icons.error_outline,
                message: '加载失败',
                description: _error,
                actionLabel: '重试',
                onAction: _reload,
                isError: true,
              )
            : _receipts.isEmpty
            ? UtenEmpty(
                icon: Icons.verified_outlined,
                message: '暂无待检单',
                description: '采购/委外收货审核后，待检明细会出现在这里等待质检处置',
                actionLabel: '刷新',
                onAction: _reload,
              )
            : RefreshIndicator(
                onRefresh: _reload,
                child: ListView.separated(
                  padding: const EdgeInsets.all(UtenSpacing.s12),
                  itemCount: _receipts.length,
                  separatorBuilder: (_, _) =>
                      const SizedBox(height: UtenSpacing.s12),
                  itemBuilder: (context, i) =>
                      _ReceiptCard(receipt: _receipts[i], onChanged: _reload),
                ),
              ),
      ),
    );
  }
}

class _ReceiptCard extends ConsumerStatefulWidget {
  const _ReceiptCard({required this.receipt, required this.onChanged});

  final PendingInspectionReceipt receipt;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ReceiptCard> createState() => _ReceiptCardState();
}

class _ReceiptCardState extends ConsumerState<_ReceiptCard> {
  bool _expanded = false;
  bool _loadingItems = false;
  List<ProcurementInspectionItem>? _items;

  Future<void> _toggle() async {
    if (_expanded) {
      setState(() => _expanded = false);
      return;
    }
    setState(() {
      _expanded = true;
      _loadingItems = _items == null;
    });
    if (_items == null) {
      try {
        final rows = await ref
            .read(procurementInspectionRepositoryProvider)
            .items(widget.receipt.receiptType, widget.receipt.receiptId);
        if (!mounted) return;
        setState(() {
          _items = rows;
          _loadingItems = false;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() => _loadingItems = false);
        UtenNotify.error(context, '加载待检明细失败：$e');
      }
    }
  }

  Future<void> _refreshItems() async {
    try {
      final rows = await ref
          .read(procurementInspectionRepositoryProvider)
          .items(widget.receipt.receiptType, widget.receipt.receiptId);
      if (!mounted) return;
      setState(() => _items = rows);
    } catch (_) {
      // 错误已由操作入口反馈，保持旧数据
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = widget.receipt;
    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: _toggle,
        child: Padding(
          padding: const EdgeInsets.all(UtenSpacing.s12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: r.isSubcontract
                          ? theme.colorScheme.tertiaryContainer
                          : theme.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      r.isSubcontract ? '委外回厂' : '采购收货',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: r.isSubcontract
                            ? theme.colorScheme.onTertiaryContainer
                            : theme.colorScheme.onSecondaryContainer,
                      ),
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      r.billNo ?? r.receiptId,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              Text(
                [
                  if (r.billDate?.isNotEmpty == true) '收货日期 ${r.billDate}',
                  if (r.supplierName?.isNotEmpty == true)
                    '${r.isSubcontract ? '委外商' : '供应商'} ${r.supplierName}',
                  '${r.itemCount} 行待检',
                  if (r.pendingBaseQty != null)
                    '待检量 ${_fmt(r.pendingBaseQty!)}',
                ].join(' · '),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              if (_expanded) ...[
                const Divider(height: 20),
                if (_loadingItems)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: UtenSpacing.s12),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_items == null || _items!.isEmpty)
                  Text('暂无明细', style: theme.textTheme.bodySmall)
                else
                  for (final it in _items!)
                    _ItemRow(
                      receiptType: r.receiptType,
                      receiptId: r.receiptId,
                      item: it,
                      onChanged: () async {
                        await _refreshItems();
                        widget.onChanged();
                      },
                    ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemRow extends ConsumerWidget {
  const _ItemRow({
    required this.receiptType,
    required this.receiptId,
    required this.item,
    required this.onChanged,
  });

  final String receiptType;
  final String receiptId;
  final ProcurementInspectionItem item;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final canHandle = ref.read(isSuperAdminProvider)
        ? true
        : ref
              .read(currentPermissionsProvider)
              .contains(Perm.procurementInspectionHandle);
    final remaining = item.remainingBaseQty ?? 0;
    final open = remaining > 0 && item.status != 'RESOLVED';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  [
                    if (item.goodsName?.isNotEmpty == true) item.goodsName!,
                    if (item.goodsCode?.isNotEmpty == true)
                      '（${item.goodsCode}）',
                    if (item.colorName?.isNotEmpty == true)
                      ' · ${item.colorName}',
                  ].join(),
                  style: theme.textTheme.bodyMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '待检 ${_fmt(remaining)}',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: open
                      ? theme.colorScheme.error
                      : theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
              '到检 ${_fmt(item.receivedBaseQty ?? 0)}',
              '已合格 ${_fmt(item.passedBaseQty ?? 0)}',
              '不合格 ${_fmt(item.failedBaseQty ?? 0)}',
              if (item.sourceOrderNo?.isNotEmpty == true)
                '来源 ${item.sourceOrderNo}',
            ].join(' · '),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          if (open && canHandle)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s4),
              child: Row(
                children: [
                  UtenButton(
                    onPressed: () => _dispose(context, ref, 'PASS'),
                    child: const Text('合格放行'),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  UtenButton(
                    type: UtenButtonType.tonal,
                    size: UtenButtonSize.small,
                    onPressed: () => _dispose(context, ref, 'FAIL'),
                    child: const Text('不合格'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _dispose(
    BuildContext context,
    WidgetRef ref,
    String action,
  ) async {
    final goodsLabel = [
      item.goodsName,
      item.goodsCode,
    ].where((s) => s?.isNotEmpty == true).map((s) => s!).join(' ');
    final input = await showDialog<_DisposeInput>(
      context: context,
      builder: (_) => _DisposeDialog(
        action: action,
        goodsLabel: goodsLabel,
        remaining: item.remainingBaseQty ?? 0,
      ),
    );
    if (input == null || !context.mounted) return;
    try {
      await ref
          .read(procurementInspectionRepositoryProvider)
          .dispose(
            receiptType: receiptType,
            receiptId: receiptId,
            inspectionItemId: item.id,
            action: action,
            baseQty: input.qty,
            reason: input.reason,
            idempotencyKey: const Uuid().v4(),
          );
      if (!context.mounted) return;
      UtenNotify.success(
        context,
        action == 'PASS'
            ? (input.qty == null ? '已全量放行进可用库存' : '已按 ${_fmt(input.qty!)} 放行')
            : '已登记不合格（不影响可用库存）',
      );
      onChanged();
    } catch (e) {
      if (!context.mounted) return;
      UtenNotify.error(context, '处置失败：$e');
    }
  }
}

class _DisposeDialog extends StatefulWidget {
  const _DisposeDialog({
    required this.action,
    required this.goodsLabel,
    required this.remaining,
  });

  final String action;
  final String goodsLabel;
  final double remaining;

  @override
  State<_DisposeDialog> createState() => _DisposeDialogState();
}

class _DisposeDialogState extends State<_DisposeDialog> {
  final TextEditingController _qty = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  String? _qtyError;
  String? _reasonError;

  @override
  void dispose() {
    _qty.dispose();
    _reason.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pass = widget.action == 'PASS';
    return AlertDialog(
      title: Text(pass ? '合格放行（PASS）' : '登记不合格（FAIL）'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UtenReviewerResponsibilityNotice(
              actionLabel: pass ? '合格放行' : '不合格处置',
              description: '确认后系统将记录该审核员、结论、数量和时间，请对本次检验结果负责。',
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(widget.goodsLabel, style: theme.textTheme.bodySmall),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              pass
                  ? '放行进可用库存；整张收货单全部明细终态后，系统一次性唤醒下游生产供给。'
                  : '不合格只记质量事实，不进可用库存；处置（退/换/补）走对应业务单据。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            if (pass)
              TextField(
                controller: _qty,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: '合格数量（留空 = 全部剩余 ${_fmt(widget.remaining)}）',
                  errorText: _qtyError,
                ),
              ),
            const SizedBox(height: UtenSpacing.s8),
            TextField(
              controller: _reason,
              maxLines: 3,
              decoration: InputDecoration(
                labelText: pass ? '放行说明（选填）' : '不合格原因（必填）',
                helperText: pass ? '可留空；如有特殊放行依据再填写' : null,
                errorText: _reasonError,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final reason = _reason.text.trim();
            if (!pass && reason.isEmpty) {
              setState(() => _reasonError = '必填');
              return;
            }
            double? qty;
            final text = _qty.text.trim();
            if (text.isNotEmpty) {
              final v = double.tryParse(text);
              if (v == null || v <= 0 || v > widget.remaining) {
                setState(
                  () => _qtyError = '须为正数且不超过剩余 ${_fmt(widget.remaining)}',
                );
                return;
              }
              qty = v;
            }
            Navigator.of(
              context,
            ).pop(_DisposeInput(qty, reason.isEmpty ? null : reason));
          },
          child: const Text('确认'),
        ),
      ],
    );
  }
}

class _DisposeInput {
  const _DisposeInput(this.qty, this.reason);

  final double? qty;
  final String? reason;
}

String _fmt(double v) {
  final s = v.toStringAsFixed(4).replaceFirst(RegExp(r'0+$'), '');
  return s.endsWith('.') ? s.substring(0, s.length - 1) : s;
}
