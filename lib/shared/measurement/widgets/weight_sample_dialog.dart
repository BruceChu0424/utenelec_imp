// 称样校准弹窗 (ADR-135 §6.2, review/product.md §1.3): 数一小把放上秤, 记一条 SAMPLE,
// 服务端同步重算后回传最新单重详情。
//
// - 供应商可空 (默认带入到货供应商); 数量「建议至少 N 个」; 重量 + 抽样单位 (默认克,
//   单独记忆); 皮重 (托盘/容器, 可选); 备注。
// - 实时一行「本次单重 2.310 g; 当前 2.298 g (+0.5%)」; 与当前单重差异超过 3 倍标准差时
//   提示「差异较大: 换了供应商/批次?」并给勾选「从本次起作为新批次(旧数据降权)」。
// - 权限: warehouse_inbound:stock_in 或 stock_doc:edit 或 stock:weight:manage。
// - 入口: 采集表格行菜单 (主要是到货行)、流水面板「单重学习」、库存分析「单重学习」批量表。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/idempotency_key.dart';
import '../weight_params.dart';
import '../weight_predictor.dart';
import '../weight_prefs.dart';
import '../weight_unit.dart';
import 'weight_grid_column.dart';
import 'weight_text.dart';

/// 供应商候选 (名称由调用方按权限给出, 可能已打码)。
class WeightSupplierOption {
  const WeightSupplierOption({required this.id, required this.name});

  final String id;
  final String name;
}

/// 打开称样校准; 保存成功返回服务端刷新后的单货品详情, 取消返回 null。
Future<GoodsWeightDetail?> showWeightSampleDialog(
  BuildContext context, {
  required String goodsId,
  required String goodsTitle,
  String? baseUnitName,
  String? supplierId,
  String? supplierName,
  List<WeightSupplierOption> supplierOptions = const [],
  String? warehouseId,
  WeightParams? params,
  String? remark,
}) => showDialog<GoodsWeightDetail>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _WeightSampleDialog(
    goodsId: goodsId,
    goodsTitle: goodsTitle,
    baseUnitName: baseUnitName,
    supplierId: supplierId,
    supplierName: supplierName,
    supplierOptions: supplierOptions,
    warehouseId: warehouseId,
    params: params,
    remark: remark,
  ),
);

class _WeightSampleDialog extends ConsumerStatefulWidget {
  const _WeightSampleDialog({
    required this.goodsId,
    required this.goodsTitle,
    required this.baseUnitName,
    required this.supplierId,
    required this.supplierName,
    required this.supplierOptions,
    required this.warehouseId,
    required this.params,
    required this.remark,
  });

  final String goodsId;
  final String goodsTitle;
  final String? baseUnitName;
  final String? supplierId;
  final String? supplierName;
  final List<WeightSupplierOption> supplierOptions;
  final String? warehouseId;
  final WeightParams? params;
  final String? remark;

  @override
  ConsumerState<_WeightSampleDialog> createState() =>
      _WeightSampleDialogState();
}

class _WeightSampleDialogState extends ConsumerState<_WeightSampleDialog> {
  final _qty = TextEditingController();
  final _weight = TextEditingController();
  final _tare = TextEditingController();
  late final TextEditingController _remark;
  final _openedAt = DateTime.now().microsecondsSinceEpoch;

  /// 按 (货品, 供应商) 取过的参数。
  final Map<String, WeightParams?> _paramsByKey = {};
  String? _supplierId;
  bool _newRegime = false;
  bool _busy = false;
  String? _error;

  String get _unitName => widget.baseUnitName ?? '个';

  @override
  void initState() {
    super.initState();
    _supplierId = widget.supplierId;
    _remark = TextEditingController(text: widget.remark ?? '');
    final given = widget.params;
    if (given != null) {
      _paramsByKey[WeightParams.keyOf(widget.goodsId, widget.supplierId)] =
          given;
    }
    for (final c in [_qty, _weight, _tare]) {
      c.addListener(_changed);
    }
    _ensureParams();
  }

  void _changed() {
    if (mounted) setState(() => _error = null);
  }

  WeightParams? get _params =>
      _paramsByKey[WeightParams.keyOf(widget.goodsId, _supplierId)];

