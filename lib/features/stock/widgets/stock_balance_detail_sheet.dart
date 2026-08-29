import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../core/ui/app_notification.dart';
import '../models/stock_query.dart';

typedef StockBalanceAdjustCallback =
    Future<StockBalanceAdjustmentResult> Function(
      String targetQty,
      String reason,
      String idempotencyKey,
    );

Future<StockBalanceAdjustmentResult?> showStockBalanceDetailSheet({
  required BuildContext context,
  required BalanceRow balance,
  required String goodsName,
  required String warehouseName,
  required String colorName,
  required bool canAdjust,
  required VoidCallback onViewMovements,
  required StockBalanceAdjustCallback onAdjust,
}) {
  final sheet = _StockBalanceDetailSheet(
    balance: balance,
    goodsName: goodsName,
    warehouseName: warehouseName,
    colorName: colorName,
    canAdjust: canAdjust,
    onViewMovements: onViewMovements,
    onAdjust: onAdjust,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<StockBalanceAdjustmentResult>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
        ),
        child: SizedBox(
          height: MediaQuery.sizeOf(sheetContext).height * 0.9,
          child: sheet,
        ),
      ),
    );
  }
  return showGeneralDialog<StockBalanceAdjustmentResult>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (dialogContext, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(dialogContext).colorScheme.surface,
        child: SizedBox(width: 460, height: double.infinity, child: sheet),
      ),
    ),
    transitionBuilder: (dialogContext, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _StockBalanceDetailSheet extends StatefulWidget {
  const _StockBalanceDetailSheet({
    required this.balance,
    required this.goodsName,
    required this.warehouseName,
    required this.colorName,
    required this.canAdjust,
    required this.onViewMovements,
    required this.onAdjust,
  });

  final BalanceRow balance;
  final String goodsName;
  final String warehouseName;
  final String colorName;
  final bool canAdjust;
  final VoidCallback onViewMovements;
  final StockBalanceAdjustCallback onAdjust;

  @override
  State<_StockBalanceDetailSheet> createState() =>
      _StockBalanceDetailSheetState();
}

class _StockBalanceDetailSheetState extends State<_StockBalanceDetailSheet> {
  final _formKey = GlobalKey<FormState>();
  final _targetQty = TextEditingController();
  final _reason = TextEditingController();
  bool _editing = false;
  bool _submitting = false;
  String? _submitError;
  String? _idempotencyKey;

  double get _currentQty => widget.balance.qty ?? 0;

  @override
  void dispose() {
    _targetQty.dispose();
    _reason.dispose();
    super.dispose();
  }

  String _quantity(double value) {
    final fixed = value.toStringAsFixed(4);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  String? _validateTarget(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return '请填写调整后数量';
    if (!RegExp(r'^\d{1,14}(\.\d{1,4})?$').hasMatch(value)) {
      return '请输入不小于 0 的数量，最多 4 位小数';
    }
    final parsed = double.tryParse(value);
    if (parsed == null || parsed < 0) return '调整后数量不能小于 0';
    if ((parsed - _currentQty).abs() < 0.0000001) {
      return '调整后数量与当前库存相同';
    }
    return null;
  }

  void _beginAdjustment() {
    final canonical =
        '${widget.balance.id}:'
        '${widget.balance.warehouseId}:'
        '${widget.balance.goodsId}:'
        '${widget.balance.colorId}:'
        '${DateTime.now().microsecondsSinceEpoch}';
    setState(() {
      _editing = true;
      _submitError = null;
      _idempotencyKey = businessIdempotencyKey(
        'stock-balance-adjust',
        canonical,
      );
    });
  }

  void _leaveAdjustment() => setState(() {
    _editing = false;
    _submitError = null;
    _idempotencyKey = null;
  });

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      final result = await widget.onAdjust(
        _targetQty.text.trim(),
        _reason.text.trim(),
        _idempotencyKey!,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (error) {
      if (!mounted) return;
      context.appApiError(error, fallback: '库存调整失败，请刷新后重试');
      setState(() {
        _submitError = error is ApiException
            ? error.message
            : '调整未完成。请关闭窗口刷新库存后重试。';
        _submitting = false;
      });
    }
  }

  void _viewMovements() {
    Navigator.of(context).pop();
    widget.onViewMovements();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: !_submitting,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                UtenSpacing.s12,
                UtenSpacing.s8,
                UtenSpacing.s12,
              ),
              child: Row(
                children: [
                  if (_editing)
                    IconButton(
                      tooltip: '返回库存详情',
                      onPressed: _submitting ? null : _leaveAdjustment,
                      icon: const Icon(Icons.arrow_back_rounded),
                    )
                  else
                    Icon(
                      Icons.inventory_2_outlined,
                      color: theme.colorScheme.primary,
                    ),
                  const SizedBox(width: UtenSpacing.s8),
                  Expanded(
                    child: Text(
                      _editing ? '授权调整库存余额' : '库存余额详情',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: _editing
                    ? _buildAdjustmentForm(theme)
                    : _buildDetails(theme),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: _editing ? _buildFormActions() : _buildDetailActions(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetails(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow('货品', widget.goodsName, theme),
        _infoRow('仓库', widget.warehouseName, theme),
        _infoRow('颜色', widget.colorName, theme),
        _infoRow('当前数量', _quantity(_currentQty), theme, emphasized: true),
        if (widget.balance.lastMovementDate != null)
          _infoRow(
            '最后变动',
            widget.balance.lastMovementDate!.replaceFirst('T', ' '),
            theme,
          ),
        const SizedBox(height: UtenSpacing.s16),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(UtenSpacing.s12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: UtenRadius.mdAll,
            border: Border.all(color: theme.colorScheme.outlineVariant),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                widget.canAdjust
                    ? Icons.verified_user_outlined
                    : Icons.lock_outline_rounded,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  widget.canAdjust
                      ? '你已获得库存余额调整权限。每次调整都会立即影响库存，并自动生成已审核盘点记录，保留修改人和原因。'
                      : '库存余额调整只对经过明确授权的人员开放。你仍可查看该货品的全部出入库流水。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildAdjustmentForm(ThemeData theme) {
    final target = double.tryParse(_targetQty.text.trim());
    final delta = target == null ? null : target - _currentQty;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer,
              borderRadius: UtenRadius.mdAll,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  color: theme.colorScheme.onErrorContainer,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '这是高权限操作。提交后库存会立即变为目标数量；数量调整不自动修改库存重量和历史订单。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s16),
          _infoRow('货品', widget.goodsName, theme),
          _infoRow('仓库', widget.warehouseName, theme),
          _infoRow('当前数量', _quantity(_currentQty), theme, emphasized: true),
          const SizedBox(height: UtenSpacing.s8),
          TextFormField(
            errorBuilder: utenTextFieldErrorBuilder,
            controller: _targetQty,
            autofocus: true,
            enabled: !_submitting,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '调整后数量 *',
              helper: UtenFieldMessage.helper('填写最终库存数量，不是增减量；最多 4 位小数'),
              prefixIcon: Icon(Icons.edit_note_rounded),
            ),
            validator: _validateTarget,
            onChanged: (_) => setState(() => _submitError = null),
          ),
          const SizedBox(height: UtenSpacing.s12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(UtenSpacing.s12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: UtenRadius.mdAll,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('本次差额', style: theme.textTheme.labelLarge),
                Text(
                  delta == null
                      ? '—'
                      : '${delta >= 0 ? '+' : ''}${_quantity(delta)}',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: delta == null
                        ? theme.colorScheme.onSurfaceVariant
                        : (delta >= 0
                              ? theme.colorScheme.primary
                              : theme.colorScheme.error),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: UtenSpacing.s12),
          TextFormField(
            errorBuilder: utenTextFieldErrorBuilder,
            controller: _reason,
            enabled: !_submitting,
            minLines: 3,
            maxLines: 5,
            maxLength: 500,
            decoration: const InputDecoration(
              labelText: '调整原因 *',
              hintText: '例如：2026-07-31 周期抽盘，发现实物少 2 件',
              alignLabelWithHint: true,
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return '必须填写调整原因，便于以后追溯';
              }
              return null;
            },
            onChanged: (_) => setState(() => _submitError = null),
          ),
          if (_submitError != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '未完成：$_submitError\n关闭窗口后列表会自动刷新。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
                height: 1.5,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDetailActions() {
    return Row(
      children: [
        Expanded(
          child: UtenButton(
            type: UtenButtonType.ghost,
            icon: Icons.history_rounded,
            onPressed: _viewMovements,
            child: const Text('查看流水'),
          ),
        ),
        if (widget.canAdjust) ...[
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: UtenButton(
              type: UtenButtonType.danger,
              icon: Icons.tune_rounded,
              onPressed: _beginAdjustment,
              child: const Text('调整余额'),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildFormActions() {
    return Row(
      children: [
        Expanded(
          child: UtenButton(
            type: UtenButtonType.ghost,
            onPressed: _submitting ? null : _leaveAdjustment,
            child: const Text('取消'),
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: UtenButton(
            type: UtenButtonType.danger,
            icon: Icons.check_rounded,
            isLoading: _submitting,
            onPressed: _submitting ? null : _submit,
            child: const Text('确认并立即调整'),
          ),
        ),
      ],
    );
  }

  Widget _infoRow(
    String label,
    String value,
    ThemeData theme, {
    bool emphasized = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style:
                  (emphasized
                          ? theme.textTheme.titleMedium
                          : theme.textTheme.bodyMedium)
                      ?.copyWith(
                        fontWeight: emphasized ? FontWeight.w700 : null,
                      ),
            ),
          ),
        ],
      ),
    );
  }
}
