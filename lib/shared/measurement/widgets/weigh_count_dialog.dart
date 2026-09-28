// 称重计数弹窗 (ADR-135 §6.2, review/product.md §1.2): 毛重 (可多次称重相加) - 皮重 x 件数
// = 净重, 按单重折算件数 (95% 区间 + 可靠度), 可选「本批抽样」提高精度。
//
// 场景 ([WeighCountContext]):
// - receipt  到货登记: 主按钮「只记重量」; 次按钮「按称重改数量」并提示「将按估算数量入账,
//            影响对账」(改的是业务数量, 必须显式点);
// - count    盘点 / 其它入库: 主按钮「填入数量和重量」;
// - outbound 出库反推: 「需要 N 个 → 净重约 X kg (区间) + 皮重 → 秤上应显示约 Y kg」, 再填实称;
// - standalone 独立称重计数页 (手机放秤旁): 只算数, 可保存抽样。
// 单重未学准时「填入数量」禁用, 直到在本弹窗里录入 >= 10 件的同批抽样。
// 按件计 (基本单位计量维度 COUNT 或未设) 的数量折算后取整。
//
// 本弹窗**不调用任何库存过账接口**: 只返回 [WeighCountResult] 让页面回填;
// 唯一的写是「本批抽样」-> POST samples (SAMPLE 记录, 自动带上到货供应商) 与
// 有管理权限时「记住为本货品皮重」-> PUT profile。
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
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

/// 称重计数的使用场景。
enum WeighCountContext {
  /// 到货登记 (数量是业务数量, 默认只记重量)。
  receipt,

  /// 盘点实盘 / 其它入库 (默认填入数量和重量)。
  count,

  /// 出库反推 (需要 N 个 → 秤上应显示多少)。
  outbound,

  /// 独立称重计数页。
  standalone,
}

/// 弹窗入参。
class WeighCountRequest {
  const WeighCountRequest({
    required this.mode,
    required this.goodsId,
    required this.goodsTitle,
    this.params,
    this.supplierId,
    this.warehouseId,
    this.baseUnitName,
    this.lineUnitName,
    this.unitRate = 1,
    this.currentQty,
    this.initialNetKg,
    this.integerQty,
    this.sampleRemark,
    this.canSaveSample,
  });

  final WeighCountContext mode;
  final String goodsId;

  /// 「货品名 编号 颜色」, 拼进标题「称重计数 · ...」。
  final String goodsTitle;

  /// 页面已取的单重参数; null 时弹窗自己取。
  final WeightParams? params;

  /// 到货供应商 (取供应商单重、抽样自动打标)。
  final String? supplierId;
  final String? warehouseId;
  final String? baseUnitName;
  final String? lineUnitName;

  /// 1 个行单位 = 多少基本单位。
  final double unitRate;

  /// 行上现有数量 (行单位): 到货 = 登记数量, 出库 = 应发数量。
  final double? currentQty;

  /// 格子里已有的净重 (千克), 带进来当第一次称重。
  final double? initialNetKg;

  /// 强制取整口径; null = 按参数的基本单位维度 (COUNT/未设 取整)。
  final bool? integerQty;

  /// 抽样记录备注 (如单号)。
  final String? sampleRemark;

  /// 能否保存抽样; null = 按当前用户权限。
  final bool? canSaveSample;

  double? get currentQtyBase =>
      currentQty == null ? null : currentQty! * (unitRate > 0 ? unitRate : 1);
}

/// 本批抽样 (件数按基本单位, 重量千克) 及是否已保存为学习记录。
class WeighCountSample {
  const WeighCountSample({
    required this.qty,
    required this.weightKg,
    required this.saved,
    this.detail,
  });

  final double qty;
  final double weightKg;
  final bool saved;

  /// 保存后服务端回的最新单重详情 (页面可据此刷新参数缓存)。
  final GoodsWeightDetail? detail;
}