  Future<void> _ensureParams() async {
    final key = WeightParams.keyOf(widget.goodsId, _supplierId);
    if (_paramsByKey.containsKey(key)) return;
    _paramsByKey[key] = null;
    try {
      final map = await ref.read(weightRepositoryProvider).params([
        WeightParamsLine(goodsId: widget.goodsId, supplierId: _supplierId),
      ]);
      if (!mounted) return;
      setState(
        () => _paramsByKey[key] =
            map[key] ?? (map.isEmpty ? null : map.values.first),
      );
    } catch (_) {
      // 取不到当前单重只影响对比行, 不妨碍称样。
    }
  }

  @override
  void dispose() {
    for (final c in [_qty, _weight, _tare, _remark]) {
      c.dispose();
    }
    super.dispose();
  }

  WeightUnit get _sampleUnit =>
      ref.read(warehouseWeightUnitsPrefsProvider).sample;

  double? get _qtyValue {
    final v = double.tryParse(_qty.text.trim());
    return v == null || v <= 0 ? null : v;
  }

  WeightInput? get _grossInput => parseWithSuffix(_weight.text, _sampleUnit);
  WeightInput? get _tareInput => parseWithSuffix(_tare.text, _sampleUnit);

  bool _invalid(TextEditingController c) =>
      c.text.trim().isNotEmpty && parseWithSuffix(c.text, _sampleUnit) == null;

  /// 净重 (千克)。
  double? get _netKg {
    final gross = _grossInput;
    if (gross == null) return null;
    final net = gross.kg - (_tareInput?.kg ?? 0);
    return net > 0 ? net : null;
  }

  WeightSampleInput? get _sample {
    final n = _qtyValue;
    final w = _netKg;
    if (n == null || w == null) return null;
    return WeightSampleInput(qty: n, weightKg: w);
  }

  /// 本次抽样相对当前单重的 z; 没有当前单重时为 null。
  double? _zOf(WeightSampleInput sample) {
    final p = _params;
    if (p == null || !p.predictable) return null;
    return WeightPredictor.sampleDeviationZ(
      logMean: p.logMean!,
      lotPrior: p.lotPrior!,
      sample: sample,
      gamma: p.effectiveGamma,
    );
  }

