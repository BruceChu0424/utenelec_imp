// 库存余额详情弹层 (单货品库存面板「库存余额」行): 查看 / 授权调整 / 核重。
//
// - 查看: 当前数量与库存重量 (按用户显示单位; 估算「≈」、没称「未称」, 绝不当 0)。
// - 调整 (stock:balance:adjust, 个人授权的高权限): 填调整后数量, 可选「调整后重量」
//   (按盘点定重记账); 自动生成已审核盘点单。带了目标重量时数量可以不变 (只核重量)。
// - 核重 (stock:weight:manage): 只改这个仓库/颜色的库存重量, 不动数量、不生成单据,
//   只记一条人工核重 (POST /stock/weight/balances/set); 数量为 0 或负数时不能核重。
// - 按重量计的货品 (基本单位就是重量单位) 重量随数量精确换算, 不出现重量输入与核重。
// - 重量输入按用户「称重单位」偏好, 也可直接带单位后缀 (850g / 1.2t / 3斤)。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/weight_unit.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../models/stock_query.dart';

/// 授权调整: 调整后数量 (文本, 原样上送) + 可选调整后重量 (千克)。
typedef StockBalanceAdjustCallback =
    Future<StockBalanceAdjustmentResult> Function(
      String targetQty,
      double? targetWeightKg,
      String reason,
      String idempotencyKey,
    );

/// 核重: 核定后的库存重量 (千克) + 原因。
typedef StockBalanceSetWeightCallback =
    Future<void> Function(
      double targetWeightKg,
      String reason,
      String idempotencyKey,
    );

/// 弹层打开时停在哪一屏。
enum StockBalanceSheetMode { details, adjust, weigh }

