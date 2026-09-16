import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_form_grid.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../warehouse/models/stock_doc.dart';
import '../../warehouse/providers/warehouse_count_refresh.dart';
import '../models/production_draw_request.dart';
import '../models/production_execution_batch.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_execution_batch_repository.dart';

/// Split a complete, immediately producible batch from an unstarted waiting task.
class ProductionExecutionBatchPage extends ConsumerStatefulWidget {
  const ProductionExecutionBatchPage({
    super.key,
    required this.segmentId,
    this.expectedVersion,
  });
  final String segmentId;
  final int? expectedVersion;

  @override
  ConsumerState<ProductionExecutionBatchPage> createState() =>
      _ProductionExecutionBatchPageState();
}

class _ProductionExecutionBatchPageState
    extends ConsumerState<ProductionExecutionBatchPage> {
  final _quantity = TextEditingController();
  ProductionExecutionBatchPreview? _preview;
  String? _error;
  String? _quantityError;
  String? _submitError;
  String? _requestKey;
  bool _loading = true;
  bool _saving = false;
  bool _uncertain = false;
  bool _needsPreview = false;

  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(context, AppLocalizations) ??
      AppLocalizationsZh();

  bool get _reusesIssuedMaterial =>
      _preview != null && _preview!.quantity > 0 && _preview!.summaries.isEmpty;

  bool get _allowed {
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.productionExecutionView) &&
        permissions.contains(Perm.productionExecutionStart);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load(initial: true));
  }

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  Future<void> _load({bool initial = false, bool useQuantity = false}) async {
    if (!mounted || _saving || _uncertain || (_loading && !initial)) return;
    double? quantity;
    if (useQuantity) {
      quantity = double.tryParse(_quantity.text.trim());
      if (quantity == null ||
          !quantity.isFinite ||
          quantity <= 0 ||
          !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(_quantity.text.trim())) {
        setState(() => _quantityError = l10n.productionBatchInvalidQuantity);
        return;
      }
      if (_preview != null && quantity > _preview!.maxReadyQty) {
        setState(
          () => _quantityError = l10n.productionBatchQuantityHint(
            _number(_preview!.maxReadyQty),
            _preview!.productUnitName ?? l10n.productionBatchUnitUnknown,
          ),
        );
        return;
      }
    }
    setState(() {
      _loading = true;
      _error = null;
      _quantityError = null;
      _submitError = null;
    });
    try {
      if (!_allowed) throw FormatException(l10n.productionBatchPermission);
      if (widget.segmentId.trim().isEmpty) {
        throw FormatException(l10n.productionBatchSelectTask);
      }
      final preview = await ref
          .read(productionExecutionBatchRepositoryProvider)
          .preview(
            segmentId: widget.segmentId,
            expectedVersion: initial ? widget.expectedVersion : null,
            quantity: quantity,
          );
      if (!mounted) return;
      setState(() {
        _preview = preview;
        _quantity.text = _number(preview.quantity);
        _needsPreview = false;
        _requestKey = null;
      });
    } on ApiException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          _needsPreview = true;
        });
      }
    } on FormatException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) setState(() => _error = l10n.productionBatchPreviewFailed);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  bool get _canSubmit =>
      _allowed &&
      !_loading &&
      !_saving &&
      !_needsPreview &&
      _quantityError == null &&
      _error == null &&
      _preview != null &&
      _preview!.quantity > 0 &&
      _preview!.quantity <= _preview!.maxReadyQty &&
      _preview!.fingerprint.isNotEmpty;

  Future<void> _submit() async {
    if (!_canSubmit) return;
    final preview = _preview!;
    _requestKey ??= const Uuid().v4();
    setState(() {
      _saving = true;
      _submitError = null;
    });
    try {
      final result = await ref
          .read(productionExecutionBatchRepositoryProvider)
          .submit(preview: preview, idempotencyKey: _requestKey!);
      if (!mounted) return;
      refreshAfterProductionPlanGenerated(ref);
      invalidateWarehouseTaskCounts(ref);
      bumpListRefresh(ref, StockDocType.draw.refreshKey);
      context.appSuccess(
        result.replayed
            ? l10n.productionBatchReplay
            : result.documentIds.isEmpty
            ? l10n.productionBatchSubmittedReuse(
                _number(preview.quantity),
                preview.productUnitName ?? '',
              )
            : l10n.productionBatchSubmitted(
                _number(preview.quantity),
                preview.productUnitName ?? '',
                _number(preview.remainingQty),
              ),
      );
      if (context.canPop()) {
        context.pop(true);
      } else {
        context.go(RouteName.productionWorkshopTasks);
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      final uncertain =
          error is NetworkException ||
          error is NetworkTimeoutException ||
          error.code == 'INTERNAL' ||
          (error.httpStatus ?? 0) >= 500;
      setState(() {
        _uncertain = uncertain;
        _needsPreview = !uncertain;
        _submitError = uncertain
            ? l10n.productionBatchUncertain(
                _reusesIssuedMaterial
                    ? l10n.productionBatchRetryArrange
                    : l10n.productionBatchRetryRequest,
              )
            : l10n.productionBatchRejected(error.message);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _uncertain = true;
          _submitError = l10n.productionBatchUncertain(
            _reusesIssuedMaterial
                ? l10n.productionBatchRetryArrange
                : l10n.productionBatchRetryRequest,
          );
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _back() =>
      popOrBackTo(context, defaultPath: RouteName.productionWorkshopTasks);

  @override
  Widget build(BuildContext context) {
    ref.watch(currentPermissionsProvider);
    ref.watch(isSuperAdminProvider);
    final preview = _preview;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: UtenAppBar(
          title: l10n.productionBatchTitle,
          leading: UtenBackButton(onPressed: _saving ? null : _back),
        ),
        body: SafeArea(
          child: Stack(
            children: [
              UtenContentContainer.wide(
                child: !_allowed
                    ? UtenEmpty(message: l10n.productionBatchPermission)
                    : _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _error != null
                    ? UtenEmpty.error(
                        message: _error,
                        actionLabel: l10n.productionBatchReview,
                        onAction: () => _load(),
                      )
                    : preview == null
                    ? UtenEmpty(message: l10n.productionBatchSelectTask)
                    : UtenCollapsingHeaderScrollView(
                        collapsingHeader: _header(preview),
                        body: _materials(preview),
                      ),
              ),
              if (_saving)
                Positioned.fill(
                  child: UtenBusyOverlay(
                    title: l10n.productionBatchSubmitting,
                    description: l10n.productionBatchSubmittingHint,
                  ),
                ),
            ],
          ),
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        // 2026-09-14 UI 统一口径：紧凑视口同样用右下悬浮组（不再吸底条）。
        floatingActionButton: _actions(),
      ),
    );
  }

  Widget _actions() => UtenFloatingActionGroup(
    children: [
      UtenButton(
        type: UtenButtonType.secondary,
        size: UtenButtonSize.large,
        onPressed: _saving ? null : _back,
        child: Text(l10n.commonBack),
      ),
      if (_allowed)
        UtenButton(
          key: const Key('execution-batch-submit'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          icon: Icons.move_to_inbox_rounded,
          isLoading: _saving,
          onPressed: _canSubmit ? _submit : null,
          child: Text(
            _uncertain
                ? _reusesIssuedMaterial
                      ? l10n.productionBatchRetryArrange
                      : l10n.productionBatchRetryRequest
                : _reusesIssuedMaterial
                ? l10n.productionBatchConfirmArrange
                : l10n.productionBatchConfirmRequest,
          ),
        ),
    ],
  );

  Widget _header(ProductionExecutionBatchPreview preview) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final unit = preview.productUnitName ?? l10n.productionBatchUnitUnknown;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s12,
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s12,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenCard(
            key: const Key('execution-batch-task-card'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      decoration: BoxDecoration(
                        color: colors.primaryContainer,
                        borderRadius: UtenRadius.mdAll,
                      ),
                      child: Icon(
                        Icons.precision_manufacturing_outlined,
                        color: colors.onPrimaryContainer,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            preview.productName ??
                                preview.productCode ??
                                l10n.productionBatchProductFallback,
                            style: theme.textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (preview.productCode?.isNotEmpty == true) ...[
                            const SizedBox(height: UtenSpacing.s4),
                            Text(
                              preview.productCode!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colors.onSurfaceVariant,
                              ),
                            ),
                          ],
                          const SizedBox(height: UtenSpacing.s8),
                          Wrap(
                            spacing: UtenSpacing.s16,
                            runSpacing: UtenSpacing.s4,
                            children: [
                              _identity(
                                l10n.productionBatchPlan,
                                preview.planNo,
                                Icons.assignment_outlined,
                              ),
                              _identity(
                                l10n.productionBatchWorkOrder,
                                preview.segmentCode,
                                Icons.work_outline_rounded,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          LayoutBuilder(
            builder: (context, constraints) => UtenFormGrid(
              columns: constraints.maxWidth >= 1050 ? 4 : 2,
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                _metric(
                  'original',
                  l10n.productionBatchOriginal,
                  preview.originalQty,
                  unit,
                  l10n.productionBatchOriginalHint,
                  colors.onSurface,
                  colors.surface,
                ),
                _metric(
                  'ready',
                  l10n.productionBatchReady,
                  preview.maxReadyQty,
                  unit,
                  l10n.productionBatchReadyHint,
                  preview.maxReadyQty > 0 ? colors.primary : colors.error,
                  preview.maxReadyQty > 0
                      ? colors.primaryContainer.withValues(alpha: 0.25)
                      : colors.errorContainer.withValues(alpha: 0.3),
                ),
                _metric(
                  'selected',
                  l10n.productionBatchSelected,
                  preview.quantity,
                  unit,
                  _needsPreview
                      ? l10n.productionBatchNeedsReview
                      : l10n.productionBatchSelectedHint,
                  colors.error,
                  colors.errorContainer.withValues(alpha: 0.35),
                  emphasized: true,
                ),
                _metric(
                  'remaining',
                  l10n.productionBatchRemaining,
                  preview.remainingQty,
                  unit,
                  l10n.productionBatchRemainingHint,
                  colors.onSurface,
                  colors.surface,
                ),
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenCard(
            key: const Key('execution-batch-quantity-card'),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  spacing: UtenSpacing.s12,
                  runSpacing: UtenSpacing.s8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      l10n.productionBatchSetup,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    UtenStatusBadge(
                      key: const Key('execution-batch-review-state'),
                      label: _needsPreview
                          ? l10n.productionBatchNeedsReview
                          : preview.maxReadyQty <= 0
                          ? l10n.productionBatchNoKit
                          : l10n.productionBatchReviewReady,
                      type: _needsPreview || preview.maxReadyQty <= 0
                          ? UtenStatusBadgeType.danger
                          : UtenStatusBadgeType.success,
                      icon: _needsPreview || preview.maxReadyQty <= 0
                          ? Icons.error_outline
                          : Icons.check_circle_outline,
                    ),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final input = TextField(
                      key: const Key('execution-batch-quantity'),
                      controller: _quantity,
                      enabled:
                          !_saving && !_uncertain && preview.maxReadyQty > 0,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colors.error,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: UtenInputDecoration(
                        InputDecoration(
                          labelText: l10n.productionBatchQuantity,
                          suffixText: unit,
                          error: _quantityError == null
                              ? null
                              : UtenFieldMessage.error(_quantityError!),
                        ),
                        info: l10n.productionBatchQuantityHint(
                          _number(preview.maxReadyQty),
                          unit,
                        ),
                      ),
                      onChanged: (_) => setState(() {
                        _needsPreview = true;
                        _quantityError = null;
                      }),
                    );
                    final review = UtenButton(
                      key: const Key('execution-batch-preview'),
                      type: _needsPreview
                          ? UtenButtonType.danger
                          : UtenButtonType.secondary,
                      icon: Icons.refresh_rounded,
                      size: UtenButtonSize.large,
                      onPressed: _saving || _uncertain
                          ? null
                          : () => _load(useQuantity: preview.maxReadyQty > 0),
                      child: Text(l10n.productionBatchReview),
                    );
                    if (constraints.maxWidth < 620) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          input,
                          const SizedBox(height: UtenSpacing.s12),
                          review,
                        ],
                      );
                    }
                    return Row(
                      children: [
                        Expanded(child: input),
                        const SizedBox(width: UtenSpacing.s16),
                        review,
                      ],
                    );
                  },
                ),
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  preview.remainingQty > 0
                      ? l10n.productionBatchRemainingText(
                          _number(preview.remainingQty),
                          unit,
                        )
                      : l10n.productionBatchAllRemaining,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
                _notice(
                  _needsPreview
                      ? l10n.productionBatchNeedsReviewHint
                      : preview.maxReadyQty <= 0
                      ? l10n.productionBatchNoKitHint
                      : _reusesIssuedMaterial
                      ? l10n.productionBatchReuseHint
                      : l10n.productionBatchFlow,
                  alert: _needsPreview || preview.maxReadyQty <= 0,
                  icon: _reusesIssuedMaterial
                      ? Icons.recycling_rounded
                      : Icons.info_outline_rounded,
                ),
                if (_submitError != null) ...[
                  const SizedBox(height: UtenSpacing.s8),
                  _notice(
                    _submitError!,
                    alert: true,
                    icon: Icons.error_outline_rounded,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _identity(String label, String? value, IconData icon) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Icon(
        icon,
        size: 16,
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
      const SizedBox(width: UtenSpacing.s4),
      Flexible(
        child: Text(
          '$label: ${value?.isNotEmpty == true ? value : '—'}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    ],
  );

  Widget _metric(
    String name,
    String label,
    double value,
    String unit,
    String hint,
    Color foreground,
    Color background, {
    bool emphasized = false,
  }) {
    final theme = Theme.of(context);
    return Container(
      key: Key('execution-batch-$name'),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: background,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(
          color: emphasized
              ? foreground.withValues(alpha: 0.45)
              : theme.colorScheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: emphasized
                  ? foreground
                  : theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: UtenSpacing.s8),
          SizedBox(
            width: double.infinity,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                _number(value),
                key: Key('execution-batch-$name-value'),
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: foreground,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          Text(
            unit,
            style: theme.textTheme.labelSmall?.copyWith(color: foreground),
          ),
          const SizedBox(height: UtenSpacing.s8),
          Text(
            hint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(
    String message, {
    required bool alert,
    required IconData icon,
  }) {
    final colors = Theme.of(context).colorScheme;
    final color = alert ? colors.error : colors.primary;
    return Semantics(
      liveRegion: true,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: (alert ? colors.errorContainer : colors.primaryContainer)
              .withValues(alpha: 0.3),
          borderRadius: UtenRadius.mdAll,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: Text(
                message,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: alert ? colors.error : colors.onSurface,
                  height: 1.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _materials(ProductionExecutionBatchPreview preview) {
    final theme = Theme.of(context);
    final compact =
        MediaQuery.sizeOf(context).width < UtenBreakpoints.mediumStart;
    final warehouses = preview.summaries
        .map((row) => row.warehouseId)
        .toSet()
        .length;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            spacing: UtenSpacing.s12,
            runSpacing: UtenSpacing.s4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                l10n.productionBatchMaterials,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                l10n.productionBatchMaterialCount(
                  preview.summaries.length,
                  warehouses,
                ),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s8),
          Expanded(
            child: MasterDataTableView<ProductionDrawRequestSummary>(
              key: const Key('execution-batch-material-table'),
              primary: true,
              columns: [
                // 2026-09-14 用户口径（全站表格统一）：名称 → 编号 → 颜色 紧邻排布，
                // 紧凑/非紧凑两种模式同序（不再把编号挪到数量之后）。
                MasterColumnDef(
                  key: 'name',
                  label: l10n.productionBatchGoodsName,
                  width: compact ? 160 : 240,
                  value: (row) => row.goodsName,
                ),
                MasterColumnDef(
                  key: 'code',
                  label: l10n.productionBatchGoodsCode,
                  width: 130,
                  value: (row) => row.goodsCode,
                ),
                MasterColumnDef(
                  key: 'color',
                  label: l10n.productionBatchColor,
                  width: 110,
                  value: (row) => row.colorName,
                ),
                MasterColumnDef(
                  key: 'qty',
                  label: l10n.productionBatchMaterialQuantity,
                  width: 165,
                  info: l10n.productionBatchMaterialQuantityHint,
                  type: 'number',
                  value: (row) => _number(row.qty),
                  cellColor: (context, _) => Theme.of(
                    context,
                  ).colorScheme.errorContainer.withValues(alpha: 0.25),
                  cellBuilder: (context, row) {
                    final quantity = Text(
                      _number(row.qty),
                      textAlign: TextAlign.right,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: Theme.of(context).colorScheme.error,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    );
                    if (!compact) return quantity;
                    return FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          quantity,
                          const SizedBox(width: UtenSpacing.s4),
                          Text(
                            row.unitName ?? '—',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                if (!compact)
                  MasterColumnDef(
                    key: 'unit',
                    label: l10n.productionBatchUnit,
                    width: 100,
                    value: (row) => row.unitName,
                  ),
                MasterColumnDef(
                  key: 'warehouse',
                  label: l10n.productionBatchWarehouse,
                  width: 190,
                  value: (row) => row.warehouseName,
                ),
              ],
              items: preview.summaries,
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
              rowKeyOf: (row) =>
                  '${row.warehouseId}:${row.goodsId}:${row.colorId}:${row.unitId}',
              emptyMessage: preview.maxReadyQty <= 0
                  ? l10n.productionBatchNoKitHint
                  : l10n.productionBatchNoAdditionalMaterials,
              // 右下悬浮操作组让位（紧凑视口同样走悬浮组）。
              bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
            ),
          ),
        ],
      ),
    );
  }
}

String _number(double value) =>
    value.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