/// 弹窗结果: 页面据此回填 (不过账)。
class WeighCountResult {
  const WeighCountResult({
    required this.netKg,
    this.grossKg,
    this.tareKg,
    this.qty,
    this.qtyBase,
    this.qtyFromWeight = false,
    this.sample,
    this.qtyEstimateNote,
  });

  /// 净重 (千克, HALF_UP 4 位)。
  final double netKg;
  final double? grossKg;

  /// 扣掉的皮重合计 (千克)。
  final double? tareKg;

  /// 回填的数量 (行单位); null = 只记重量。
  final double? qty;
  final double? qtyBase;
  final bool qtyFromWeight;
  final WeighCountSample? sample;

  /// 数量格黄框 ⓘ 说明 (「按称重推算 5,373~5,449个」)。
  final String? qtyEstimateNote;
}

/// 打开称重计数弹窗; 取消返回 null。
Future<WeighCountResult?> showWeighCountDialog(
  BuildContext context, {
  required WeighCountRequest request,
}) => showDialog<WeighCountResult>(
  context: context,
  barrierDismissible: false,
  builder: (dialogContext) => AlertDialog(
    title: Text('称重计数 · ${request.goodsTitle}'),
    content: ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: 520,
        maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.8,
      ),
      child: WeighCountPanel(
        request: request,
        onSubmit: (result) => Navigator.of(dialogContext).pop(result),
        onCancel: () => Navigator.of(dialogContext).pop(),
      ),
    ),
  ),
);

/// 把弹窗结果写回一行: 重量 (及是否按称重改数量), 需要时数量黄框预填。
void applyWeighCountResult(
  WeighCountResult result, {
  required WeightEntryController weight,
  UtenAutofillTextController? qty,
}) {
  weight.setKg(result.netKg, qtyFromWeight: result.qtyFromWeight);
  final q = result.qty;
  if (q != null && qty != null) {
    final text = plainWeighQtyText(q);
    qty.setAutomaticText(text);
    weight.markQtyDerived(text, note: result.qtyEstimateNote);
  }
}

/// 称重计数面板 (弹窗与独立页共用同一份)。[embedded] = 放在页面里 (不自带滚动)。
class WeighCountPanel extends ConsumerStatefulWidget {
  const WeighCountPanel({
    super.key,
    required this.request,
    required this.onSubmit,
    this.onCancel,
    this.embedded = false,
  });

  final WeighCountRequest request;
  final ValueChanged<WeighCountResult> onSubmit;
  final VoidCallback? onCancel;
  final bool embedded;

  @override
  ConsumerState<WeighCountPanel> createState() => _WeighCountPanelState();
}

class _WeighCountPanelState extends ConsumerState<WeighCountPanel> {
  final List<TextEditingController> _gross = [];
  final _tare = TextEditingController();
  final _pieces = TextEditingController();
  final _sampleQty = TextEditingController();
  final _sampleWeight = TextEditingController();
  final _openedAt = DateTime.now().microsecondsSinceEpoch;

  WeightParams? _params;
  bool _loadingParams = false;
  bool _piecesEdited = false;
  bool _rememberTare = false;
  bool _busy = false;
  String? _submitError;

  WeighCountRequest get _req => widget.request;

  @override
  void initState() {
    super.initState();
    final units = ref.read(warehouseWeightUnitsPrefsProvider);
    final initial = _req.initialNetKg;
    _gross.add(
      _listen(
        TextEditingController(
          text: initial == null || initial <= 0
              ? ''
              : units.entry.editText(initial),
        ),
      ),
    );
    _params = _req.params;
    if (initial == null) _prefillTare(units.entry);
    for (final c in [_tare, _sampleQty, _sampleWeight]) {
      _listen(c);
    }
    _pieces.addListener(_changed);
    if (_params == null) _loadParams();
  }

  TextEditingController _listen(TextEditingController c) {
    c.addListener(_changed);
    return c;
  }

  void _changed() {
    if (mounted) setState(() => _submitError = null);
  }

