// 采集表格「实称重量」列 (ADR-135 §6.2, review/product.md §1.1): 所有仓库采集表格共用。
//
// - 列放在数量组之后 (单位跟在数量后面时放在单位之后); 表头「实称重量(kg)」随录入单位变化,
//   单位由工具条「称重单位: 千克▾」([WeightEntryUnitButton]) 切换 (用户级偏好, 不做逐行下拉)。
// - 格子接受带后缀的输入 (850g / 1.2t / 3斤 / 2lb), 失焦后规范成列单位; 0 或空 = 没称。
// - 有可靠依据时预填建议重量(黄框待核对, 与全站预填口径一致)；用户改字后停止自动覆盖；
//   货品/行单位本身是重量单位时只读灰字「=25 kg」(服务端按数量精确换算)。
// - 偏差: 琥珀框与文字提示，悬停给出依据；说明图标统一放表头。
// - 格子外层 Tooltip 恒定包裹(空闲时给一句固定短提示): message 在 null/非null 间切换
//   会让 Flutter 废弃重建 TextField 元素, 输入一位光标就丢(同 uten_editable_grid
//   RequiredCellFrame 2026-10-06 的病灶), 结构恒定才能保住焦点。
// - **重量格与数量格永不批量生效**: 勾选多行后改一行的重量只改这一行 (一次称重是一个
//   物理事实, 绝不能复制到其它行); 页面级的只有工具条上的录入单位。
// - 数量为空 (盘点实盘 / 其它入库) 且单重不是未学准时, 填重量自动推算数量 (黄框预填,
//   ⓘ「按称重推算 5,373~5,449个」), 行打上 qtyFromWeight; 改重量才清除该标记,
//   改数量只清黄框、不会让这行重新参与学习。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/theme/uten_tokens.dart';
import '../weight_params.dart';
import '../weight_predictor.dart';
import '../weight_prefs.dart';
import '../weight_unit.dart';
import 'weight_text.dart';

/// 表头说明 (ⓘ)。
const String weightColumnHeaderInfo =
    '填净重(扣除箱/袋); 可直接输 850g、1.2t、3斤。'
    '系统按对应库存或历史实称预填建议，标为“预估”；输入秤上读数才记实称。'
    '偏差较大时黄框提醒核对数量、单位与皮重；空着=没称。';

/// 非法输入提示。
const String weightInputErrorText = '看不懂这个重量, 例: 850g、1.2t、3斤、12';

/// 重量格空闲(无错误/偏差/核对说明)时 Tooltip 的固定短提示。
///
/// 格子外层 Tooltip 必须恒定包裹才能保住输入焦点(见文件头注释)，所以没有
/// 专属说明可展示时兜底显示这一句，而不是移除 Tooltip 导致结构切换。
const String weightCellIdleTooltip = '可直接输 850g、1.2t、3斤；空着=没称';

/// 一行的重量录入状态 (放在行 model 里, 跟行一起创建/释放, 跨重建存活)。
///
/// 事实源是 [kg] (千克, HALF_UP 4 位); [text] 只是它在当前录入单位 [unit] 下的样子。
/// 用户敲字 -> 重新解析 (支持单位后缀); 程序写值 ([setKg] / [switchUnit] / [normalize])
/// 不重新解析, 保证 lb/oz 这类非十进制换算来回切换不漂。
class WeightEntryController extends ChangeNotifier {
  WeightEntryController({
    double? kg,
    WeightUnit unit = WeightUnit.kg,
    this._qtyFromWeight = false,
  }) : _unit = unit,
       _kg = _positiveKg(kg) {
    _userEdited = _kg != null;
    text = TextEditingController(text: _kg == null ? '' : unit.editText(_kg!));
    _lastText = text.text;
    text.addListener(_onText);
  }

  late final TextEditingController text;

  WeightUnit _unit;
  double? _kg;
  double? _suggestedKg;
  String? _suggestionSource;
  late bool _userEdited;
  String? _error;
  bool _qtyFromWeight;
  bool _programmatic = false;
  late String _lastText;
  String? _autofilledQtyText;
  String? _qtyEstimateNote;

  /// 当前录入单位 (文本按它理解)。
  WeightUnit get unit => _unit;

  /// 千克 (HALF_UP 4 位); 空/0/非法 = null (没称)。
  double? get kg => _kg;

