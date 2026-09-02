import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_sales_outbound.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';
import '../providers/warehouse_count_refresh.dart';

class WarehouseSalesOutboundDetailPage extends ConsumerStatefulWidget {
  const WarehouseSalesOutboundDetailPage({super.key, required this.id});

  final String id;

  @override
  ConsumerState<WarehouseSalesOutboundDetailPage> createState() =>
      _WarehouseSalesOutboundDetailPageState();
}

class _WarehouseSalesOutboundDetailPageState
    extends ConsumerState<WarehouseSalesOutboundDetailPage> {
  WarehouseSalesOutboundDetail? _detail;
  bool _loading = false;
  bool _acting = false;
  String? _error;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(warehouseSalesOutboundRepositoryProvider)
          .detail(widget.id);
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _detail = detail;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = '销售出库详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _runAction(WarehouseSalesOutboundAction action) async {
    if (_acting || _detail?.header.allows(action) != true) return;
    final reason = await _confirmAction(action);
    if (reason == null || !mounted) return;
    setState(() => _acting = true);
    try {
      final updated = await ref
          .read(warehouseSalesOutboundRepositoryProvider)
          .transition(
            widget.id,
            targetStatus: action.targetStatus,
            reason: reason,
          );
      if (!mounted) return;
      setState(() => _detail = updated);
      // 交接出库会减少待出库角标；流转成功立即失效全部仓库任务计数。
      invalidateWarehouseTaskCounts(ref);
      context.appSuccess('${action.label}已完成');
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appError(error.message);
      if (error.code == 'CONFLICT') await _load();
    } catch (_) {
      if (mounted) context.appError('${action.label}失败，请稍后重试');
    } finally {
      if (mounted) setState(() => _acting = false);
    }
  }

  Future<String?> _confirmAction(WarehouseSalesOutboundAction action) async {
    final controller = TextEditingController();
    String? validation;
    final result = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(action.label),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(_actionDescription(action)),
                if (action.requiresReason) ...[
                  const SizedBox(height: UtenSpacing.s12),
                  TextField(
                    key: const Key('warehouse-sales-outbound-action-reason'),
                    controller: controller,
                    minLines: 2,
                    maxLines: 4,
                    maxLength: 1000,
                    decoration: InputDecoration(
                      labelText:
                          action == WarehouseSalesOutboundAction.reportException
                          ? '异常说明'
                          : '恢复说明',
                      error: validation == null
                          ? null
                          : UtenFieldMessage.error(validation!),
                    ),
                  ),
                ],
              ],
            ),
          ),
          actionsAlignment: MainAxisAlignment.center,
          actions: [
            TextButton(
              style: TextButton.styleFrom(minimumSize: const Size(88, 48)),
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(minimumSize: const Size(88, 48)),
              onPressed: () {
                final reason = controller.text.trim();
                if (action.requiresReason && reason.isEmpty) {
                  setDialogState(() => validation = '请填写具体说明');
                  return;
                }
                Navigator.of(dialogContext).pop(reason);
              },
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final actions = detail == null
        ? const <WarehouseSalesOutboundAction>[]
        : WarehouseSalesOutboundAction.values
              .where(detail.header.allows)
              .toList(growable: false);
    return Scaffold(
      appBar: UtenAppBar(
        title: '销售出库详情',
        subtitle: '仓库作业视图',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: '/warehouse/sales-outbound'),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('warehouse-sales-outbound-detail-refresh'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && detail != null,
              onPressed: _loading || _acting ? null : _load,
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: _loading && detail == null
            ? const UtenSkeletonList(itemCount: 6)
            : _error != null && detail == null
            ? UtenEmpty.error(
                message: _error,
                actionLabel: '重新加载',
                onAction: _load,
              )
            : detail == null
            ? UtenEmpty.error(message: '任务不存在或已不在仓库作业范围')
            : UtenContentContainer.wide(
                child: ListView(
                  padding: const EdgeInsets.symmetric(
                    vertical: UtenSpacing.s16,
                  ),
                  children: [
                    _OutboundStatusBanner(detail: detail),
                    if (_error != null) ...[
                      const SizedBox(height: UtenSpacing.s8),
                      Semantics(
                        liveRegion: true,
                        child: Text(
                          _error!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: UtenSpacing.s12),
                    _factsCard(detail),
                    const SizedBox(height: UtenSpacing.s16),
                    Text(
                      '拣货明细 (${detail.lines.length})',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s8),
                    MasterDataTableView<WarehouseSalesOutboundLine>(
                      key: const Key('warehouse-sales-outbound-detail-table'),
                      embedded: true,
                      columns: _lineColumns(detail.lines),
                      items: detail.lines,
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      emptyMessage: '该任务暂无拣货明细',
                    ),
                    const SizedBox(height: UtenSpacing.s24),
                  ],
                ),
              ),
      ),
      bottomNavigationBar: actions.isEmpty
          ? null
          : SafeArea(
              child: Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surface,
                  border: Border(
                    top: BorderSide(
                      color: Theme.of(context).colorScheme.outlineVariant,
                    ),
                  ),
                ),
                child: Wrap(
                  alignment: WrapAlignment.center,
                  spacing: UtenSpacing.s8,
                  runSpacing: UtenSpacing.s8,
                  children: [
                    for (final action in actions)
                      UtenButton(
                        key: Key(
                          'warehouse-sales-outbound-action-'
                          '${action.targetStatus}',
                        ),
                        size: UtenButtonSize.large,
                        type:
                            action ==
                                WarehouseSalesOutboundAction.reportException
                            ? UtenButtonType.danger
                            : action == WarehouseSalesOutboundAction.handOver
                            ? UtenButtonType.primary
                            : UtenButtonType.secondary,
                        icon: _actionIcon(action),
                        isLoading: _acting,
                        onPressed: _acting ? null : () => _runAction(action),
                        child: Text(action.label),
                      ),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _factsCard(WarehouseSalesOutboundDetail detail) {
    final facts = <(String, String?)>[
      ('出货单号', detail.header.billNo),
      ('业务日期', detail.header.billDate),
      ('客户', detail.header.clientName),
      ('仓库', detail.header.warehouseName),
      ('收货地址', detail.shipAddress),
      ('联系电话', detail.contactPhone),
      ('物流单号', detail.logisticsNo),
      ('件数', detail.parcelCount?.toString()),
      ('作业状态', detail.header.statusLabel),
      ('异常说明', detail.warehouseExceptionReason),
      ('开始拣货', detail.pickingStartedAt),
      ('拣货完成', detail.pickedAt),
      ('交接出库', detail.handedOverAt),
      ('作业更新', detail.warehouseWorkUpdatedAt),
    ].where((fact) => _present(fact.$2)).toList(growable: false);
    final theme = Theme.of(context);
    return Card(
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: UtenRadius.lgAll,
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 1080
                ? 3
                : constraints.maxWidth >= 640
                ? 2
                : 1;
            final width =
                (constraints.maxWidth - UtenSpacing.s12 * (columns - 1)) /
                columns;
            return Wrap(
              spacing: UtenSpacing.s12,
              runSpacing: UtenSpacing.s12,
              children: [
                for (final fact in facts)
                  SizedBox(
                    width: width,
                    child: _OutboundFact(label: fact.$1, value: fact.$2!),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  List<MasterColumnDef<WarehouseSalesOutboundLine>> _lineColumns(
    List<WarehouseSalesOutboundLine> lines,
  ) {
    bool has(String? Function(WarehouseSalesOutboundLine) value) =>
        lines.any((line) => _present(value(line)));
    return [
      MasterColumnDef(
        key: 'lineNumber',
        label: '行号',
        width: 64,
        type: 'number',
        value: (line) => line.lineNumber?.toString() ?? '—',
      ),
      MasterColumnDef(
        key: 'goodsCode',
        label: '货品编码',
        width: 126,
        value: (line) => line.goodsCode ?? '—',
      ),
      MasterColumnDef(
        key: 'goodsName',
        label: '货品名称',
        width: 210,
        value: (line) => line.goodsName ?? '—',
      ),
      if (has((line) => line.currentStockPlaceHint))
        MasterColumnDef(
          key: 'currentStockPlaceHint',
          label: '当前建议库位',
          width: 126,
          value: (line) => line.currentStockPlaceHint ?? '—',
        ),
      if (has((line) => line.colorName))
        MasterColumnDef(
          key: 'colorName',
          label: '颜色',
          width: 96,
          value: (line) => line.colorName ?? '—',
        ),
      if (has((line) => line.unitName))
        MasterColumnDef(
          key: 'unitName',
          label: '单位',
          width: 80,
          value: (line) => line.unitName ?? '—',
        ),
      MasterColumnDef(
        key: 'quantity',
        label: '出货数量',
        width: 108,
        type: 'number',
        value: (line) => line.quantity ?? '—',
      ),
      if (has((line) => line.weight))
        MasterColumnDef(
          key: 'weight',
          label: '重量',
          width: 96,
          type: 'number',
          value: (line) => line.weight ?? '—',
        ),
      if (has((line) => line.parcelQuantity))
        MasterColumnDef(
          key: 'parcelQuantity',
          label: '件数',
          width: 90,
          type: 'number',
          value: (line) => line.parcelQuantity ?? '—',
        ),
      if (lines.any((line) => line.cartonCount != null))
        MasterColumnDef(
          key: 'cartonCount',
          label: '箱数',
          width: 90,
          type: 'number',
          value: (line) => line.cartonCount?.toString() ?? '—',
        ),
      if (has((line) => line.clientProductCode))
        MasterColumnDef(
          key: 'clientProductCode',
          label: '客户产品号',
          width: 140,
          value: (line) => line.clientProductCode ?? '—',
        ),
      if (has((line) => line.clientModel))
        MasterColumnDef(
          key: 'clientModel',
          label: '客户型号',
          width: 130,
          value: (line) => line.clientModel ?? '—',
        ),
      if (has((line) => line.sourceDocumentNo))
        MasterColumnDef(
          key: 'sourceDocumentNo',
          label: '来源订单',
          width: 170,
          value: (line) => line.sourceDocumentNo ?? '—',
        ),
    ];
  }
}

class _OutboundStatusBanner extends StatelessWidget {
  const _OutboundStatusBanner({required this.detail});

  final WarehouseSalesOutboundDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label:
          '仓库状态 ${detail.header.statusLabel}。'
          '${WarehouseSalesOutboundStatus.nextStep(detail.header.warehouseWorkStatus)}',
      child: Container(
        key: const Key('warehouse-sales-outbound-detail-boundary'),
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
          borderRadius: UtenRadius.lgAll,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              detail.header.statusLabel,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              WarehouseSalesOutboundStatus.nextStep(
                detail.header.warehouseWorkStatus,
              ),
              style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
            ),
            const SizedBox(height: UtenSpacing.s4),
            Text(
              '仓库作业视图不包含商业与财务信息，也不提供销售业务编辑操作。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _OutboundFact extends StatelessWidget {
  const _OutboundFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      label: '$label：$value',
      child: Container(
        constraints: const BoxConstraints(minHeight: 64),
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLowest,
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: theme.colorScheme.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s4),
            SelectableText(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _actionDescription(WarehouseSalesOutboundAction action) =>
    switch (action) {
      WarehouseSalesOutboundAction.startPicking => '确认开始实物拣货。开始后任务进入拣货中。',
      WarehouseSalesOutboundAction.finishPicking => '确认所有行已按实物核对并完成拣货。',
      WarehouseSalesOutboundAction.reportException => '登记真实仓库异常，任务会暂停后续交接。',
      WarehouseSalesOutboundAction.restorePending => '确认异常已处理，并说明处理结果。任务恢复待拣货。',
      WarehouseSalesOutboundAction.handOver => '确认实物已完成交接。该动作会推进正式出库，请再次核对。',
    };

IconData _actionIcon(WarehouseSalesOutboundAction action) => switch (action) {
  WarehouseSalesOutboundAction.startPicking => Icons.play_circle_outline,
  WarehouseSalesOutboundAction.finishPicking => Icons.task_alt_outlined,
  WarehouseSalesOutboundAction.reportException => Icons.report_problem_outlined,
  WarehouseSalesOutboundAction.restorePending => Icons.restart_alt_rounded,
  WarehouseSalesOutboundAction.handOver => Icons.local_shipping_outlined,
};

bool _present(String? value) => value?.trim().isNotEmpty == true;