  void _prefillTare(WeightUnit entry) {
    final tare = _params?.prefillTareKg;
    if (tare == null || tare <= 0 || _tare.text.isNotEmpty) return;
    _tare.text = entry.editText(tare);
    if (!_piecesEdited) _pieces.text = '${_gross.length}';
  }

  Future<void> _loadParams() async {
    setState(() => _loadingParams = true);
    try {
      final map = await ref.read(weightRepositoryProvider).params([
        WeightParamsLine(goodsId: _req.goodsId, supplierId: _req.supplierId),
      ]);
      if (!mounted) return;
      setState(() {
        _params = map.values.isEmpty ? null : map.values.first;
        _loadingParams = false;
      });
      if (_req.initialNetKg == null) {
        _prefillTare(ref.read(warehouseWeightUnitsPrefsProvider).entry);
      }
    } catch (_) {
      // 取不到单重参数也能记重量 (重量从不阻断), 只是不能折算。
      if (mounted) setState(() => _loadingParams = false);
    }
  }

  @override
  void dispose() {
    for (final c in [..._gross, _tare, _pieces, _sampleQty, _sampleWeight]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---- 计算 ----

  WeightUnitsPrefs get _units => ref.read(warehouseWeightUnitsPrefsProvider);

  double? _kgOf(TextEditingController c, WeightUnit unit) {
    final raw = c.text.trim();
    if (raw.isEmpty) return null;
    return parseWithSuffix(raw, unit)?.kg;
  }

  bool _invalid(TextEditingController c, WeightUnit unit) =>
      c.text.trim().isNotEmpty && parseWithSuffix(c.text, unit) == null;

  double? get _grossKg {
    double? sum;
    for (final c in _gross) {
      final kg = _kgOf(c, _units.entry);
      if (kg != null) sum = (sum ?? 0) + kg;
    }
    return sum;
  }

  double get _piecesCount => double.tryParse(_pieces.text.trim()) ?? 0;

  double? get _tareKg {
    final per = _kgOf(_tare, _units.entry);
    if (per == null || per <= 0) return null;
    final pieces = _piecesCount;
    return pieces <= 0 ? null : per * pieces;
  }

  double? get _netKg {
    final gross = _grossKg;
    if (gross == null) return null;
    final net = roundKgLine(gross - (_tareKg ?? 0));
    return net == null || net <= 0 ? null : net;
  }

  WeightSampleInput? get _sample {
    final n = double.tryParse(_sampleQty.text.trim());
    final w = _kgOf(_sampleWeight, _units.sample);
    if (n == null || n <= 0 || w == null || w <= 0) return null;
    return WeightSampleInput(qty: n, weightKg: w);
  }

  bool get _integerQty => _req.integerQty ?? _params?.integerQty ?? true;

  CountEstimate? _estimate(double net, WeightSampleInput? sample) {
    final p = _params;
    if (p != null && p.isExact) return null;
    if (p == null) {
      if (sample == null) return null;
      return WeightPredictor.countFromWeight(
        logMean: null,
        lotPrior: null,
        df: WeightPredictor.priorDf,
        weightKg: net,
        sample: sample,
      );
    }
    return p.countFromWeight(net, sample: sample);
  }

  WeightTier _tier(CountEstimate estimate, WeightSampleInput? sample) {
    final p = _params;
    if (p == null) {
      return WeightPredictor.requestTier(
        logHalfWidth: estimate.logHalfWidth,
        baseTier: null,
        sufficientSample: sample?.sufficient ?? false,
      );
    }
    return p.requestTierFor(estimate, sample: sample);
  }

  /// 折算出的基本单位数量 (精确换算货品直接除系数; 按件计取整)。
  double? _qtyBase(double net, CountEstimate? estimate) {
    final p = _params;
    if (p != null && p.isExact) {
      return WeightPredictor.roundQty(net / p.massFactorKg!, integer: false);
    }
    if (estimate == null) return null;
    return WeightPredictor.roundQty(
      estimate.estimatedQty,
      integer: _integerQty,
    );
  }

  bool _canFill(CountEstimate? estimate, WeightSampleInput? sample) {
    final p = _params;
    if (p != null && p.isExact) return true;
    if (estimate == null) return false;
    if (sample?.sufficient ?? false) return true;
    return _tier(estimate, sample) != WeightTier.red;
  }

  // ---- 提交 ----

  Future<void> _submit({required bool fillQty}) async {
    final net = _netKg;
    if (net == null || _busy) return;
    final sample = _sample;
    final estimate = _estimate(net, sample);
    final qtyBase = fillQty ? _qtyBase(net, estimate) : null;
    if (fillQty && qtyBase == null) return;
    setState(() {
      _busy = true;
      _submitError = null;
    });
    WeighCountSample? sampleResult;
    try {
      if (sample != null) sampleResult = await _saveSample(sample);
      if (_rememberTare) await _saveDefaultTare();
    } catch (e) {
      if (mounted) {
        final reason = e is ApiException ? e.message : '网络或数据异常';
        setState(() {
          _busy = false;
          _submitError = '没保存成功: $reason (可清空抽样/取消记住皮重后继续)';
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    final rate = _req.unitRate > 0 ? _req.unitRate : 1.0;
    final lineQty = qtyBase == null
        ? null
        : (rate == 1
              ? qtyBase
              : WeightPredictor.roundQty(qtyBase / rate, integer: false));
    widget.onSubmit(
      WeighCountResult(
        netKg: net,
        grossKg: roundKgLine(_grossKg),
        tareKg: roundKgLine(_tareKg),
        qty: lineQty,
        qtyBase: qtyBase,
        qtyFromWeight: fillQty,
        sample: sampleResult,
        qtyEstimateNote: fillQty && estimate != null
            ? '按称重推算 ${formatWeighQtyRange(estimate, integer: _integerQty, unitName: _req.baseUnitName)}'
            : null,
      ),
    );
  }

  bool get _canSaveSample =>
      _req.canSaveSample ?? ref.read(weightSampleAllowedProvider);

  Future<WeighCountSample> _saveSample(WeightSampleInput sample) async {
    if (!_canSaveSample) {
      return WeighCountSample(
        qty: sample.qty,
        weightKg: sample.weightKg,
        saved: false,
      );
    }
    final unit = _units.sample;
    final parsed = parseWithSuffix(_sampleWeight.text, unit)!;
    final detail = await ref
        .read(weightRepositoryProvider)
        .recordSample(
          _req.goodsId,
          WeightSampleRequest(
            qty: sample.qty,
            weight: parsed.value,
            weightUnitCode: parsed.unit.code,
            supplierId: _req.supplierId,
            warehouseId: _req.warehouseId,
            remark: _req.sampleRemark ?? '称重计数抽样',
            idempotencyKey: businessIdempotencyKey(
              'weight-sample',
              '${_req.goodsId}|${sample.qty}|${parsed.numberText}|'
                  '${parsed.unit.code}|$_openedAt',
            ),
          ),
        );
    return WeighCountSample(
      qty: sample.qty,
      weightKg: sample.weightKg,
      saved: true,
      detail: detail,
    );
  }

  Future<void> _saveDefaultTare() async {
    final per = _kgOf(_tare, _units.entry);
    if (per == null || per <= 0) return;
    final repo = ref.read(weightRepositoryProvider);
    final detail = await repo.goods(_req.goodsId);
    await repo.updateProfile(
      _req.goodsId,
      WeightProfileUpdate.from(detail.profile).copyWith(defaultTareKg: per),
    );
  }

  void _addWeighing() {
    setState(() {
      _gross.add(_listen(TextEditingController()));
      if (!_piecesEdited && _tare.text.trim().isNotEmpty) {
        _pieces.text = '${_gross.length}';
      }
    });
  }

  void _removeWeighing(int index) {
    if (_gross.length <= 1) return;
    setState(() {
      _gross.removeAt(index).dispose();
      if (!_piecesEdited && _tare.text.trim().isNotEmpty) {
        _pieces.text = '${_gross.length}';
      }
    });
  }

  void _reset() {
    setState(() {
      for (final c in _gross.skip(1)) {
        c.dispose();
      }
      _gross.removeRange(1, _gross.length);
      _gross.first.clear();
      _sampleQty.clear();
      _sampleWeight.clear();
      _submitError = null;
    });
  }

  // ---- 界面 ----

  @override
  Widget build(BuildContext context) {
    final units = ref.watch(warehouseWeightUnitsPrefsProvider);
    final theme = Theme.of(context);
    final net = _netKg;
    final sample = _sample;
    final estimate = net == null ? null : _estimate(net, sample);
    final tier = estimate == null ? null : _tier(estimate, sample);
    final canFill = net != null && _canFill(estimate, sample);
    final params = _params;
    final redTier =
        !(params?.isExact ?? false) &&
        (estimate == null
            ? (params == null ||
                  !params.predictable ||
                  params.effectiveTier == WeightTier.red)
            : tier == WeightTier.red) &&
        !(sample?.sufficient ?? false);

    final body = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_loadingParams) const LinearProgressIndicator(minHeight: 2),
        if (_req.mode == WeighCountContext.outbound) _outboundTarget(theme),
        if (redTier && !_loadingParams) ...[
          UtenInlineNotice(
            key: const ValueKey('weigh-count-red-banner'),
            level: UtenInlineNoticeLevel.warning,
            message:
                '单重数据不足, 请数 ${params?.effectiveSuggestedSampleSize ?? WeightPredictor.suggestedSampleSize()} '
                '${_req.baseUnitName ?? '个'}放上秤 (下方抽样)',
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        ..._grossRows(units.entry),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            key: const ValueKey('weigh-count-add-gross'),
            onPressed: _busy ? null : _addWeighing,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('再称一次'),
          ),
        ),
        _tareRow(units.entry),
        if (_canManageTare) _rememberTareRow(),
        const SizedBox(height: UtenSpacing.s8),
        _netLine(theme, units),
        const SizedBox(height: UtenSpacing.s16),
        _sampleSection(theme, units.sample, sample),
        const SizedBox(height: UtenSpacing.s12),
        if (net != null) _resultSection(theme, net, estimate, tier, sample),
        if (_submitError != null) ...[
          const SizedBox(height: UtenSpacing.s8),
          Text(
            _submitError!,
            key: const ValueKey('weigh-count-error'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
    final actions = _actions(net: net, canFill: canFill);
    if (widget.embedded) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          body,
          const SizedBox(height: UtenSpacing.s16),
          actions,
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(child: SingleChildScrollView(child: body)),
        const SizedBox(height: UtenSpacing.s16),
        actions,
      ],
    );
  }

  bool get _canManageTare => ref.watch(weightManageAllowedProvider);

  Widget _outboundTarget(ThemeData theme) {
    final params = _params;
    final needed = _req.currentQtyBase;
    if (needed == null || needed <= 0 || params == null) {
      return const SizedBox.shrink();
    }
    final integer = _integerQty;
    final String text;
    if (params.isExact) {
      final kg = needed * params.massFactorKg!;
      text =
          '需要 ${formatWeighQtyWithUnit(needed, unitName: _req.baseUnitName, integer: false)} '
          '→ 净重 ${formatWeight(kg)} (精确换算)';
    } else {
      final expectation = params.expectationFor(needed, sample: _sample);
      if (expectation == null) return const SizedBox.shrink();
      final tare = _tareKg ?? 0;
      final expected = expectation.expectedWeightKg;
      final bandUnit = WeightDisplay.auto.unitFor(expected);
      final low = bandUnit.format(expectation.weightLowKg, withSymbol: false);
      final high = bandUnit.format(expectation.weightHighKg, withSymbol: false);
      final needText = formatWeighQtyWithUnit(
        needed,
        unitName: _req.baseUnitName,
        integer: integer,
      );
      final buffer = StringBuffer()
        ..write('需要 $needText ')
        ..write('→ 净重约 ${bandUnit.format(expected)} ($low~$high)');
      if (tare > 0) {
        buffer
          ..write(' + 皮重 ${formatWeight(tare)} ')
          ..write(
            '→ 秤上应显示约 ${formatWeight(expectation.expectedWeightKg + tare)}',
          );
      }
      text = buffer.toString();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: UtenInlineNotice(
        key: const ValueKey('weigh-count-outbound-target'),
        message: text,
      ),
    );
  }

  List<Widget> _grossRows(WeightUnit entry) => [
    for (var i = 0; i < _gross.length; i++)
      Padding(
        padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                key: ValueKey('weigh-count-gross-$i'),
                controller: _gross[i],
                autofocus: i == 0 && _req.initialNetKg == null,
                enabled: !_busy,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: _req.mode == WeighCountContext.outbound
                        ? (_gross.length == 1 ? '实称(秤上读数)' : '实称第 ${i + 1} 次')
                        : (_gross.length == 1 ? '毛重' : '毛重第 ${i + 1} 次'),
                    suffixText: entry.symbol,
                    error: utenFieldError(
                      _invalid(_gross[i], entry) ? weightInputErrorText : null,
                    ),
                  ),
                ),
              ),
            ),
            if (_gross.length > 1)
              IconButton(
                tooltip: '删掉这次称重',
                onPressed: _busy ? null : () => _removeWeighing(i),
                icon: const Icon(Icons.remove_circle_outline),
              ),
          ],
        ),
      ),
  ];