  /// 当前自动预填（千克）。只供呈现；不得提交为实称或参与学习。
  double? get suggestedKg => _suggestedKg;
  double? get displayKg => _kg ?? _suggestedKg;
  bool get isSuggested => _suggestedKg != null;
  String? get suggestionSource => _suggestionSource;
  bool get userEdited => _userEdited;

  /// 同步数量/库存/单重变化。人工改过、清空过或恢复的实称永不覆盖。
  void setSuggestedKg(double? kg, {String? source}) {
    if (_userEdited) return;
    final next = _positiveKg(kg);
    final nextSource = next == null ? null : source;
    if (_suggestedKg == next && _suggestionSource == nextSource) return;
    _suggestedKg = next;
    _suggestionSource = nextSource;
    _writeText(next == null ? '' : _unit.editText(next));
    notifyListeners();
  }

  /// 用户明确输入了秤上读数（包括与预填恰好相同的数字）。
  void acceptUserInput() {
    if (_userEdited) return;
    _userEdited = true;
    _suggestedKg = null;
    _suggestionSource = null;
    _reparse();
    notifyListeners();
  }

  /// 文本非空但看不懂/为负。
  bool get hasError => _error != null;
  String? get errorText => _error;

  /// 这行的数量是按称重折算的 (不参与单重学习; 服务端哈希/客户端幂等键都要带上)。
  bool get qtyFromWeight => _qtyFromWeight;
  set qtyFromWeight(bool value) {
    if (value == _qtyFromWeight) return;
    _qtyFromWeight = value;
    if (!value) {
      _qtyEstimateNote = null;
      _autofilledQtyText = null;
    }
    notifyListeners();
  }

  /// 数量格黄框 ⓘ 的来源说明 (如「按称重推算 5,373~5,449个」); 数量格 sourceOf 读它。
  String? get qtyEstimateNote => _qtyEstimateNote;
  set qtyEstimateNote(String? value) {
    if (value == _qtyEstimateNote) return;
    _qtyEstimateNote = value;
    notifyListeners();
  }

  /// 幂等键/指纹片段: `千克|是否按称重改数量` (千克去尾零, 没称为空)。
  String get canonicalKeyPart =>
      '${weightKeyPart(_kg)}|${_qtyFromWeight ? 1 : 0}';

  /// 最近一次按称重预填进数量格的文本 (数量格仍是这段黄框预填时, 重量再变可跟着重算/清除)。
  String? get derivedQtyText => _autofilledQtyText;

  /// 记下「数量是按本次重量折算预填的」: 打上 qtyFromWeight 并保存预填文本与 ⓘ 说明。
  void markQtyDerived(String qtyText, {String? note}) {
    _autofilledQtyText = qtyText;
    _qtyFromWeight = true;
    _qtyEstimateNote = note;
    notifyListeners();
  }

  /// 程序写入千克值 (称重计数回填/草稿恢复); 默认视为重量变了 -> 清 qtyFromWeight。
  void setKg(double? kg, {bool qtyFromWeight = false, bool userEdited = true}) {
    _userEdited = userEdited || _positiveKg(kg) != null;
    _suggestedKg = null;
    _suggestionSource = null;
    _kg = _positiveKg(kg);
    _error = null;
    _writeText(_kg == null ? '' : _unit.editText(_kg!));
    _qtyFromWeight = qtyFromWeight;
    if (!qtyFromWeight) {
      _qtyEstimateNote = null;
      _autofilledQtyText = null;
    }
    notifyListeners();
  }

  /// 切换录入单位: 千克值不变, 文本改写成新单位 (非法文本原样保留、按新单位重新解析)。
  void switchUnit(WeightUnit next) {
    if (next == _unit) return;
    _unit = next;
    if (_error != null) {
      _reparse();
    } else if (displayKg != null) {
      _writeText(next.editText(displayKg!));
    }
    notifyListeners();
  }

  /// 失焦/回车: 把带后缀或带千分位的输入规范成列单位的纯数字; 0 清空。
  void normalize() {
    if (_error != null) return;
    final canonical = displayKg == null ? '' : _unit.editText(displayKg!);
    if (canonical == text.text) return;
    _writeText(canonical);
    notifyListeners();
  }

  void _writeText(String value) {
    _programmatic = true;
    try {
      text.value = TextEditingValue(
        text: value,
        selection: TextSelection.collapsed(offset: value.length),
      );
      _lastText = value;
    } finally {
      _programmatic = false;
    }
  }

