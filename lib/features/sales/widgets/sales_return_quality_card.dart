import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../components/inputs/uten_field_message.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/sales_return_quality.dart';
import '../providers/master_name_provider.dart';
import '../repositories/sales_return_quality_repository.dart';

/// 已审销售退货的质检冻结与处置区。
///
/// 只有父页面完成 sales_return_quality:view 权限判断后才应挂载本组件；
/// 服务端仍会再次校验权限与单据数据范围。空列表只作历史兼容展示，不补造台账。
class SalesReturnQualityCard extends ConsumerStatefulWidget {
  const SalesReturnQualityCard({
    super.key,
    required this.returnId,
    required this.canCorrect,
    required this.canDispose,
    this.onSnapshotChanged,
    this.onSnapshotInvalidated,
  });

  final String returnId;
  final bool canCorrect;
  final bool canDispose;
  final ValueChanged<List<SalesReturnQualityItem>>? onSnapshotChanged;
  final VoidCallback? onSnapshotInvalidated;

  @override
  ConsumerState<SalesReturnQualityCard> createState() =>
      _SalesReturnQualityCardState();
}

class _SalesReturnQualityCardState
    extends ConsumerState<SalesReturnQualityCard> {
  List<SalesReturnQualityItem>? _items;
  String? _error;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(covariant SalesReturnQualityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.returnId != widget.returnId) {
      _items = null;
      _error = null;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  Future<void> _load() async {
    final requestVersion = ++_requestVersion;
    widget.onSnapshotInvalidated?.call();
    if (mounted) {
      setState(() {
        _items = null;
        _error = null;
      });
    }
    try {
      final items = await ref
          .read(salesReturnQualityRepositoryProvider)
          .list(widget.returnId);
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() => _items = items);
      widget.onSnapshotChanged?.call(items);
    } on ApiException catch (e) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() => _error = '无法加载退货质检冻结，请检查网络后重试');
    }
  }

  Future<void> _dispose(
    SalesReturnQualityItem item,
    SalesReturnQualityAction action,
  ) async {
    if (!widget.canDispose) return;
    // One dialog represents one logical command. Reuse this nonce for every
    // retry from the dialog, regardless of editable payload fields.
    final idempotencyKey = 'sales-return-quality-dispose-${const Uuid().v4()}';
    final updated = await showDialog<List<SalesReturnQualityItem>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DispositionDialog(
        item: item,
        action: action,
        onSubmit: (baseQty, reason) => ref
            .read(salesReturnQualityRepositoryProvider)
            .dispose(
              returnId: widget.returnId,
              returnItemId: item.returnItemId,
              action: action,
              baseQty: baseQty,
              reason: reason,
              idempotencyKey: idempotencyKey,
            ),
      ),
    );
    if (!mounted || updated == null) return;
    setState(() {
      _items = updated;
      _error = null;
    });
    widget.onSnapshotChanged?.call(updated);
    context.appSuccess('${action.label}已登记，冻结余量已刷新');
  }

  /// 受控纠错（追加式补偿）：撤回某类已登记处置量。复用处置对话框，
  /// 数量上限为该桶已登记量（服务端硬校验，前端仅默认值/提示）。
  Future<void> _correct(
    SalesReturnQualityItem item,
    SalesReturnQualityAction action,
  ) async {
    if (!widget.canCorrect) return;
    final idempotencyKey = 'sales-return-quality-correct-${const Uuid().v4()}';
    final updated = await showDialog<List<SalesReturnQualityItem>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => _DispositionDialog(
        item: item,
        action: action,
        correction: true,
        onSubmit: (baseQty, reason) => ref
            .read(salesReturnQualityRepositoryProvider)
            .correct(
              returnId: widget.returnId,
              returnItemId: item.returnItemId,
              action: action,
              baseQty: baseQty,
              reason: reason,
              idempotencyKey: idempotencyKey,
            ),
      ),
    );
    if (!mounted || updated == null) return;
    setState(() {
      _items = updated;
      _error = null;
    });
    widget.onSnapshotChanged?.call(updated);
    context.appSuccess('${action.label}已撤回，处置台账与库存已按补偿事件刷新');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final names = ref.watch(salesMasterNameServiceProvider);
    return Card(
      key: const ValueKey('sales-return-quality-card'),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.fact_check_outlined,
                  color: theme.colorScheme.primary,
                  semanticLabel: '质检冻结',
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '退货质检冻结',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: UtenSpacing.s4),
                      Text(
                        '冻结余量不参与可售库存、预留或拣货；只有“良品释放”会正式增加可售库存。',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (_items != null || _error != null)
                  IconButton(
                    key: const ValueKey('sales-return-quality-refresh'),
                    tooltip: '刷新质检冻结',
                    onPressed: _load,
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            if (_items == null && _error == null)
              const LinearProgressIndicator(
                key: ValueKey('sales-return-quality-loading'),
              )
            else if (_error != null)
              _QualityMessage(
                icon: Icons.error_outline,
                title: '质检冻结加载失败',
                message: _error!,
                color: theme.colorScheme.error,
                action: OutlinedButton.icon(
                  key: const ValueKey('sales-return-quality-retry'),
                  onPressed: _load,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              )
            else if (_items!.isEmpty)
              const _QualityMessage(
                key: ValueKey('sales-return-quality-history-empty'),
                icon: Icons.history,
                title: '未找到质检冻结台账',
                message: '通常表示这是 V189 上线前已审核的历史退货。系统不会补造收货或质检事实；如果这是新审核单，请联系管理员核查，勿手工释放库存。',
              )
            else
              for (var index = 0; index < _items!.length; index++) ...[
                if (index > 0) const Divider(height: UtenSpacing.s24),
                _qualityItem(theme, names, _items![index]),
              ],
          ],
        ),
      ),
    );
  }

  Widget _qualityItem(
    ThemeData theme,
    SalesMasterNameService names,
    SalesReturnQualityItem item,
  ) {
    final statusLabel = salesReturnQualityStatusLabel(item.status);
    return Semantics(
      container: true,
      label: '${names.goods(item.goodsId)}，质检状态$statusLabel',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            runSpacing: UtenSpacing.s8,
            spacing: UtenSpacing.s12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${names.goods(item.goodsId)} · ${names.color(item.colorId)}',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(
                    '退货单位 ${names.unit(item.unitId)} · 换算率 ${_qty(item.unitRate)}；下列数量均为库存基本单位',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              Chip(
                key: ValueKey('quality-status-${item.returnItemId}'),
                avatar: Icon(_statusIcon(item.status), size: 18),
                label: Text('$statusLabel(${item.status})'),
                backgroundColor: _statusBackground(theme, item.status),
                side: BorderSide.none,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          Wrap(
            spacing: UtenSpacing.s8,
            runSpacing: UtenSpacing.s8,
            children: [
              _Metric(
                key: ValueKey('quality-received-${item.returnItemId}'),
                label: '收货冻结',
                value: _qty(item.receivedBaseQty),
              ),
              _Metric(label: '良品释放', value: _qty(item.releasedBaseQty)),
              _Metric(label: '报废', value: _qty(item.scrappedBaseQty)),
              _Metric(label: '返工', value: _qty(item.reworkBaseQty)),
              _Metric(
                key: ValueKey('quality-remaining-${item.returnItemId}'),
                label: '待处置余量',
                value: _qty(item.remainingBaseQty),
                emphasized: item.remainingBaseQty > 0,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          if (widget.canDispose && item.canDispose)
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                FilledButton.icon(
                  key: ValueKey(
                    'quality-action-GOOD_RELEASE-${item.returnItemId}',
                  ),
                  onPressed: () =>
                      _dispose(item, SalesReturnQualityAction.goodRelease),
                  icon: const Icon(Icons.inventory_2_outlined),
                  label: const Text('良品释放'),
                ),
                OutlinedButton.icon(
                  key: ValueKey('quality-action-REWORK-${item.returnItemId}'),
                  onPressed: () =>
                      _dispose(item, SalesReturnQualityAction.rework),
                  icon: const Icon(Icons.build_outlined),
                  label: const Text('转返工'),
                ),
                OutlinedButton.icon(
                  key: ValueKey('quality-action-SCRAP-${item.returnItemId}'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: theme.colorScheme.error,
                  ),
                  onPressed: () =>
                      _dispose(item, SalesReturnQualityAction.scrap),
                  icon: const Icon(Icons.delete_forever_outlined),
                  label: const Text('报废'),
                ),
              ],
            ),
          if (widget.canCorrect && item.disposedBaseQty > 0)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  if (item.releasedBaseQty > 0)
                    TextButton.icon(
                      key: ValueKey(
                        'quality-correct-GOOD_RELEASE-${item.returnItemId}',
                      ),
                      onPressed: () =>
                          _correct(item, SalesReturnQualityAction.goodRelease),
                      icon: const Icon(Icons.undo, size: 18),
                      label: Text('撤回良品释放 ${_qty(item.releasedBaseQty)}'),
                    ),
                  if (item.scrappedBaseQty > 0)
                    TextButton.icon(
                      key: ValueKey(
                        'quality-correct-SCRAP-${item.returnItemId}',
                      ),
                      onPressed: () =>
                          _correct(item, SalesReturnQualityAction.scrap),
                      icon: const Icon(Icons.undo, size: 18),
                      label: Text('撤回报废 ${_qty(item.scrappedBaseQty)}'),
                    ),
                  if (item.reworkBaseQty > 0)
                    TextButton.icon(
                      key: ValueKey(
                        'quality-correct-REWORK-${item.returnItemId}',
                      ),
                      onPressed: () =>
                          _correct(item, SalesReturnQualityAction.rework),
                      icon: const Icon(Icons.undo, size: 18),
                      label: Text('撤回返工 ${_qty(item.reworkBaseQty)}'),
                    ),
                ],
              ),
            )
          else if (!widget.canDispose && item.canDispose)
            Row(
              children: [
                Icon(
                  Icons.lock_outline,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '当前为只读；需要“确认销售退货质检处置”权限才能释放、报废或转返工。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          if (!widget.canCorrect && item.disposedBaseQty > 0)
            Padding(
              padding: const EdgeInsets.only(top: UtenSpacing.s8),
              child: Row(
                children: [
                  Icon(
                    Icons.lock_outline,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      '已登记处置结果为只读；需要“修正销售退货质检结果”权限才能撤回。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
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

class _DispositionDialog extends StatefulWidget {
  const _DispositionDialog({
    required this.item,
    required this.action,
    required this.onSubmit,
    this.correction = false,
  });

  final SalesReturnQualityItem item;
  final SalesReturnQualityAction action;

  /// true = 受控纠错（撤回该桶已登记量；上限与文案切换为撤回口径）。
  final bool correction;
  final Future<List<SalesReturnQualityItem>> Function(
    double baseQty,
    String reason,
  )
  onSubmit;

  @override
  State<_DispositionDialog> createState() => _DispositionDialogState();
}

class _DispositionDialogState extends State<_DispositionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _qtyController = TextEditingController();
  final _reasonController = TextEditingController();
  bool _submitting = false;
  String? _submitError;

  @override
  void dispose() {
    _qtyController.dispose();
    _reasonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isScrap = widget.action == SalesReturnQualityAction.scrap;
    final maxQty = widget.correction
        ? widget.item.registeredQty(widget.action)
        : widget.item.remainingBaseQty;
    return PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        title: Text(
          widget.correction
              ? '确认撤回${widget.action.label}'
              : '确认${widget.action.label}',
        ),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(_actionHint(widget.action)),
                  const SizedBox(height: UtenSpacing.s12),
                  TextFormField(
                    errorBuilder: utenTextFieldErrorBuilder,
                    key: const ValueKey('return-quality-qty'),
                    controller: _qtyController,
                    autofocus: true,
                    enabled: !_submitting,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: widget.correction
                          ? '撤回数量(基本单位)*'
                          : '处置数量(基本单位)*',
                      helper: UtenFieldMessage.helper(
                        '必须大于 0，最多 ${_qty(maxQty)}，最多 4 位小数',
                      ),
                    ),
                    validator: _validateQty,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  TextFormField(
                    errorBuilder: utenTextFieldErrorBuilder,
                    key: const ValueKey('return-quality-reason'),
                    controller: _reasonController,
                    enabled: !_submitting,
                    maxLength: 500,
                    minLines: 2,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      labelText: '处置原因或检验依据 *',
                      helper: UtenFieldMessage.helper(
                        '该内容会写入不可改写的质检处置事件，请填写可追溯依据。',
                      ),
                    ),
                    validator: (value) => value == null || value.trim().isEmpty
                        ? '请填写处置原因或检验依据'
                        : null,
                  ),
                  if (_submitError != null) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _submitError!,
                        key: const ValueKey('return-quality-submit-error'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: _submitting ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            key: const ValueKey('return-quality-submit'),
            style: isScrap
                ? FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  )
                : null,
            onPressed: _submitting ? null : _submit,
            icon: _submitting
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_circle_outline),
            label: Text(_submitting ? '正在提交' : '确认${widget.action.label}'),
          ),
        ],
      ),
    );
  }

  String? _validateQty(String? value) {
    final text = value?.trim() ?? '';
    if (!RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(text)) {
      return '请输入大于 0、最多 4 位小数的数量';
    }
    final qty = double.tryParse(text);
    if (qty == null || qty <= 0) return '数量必须大于 0';
    final maxQty = widget.correction
        ? widget.item.registeredQty(widget.action)
        : widget.item.remainingBaseQty;
    if (qty > maxQty + 0.0000001) {
      return widget.correction
          ? '撤回数量不能超过该类处置已登记量 ${_qty(maxQty)}'
          : '处置数量不能超过待处置余量 ${_qty(maxQty)}';
    }
    return null;
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final qty = double.parse(_qtyController.text.trim());
    final reason = _reasonController.text.trim();
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final updated = await widget.onSubmit(qty, reason);
      if (!mounted) return;
      Navigator.pop(context, updated);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _submitting = false;
        _submitError = '提交失败，请核对冻结余量并重试';
      });
    }
  }
}

