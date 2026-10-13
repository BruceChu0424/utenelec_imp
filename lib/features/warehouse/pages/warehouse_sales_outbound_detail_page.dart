import 'package:flutter/material.dart';
import '../../../components/feedback/uten_dialog.dart';
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
import '../../../shared/measurement/weight_params.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/measurement/widgets/weight_params_load_notice.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/widgets/weight_grid_column.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/outbound_weight_entry.dart';
import '../models/warehouse_sales_outbound.dart';
import '../repositories/warehouse_sales_outbound_repository.dart';
import '../providers/warehouse_count_refresh.dart';
import '../widgets/outbound_weight_columns.dart';
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
    extends ConsumerState<WarehouseSalesOutboundDetailPage>
    with FormDraftMixin<WarehouseSalesOutboundDetailPage> {
  @override
  bool get formDraftBusy => _acting || _confirming || _loading;
  @override
  Future<void> Function()? get formDraftReloadSource => () async {
    await _load(preserveInputs: false);
    if (_error != null) throw StateError(_error!);
  };
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.warehouseSalesOutbound
      .spec(route: '/warehouse/sales-outbound/${widget.id}');
  @override
  Iterable<Listenable> get formDraftListenables =>
      _picking?.inputListenables ?? [];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'shipmentId': widget.id,
    'input': _picking?.captureInput(),
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['shipmentId'] != widget.id) {
      throw const FormatException('出库草稿不属于当前任务');
    }
    if (_detail?.header.warehouseWorkStatus ==
        WarehouseSalesOutboundStatus.shipped) {
      _restoredShipped = true;
      return;
    }
    final input = data['input'];
    if (input is! Map) throw const FormatException('出库草稿缺少明细');
    _picking!.restoreInput(Map<String, dynamic>.from(input));
  }

  @override
  Widget? get formDraftSubmissionRecoveryAction => UtenButton(
    icon: Icons.refresh_rounded,
    onPressed: _acting || _loading ? null : _verifySubmission,
    child: const Text('核对出库结果'),
  );

  Future<void> _verifySubmission() async {
    try {
      final latest = await ref
          .read(warehouseSalesOutboundRepositoryProvider)
          .detail(widget.id);
      if (!formDraftIdentityIsCurrent) return;
      if (latest.header.warehouseWorkStatus ==
          WarehouseSalesOutboundStatus.shipped) {
        await completeFormDraft();
        if (mounted) setState(() => _replaceDetail(latest));
        invalidateWarehouseTaskCounts(ref);
        if (mounted) context.appSuccess('已核对：这张任务已出库');
      } else if (mounted) {
        context.appWarning('尚未查到已出库结果，原输入继续保留，请稍后再次核对');
      }
    } catch (error) {
      if (mounted) {
        context.appError(describeSubmitError(error, fallback: '核对出库结果失败'));
      }
    }
  }

  WarehouseSalesOutboundDetail? _detail;
  bool _loading = false;
  bool _acting = false;
  bool _confirming = false;
  bool _needsReview = false;
  String? _error;
  int _requestVersion = 0;
  WarehouseSalesPickingDraft? _picking;
  bool _restoredShipped = false;

  /// 本次 build 盯住的页内单重参数缓存 (待出库且行带货品时才建)。
  WeightParamsCache? _weightCache;

  @override
  void dispose() {
    _picking?.dispose();
    super.dispose();
  }

  void _replaceDetail(
    WarehouseSalesOutboundDetail detail, {
    bool preserveInput = false,
  }) {
    final previous =
        preserveInput &&
            _picking?.detail.header.warehouseWorkStatus ==
                WarehouseSalesOutboundStatus.pendingPick
        ? _picking!.captureInput()
        : null;
    final next = WarehouseSalesPickingDraft(
      detail,
      weightUnit: ref.read(warehouseWeightUnitsPrefsProvider).entry,
    );
    try {
      if (previous != null &&
          detail.header.warehouseWorkStatus ==
              WarehouseSalesOutboundStatus.pendingPick) {
        next.restoreInput(previous);
      }
    } catch (_) {
      next.dispose();
      rethrow;
    }
    _picking?.dispose();
    _detail = detail;
    _picking = next;
    // 缓存在 build 里按需盯住: 下一帧再按行批量取单重参数。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        ensureOutboundWeightParams(
          _weightCache,
          _picking?.weights.values ?? const <OutboundWeightEntry>[],
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load({bool preserveInputs = true}) async {
    final version = ++_requestVersion;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(warehouseSalesOutboundRepositoryProvider)
          .detail(widget.id);
      if (!mounted ||
          !formDraftIdentityIsCurrent ||
          version != _requestVersion) {
        return;
      }
      setState(() {
        _replaceDetail(detail, preserveInput: preserveInputs);
        _loading = false;
        _needsReview = false;
      });
      await initializeFormDraft();
      if (_restoredShipped) {
        _restoredShipped = false;
        await resetFormDraftAfterSubmission();
      }
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _error = error is FormatException
            ? error.message
            : '销售出库详情加载失败，请检查网络后重试';
        _needsReview = _detail != null;
        _loading = false;
      });
      if (error is FormatException) holdFormDraftForSourceReload(error);
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
      final reason = await _confirmAction(
        action,
        weightAlerts: [
          for (final alert
              in _picking?.weightAlerts(_weightCache) ??
                  const <
                    ({WarehouseSalesOutboundLine line, WeightCheck check})
                  >[])
            warehouseSalesWeightAlertText(alert.line, alert.check),
        ],
      );
      if (reason == null || !mounted) return;
      setState(() {
        _confirming = false;
        _acting = true;
      });
      final repository = ref.read(warehouseSalesOutboundRepositoryProvider);
      final latest = await repository.detail(widget.id);
      if (!mounted || !formDraftIdentityIsCurrent) return;
      if (warehouseSalesOutboundReviewSnapshot(latest) !=
              warehouseSalesOutboundReviewSnapshot(reviewed) ||
          !latest.header.allows(action)) {
        setState(() {
          _replaceDetail(latest, preserveInput: true);
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
      final updated = await runFormDraftSubmission(
        () => ref
            .read(warehouseSalesOutboundRepositoryProvider)
            .transition(
              widget.id,
              targetStatus: action.targetStatus,
              reason: reason,
              stockPlaces: _picking?.stockPlaces,
              lineWarehouses: _picking?.lineWarehouses,
              lineWeights: _picking?.lineWeights,
            ),
      );
      if (!mounted || !formDraftIdentityIsCurrent) return;
      if (updated.header.id != widget.id ||
          updated.header.warehouseWorkStatus != action.targetStatus) {
        throw const FormatException();
      }
      await completeFormDraft();
      if (!mounted) return;
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
    } catch (error) {
      if (mounted) {
        setState(() {
          _needsReview = true;
          _error = describeSubmitError(
            error,
            fallback:
                (Localizations.of<AppLocalizations>(
                          context,
                          AppLocalizations,
                        ) ??
                        AppLocalizationsZh())
                    .warehouseOutboundBatchUnknown,
          );
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
  /// [weightAlerts] 为称重明显偏离应发数量的行 (只提醒复核, 不拦截)。
  Future<String?> _confirmAction(
    WarehouseSalesOutboundAction action, {
    List<String> weightAlerts = const [],
  }) async {
    final controller = TextEditingController();
    final result = await UtenDialog.showAndWaitForExit<String?>(
      context,
      builder: (dialogContext) => UtenAlertDialog(
        title: Text(action.label),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(_actionDescription(action)),
              if (warehouseSalesWeightAlertNotice(dialogContext, weightAlerts)
                  case final notice?) ...[
                const SizedBox(height: UtenSpacing.s12),
                notice,
              ],
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
    final weightUnits = ref.watch(warehouseWeightUnitsPrefsProvider);
    final weightEntries =
        _picking?.weights.values.toList() ?? const <OutboundWeightEntry>[];
    // 待出库且行带货品时才盯住页内单重参数缓存 (离开页面随之释放)。
    _weightCache = weightEntries.any((entry) => entry.paramsLine != null)
        ? ref.watch(weightParamsCacheProvider)
        : null;
    final actions = detail == null
        ? const <WarehouseSalesOutboundAction>[]
        : WarehouseSalesOutboundAction.values
              .where(detail.header.allows)
              .toList(growable: false);
    return withFormDraft(
      PopScope(
        canPop: !_acting,
        child: Scaffold(
          appBar: UtenAppBar(
            title: '销售出库详情',
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
                            padding: const EdgeInsets.only(
                              top: UtenSpacing.s16,
                            ),
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
                                WeightParamsLoadNotice(cache: _weightCache),
                              ],
                            ),
                          ),
                          // body：明细表占满内滚（primary 拾取联动控制器）。
                          body: MasterDataTableView<WarehouseSalesOutboundTableRow>(
                            tableKey:
                                'features.warehouse.pages.warehouse_sales_outbound_detail_page.WarehouseSalesOutboundDetailPageState.build.1',
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
                              onDraftChanged: () {
                                setState(() {});
                                ensureOutboundWeightParams(
                                  _weightCache,
                                  _picking?.weights.values ??
                                      const <OutboundWeightEntry>[],
                                );
                              },
                              stockPlaceControllerOf:
                                  detail.header.allows(
                                    WarehouseSalesOutboundAction
                                        .confirmShipment,
                                  )
                                  ? (row) => _picking?.places[row.line.id]
                                  : null,
                              editingEnabled:
                                  !_acting && !_confirming && !_needsReview,
                              weightParams: _weightCache,
                              weightEntryUnit: weightUnits.entry,
                            ),
                            toolbarActions: weightEntries.isEmpty
                                ? null
                                : const [WeightEntryUnitButton()],
                            summaryBar: weightEntries.isEmpty
                                ? null
                                : OutboundWeightSummaryBar(
                                    entries: weightEntries,
                                    params: _weightCache,
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
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
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
        '确认出库会一起完成：扣库存、释放预留、更新订单已发数量并生成应收，'
            '确认后不能撤回。请核对实物后再确认。',
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