  void _onText() {
    if (text.text == _lastText) return; // 只是光标/选区变化
    _lastText = text.text;
    if (_programmatic) return;
    _userEdited = true;
    _suggestedKg = null;
    _suggestionSource = null;
    _reparse();
    // 用户改了重量: 之前「按称重折算的数量」不再对应这次重量。
    _qtyFromWeight = false;
    _qtyEstimateNote = null;
    notifyListeners();
  }

  void _reparse() {
    final raw = text.text.trim();
    if (raw.isEmpty) {
      _kg = null;
      _error = null;
      return;
    }
    final parsed = parseWithSuffix(raw, _unit);
    if (parsed == null) {
      _kg = null;
      _error = weightInputErrorText;
      return;
    }
    _error = null;
    _kg = _positiveKg(parsed.kgLine);
  }

  @override
  void dispose() {
    text
      ..removeListener(_onText)
      ..dispose();
    super.dispose();
  }

  static double? _positiveKg(double? kg) {
    final rounded = roundKgLine(kg);
    return rounded == null || rounded <= 0 ? null : rounded;
  }
}

/// 可选: 行 model 混入一个现成的 [weightEntry] (随行释放)。
mixin WeightEntryRowMixin on EditableGridRow {
  final WeightEntryController weightEntry = WeightEntryController();

  @override
  void dispose() {
    weightEntry.dispose();
    super.dispose();
  }
}

/// 「数量空着时按称重推算数量」的接线 (盘点实盘 / 其它入库)。
class WeightQtyAutofill<T> {
  const WeightQtyAutofill({
    required this.qtyControllerOf,
    this.unitRateOf,
    this.enabledOf,
  });

  /// 数量格控制器 (黄框预填)。
  final UtenAutofillTextController Function(T row) qtyControllerOf;

  /// 1 个行单位 = 多少基本单位 (unit_rate); 不给 = 1。
  final double? Function(T row)? unitRateOf;

  /// 行级开关 (如只读行/已过账行关闭)。
  final bool Function(T row)? enabledOf;
}

/// 采集表格「实称重量(单位)」列。
///
/// - [controllerOf]: 行上的 [WeightEntryController];
/// - [entryUnit]: 录入单位 (页面 watch [warehouseWeightUnitsPrefsProvider] 后传 `.entry`);
/// - [paramsOf] + [paramsListenable]: 该行单重参数 (通常取自 [WeightParamsCache]), 参数到达后格子重绘;
/// - [qtyBaseOf] + [qtyListenableOf]: 本行数量 (基本单位) 与其变更源, 用于占位与偏差;
/// - [exactKgOf]: 行单位是重量单位时的精确重量 (只读); 不给则按参数 EXACT x 数量;
/// - [onWeighCount]: 给了就在格内挂 ⚖ 按钮 (打开称重计数)。
EditableGridColumn<T> weightGridColumn<T extends EditableGridRow>({
  required WeightEntryController Function(T row) controllerOf,
  required WeightUnit entryUnit,
  String key = 'weight',
  String label = '实称重量',
  double width = 150,
  WeightCaptureMode mode = WeightCaptureMode.inbound,
  WeightParams? Function(T row)? paramsOf,
  Listenable? paramsListenable,
  double? Function(T row)? qtyBaseOf,
  Listenable? Function(T row)? qtyListenableOf,
  double? Function(T row)? exactKgOf,
  double? Function(T row)? expectedKgOf,
  String? Function(T row)? expectedSourceOf,
  String? Function(T row)? baseUnitNameOf,
  bool Function(T row)? enabledOf,
  bool required = false,
  bool Function(T row)? requiredOf,
  WeightQtyAutofill<T>? qtyAutofill,
  Future<void> Function(BuildContext context, T row)? onWeighCount,
  ValueChanged<T>? onChanged,
  String? headerInfo = weightColumnHeaderInfo,
}) {
  return EditableGridColumn<T>(
    key: key,
    label: '$label(${entryUnit.symbol})',
    width: width,
    numeric: true,
    // Formula facts use kilograms regardless of the entry/display unit, and
    // follow the same exact-unit precedence as the visible weight cell.
    exactValueOf: (row) =>
        (_exactKg(row, exactKgOf, paramsOf, qtyBaseOf) ?? controllerOf(row).kg)
            ?.toString(),
    exactListenableOf: (row) => Listenable.merge([
      controllerOf(row),
      ?qtyListenableOf?.call(row),
      ?paramsListenable,
    ]),
    required: required,
    headerInfo: headerInfo,
    chromeWidth: onWeighCount == null
        ? 0
        : UtenEditableGridCellSpec.hintIconWidth,
    frozenTextOf: (row) {
      final exact = _exactKg(row, exactKgOf, paramsOf, qtyBaseOf);
      if (exact != null) return '=${formatWeight(exact)}';
      final controller = controllerOf(row);
      return '${controller.isSuggested ? '≈' : ''}${controller.text.text}';
    },
    cellBuilder: (context, row) => _WeightCell<T>(
      row: row,
      controller: controllerOf(row),
      entryUnit: entryUnit,
      mode: mode,
      paramsOf: paramsOf,
      paramsListenable: paramsListenable,
      qtyBaseOf: qtyBaseOf,
      qtyListenable: qtyListenableOf?.call(row),
      exactKgOf: exactKgOf,
      expectedKgOf: expectedKgOf,
      expectedSourceOf: expectedSourceOf,
      baseUnitName: baseUnitNameOf?.call(row),
      enabled: enabledOf?.call(row) ?? true,
      required: requiredOf?.call(row) ?? required,
      qtyAutofill: qtyAutofill,
      onWeighCount: onWeighCount,
      onChanged: onChanged,
    ),
  );
}