class _Metric extends StatelessWidget {
  const _Metric({
    super.key,
    required this.label,
    required this.value,
    this.emphasized = false,
  });

  final String label;
  final String value;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      constraints: const BoxConstraints(minWidth: 104),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s12,
        vertical: UtenSpacing.s8,
      ),
      decoration: BoxDecoration(
        color: emphasized
            ? theme.colorScheme.tertiaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
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
          Text(
            value,
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}

class _QualityMessage extends StatelessWidget {
  const _QualityMessage({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.color,
    this.action,
  });

  final IconData icon;
  final String title;
  final String message;
  final Color? color;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foreground = color ?? theme.colorScheme.onSurfaceVariant;
    return Semantics(
      container: true,
      liveRegion: color == theme.colorScheme.error,
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: foreground),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s4),
                  Text(message),
                  if (action != null) ...[
                    const SizedBox(height: UtenSpacing.s8),
                    action!,
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

IconData _statusIcon(String status) => switch (status) {
  'PENDING' => Icons.hourglass_top,
  'PARTIAL' => Icons.pending_actions,
  'DISPOSED' => Icons.task_alt,
  'REVERSED' => Icons.undo,
  _ => Icons.help_outline,
};

Color _statusBackground(ThemeData theme, String status) => switch (status) {
  'PENDING' => theme.colorScheme.tertiaryContainer,
  'PARTIAL' => theme.colorScheme.secondaryContainer,
  'DISPOSED' => theme.colorScheme.primaryContainer,
  'REVERSED' => theme.colorScheme.errorContainer,
  _ => theme.colorScheme.surfaceContainerHighest,
};

String _actionHint(SalesReturnQualityAction action) => switch (action) {
  SalesReturnQualityAction.goodRelease =>
    '良品释放会正式增加可售库存，随后可能被销售订单预留或拣货。请先确认检验结论与实物数量。',
  SalesReturnQualityAction.scrap => '报废只记录处置，不增加可售库存。请确认实物已隔离，并填写报废或责任依据。',
  SalesReturnQualityAction.rework => '转返工只记录处置，不增加可售库存。返工完成后的入库须走后续受控流程。',
};

String _qty(double value) {
  final fixed = value.toStringAsFixed(4);
  return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
}