  Future<void> _save() async {
    final sample = _sample;
    final gross = _grossInput;
    if (sample == null || gross == null || _busy) {
      setState(() => _error = '请填写数量和重量 (扣皮后要大于 0)');
      return;
    }
    // 净重按抽样输入的单位回传 (服务端 x 系数保留 6 位), 皮重单独以千克留痕。
    final tareKg = _tareInput?.kg;
    final netValue = _round6(
      gross.value - (tareKg ?? 0) / gross.unit.kgPerUnit,
    );
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(weightRepositoryProvider)
          .recordSample(
            widget.goodsId,
            WeightSampleRequest(
              qty: sample.qty,
              weight: netValue,
              weightUnitCode: gross.unit.code,
              tareKg: tareKg == null || tareKg <= 0 ? null : _round6(tareKg),
              supplierId: _supplierId,
              warehouseId: widget.warehouseId,
              newRegime: _newRegime,
              remark: _remark.text,
              idempotencyKey: businessIdempotencyKey(
                'weight-sample',
                '${widget.goodsId}|${_supplierId ?? ''}|${sample.qty}|'
                    '$netValue|${gross.unit.code}|${tareKg ?? ''}|'
                    '$_newRegime|$_openedAt',
              ),
            ),
          );
      if (!mounted) return;
      Navigator.of(context).pop(detail);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is ApiException ? e.message : '保存失败, 请稍后重试';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final allowed = ref.watch(weightSampleAllowedProvider);
    final sampleUnit = ref.watch(warehouseWeightUnitsPrefsProvider).sample;
    final params = _params;
    final sample = _sample;
    final z = sample == null ? null : _zOf(sample);
    final bigDiff = z != null && z.abs() > 3;
    final suggested =
        params?.effectiveSuggestedSampleSize ??
        WeightPredictor.suggestedSampleSize();

    final supplierItems = <UtenDropdownItem>[
      for (final o in widget.supplierOptions)
        UtenDropdownItem(value: o.id, label: o.name),
      if (widget.supplierId != null &&
          widget.supplierOptions.every((o) => o.id != widget.supplierId))
        UtenDropdownItem(
          value: widget.supplierId,
          label: widget.supplierName ?? '当前供应商',
        ),
    ];

    return AlertDialog(
      title: Text('称样校准 · ${widget.goodsTitle}'),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!allowed) ...[
                const UtenInlineNotice(
                  level: UtenInlineNoticeLevel.warning,
                  message: '没有称样权限 (需要到货入库、仓库单据编辑或单重管理权限)',
                ),
                const SizedBox(height: UtenSpacing.s12),
              ],
              if (supplierItems.isNotEmpty) ...[
                UtenDropdownField(
                  key: const ValueKey('weight-sample-supplier'),
                  label: '供应商',
                  hintText: '可不选',
                  value: _supplierId,
                  items: supplierItems,
                  enabled: !_busy,
                  onChanged: (v) {
                    setState(() {
                      _supplierId = v;
                      _newRegime = false;
                    });
                    _ensureParams();
                  },
                ),
                const SizedBox(height: UtenSpacing.s12),
              ],
              TextField(
                key: const ValueKey('weight-sample-qty'),
                controller: _qty,
                autofocus: true,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '数量 *',
                  hintText: '建议至少 $suggested $_unitName',
                  suffixText: _unitName,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                key: const ValueKey('weight-sample-weight'),
                controller: _weight,
                enabled: !_busy,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: '重量 *',
                    error: utenFieldError(
                      _invalid(_weight) ? weightInputErrorText : null,
                    ),
                    suffixIcon: PopupMenuButton<WeightUnit>(
                      key: const ValueKey('weight-sample-unit'),
                      tooltip: '抽样重量单位',
                      initialValue: sampleUnit,
                      onSelected: ref
                          .read(warehouseWeightUnitsPrefsProvider.notifier)
                          .setSample,
                      itemBuilder: (_) => [
                        for (final u in WeightUnit.values)
                          PopupMenuItem(value: u, child: Text(u.label)),
                      ],
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: UtenSpacing.s8,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(sampleUnit.label),
                            const Icon(Icons.arrow_drop_down),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                key: const ValueKey('weight-sample-tare'),
                controller: _tare,
                enabled: !_busy,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: '皮重 (可选, 托盘/容器)',
                    suffixText: sampleUnit.symbol,
                    error: utenFieldError(
                      _invalid(_tare) ? weightInputErrorText : null,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                key: const ValueKey('weight-sample-remark'),
                controller: _remark,
                enabled: !_busy,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: '备注',
                  counterText: '',
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              _liveLine(theme, sample, params),
              if (bigDiff) ...[
                const SizedBox(height: UtenSpacing.s8),
                const UtenInlineNotice(
                  key: ValueKey('weight-sample-big-diff'),
                  level: UtenInlineNoticeLevel.warning,
                  message: '差异较大: 换了供应商/批次?',
                ),
                CheckboxListTile(
                  key: const ValueKey('weight-sample-new-regime'),
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _newRegime,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _newRegime = v ?? false),
                  title: const Text('从本次起作为新批次(旧数据降权)'),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  _error!,
                  key: const ValueKey('weight-sample-error'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      // 按钮整体居中 (全仓弹窗统一规范)。
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          key: const ValueKey('weight-sample-cancel'),
          type: UtenButtonType.ghost,
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const ValueKey('weight-sample-save'),
          isLoading: _busy,
          onPressed: allowed && sample != null && !_busy ? _save : null,
          child: const Text('保存称样'),
        ),
      ],
    );
  }

  Widget _liveLine(
    ThemeData theme,
    WeightSampleInput? sample,
    WeightParams? params,
  ) {
    final current = params?.currentUnitWeightKg;
    final parts = <String>[];
    if (sample != null) {
      final unitWeight = sample.weightKg / sample.qty;
      parts.add('本次单重 ${formatUnitWeight(unitWeight)}');
      if (current != null && current > 0) {
        final pct = (unitWeight / current - 1) * 100;
        parts.add('当前 ${formatUnitWeight(current)} (${formatSignedPct(pct)})');
      }
    } else if (current != null) {
      parts.add('当前 ${formatUnitWeight(current)}');
    }
    if (parts.isEmpty) return const SizedBox.shrink();
    return Row(
      children: [
        Flexible(
          child: Text(
            parts.join('; '),
            key: const ValueKey('weight-sample-live'),
            style: theme.textTheme.bodyMedium,
          ),
        ),
        if (params != null && params.basis != WeightBasis.none) ...[
          const SizedBox(width: UtenSpacing.s8),
          WeightTierBadge(tier: params.effectiveTier),
        ],
      ],
    );
  }

  static double _round6(double v) => (v * 1000000).roundToDouble() / 1000000;
}