double? _exactKg<T>(
  T row,
  double? Function(T row)? exactKgOf,
  WeightParams? Function(T row)? paramsOf,
  double? Function(T row)? qtyBaseOf,
) {
  if (exactKgOf != null) {
    final v = exactKgOf(row);
    if (v != null) return roundKgLine(v);
  }
  final params = paramsOf?.call(row);
  if (params == null || !params.isExact) return null;
  final qty = qtyBaseOf?.call(row);
  if (qty == null || qty <= 0) return null;
  return roundKgLine(qty * params.massFactorKg!);
}

class _WeightCell<T extends EditableGridRow> extends StatefulWidget {
  const _WeightCell({
    required this.row,
    required this.controller,
    required this.entryUnit,
    required this.mode,
    required this.paramsOf,
    required this.paramsListenable,
    required this.qtyBaseOf,
    required this.qtyListenable,
    required this.exactKgOf,
    required this.expectedKgOf,
    required this.expectedSourceOf,
    required this.baseUnitName,
    required this.enabled,
    required this.required,
    required this.qtyAutofill,
    required this.onWeighCount,
    required this.onChanged,
  });

  final T row;
  final WeightEntryController controller;
  final WeightUnit entryUnit;
  final WeightCaptureMode mode;
  final WeightParams? Function(T row)? paramsOf;
  final Listenable? paramsListenable;
  final double? Function(T row)? qtyBaseOf;
  final Listenable? qtyListenable;
  final double? Function(T row)? exactKgOf;
  final double? Function(T row)? expectedKgOf;
  final String? Function(T row)? expectedSourceOf;
  final String? baseUnitName;
  final bool enabled;
  final bool required;
  final WeightQtyAutofill<T>? qtyAutofill;
  final Future<void> Function(BuildContext context, T row)? onWeighCount;
  final ValueChanged<T>? onChanged;

  @override
  State<_WeightCell<T>> createState() => _WeightCellState<T>();
}