/// 打开余额详情; 调整或核重成功返回 true (调用方刷新), 其余返回 null。
Future<bool?> showStockBalanceDetailSheet({
  required BuildContext context,
  required BalanceRow balance,
  required String goodsName,
  required String unitName,
  required String warehouseName,
  required String colorName,
  required bool canAdjust,
  required bool canSetWeight,
  bool weightExact = false,
  StockBalanceSheetMode initialMode = StockBalanceSheetMode.details,
  required VoidCallback onViewMovements,
  required StockBalanceAdjustCallback onAdjust,
  required StockBalanceSetWeightCallback onSetWeight,
}) {
  final sheet = _StockBalanceDetailSheet(
    balance: balance,
    goodsName: goodsName,
    unitName: unitName,
    warehouseName: warehouseName,
    colorName: colorName,
    canAdjust: canAdjust,
    canSetWeight: canSetWeight && !weightExact,
    weightExact: weightExact,
    initialMode: initialMode,
    onViewMovements: onViewMovements,
    onAdjust: onAdjust,
    onSetWeight: onSetWeight,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<bool>(
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
  return showGeneralDialog<bool>(
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

class _StockBalanceDetailSheet extends ConsumerStatefulWidget {
  const _StockBalanceDetailSheet({
    required this.balance,
    required this.goodsName,
    required this.unitName,
    required this.warehouseName,
    required this.colorName,
    required this.canAdjust,
    required this.canSetWeight,
    required this.weightExact,
    required this.initialMode,
    required this.onViewMovements,
    required this.onAdjust,
    required this.onSetWeight,
  });

  final BalanceRow balance;
  final String goodsName;
  final String unitName;
  final String warehouseName;
  final String colorName;
  final bool canAdjust;
  final bool canSetWeight;
  final bool weightExact;
  final StockBalanceSheetMode initialMode;
  final VoidCallback onViewMovements;
  final StockBalanceAdjustCallback onAdjust;
  final StockBalanceSetWeightCallback onSetWeight;

  @override
  ConsumerState<_StockBalanceDetailSheet> createState() =>
      _StockBalanceDetailSheetState();
}

class _StockBalanceDetailSheetState
    extends ConsumerState<_StockBalanceDetailSheet> {
  final _formKey = GlobalKey<FormState>();
  final _targetQty = TextEditingController();
  final _targetWeight = TextEditingController();
  final _reason = TextEditingController();
  late StockBalanceSheetMode _mode;
  bool _submitting = false;
  String? _submitError;

  /// 进入调整/核重屏的时刻: 与提交内容一起组成幂等键, 同一内容重试复用同一键,
  /// 改了内容再交就是新键 (服务端不会把它当成同键不同内容的冲突)。
  int _formOpenedAt = 0;

  double get _currentQty => widget.balance.qty ?? 0;

  @override
  void initState() {
    super.initState();
    _mode = switch (widget.initialMode) {
      StockBalanceSheetMode.adjust when widget.canAdjust =>
        StockBalanceSheetMode.adjust,
      StockBalanceSheetMode.weigh when widget.canSetWeight =>
        StockBalanceSheetMode.weigh,
      _ => StockBalanceSheetMode.details,
    };
    _formOpenedAt = DateTime.now().microsecondsSinceEpoch;
  }

  @override
  void dispose() {
    _targetQty.dispose();
    _targetWeight.dispose();
    _reason.dispose();
    super.dispose();
  }

  String _quantity(double value) {
    final fixed = value.toStringAsFixed(4);
    return fixed.replaceFirst(RegExp(r'\.?0+$'), '');
  }

  WeightUnit get _entryUnit =>
      ref.read(warehouseWeightUnitsPrefsProvider).entry;

  /// 目标重量输入 -> 千克 (4 位); 空或 0 = 不填 (null); 非法返回 double.nan。
  double? _targetWeightKg() {
    final text = _targetWeight.text.trim();
    if (text.isEmpty) return null;
    final input = parseWithSuffix(text, _entryUnit);
    if (input == null) return double.nan;
    final kg = input.kgLine;
    return kg <= 0 ? null : kg;
  }

  String? _validateWeightText({required bool required}) {
    final text = _targetWeight.text.trim();
    if (text.isEmpty) return required ? '请填写核定后的库存重量' : null;
    final kg = _targetWeightKg();
    if (kg != null && kg.isNaN) {
      return '重量格式不对, 可以直接写 850g、1.2t、3斤';
    }
    if (kg == null) return required ? '核定后的重量必须大于 0' : null;
    if (kg >= 1e14) return '重量过大';
    return null;
  }

  String? _validateTarget(String? raw) {
    final value = raw?.trim() ?? '';
    if (value.isEmpty) return '请填写调整后数量';
    if (!RegExp(r'^\d{1,14}(\.\d{1,4})?$').hasMatch(value)) {
      return '请输入不小于 0 的数量，最多 4 位小数';
    }
    final parsed = double.tryParse(value);
    if (parsed == null || parsed < 0) return '调整后数量不能小于 0';
    final weight = _targetWeightKg();
    final weightChanges =
        weight != null &&
        !weight.isNaN &&
        (widget.balance.weight == null ||
            (weight - widget.balance.weight!).abs() >= 0.00005);
    if ((parsed - _currentQty).abs() < 0.0000001 && !weightChanges) {
      return '调整后数量与当前库存相同';
    }
    if (parsed == 0 && weight != null && !weight.isNaN) {
      return '数量调成 0 时不能再填重量';
    }
    return null;
  }

  void _switchMode(StockBalanceSheetMode mode) => setState(() {
    _mode = mode;
    _submitError = null;
    _formOpenedAt = DateTime.now().microsecondsSinceEpoch;
  });

  String _key(String action, String payload) => businessIdempotencyKey(
    action,
    '${widget.balance.id}:${widget.balance.warehouseId}:'
    '${widget.balance.goodsId}:${widget.balance.colorId}:'
    '$_formOpenedAt:$payload',
  );

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final adjusting = _mode == StockBalanceSheetMode.adjust;
    final weightKg = _targetWeightKg();
    final reason = _reason.text.trim();
    setState(() {
      _submitting = true;
      _submitError = null;
    });
    try {
      if (adjusting) {
        final targetQty = _targetQty.text.trim();
        await widget.onAdjust(
          targetQty,
          weightKg,
          reason,
          _key(
            'stock-balance-adjust',
            '$targetQty|${weightKeyPart(weightKg)}|$reason',
          ),
        );
      } else {
        await widget.onSetWeight(
          weightKg!,
          reason,
          _key('stock-balance-weigh', '${weightKeyPart(weightKg)}|$reason'),
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      context.appApiError(
        error,
        fallback: adjusting ? '库存调整失败，请刷新后重试' : '核重失败, 请刷新后重试',
      );
      setState(() {
        _submitError = error is ApiException
            ? error.message
            : '未完成。请关闭窗口刷新库存后重试。';
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
    final editing = _mode != StockBalanceSheetMode.details;
    final title = switch (_mode) {
      StockBalanceSheetMode.details => '库存余额详情',
      StockBalanceSheetMode.adjust => '授权调整库存余额',
      StockBalanceSheetMode.weigh => '核重',
    };
    return PopScope(
      canPop: !_submitting,
      child: SafeArea(
        child: Column(
          children: [
            // 提交期间全屏加载遮罩（root Overlay 传送门，不占布局）。
            if (_submitting)
              UtenBusyOverlay(
                title: _mode == StockBalanceSheetMode.weigh
                    ? '正在核定库存重量'
                    : '正在调整库存余额',
                description: '正在写入调整记录，请勿重复提交或关闭面板。',
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s16,
                UtenSpacing.s12,
                UtenSpacing.s8,
                UtenSpacing.s12,
              ),
              child: Row(
                children: [
                  if (editing)
                    IconButton(
                      tooltip: '返回库存详情',
                      onPressed: _submitting
                          ? null
                          : () => _switchMode(StockBalanceSheetMode.details),
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
                      title,
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
                child: switch (_mode) {
                  StockBalanceSheetMode.details => _buildDetails(theme),
                  StockBalanceSheetMode.adjust => _buildAdjustmentForm(theme),
                  StockBalanceSheetMode.weigh => _buildWeighForm(theme),
                },
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: editing ? _buildFormActions() : _buildDetailActions(),
            ),
          ],
        ),
      ),
    );
  }

  String _weightText() {
    final display = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    return formatWeightValue(
      widget.balance.weight,
      display: display,
      estimated: widget.balance.weightEstimated,
    );
  }

  Widget _buildDetails(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _infoRow('货品', widget.goodsName, theme),
        _infoRow('仓库', widget.warehouseName, theme),
        _infoRow('颜色', widget.colorName, theme),
        _infoRow('基本单位', widget.unitName, theme),
        _infoRow('当前数量', _quantity(_currentQty), theme, emphasized: true),
        _infoRow(
          '库存重量',
          _weightText(),
          theme,
          emphasized: widget.balance.weight != null,
        ),
        if (widget.balance.weightEstimated)
          _hint(theme, '重量里有按库存均重或单重估算的部分, 可以称一下后「核重」。'),
        if (widget.weightExact) _hint(theme, '这个货品按重量计, 库存重量随数量自动换算, 不需要单独核重。'),
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

  Widget _hint(ThemeData theme, String text) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
    child: Text(
      text,
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant,
        height: 1.5,
      ),
    ),
  );

  Widget _warningBox(ThemeData theme, String text) => Container(
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
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onErrorContainer,
              height: 1.5,
            ),
          ),
        ),
      ],
    ),
  );

  Widget _weightField(
    ThemeData theme, {
    required String label,
    required bool required,
    required String info,
  }) {
    final entry = ref.watch(warehouseWeightUnitsPrefsProvider).entry;
    return TextFormField(
      key: const ValueKey('stock-balance-target-weight'),
      errorBuilder: utenTextFieldErrorBuilder,
      controller: _targetWeight,
      ignorePointers: false,
      enabled: !_submitting,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: UtenInputDecoration(
        InputDecoration(
          label: fieldLabel(label, theme, required: required, info: info),
          prefixIcon: const Icon(Icons.scale_outlined),
          suffixText: entry.symbol,
        ),
      ),
      validator: (_) => _validateWeightText(required: required),
      onChanged: (_) => setState(() => _submitError = null),
    );
  }

  Widget _reasonField({required String hint, required int maxLength}) =>
      TextFormField(
        key: const ValueKey('stock-balance-reason'),
        errorBuilder: utenTextFieldErrorBuilder,
        controller: _reason,
        ignorePointers: false,
        enabled: !_submitting,
        minLines: 3,
        maxLines: 5,
        maxLength: maxLength,
        decoration: UtenInputDecoration(
          InputDecoration(
            labelText: '调整原因 *',
            hintText: hint,
            alignLabelWithHint: true,
          ),
        ),
        validator: (value) {
          final text = value?.trim() ?? '';
          if (text.isEmpty) return '必须填写调整原因，便于以后追溯';
          if (text.length < 2) return '原因至少写 2 个字';
          return null;
        },
        onChanged: (_) => setState(() => _submitError = null),
      );

  Widget _submitErrorText(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(top: UtenSpacing.s8),
    child: Text(
      '未完成：$_submitError\n关闭窗口后列表会自动刷新。',
      style: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.error,
        height: 1.5,
      ),
    ),
  );

  Widget _buildAdjustmentForm(ThemeData theme) {
    final target = double.tryParse(_targetQty.text.trim());
    final delta = target == null ? null : target - _currentQty;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _warningBox(
            theme,
            '这是高权限操作。提交后库存会立即变为目标数量；填了调整后重量时同时按盘点定重，'
            '不填则重量按数量自动推算。历史订单不受影响。',
          ),
          const SizedBox(height: UtenSpacing.s16),
          _infoRow('货品', widget.goodsName, theme),
          _infoRow('仓库', widget.warehouseName, theme),
          _infoRow('当前数量', _quantity(_currentQty), theme, emphasized: true),
          _infoRow('库存重量', _weightText(), theme),
          const SizedBox(height: UtenSpacing.s8),
          TextFormField(
            key: const ValueKey('stock-balance-target-qty'),
            errorBuilder: utenTextFieldErrorBuilder,
            controller: _targetQty,
            autofocus: true,
            ignorePointers: false,
            enabled: !_submitting,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: UtenInputDecoration(
              InputDecoration(
                label: fieldLabel(
                  '调整后数量',
                  theme,
                  required: true,
                  info: '填写最终库存数量，不是增减量；最多 4 位小数',
                ),
                prefixIcon: const Icon(Icons.edit_note_rounded),
              ),
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
          if (!widget.weightExact) ...[
            const SizedBox(height: UtenSpacing.s12),
            _weightField(
              theme,
              label: '调整后重量 (可选)',
              required: false,
              info: '称过实物就填称得的净重, 按盘点定重记账; 不填则重量按数量自动推算。',
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          _reasonField(hint: '例如：2026-07-31 周期抽盘，发现实物少 2 件', maxLength: 500),
          if (_submitError != null) _submitErrorText(theme),
        ],
      ),
    );
  }

  Widget _buildWeighForm(ThemeData theme) {
    final qtyOk = _currentQty > 0;
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _hint(theme, '核重只改这个仓库/颜色的库存重量，不动数量、不生成单据；会保留核重人和原因。'),
          _infoRow('货品', widget.goodsName, theme),
          _infoRow('仓库', widget.warehouseName, theme),
          _infoRow('颜色', widget.colorName, theme),
          _infoRow('当前数量', _quantity(_currentQty), theme, emphasized: true),
          _infoRow('当前重量', _weightText(), theme, emphasized: true),
          const SizedBox(height: UtenSpacing.s8),
          if (!qtyOk)
            _warningBox(theme, '库存数量为 0 或负数时不能核重，请先调整数量。')
          else ...[
            _weightField(
              theme,
              label: '核定后重量',
              required: true,
              info: '称得的净重 (扣除箱/袋)；可直接写 850g、1.2t、3斤',
            ),
            const SizedBox(height: UtenSpacing.s12),
            _reasonField(hint: '例如：整批过磅 126.4 kg，原记录是估算', maxLength: 200),
          ],
          if (_submitError != null) _submitErrorText(theme),
        ],
      ),
    );
  }

  Widget _buildDetailActions() {
    return Wrap(
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      alignment: WrapAlignment.end,
      children: [
        UtenButton(
          key: const ValueKey('stock-balance-view-ledger'),
          type: UtenButtonType.ghost,
          icon: Icons.history_rounded,
          onPressed: _viewMovements,
          child: const Text('查看流水'),
        ),
        if (widget.canSetWeight)
          UtenButton(
            key: const ValueKey('stock-balance-weigh'),
            type: UtenButtonType.secondary,
            icon: Icons.scale_outlined,
            onPressed: () => _switchMode(StockBalanceSheetMode.weigh),
            child: const Text('核重'),
          ),
        if (widget.canAdjust)
          UtenButton(
            key: const ValueKey('stock-balance-adjust'),
            type: UtenButtonType.danger,
            icon: Icons.tune_rounded,
            onPressed: () => _switchMode(StockBalanceSheetMode.adjust),
            child: const Text('调整余额'),
          ),
      ],
    );
  }

  Widget _buildFormActions() {
    final weighing = _mode == StockBalanceSheetMode.weigh;
    final canSubmit = !weighing || _currentQty > 0;
    return Row(
      children: [
        Expanded(
          child: UtenButton(
            type: UtenButtonType.ghost,
            onPressed: _submitting
                ? null
                : () => _switchMode(StockBalanceSheetMode.details),
            child: const Text('取消'),
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: UtenButton(
            key: const ValueKey('stock-balance-submit'),
            type: weighing ? UtenButtonType.primary : UtenButtonType.danger,
            icon: Icons.check_rounded,
            isLoading: _submitting,
            onPressed: _submitting || !canSubmit ? null : _submit,
            child: Text(weighing ? '确认核重' : '确认并立即调整'),
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
