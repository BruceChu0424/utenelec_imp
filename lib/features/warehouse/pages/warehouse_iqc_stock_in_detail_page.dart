import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../models/warehouse_iqc_stock_in.dart';
import '../providers/warehouse_iqc_stock_in_count_provider.dart';
import '../repositories/warehouse_iqc_stock_in_repository.dart';

class WarehouseIqcStockInDetailPage extends ConsumerStatefulWidget {
  const WarehouseIqcStockInDetailPage({
    super.key,
    required this.receiptType,
    required this.receiptId,
  });

  final String receiptType;
  final String receiptId;

  @override
  ConsumerState<WarehouseIqcStockInDetailPage> createState() =>
      _WarehouseIqcStockInDetailPageState();
}

class _WarehouseIqcStockInDetailPageState
    extends ConsumerState<WarehouseIqcStockInDetailPage> {
  final _formKey = GlobalKey<FormState>();
  WarehouseIqcStockInTaskDetail? _detail;
  List<_StockInDraft> _drafts = const [];
  bool _loading = true;
  bool _saving = false;
  String? _loadError;
  String? _submitError;
  String? _conflictMessage;
  int _requestVersion = 0;
  String? _submissionFingerprint;
  String? _submissionKey;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final draft in _drafts) {
      draft.dispose();
    }
    super.dispose();
  }

  bool get _hasLocalConfirmPermission {
    if (ref.read(isSuperAdminProvider)) return true;
    final permissions = ref.read(currentPermissionsProvider);
    return permissions.contains(Perm.warehouseIqcStockInView) &&
        permissions.contains(Perm.warehouseIqcStockInConfirm);
  }

  bool get _canConfirm =>
      _detail?.canConfirm == true && _hasLocalConfirmPermission;

  String get _confirmUnavailableText {
    if (!_hasLocalConfirmPermission) {
      return '当前为只读查看；仓库入库确认同时需要本页查看和确认入库权限。';
    }
    return '服务端当前未开放确认动作；任务状态可能已变化，或命中品质放行与仓库确认职责分离。'
        '请刷新，或由另一名有权限的仓库人员处理。';
  }

  Future<void> _load({
    bool preserveInputs = false,
    String? conflictMessage,
  }) async {
    final version = ++_requestVersion;
    final snapshots = preserveInputs
        ? {for (final draft in _drafts) draft.slice.passEventId: draft.snapshot}
        : const <String, _DraftSnapshot>{};
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final detail = await ref
          .read(warehouseIqcStockInRepositoryProvider)
          .detail(widget.receiptType, widget.receiptId);
      if (!mounted || version != _requestVersion) return;
      final nextDrafts = [
        for (final slice in detail.items)
          _StockInDraft(slice, snapshot: snapshots[slice.passEventId]),
      ];
      final previous = _drafts;
      setState(() {
        _detail = detail;
        _drafts = nextDrafts;
        _loading = false;
        _loadError = null;
        _conflictMessage = conflictMessage;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final draft in previous) {
          draft.dispose();
        }
      });
    } on ApiException catch (error) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _loadError = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _requestVersion) return;
      setState(() {
        _loadError = 'IQC 待入库详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _confirm() async {
    if (_saving || !_canConfirm) return;
    final selected = _drafts.where((draft) => draft.selected).toList();
    if (selected.isEmpty) {
      context.appWarning('请至少选择一条品质放行明细');
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      setState(() => _submitError = '请修正标红的入库数量或实际库位');
      return;
    }
    final items = [
      for (final draft in selected)
        WarehouseIqcStockInConfirmItem(
          passEventId: draft.slice.passEventId,
          baseQty: double.parse(draft.quantity.text.trim()),
          expectedRemainingBaseQty: draft.slice.remainingBaseQty,
          place: draft.place.text.trim(),
        ),
    ];
    final fingerprint = _fingerprint(items);
    if (_submissionFingerprint != fingerprint || _submissionKey == null) {
      _submissionFingerprint = fingerprint;
      _submissionKey = businessIdempotencyKey(
        'warehouse-iqc-stock-in',
        fingerprint,
      );
    }
    final approved = await showUtenReviewerConfirmDialog(
      context,
      title: '确认 IQC 合格品入库',
      actionLabel: '仓库实物入库确认',
      confirmLabel: '确认入库',
      message:
          '本次将确认 ${items.length} 条品质放行切片的实收数量与实际库位。'
          '提交成功后才会增加可用库存并推进对应生产供给；未选择的切片继续留在待入库任务中。',
    );
    if (!approved || !mounted) return;
    setState(() {
      _saving = true;
      _submitError = null;
      _conflictMessage = null;
    });
    try {
      final result = await ref
          .read(warehouseIqcStockInRepositoryProvider)
          .confirm(
            widget.receiptType,
            widget.receiptId,
            WarehouseIqcStockInConfirmCommand(
              idempotencyKey: _submissionKey!,
              items: items,
            ),
          );
      if (!mounted) return;
      _submissionFingerprint = null;
      _submissionKey = null;
      ref.invalidate(warehouseIqcStockInPendingCountProvider);
      context.appSuccess(
        result.replayed
            ? '该入库命令已完成，已安全重放 ${result.confirmedCount} 条结果'
            : '已确认入库 ${result.confirmedCount} 条品质放行明细',
      );
      await _load();
    } on ApiException catch (error) {
      if (!mounted) return;
      if (error.code == 'CONFLICT') {
        final message = '${error.message}；已保留当前输入，请按刷新后的余量重新核对。';
        context.appWarning(message, force: true);
        await _load(preserveInputs: true, conflictMessage: message);
      } else {
        setState(() => _submitError = error.message);
        context.appError(error.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _submitError = '入库确认失败，当前输入已保留，请稍后重试');
        context.appError('入库确认失败，当前输入已保留，请稍后重试');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  String _fingerprint(List<WarehouseIqcStockInConfirmItem> items) {
    final parts = [
      for (final item in items)
        '${item.passEventId}|${item.baseQty}|${item.expectedRemainingBaseQty}|${item.place.trim()}',
    ]..sort();
    return parts.join('||');
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return Scaffold(
      appBar: UtenAppBar(
        title: 'IQC 入库 · ${detail?.billNo ?? widget.receiptId}',
        subtitle: '仓库专属实物详情',
        leading: UtenBackButton(
          onPressed: () =>
              popOrBackTo(context, defaultPath: RouteName.warehouseIqcStockIns),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: UtenSpacing.s8),
            child: UtenButton(
              key: const Key('warehouse-iqc-stock-in-detail-refresh'),
              size: UtenButtonSize.large,
              type: UtenButtonType.tonal,
              icon: Icons.refresh_rounded,
              isLoading: _loading && detail != null,
              onPressed: _loading || _saving
                  ? null
                  : () => _load(preserveInputs: true),
              child: const Text('刷新'),
            ),
          ),
        ],
      ),
      body: SafeArea(child: _body()),
      bottomNavigationBar: detail != null && _canConfirm ? _bottomBar() : null,
    );
  }

  Widget _body() {
    final detail = _detail;
    if (detail == null && _loading) return const UtenSkeletonList();
    if (detail == null) {
      return UtenEmpty.error(
        message: _loadError ?? 'IQC 待入库任务不存在',
        actionLabel: '重新加载',
        onAction: _load,
      );
    }
    return UtenContentContainer.wide(
      child: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(
            0,
            UtenSpacing.s16,
            0,
            UtenSpacing.s24,
          ),
          children: [
            _header(detail),
            const SizedBox(height: UtenSpacing.s12),
            const _StockInEffectBanner(),
            if (_conflictMessage != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              _messagePanel(
                _conflictMessage!,
                icon: Icons.sync_problem_outlined,
                color: Theme.of(context).colorScheme.error,
              ),
            ],
            if (_loadError != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              _messagePanel(
                '刷新失败：$_loadError',
                icon: Icons.error_outline_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
            ],
            if (_submitError != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              _messagePanel(
                _submitError!,
                icon: Icons.error_outline_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
            ],
            if (_loading) ...[
              const SizedBox(height: UtenSpacing.s8),
              const LinearProgressIndicator(),
            ],
            const SizedBox(height: UtenSpacing.s20),
            _sectionTitle(
              detail.completed ? '待入库明细' : '品质放行待入库明细',
              detail.completed
                  ? '当前没有剩余待入库量。'
                  : _canConfirm
                  ? '选择本次要点收的切片；可填写小于剩余量的数量做部分入库。'
                  : _confirmUnavailableText,
            ),
            const SizedBox(height: UtenSpacing.s8),
            if (_drafts.isEmpty)
              UtenEmpty(
                key: const Key('warehouse-iqc-stock-in-completed'),
                icon: Icons.inventory_rounded,
                message: detail.completed ? '当前合格切片已全部完成入库' : '暂无可入库切片',
                description: detail.completed
                    ? detail.qualityStatus == 'IN_PROGRESS'
                          ? '品质检验仍在进行；后续新增 PASS 会再次形成待入库任务。下方保留本次历史。'
                          : '下方保留每次仓库点收的数量、库位、操作人与时间。'
                    : '品质决定可能已撤销，或任务已被其他仓库同事处理。',
              )
            else
              AbsorbPointer(
                absorbing: _saving,
                child: Column(
                  children: [
                    for (final draft in _drafts) ...[
                      _sliceCard(draft),
                      const SizedBox(height: UtenSpacing.s8),
                    ],
                  ],
                ),
              ),
            if (detail.history.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s20),
              _sectionTitle('仓库入库历史', '历史为已落库存事实，只读保留，不可在本页修改。'),
              const SizedBox(height: UtenSpacing.s8),
              for (final item in detail.history) ...[
                _historyCard(item),
                const SizedBox(height: UtenSpacing.s8),
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _header(WarehouseIqcStockInTaskDetail detail) {
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                UtenStatusBadge(
                  label: detail.completed ? '当前合格切片已入库' : '品质已放行 · 待仓库入库',
                  type: detail.completed
                      ? UtenStatusBadgeType.success
                      : UtenStatusBadgeType.warning,
                  icon: detail.completed
                      ? Icons.inventory_rounded
                      : Icons.move_to_inbox_outlined,
                ),
                UtenStatusBadge(
                  label: detail.qualityStatusLabel,
                  type: detail.qualityStatus == 'REVERSED'
                      ? UtenStatusBadgeType.danger
                      : UtenStatusBadgeType.info,
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            Text(
              detail.billNo ?? detail.receiptId,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            LayoutBuilder(
              builder: (context, constraints) {
                final width = constraints.maxWidth >= 900
                    ? (constraints.maxWidth - UtenSpacing.s24) / 3
                    : constraints.maxWidth >= 560
                    ? (constraints.maxWidth - UtenSpacing.s12) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: UtenSpacing.s12,
                  runSpacing: UtenSpacing.s12,
                  children: [
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '来源类型',
                        value: detail.receiptType.label,
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '收货日期',
                        value: detail.billDate ?? '—',
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '供应商 / 委外商',
                        value: detail.supplierName ?? '—',
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '本次入库仓库',
                        value: detail.warehouseName ?? '—',
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: _InfoTile(
                        label: '剩余品质放行切片',
                        value: '${detail.pendingSliceCount} 个',
                      ),
                    ),
                    SizedBox(
                      width: width,
                      child: const _InfoTile(label: '商业字段', value: '本仓库页面不提供'),
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

  Widget _sliceCard(_StockInDraft draft) {
    final slice = draft.slice;
    final theme = Theme.of(context);
    return Card(
      key: ValueKey('warehouse-iqc-stock-in-slice-${slice.passEventId}'),
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (_canConfirm)
                  Semantics(
                    label: '选择 ${slice.goodsLabel} 本次入库',
                    checked: draft.selected,
                    child: Checkbox(
                      key: ValueKey(
                        'warehouse-iqc-stock-in-select-${slice.passEventId}',
                      ),
                      value: draft.selected,
                      onChanged: _saving
                          ? null
                          : (value) =>
                                setState(() => draft.selected = value ?? false),
                    ),
                  )
                else
                  Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s8),
                    child: Icon(
                      Icons.inventory_2_outlined,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        slice.goodsLabel.isEmpty ? '未命名货品' : slice.goodsLabel,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        [
                          if (slice.sourceOrderNo?.isNotEmpty == true)
                            '来源订货单 ${slice.sourceOrderNo}',
                          if (slice.releasedBy?.isNotEmpty == true)
                            '品质放行人 ${slice.releasedBy}',
                          if (slice.releasedAt?.isNotEmpty == true)
                            '放行时间 ${_dateTime(slice.releasedAt)}',
                        ].join(' · '),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                UtenStatusBadge(
                  label:
                      '待入库 ${_quantity(slice.remainingBaseQty)}'
                      '${slice.unitName == null ? '' : ' ${slice.unitName}'}',
                  type: UtenStatusBadgeType.warning,
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            Wrap(
              spacing: UtenSpacing.s16,
              runSpacing: UtenSpacing.s8,
              children: [
                _metric('本次品质放行', slice.releasedBaseQty, slice.unitName),
                _metric(
                  '本放行批次已入库',
                  slice.stockedForReleaseBaseQty,
                  slice.unitName,
                ),
                _metric('累计品质合格', slice.qualityPassedBaseQty, slice.unitName),
                _metric(
                  '累计仓库已入库',
                  slice.warehouseStockedBaseQty,
                  slice.unitName,
                ),
                if (slice.releasedWeight != null)
                  Text(
                    '放行重量 ${_quantity(slice.releasedWeight!)}'
                    '${slice.weightUnitName == null ? '' : ' ${slice.weightUnitName}'}',
                  ),
              ],
            ),
            if (slice.releaseNote?.isNotEmpty == true) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '品质说明：${slice.releaseNote}',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: UtenSpacing.s12),
            if (_canConfirm)
              _stockInFields(draft)
            else
              _InfoTile(
                label: '建议库位',
                value: slice.placeHint ?? '未维护；执行人员确认时必须填写实际库位',
              ),
          ],
        ),
      ),
    );
  }

  Widget _stockInFields(_StockInDraft draft) {
    final slice = draft.slice;
    return LayoutBuilder(
      builder: (context, constraints) {
        final quantity = TextFormField(
          key: ValueKey('warehouse-iqc-stock-in-qty-${slice.passEventId}'),
          controller: draft.quantity,
          enabled: draft.selected && !_saving,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [LengthLimitingTextInputFormatter(24)],
          decoration: InputDecoration(
            labelText: '本次实收入库数量 *',
            helperText: '可小于剩余量，余量继续保留为待入库任务',
            suffixText: slice.unitName,
          ),
          validator: (value) => _quantityError(draft, value),
          onChanged: (_) => setState(() => _submitError = null),
        );
        final place = TextFormField(
          key: ValueKey('warehouse-iqc-stock-in-place-${slice.passEventId}'),
          controller: draft.place,
          enabled: draft.selected && !_saving,
          maxLength: 100,
          decoration: InputDecoration(
            labelText: '本次实际库位 *',
            helperText: slice.placeHint?.isNotEmpty == true
                ? '已按货品主档建议“${slice.placeHint}”预填，请按实物确认'
                : '必须填写本次真实上架库位；不是货品主档备注',
          ),
          validator: (value) => _placeError(draft, value),
          onChanged: (_) => setState(() => _submitError = null),
        );
        if (constraints.maxWidth < 720) {
          return Column(
            children: [
              quantity,
              const SizedBox(height: UtenSpacing.s8),
              place,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: quantity),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(child: place),
          ],
        );
      },
    );
  }

  String? _quantityError(_StockInDraft draft, String? value) {
    if (!draft.selected) return null;
    final quantity = double.tryParse(value?.trim() ?? '');
    if (quantity == null || quantity <= 0) return '请输入大于 0 的本次实收数量';
    if (quantity - draft.slice.remainingBaseQty > 0.0000001) {
      return '不得超过刷新后的待入库余量 ${_quantity(draft.slice.remainingBaseQty)}';
    }
    return null;
  }

  String? _placeError(_StockInDraft draft, String? value) {
    if (!draft.selected) return null;
    if (value?.trim().isEmpty != false) return '请填写本次真实库位';
    return null;
  }

  Widget _historyCard(WarehouseIqcStockInHistoryItem item) {
    final theme = Theme.of(context);
    return Card(
      key: ValueKey('warehouse-iqc-stock-in-history-${item.stockInItemId}'),
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              item.goodsLabel.isEmpty ? '未命名货品' : item.goodsLabel,
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Wrap(
              spacing: UtenSpacing.s16,
              runSpacing: UtenSpacing.s8,
              children: [
                Text(
                  '入库数量 ${_quantity(item.baseQty)}'
                  '${item.unitName == null ? '' : ' ${item.unitName}'}',
                ),
                Text('实际库位 ${item.place}'),
                if (item.weight != null)
                  Text(
                    '分配重量 ${_quantity(item.weight!)}'
                    '${item.weightUnitName == null ? '' : ' ${item.weightUnitName}'}',
                  ),
                Text('确认人 ${item.confirmedBy ?? '—'}'),
                Text('确认时间 ${_dateTime(item.confirmedAt)}'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomBar() {
    final selected = _drafts.where((draft) => draft.selected).length;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: UtenSpacing.s16,
          vertical: UtenSpacing.s12,
        ),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.surface,
          border: Border(
            top: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final summary = Text(
              selected == 0 ? '请选择本次要点收的明细' : '已选择 $selected 条品质放行明细',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            );
            final action = UtenButton(
              key: const Key('warehouse-iqc-stock-in-confirm'),
              size: UtenButtonSize.large,
              icon: Icons.inventory_rounded,
              isLoading: _saving,
              onPressed: _saving || selected == 0 ? null : _confirm,
              child: Text(selected == 0 ? '确认入库' : '确认入库($selected)'),
            );
            if (constraints.maxWidth < 560) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  summary,
                  const SizedBox(height: UtenSpacing.s8),
                  action,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: summary),
                action,
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _messagePanel(
    String message, {
    required IconData icon,
    required Color color,
  }) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.08),
          borderRadius: UtenRadius.mdAll,
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(child: Text(message)),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(String title, String description) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Text(
          description,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Widget _metric(String label, double value, String? unit) {
    return Text('$label ${_quantity(value)}${unit == null ? '' : ' $unit'}');
  }
}

class _StockInEffectBanner extends StatelessWidget {
  const _StockInEffectBanner();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.55),
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: theme.colorScheme.onTertiaryContainer,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '品质 PASS/PARTIAL 只证明该切片可以办理入库，不代表库存已经增加。'
              '仓库必须按实物填写本次数量与实际库位；确认成功后才写库存流水。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onTertiaryContainer,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _InfoTile extends StatelessWidget {
  const _InfoTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: UtenSpacing.s4),
        Text(value, style: theme.textTheme.bodyMedium),
      ],
    );
  }
}

class _StockInDraft {
  _StockInDraft(this.slice, {_DraftSnapshot? snapshot})
    : selected = snapshot?.selected ?? true,
      quantity = TextEditingController(
        text: snapshot?.quantity ?? _quantity(slice.remainingBaseQty),
      ),
      place = TextEditingController(
        text: snapshot?.place ?? slice.placeHint ?? '',
      );

  final WarehouseIqcStockInReleasedSlice slice;
  bool selected;
  final TextEditingController quantity;
  final TextEditingController place;

  _DraftSnapshot get snapshot => _DraftSnapshot(
    selected: selected,
    quantity: quantity.text,
    place: place.text,
  );

  void dispose() {
    quantity.dispose();
    place.dispose();
  }
}

class _DraftSnapshot {
  const _DraftSnapshot({
    required this.selected,
    required this.quantity,
    required this.place,
  });

  final bool selected;
  final String quantity;
  final String place;
}

String _quantity(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

String _dateTime(String? value) {
  final text = value?.trim();
  if (text == null || text.isEmpty) return '—';
  final normalized = text.replaceFirst('T', ' ');
  return normalized.length > 16 ? normalized.substring(0, 16) : normalized;
}