class _WeightCellState<T extends EditableGridRow>
    extends State<_WeightCell<T>> {
  /// 焦点归格子自己 (不放进行 model: 同一个 FocusNode 不能挂到两个输入框上)。
  final FocusNode _focus = FocusNode(debugLabel: 'weight-cell');
  bool _syncScheduled = false;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocus);
    _scheduleSync();
  }

  @override
  void didUpdateWidget(covariant _WeightCell<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleSync();
  }

  @override
  void dispose() {
    _focus
      ..removeListener(_onFocus)
      ..dispose();
    super.dispose();
  }

  /// 失焦: 带后缀/千分位的输入规范成列单位的纯数字。
  void _onFocus() {
    if (!_focus.hasFocus) widget.controller.normalize();
  }

  /// 构建与参数异步到达时下一帧同步，回调执行时读当前行，避免旧值覆盖新行。
  void _scheduleSync() {
    if (_syncScheduled) return;
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) return;
      widget.controller.switchUnit(widget.entryUnit);
      final exact = _exactKg(
        widget.row,
        widget.exactKgOf,
        widget.paramsOf,
        widget.qtyBaseOf,
      );
      final suggestion = widget.enabled && exact == null ? _suggestion() : null;
      widget.controller.setSuggestedKg(
        suggestion?.kg,
        source: suggestion?.source,
      );
    });
  }

  WeightSuggestion? _suggestion() {
    final qty = widget.qtyBaseOf?.call(widget.row);
    if (widget.qtyBaseOf != null &&
        (qty == null || !qty.isFinite || qty <= 0)) {
      return null;
    }
    final override = widget.expectedKgOf?.call(widget.row);
    if (override != null && override.isFinite && override > 0) {
      return WeightSuggestion(
        kg: override,
        source: widget.expectedSourceOf?.call(widget.row) ?? '按对应库存重量预填',
        tolerancePct: 5,
        inventoryBased: true,
      );
    }
    return widget.paramsOf
        ?.call(widget.row)
        ?.suggestionFor(qty, mode: widget.mode);
  }

  /// 用户敲重量: 只动本行 (永不批量), 需要时按称重推算数量。
  void _handleChanged(String _) {
    widget.controller.acceptUserInput();
    _maybeAutofillQty();
    widget.onChanged?.call(widget.row);
  }

  void _maybeAutofillQty() {
    final autofill = widget.qtyAutofill;
    if (autofill == null) return;
    final row = widget.row;
    if (!(autofill.enabledOf?.call(row) ?? true)) return;
    final weight = widget.controller;
    final qty = autofill.qtyControllerOf(row);
    final qtyText = qty.text.trim();
    final derivedBefore =
        qty.autofilled &&
        weight.derivedQtyText != null &&
        qty.text == weight.derivedQtyText;
    if (qtyText.isNotEmpty && !derivedBefore) return;

    final params = widget.paramsOf?.call(row);
    final kg = weight.kg;
    final usable =
        kg != null &&
        params != null &&
        params.predictable &&
        params.effectiveTier != WeightTier.red;
    if (!usable) {
      if (derivedBefore) qty.setAutomaticText('');
      weight.qtyFromWeight = false;
      return;
    }
    final estimate = params.countFromWeight(kg);
    if (estimate == null) return;
    final base = WeightPredictor.roundQty(
      estimate.estimatedQty,
      integer: params.integerQty,
    );
    final rate = autofill.unitRateOf?.call(row) ?? 1;
    final lineQty = rate > 0 && rate != 1
        ? WeightPredictor.roundQty(base / rate, integer: false)
        : base;
    final text = plainWeighQtyText(lineQty);
    qty.setAutomaticText(text);
    final range = formatWeighQtyRange(
      estimate,
      integer: params.integerQty,
      unitName: widget.baseUnitName,
    );
    weight.markQtyDerived(text, note: '按称重推算 $range');
  }

  @override
  Widget build(BuildContext context) {
    // 数量/参数变化也要重绘: 精确换算的只读值、占位与偏差都依赖它们。
    final listenables = <Listenable>[
      widget.controller,
      ?widget.paramsListenable,
      ?widget.qtyListenable,
    ];
    return ListenableBuilder(
      listenable: Listenable.merge(listenables),
      builder: (context, _) {
        _scheduleSync();
        final exact = _exactKg<T>(
          widget.row,
          widget.exactKgOf,
          widget.paramsOf,
          widget.qtyBaseOf,
        );
        if (exact != null) return _ExactWeightText(kg: exact);
        final field = _buildField(context);
        if (!widget.required) return field;
        return RequiredCellFrame(
          listenable: widget.controller,
          isEmpty: () => widget.controller.kg == null,
          child: field,
        );
      },
    );
  }

  Widget _buildField(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.controller;
    final params = widget.paramsOf?.call(widget.row);
    final qtyBase = widget.qtyBaseOf?.call(widget.row);
    final suggestion = _suggestion();
    final stockReference = suggestion?.inventoryBased ?? false;
    final check = c.qtyFromWeight || params == null
        ? null
        : params.check(qtyBase: qtyBase, weightKg: c.kg, mode: widget.mode);
    final deviation =
        !c.qtyFromWeight &&
        c.kg != null &&
        (stockReference
            ? (suggestion?.differsFrom(
                    c.kg,
                    scaleResKg:
                        params?.scaleResKg ?? WeightPredictor.defaultScaleResKg,
                  ) ??
                  false)
            : (check?.level != null && check!.level != WeightAlertLevel.none));
    String? info = c.isSuggested
        ? '${c.suggestionSource ?? '系统预填'}；预估 ${formatWeight(c.suggestedKg!, display: WeightDisplay.of(widget.entryUnit))}，尚未实称。请输入秤上读数。'
        : null;
    final error = c.errorText;
    if (error == null && c.kg != null && params != null) {
      if (check != null && params.alertsEnabled && !stockReference) {
        info = weightCheckTooltip(
          check,
          params,
          mode: widget.mode,
          unitName: widget.baseUnitName,
          display: WeightDisplay.of(widget.entryUnit),
        );
      } else if (!c.qtyFromWeight &&
          params.basis != WeightBasis.exact &&
          !params.alertsEnabled) {
        info = weightNotLearnedHint;
      }
    }
    if (stockReference && suggestion != null && c.kg != null) {
      info =
          '${suggestion.source}：预计 ${formatWeight(suggestion.kg, display: WeightDisplay.of(widget.entryUnit))}，'
          '实称 ${formatWeight(c.kg!, display: WeightDisplay.of(widget.entryUnit))}，'
          '偏差 ${formatSignedPct((c.kg! / suggestion.kg - 1) * 100)}。';
    }
    if (deviation) info = '数值可能有问题，请核对数量、重量单位和皮重。${info ?? ''}';

    final borderColor = error != null
        ? theme.colorScheme.error
        : deviation
        ? weightAlertColor(theme, WeightAlertLevel.warn)
        : null;
    OutlineInputBorder? border({required bool focused}) => borderColor == null
        ? null
        : OutlineInputBorder(
            borderRadius: UtenRadius.controlAll,
            borderSide: BorderSide(
              color: borderColor,
              width: focused ? 2 : 1.5,
            ),
          );

    final suffix = <Widget>[
      if (widget.onWeighCount != null)
        IconButton(
          key: const ValueKey('weight-cell-weigh'),
          tooltip: widget.mode == WeightCaptureMode.outbound ? '称重核对' : '称重算数量',
          onPressed: widget.enabled
              ? () => widget.onWeighCount!(context, widget.row)
              : null,
          // 2026-10-10 表格内输入框高度统一：44 触控槽会把整格撑到 44+，比同行
          // 27 高的库位/数量格明显高一截。格内图标口径 = 16px 图标 + 24 命中槽
          // (16 图标 + 4 边距，不超同行输入格 27 的自然高度)。
          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          padding: const EdgeInsets.all(UtenSpacing.s4),
          icon: const Icon(Icons.scale_outlined, size: 16),
        ),
    ];

    final field = TextField(
      key: const ValueKey('weight-cell-input'),
      controller: c.text,
      focusNode: _focus,
      enabled: widget.enabled,
      keyboardType: TextInputType.text,
      onChanged: _handleChanged,
      onSubmitted: (_) => c.normalize(),
      decoration: applyAutofillHint(
        UtenInputDecoration(
          InputDecoration(
            isDense: true,
            hintText: _placeholder(params, qtyBase),
            enabledBorder: border(focused: false),
            focusedBorder: border(focused: true),
            // 格内 suffix 不吃 48×48 默认触控槽(2026-10-06 口径)；无 ⓘ 时
            // 24 槽的称重按钮不再把框撑高，重量格与同行输入格等高。
            suffixIconConstraints: const BoxConstraints(
              minWidth: 24,
              minHeight: 24,
            ),
            suffixIcon: suffix.isEmpty
                ? null
                : Row(mainAxisSize: MainAxisSize.min, children: suffix),
          ),
          info: c.isSuggested
              ? '${c.suggestionSource ?? '系统预填'}；预估 ${formatWeight(c.suggestedKg!, display: WeightDisplay.of(widget.entryUnit))}，尚未实称。请输入秤上读数。'
              : null,
        ),
        theme,
        autofilled: c.isSuggested && error == null && !deviation,
      ),
    );
    final message = error ?? info;
    final content = Column(
      key: const ValueKey('weight-cell-content'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        field,
        if (error != null || deviation)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: error != null
                ? UtenFieldMessage.error(
                    error,
                    key: const ValueKey('weight-cell-message'),
                    maxLines: 2,
                  )
                : const UtenFieldMessage.autofill(
                    '数值可能有问题',
                    key: ValueKey('weight-cell-message'),
                    maxLines: 2,
                  ),
          ),
      ],
    );
    // 结构恒定：空闲时也包一层 Tooltip(给固定短提示)。若按 message 有无切换
    // Tooltip 包裹，首个字符击键就会让 TextField 元素被废弃重建、光标丢失
    // (用户得再点一次才能继续输)；恒定结构下只有文本在变。
    return Tooltip(message: message ?? weightCellIdleTooltip, child: content);
  }

  String _placeholder(WeightParams? params, double? qtyBase) {
    if (params == null ||
        !params.predictable ||
        params.effectiveTier == WeightTier.red) {
      return '可选';
    }
    final expected = params.expectedKgFor(qtyBase);
    if (expected == null) return '可选';
    final number = widget.entryUnit.format(expected, withSymbol: false);
    return widget.mode == WeightCaptureMode.outbound
        ? '应称 $number'
        : '约 $number';
  }
}

