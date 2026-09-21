import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/warehouse_sales_outbound.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';
import '../providers/warehouse_count_refresh.dart';
import '../widgets/warehouse_sales_outbound_table_columns.dart';
import '../widgets/warehouse_sales_picking_fields.dart';

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
  bool _confirming = false;
  bool _needsReview = false;
  String? _error;
  int _requestVersion = 0;
  WarehouseSalesPickingDraft? _picking;

  @override
  void dispose() {
    _picking?.dispose();
    super.dispose();
  }

  void _replaceDetail(WarehouseSalesOutboundDetail detail) {
    _picking?.dispose();
    _detail = detail;
    _picking = WarehouseSalesPickingDraft(detail);
  }

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
        _replaceDetail(detail);
        _loading = false;
        _needsReview = false;
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
    if (_acting ||
        _confirming ||
        _loading ||
        _needsReview ||
        _error != null ||
        _detail?.header.allows(action) != true) {
      return;
    }
    final reviewed = _detail!;
    if (_picking?.validate() == false) {
      setState(() {});
      context.appWarning(_picking!.error!);
      return;
    }
    setState(() => _confirming = true);
    try {
      final reason = await _confirmAction(action);
      if (reason == null || !mounted) return;
      setState(() {
        _confirming = false;
        _acting = true;
      });
      final repository = ref.read(warehouseSalesOutboundRepositoryProvider);
      final latest = await repository.detail(widget.id);
      if (!mounted) return;
      if (warehouseSalesOutboundReviewSnapshot(latest) !=
              warehouseSalesOutboundReviewSnapshot(reviewed) ||
          !latest.header.allows(action)) {
        setState(() {
          _replaceDetail(latest);
          _needsReview = true;
          _error =
              (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
                      AppLocalizationsZh())
                  .warehouseOutboundBatchStale;
        });
        context.appWarning(
          (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
                  AppLocalizationsZh())
              .warehouseOutboundBatchStale,
        );
        return;
      }
      final updated = await ref
          .read(warehouseSalesOutboundRepositoryProvider)
          .transition(
            widget.id,
            targetStatus: action.targetStatus,
            reason: reason,
            stockPlaces: _picking?.stockPlaces,
            lineWarehouses: _picking?.lineWarehouses,
          );
      if (!mounted) return;
      if (updated.header.id != widget.id ||
          updated.header.warehouseWorkStatus != action.targetStatus) {
        throw const FormatException();
      }
      setState(() => _replaceDetail(updated));
      // 确认出库会减少待出库角标；流转成功立即失效全部仓库任务计数。
      invalidateWarehouseTaskCounts(ref);
      context.appSuccess('${action.label}已完成');
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _needsReview = true;
        _error = error.message;
      });
      context.appError(error.message);
    } catch (_) {
      if (mounted) {
        setState(() {
          _needsReview = true;
          _error =
              (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
                      AppLocalizationsZh())
                  .warehouseOutboundBatchUnknown;
        });
        context.appError(
          (Localizations.of<AppLocalizations>(context, AppLocalizations) ??
                  AppLocalizationsZh())
              .warehouseOutboundBatchUnknown,
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _acting = false;
          _confirming = false;
        });
      }
    }
  }

  /// 返回 null = 取消；返回字符串 = 确认，内容是选填的出库备注（可为空串）。
  Future<String?> _confirmAction(WarehouseSalesOutboundAction action) async {
    final controller = TextEditingController();
    final result = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(action.label),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_actionDescription(action)),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                key: const Key('warehouse-sales-outbound-action-reason'),
                controller: controller,
                minLines: 2,
                maxLines: 4,
                maxLength: 500,
                decoration: const UtenInputDecoration(
                  InputDecoration(labelText: '出库备注(选填)'),
                ),
              ),
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            onPressed: () =>
                Navigator.of(dialogContext).pop(controller.text.trim()),
            child: const Text('确认'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    final rows = [
      if (detail != null)
        for (final line in detail.lines)
          WarehouseSalesOutboundTableRow(detail, line),
    ];
    final actions = detail == null
        ? const <WarehouseSalesOutboundAction>[]
        : WarehouseSalesOutboundAction.values
              .where(detail.header.allows)
              .toList(growable: false);
    return PopScope(
      canPop: !_acting,
      child: Scaffold(
        appBar: UtenAppBar(
          title: '销售出库详情',
          subtitle: '仓库作业视图',
          leading: UtenBackButton(
            onPressed: _acting
                ? null
                : () => popOrBackTo(
                    context,
                    defaultPath: '/warehouse/sales-outbound',
                  ),
          ),
          actions: [
            UtenAppBarActionButton(
              key: const Key('warehouse-sales-outbound-detail-refresh'),
              label: '刷新',
              icon: Icons.refresh_rounded,
              isLoading: _loading && detail != null,
              onPressed: _loading || _acting ? null : _load,
            ),
          ],
        ),
        body: Stack(
          children: [
            SafeArea(
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
                  // 2026-09-11 折叠头+表内滚（对齐采购/货品资料页）：上滑先收头部
                  // （作业状态横幅/错误提示/事实卡），明细标题吸顶后表格内部继续滚。
                  : UtenContentContainer.wide(
                      child: UtenCollapsingHeaderScrollView(
                        collapsingHeader: Padding(
                          padding: const EdgeInsets.only(top: UtenSpacing.s16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _OutboundStatusBanner(detail: detail),
                              if (_error != null) ...[
                                const SizedBox(height: UtenSpacing.s8),
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    _error!,
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.error,
                                    ),
                                  ),
                                ),
                              ],
                              const SizedBox(height: UtenSpacing.s12),
                              _factsCard(detail),
                              const SizedBox(height: UtenSpacing.s16),
                            ],
                          ),
                        ),
                        // body：明细标题（钉住）+ 表格占满内滚（primary 拾取联动控制器）。
                        body: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '出库明细 (${detail.lines.length})',
                              style: Theme.of(context).textTheme.titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: UtenSpacing.s8),
                            Expanded(
                              child:
                                  MasterDataTableView<
                                    WarehouseSalesOutboundTableRow
                                  >(
                                    key: const Key(
                                      'warehouse-sales-outbound-detail-table',
                                    ),
                                    primary: true,
                                    bottomContentPadding:
                                        UtenFloatingActionGroup.scrollClearance,
                                    columns: warehouseSalesOutboundTableColumns(
                                      l10n:
                                          Localizations.of<AppLocalizations>(
                                            context,
                                            AppLocalizations,
                                          ) ??
                                          AppLocalizationsZh(),
                                      rows: rows,
                                      // V631：发出仓按行在表格里选，预填建议仓。
                                      draftOf: (_) => _picking,
                                      onDraftChanged: () => setState(() {}),
                                      stockPlaceControllerOf:
                                          detail.header.allows(
                                            WarehouseSalesOutboundAction
                                                .confirmShipment,
                                          )
                                          ? (row) =>
                                                _picking?.places[row.line.id]
                                          : null,
                                      editingEnabled:
                                          !_acting &&
                                          !_confirming &&
                                          !_needsReview,
                                    ),
                                    items: rows,
                                    rowKeyOf: (row) => row.key,
                                    facets: const {},
                                    nullCounts: const {},
                                    filters: const {},
                                    onFilterChanged: (_, _) {},
                                    emptyMessage: '该任务暂无出库明细',
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
            ),
            // 状态流转网络段的全屏加载遮罩（复核→出库等，含转前一致性检查）。
            if (_acting)
              const UtenBusyOverlay(
                title: '正在提交出库流转',
                description: '正在复核最新状态并写入出库事实，请勿重复提交或离开本页。',
              ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: actions.isEmpty
            ? null
            : UtenFloatingActionGroup(
                children: [
                  for (final action in actions)
                    UtenButton(
                      key: Key(
                        'warehouse-sales-outbound-action-${action.targetStatus}',
                      ),
                      size: UtenButtonSize.large,
                      type: UtenButtonType.danger,
                      icon: _actionIcon(action),
                      isLoading: _acting,
                      onPressed:
                          _acting ||
                              _confirming ||
                              _loading ||
                              _needsReview ||
                              _error != null
                          ? null
                          : () => _runAction(action),
                      child: Text(action.label),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _factsCard(WarehouseSalesOutboundDetail detail) {
    final facts = <(String, String?)>[
      ('出货单号', detail.header.billNo),
      ('业务日期', detail.header.billDate),
      ('客户', detail.header.clientName),
      // V631：表头仓只是默认/主发出仓，实际发出仓按行在表格里选。
      (
        detail.header.allows(WarehouseSalesOutboundAction.confirmShipment)
            ? '默认发出仓'
            : '仓库',
        detail.header.warehouseName,
      ),
      ('收货地址', detail.shipAddress),
      ('联系电话', detail.contactPhone),
      ('物流单号', detail.logisticsNo),
      ('件数', detail.parcelCount?.toString()),
      ('作业状态', detail.header.statusLabel),
      ('出库时间', _wallTime(detail.handedOverAt)),
      ('作业更新', _wallTime(detail.warehouseWorkUpdatedAt)),
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
      WarehouseSalesOutboundAction.confirmShipment =>
        '确认出库会在同一事务里扣减库存、消耗预留、回写订单已发数量并生成应收，'
            '不能撤回。请核对实物后再确认。',
    };

IconData _actionIcon(WarehouseSalesOutboundAction action) => switch (action) {
  WarehouseSalesOutboundAction.confirmShipment => Icons.local_shipping_outlined,
};

bool _present(String? value) => value?.trim().isNotEmpty == true;

/// 服务端给的是 ISO 瞬时(如 2026-09-20T22:19:29.862649Z)，页面按北京时间显示；
/// 解析不了时原样回显而不是隐藏。
String? _wallTime(String? value) => value == null
    ? null
    : ChinaDateTime.formatIsoInstant(value, fallback: value);