  Widget _tareRow(WeightUnit entry) => Row(
    children: [
      Expanded(
        flex: 3,
        child: TextField(
          key: const ValueKey('weigh-count-tare'),
          controller: _tare,
          enabled: !_busy,
          decoration: UtenInputDecoration(
            InputDecoration(
              labelText: '皮重(每件箱/袋)',
              suffixText: entry.symbol,
              error: utenFieldError(
                _invalid(_tare, entry) ? weightInputErrorText : null,
              ),
            ),
          ),
        ),
      ),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
        child: Text('×'),
      ),
      Expanded(
        flex: 2,
        child: TextField(
          key: const ValueKey('weigh-count-pieces'),
          controller: _pieces,
          enabled: !_busy,
          keyboardType: TextInputType.number,
          onChanged: (_) => _piecesEdited = true,
          decoration: const InputDecoration(labelText: '件数', suffixText: '件'),
        ),
      ),
    ],
  );

  Widget _rememberTareRow() => CheckboxListTile(
    key: const ValueKey('weigh-count-remember-tare'),
    contentPadding: EdgeInsets.zero,
    dense: true,
    controlAffinity: ListTileControlAffinity.leading,
    value: _rememberTare,
    onChanged: _busy ? null : (v) => setState(() => _rememberTare = v ?? false),
    title: const Text('记住为本货品皮重'),
  );

  Widget _netLine(ThemeData theme, WeightUnitsPrefs units) {
    final net = _netKg;
    final gross = _grossKg;
    final text = net != null
        ? formatWeight(net, display: WeightDisplay.of(units.entry))
        : (gross != null ? '净重必须大于 0' : '—');
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text('净重 ', style: theme.textTheme.titleSmall),
        Flexible(
          child: Text(
            text,
            key: const ValueKey('weigh-count-net'),
            style: net != null
                ? theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  )
                : theme.textTheme.bodyMedium?.copyWith(
                    color: gross != null
                        ? theme.colorScheme.error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
          ),
        ),
      ],
    );
  }

  Widget _sampleSection(
    ThemeData theme,
    WeightUnit sampleUnit,
    WeightSampleInput? sample,
  ) {
    final unitName = _req.baseUnitName ?? '个';
    final suggested =
        _params?.effectiveSuggestedSampleSize ??
        WeightPredictor.suggestedSampleSize();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('本批抽样 (可选)', style: theme.textTheme.titleSmall),
        const SizedBox(height: UtenSpacing.s4),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('weigh-count-sample-qty'),
                controller: _sampleQty,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: '数',
                  hintText: '建议 $suggested',
                  suffixText: unitName,
                ),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: TextField(
                key: const ValueKey('weigh-count-sample-weight'),
                controller: _sampleWeight,
                enabled: !_busy,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: '重',
                    error: utenFieldError(
                      _invalid(_sampleWeight, sampleUnit)
                          ? weightInputErrorText
                          : null,
                    ),
                    suffixIcon: _SampleUnitMenu(
                      unit: sampleUnit,
                      onSelected: ref
                          .read(warehouseWeightUnitsPrefsProvider.notifier)
                          .setSample,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (sample != null) ...[
          const SizedBox(height: UtenSpacing.s4),
          Text(
            '本批单重 ${formatUnitWeight(sample.weightKg / sample.qty)}'
            '${sample.sufficient ? '' : ' (少于 10 $unitName, 只作参考)'}'
            '${_canSaveSample ? '' : ' · 没有称样权限, 本次抽样只用于这次计数'}',
            key: const ValueKey('weigh-count-sample-unit-weight'),
            style: theme.textTheme.bodySmall,
          ),
        ],
      ],
    );
  }

  Widget _resultSection(
    ThemeData theme,
    double net,
    CountEstimate? estimate,
    WeightTier? tier,
    WeightSampleInput? sample,
  ) {
    final params = _params;
    final unitName = _req.baseUnitName;
    final children = <Widget>[];
    if (params != null && params.isExact) {
      final qty = _qtyBase(net, null)!;
      children.add(
        Text(
          '= ${formatWeighQtyWithUnit(qty, unitName: unitName, integer: false)} (按数量精确换算)',
          key: const ValueKey('weigh-count-result'),
          style: theme.textTheme.titleMedium,
        ),
      );
    } else if (estimate == null) {
      children.add(
        Text(
          params == null || !params.predictable ? '暂无单重, 在上面录入本批抽样后即可折算' : '—',
          key: const ValueKey('weigh-count-result'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    } else {
      final integer = _integerQty;
      final n = WeightPredictor.roundQty(
        estimate.estimatedQty,
        integer: integer,
      );
      children.add(
        Wrap(
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '约 ${formatWeighQtyWithUnit(n, unitName: unitName, integer: integer)} '
              '(${formatWeighQtyRange(estimate, integer: integer)}, 95%)',
              key: const ValueKey('weigh-count-result'),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            if (tier != null) WeightTierBadge(tier: tier),
          ],
        ),
      );
      final basis = <String>[
        if (params != null && params.predictable) weightBasisText(params),
        if (sample != null)
          '本批抽样 ${formatWeighQtyWithUnit(sample.qty, unitName: unitName, integer: true)}',
      ];
      if (basis.isNotEmpty) {
        children.add(
          Text(
            '依据: ${basis.join(' · ')}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      }
      final exactUpTo = estimate.exactUpToQty;
      if (exactUpTo.isFinite && exactUpTo >= 1) {
        children.add(
          Text(
            '超过 ${formatWeighQtyWithUnit(math.max(1.0, exactUpTo.floorToDouble()), unitName: unitName ?? '个', integer: true)}时称重计数只是估算',
            key: const ValueKey('weigh-count-exact-hint'),
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        );
      }
    }
    final deviation = _deviationChip();
    if (deviation != null) children.add(deviation);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final w in children)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s4),
            child: w,
          ),
      ],
    );
  }

  /// 到货: 称重折算 vs 登记数量; 出库: 实称 vs 应发。
  Widget? _deviationChip() {
    final params = _params;
    final qtyBase = _req.currentQtyBase;
    final net = _netKg;
    if (params == null || qtyBase == null || net == null) return null;
    if (_req.mode != WeighCountContext.receipt &&
        _req.mode != WeighCountContext.outbound) {
      return null;
    }
    final mode = _req.mode == WeighCountContext.outbound
        ? WeightCaptureMode.outbound
        : WeightCaptureMode.inbound;
    final check = params.check(qtyBase: qtyBase, weightKg: net, mode: mode);
    if (check == null || !params.alertsEnabled) return null;
    return WeightDeviationChip(
      key: const ValueKey('weigh-count-deviation'),
      check: check,
      mode: mode,
      unitName: _req.baseUnitName,
      showWhenNone: true,
    );
  }

  Widget _actions({required double? net, required bool canFill}) {
    final cancel = widget.onCancel == null
        ? null
        : UtenButton(
            key: const ValueKey('weigh-count-cancel'),
            type: UtenButtonType.ghost,
            onPressed: _busy ? null : widget.onCancel,
            child: const Text('取消'),
          );
    final hasNet = net != null && !_busy;
    final List<Widget> buttons;
    Widget? warning;
    switch (_req.mode) {
      case WeighCountContext.receipt:
        buttons = [
          UtenButton(
            key: const ValueKey('weigh-count-secondary'),
            type: UtenButtonType.secondary,
            onPressed: hasNet && canFill ? () => _submit(fillQty: true) : null,
            child: const Text('按称重改数量'),
          ),
          UtenButton(
            key: const ValueKey('weigh-count-primary'),
            isLoading: _busy,
            onPressed: hasNet ? () => _submit(fillQty: false) : null,
            child: const Text('只记重量'),
          ),
        ];
        if (hasNet && canFill) warning = const Text('按称重改数量: 将按估算数量入账, 影响对账');
      case WeighCountContext.count:
        buttons = [
          UtenButton(
            key: const ValueKey('weigh-count-secondary'),
            type: UtenButtonType.secondary,
            onPressed: hasNet ? () => _submit(fillQty: false) : null,
            child: const Text('只记重量'),
          ),
          UtenButton(
            key: const ValueKey('weigh-count-primary'),
            isLoading: _busy,
            onPressed: hasNet && canFill ? () => _submit(fillQty: true) : null,
            child: const Text('填入数量和重量'),
          ),
        ];
      case WeighCountContext.outbound:
        buttons = [
          UtenButton(
            key: const ValueKey('weigh-count-primary'),
            isLoading: _busy,
            onPressed: hasNet ? () => _submit(fillQty: false) : null,
            child: const Text('填入重量'),
          ),
        ];
      case WeighCountContext.standalone:
        buttons = [
          UtenButton(
            key: const ValueKey('weigh-count-secondary'),
            type: UtenButtonType.secondary,
            onPressed: _busy ? null : _reset,
            child: const Text('清空重来'),
          ),
          UtenButton(
            key: const ValueKey('weigh-count-primary'),
            isLoading: _busy,
            onPressed: hasNet && _sample != null && _canSaveSample
                ? () => _submit(fillQty: false)
                : null,
            child: const Text('保存抽样'),
          ),
        ];
    }
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (warning != null)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: DefaultTextStyle.merge(
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
              textAlign: TextAlign.center,
              child: KeyedSubtree(
                key: const ValueKey('weigh-count-fill-warning'),
                child: warning,
              ),
            ),
          ),
        // 按钮整体居中 (全仓弹窗统一规范)。
        Wrap(
          alignment: WrapAlignment.center,
          spacing: UtenSpacing.s8,
          runSpacing: UtenSpacing.s8,
          children: [?cancel, ...buttons],
        ),
      ],
    );
  }
}

/// 抽样重量输入框里的单位切换 (「克▾」), 选择记为用户抽样单位偏好。
class _SampleUnitMenu extends StatelessWidget {
  const _SampleUnitMenu({required this.unit, required this.onSelected});

  final WeightUnit unit;
  final ValueChanged<WeightUnit> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<WeightUnit>(
    key: const ValueKey('weigh-count-sample-unit'),
    tooltip: '抽样重量单位',
    initialValue: unit,
    onSelected: onSelected,
    itemBuilder: (_) => [
      for (final u in WeightUnit.values)
        PopupMenuItem(value: u, child: Text(u.label)),
    ],
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [Text(unit.label), const Icon(Icons.arrow_drop_down)],
      ),
    ),
  );
}