/// 回填进数量输入框的纯数字文本 (无千分位, 最多 4 位小数, 去尾零)。
String plainWeighQtyText(double qty) {
  if (qty == qty.roundToDouble()) return qty.toStringAsFixed(0);
  return qty
      .toStringAsFixed(4)
      .replaceFirst(RegExp(r'0+$'), '')
      .replaceFirst(RegExp(r'\.$'), '');
}

/// 精确换算的只读重量 (灰字「=25 kg」)。
class _ExactWeightText extends StatelessWidget {
  const _ExactWeightText({required this.kg});

  final double kg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: '按数量精确换算, 不用称',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
        child: Text(
          '=${formatWeight(kg)}',
          key: const ValueKey('weight-cell-exact'),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// 工具条「称重单位: 千克▾」: 写用户录入单位偏好, 所有采集表格表头与格子跟着换。
class WeightEntryUnitButton extends ConsumerWidget {
  const WeightEntryUnitButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final prefs = ref.watch(warehouseWeightUnitsPrefsProvider);
    return WeightUnitMenuButton<WeightUnit>(
      key: const ValueKey('weight-entry-unit-button'),
      prefix: '称重单位',
      value: prefs.entry,
      options: WeightUnit.values,
      labelOf: (u) => u.label,
      onSelected: ref.read(warehouseWeightUnitsPrefsProvider.notifier).setEntry,
    );
  }
}

/// 行右键菜单的称重条目 (`称重计数...` / `称样校准...`); 回调为 null 的条目不出现。
List<UtenContextMenuEntry> weightRowMenuEntries({
  FutureOr<void> Function()? onWeighCount,
  FutureOr<void> Function()? onSample,
  bool sampleEnabled = true,
}) => [
  if (onWeighCount != null)
    UtenMenuItem(
      label: '称重计数...',
      icon: Icons.scale_outlined,
      onTap: onWeighCount,
    ),
  if (onSample != null)
    UtenMenuItem(
      label: '称样校准...',
      icon: Icons.tune_rounded,
      enabled: sampleEnabled,
      onTap: onSample,
    ),
];

/// 表尾「称重偏差 N 行」计数: 逐行按参数核对 (按称重改过数量的行不算)。
int weightDeviationRowCount<T>(
  Iterable<T> rows, {
  required WeightEntryController Function(T row) controllerOf,
  required WeightParams? Function(T row) paramsOf,
  required double? Function(T row) qtyBaseOf,
  WeightCaptureMode mode = WeightCaptureMode.inbound,
}) {
  var count = 0;
  for (final row in rows) {
    final c = controllerOf(row);
    if (c.qtyFromWeight || c.kg == null) continue;
    final params = paramsOf(row);
    final suggestion = params?.suggestionFor(qtyBaseOf(row), mode: mode);
    if (suggestion?.inventoryBased ?? false) {
      if (suggestion!.differsFrom(c.kg, scaleResKg: params!.scaleResKg)) {
        count++;
      }
    } else {
      final check = params?.check(
        qtyBase: qtyBaseOf(row),
        weightKg: c.kg,
        mode: mode,
      );
      if (check != null && check.level != WeightAlertLevel.none) count++;
    }
  }
  return count;
}
