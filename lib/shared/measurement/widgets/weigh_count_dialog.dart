import 'package:collection/collection.dart';
import 'package:uten_imp/components/buttons/uten_close_button.dart';
import '../../../core/network/business_precision.dart';
import '../../../core/network/business_precision_coordinator.dart';
import '../../drafts/form_draft_mixin.dart';
import '../../drafts/form_draft_catalog.dart';
import '../../auth/permissions.dart';
import '../../auth/read_owner_fence.dart';
import '../../providers/authenticated_scope_provider.dart';
import '../../formatters/exact_decimal.dart';
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
// 估算保留模型有效位；采用数量由用户确认，不按 COUNT 偏好自动取整。
//
// 本弹窗**不调用任何库存过账接口**: 只返回 [WeighCountResult] 让页面回填;
// 唯一的写是「本批抽样」-> POST samples (SAMPLE 记录, 自动带上到货供应商) 与
// 有管理权限时「记住为本货品皮重」-> PUT profile。
import '../../../components/inputs/uten_dropdown_scroll_scope.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_autofill_text_controller.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/idempotency_key.dart';
import '../weight_params.dart';
import '../weight_predictor.dart';
import '../weight_prefs.dart';
import '../weight_unit.dart';
import '../weight_quantity_adoption.dart';
import 'weight_grid_column.dart';
import 'weight_params_load_notice.dart';
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
    this.initialNetKgExact,
    this.currentQtyExact,
    this.unitRateExact,
    this.integerQty,
    this.sampleRemark,
    this.canSaveSample,
    this.expectedWeightKg,
    this.expectedWeightSource,
    this.colorId,
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
  final String? colorId;

  /// Reference only; never initializes the actual scale reading.
  final double? expectedWeightKg;
  final String? expectedWeightSource;
  final String? baseUnitName;
  final String? lineUnitName;

  /// 1 个行单位 = 多少基本单位。
  final double unitRate;

  /// 行上现有数量 (行单位): 到货 = 登记数量, 出库 = 应发数量。
  final double? currentQty;

  /// 格子里已有的净重 (千克), 带进来当第一次称重。
  final double? initialNetKg;
  final String? initialNetKgExact, currentQtyExact, unitRateExact;

  /// 仅区间/差异等估算说明的旧显示口径，不适用于实际采用数量。
  final bool? integerQty;

  /// 抽样记录备注 (如单号)。
  final String? sampleRemark;

  /// 能否保存抽样; null = 按当前用户权限。
  final bool? canSaveSample;

  Map<String, dynamic> toDraftJson() => {
    'mode': mode.name,
    'goodsId': goodsId,
    'goodsTitle': goodsTitle,
    'supplierId': supplierId,
    'warehouseId': warehouseId,
    'colorId': colorId,
    'baseUnitName': baseUnitName,
    'lineUnitName': lineUnitName,
    'unitRate': unitRateExact ?? unitRate.toString(),
    'currentQty': currentQtyExact ?? financeExactDecimal(currentQty),
    'initialNetKg': initialNetKgExact ?? financeExactDecimal(initialNetKg),
    'integerQty': integerQty,
    'sampleRemark': sampleRemark,
    'canSaveSample': canSaveSample,
    'expectedWeightKg': financeExactDecimal(expectedWeightKg),
    'expectedWeightSource': expectedWeightSource,
  };
  factory WeighCountRequest.fromDraftJson(Map<String, dynamic> data) =>
      WeighCountRequest(
        mode: WeighCountContext.values.byName(data['mode'] as String),
        goodsId: data['goodsId'] as String,
        goodsTitle: data['goodsTitle'] as String,
        supplierId: data['supplierId'] as String?,
        warehouseId: data['warehouseId'] as String?,
        colorId: data['colorId'] as String?,
        baseUnitName: data['baseUnitName'] as String?,
        lineUnitName: data['lineUnitName'] as String?,
        unitRate: double.parse(data['unitRate'] as String),
        unitRateExact: data['unitRate'] as String,
        currentQty: double.tryParse(data['currentQty']?.toString() ?? ''),
        currentQtyExact: data['currentQty'] as String?,
        initialNetKg: double.tryParse(data['initialNetKg']?.toString() ?? ''),
        initialNetKgExact: data['initialNetKg'] as String?,
        integerQty: data['integerQty'] as bool?,
        sampleRemark: data['sampleRemark'] as String?,
        canSaveSample: data['canSaveSample'] as bool?,
        expectedWeightKg: double.tryParse(
          data['expectedWeightKg']?.toString() ?? '',
        ),
        expectedWeightSource: data['expectedWeightSource'] as String?,
      );
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
    this.netKgExact,
    this.grossKg,
    this.grossKgExact,
    this.tareKg,
    this.tareKgExact,
    this.qty,
    this.qtyExact,
    this.qtyBase,
    this.qtyBaseExact,
    this.qtyFromWeight = false,
    this.sample,
    this.qtyEstimateNote,
  });

  /// 净重；完整十进制原文为事实源。
  final double netKg;
  final String? netKgExact;
  String get netKgText => financeExactTrimmed(netKgExact ?? netKg.toString())!;
  final double? grossKg;
  final String? grossKgExact;
  String? get grossKgText =>
      financeExactTrimmed(grossKgExact ?? grossKg?.toString());

  /// 扣掉的皮重合计 (千克)。
  final double? tareKg;
  final String? tareKgExact;
  String? get tareKgText =>
      financeExactTrimmed(tareKgExact ?? tareKg?.toString());

  /// 回填的数量 (行单位); null = 只记重量。
  final double? qty;
  final String? qtyExact;
  final double? qtyBase;
  final String? qtyBaseExact;
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
  builder: (dialogContext) => UtenAlertDialog(
    title: Text(
      '${request.mode == WeighCountContext.outbound ? '出库称重核对' : '称重算数量'} · ${request.goodsTitle}',
    ),
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
  weight.setKgText(result.netKgText, qtyFromWeight: result.qtyFromWeight);
  final text =
      result.qtyExact ??
      (result.qty == null ? null : plainWeighQtyText(result.qty!));
  if (text != null && qty != null) {
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
    this.resumeDraftId,
  });

  final WeighCountRequest request;
  final ValueChanged<WeighCountResult> onSubmit;
  final VoidCallback? onCancel;
  final bool embedded;
  final String? resumeDraftId;

  @override
  ConsumerState<WeighCountPanel> createState() => _WeighCountPanelState();
}

class _WeighCountPanelState extends ConsumerState<WeighCountPanel>
    with FormDraftMixin<WeighCountPanel> {
  final List<TextEditingController> _gross = [];
  final _tare = TextEditingController();
  final _pieces = TextEditingController();
  final _sampleQty = TextEditingController();
  final _sampleWeight = TextEditingController();
  final _adoptedQty = TextEditingController();
  bool _adoptedEdited = false, _resolvingQty = false;
  String? _adoptionSource, _adoptedOriginalInput;
  int _quantityEpoch = 0;
  int _openedAt = DateTime.now().microsecondsSinceEpoch;
  WeightSampleRequest? _sampleSent;
  WeightProfileUpdate? _profileSent;
  WeighCountResult? _frozenResult;
  bool _sampleConfirmed = false,
      _profileConfirmed = false,
      _outcomeUnknown = false,
      _ready = false,
      _ownerRetired = false;
  late bool Function() _ownerCurrent;
  late String _permission;
  WeightUnitsPrefs? _draftUnits;
  BusinessPrecisionChoice? _qtyChoice;

  WeightParams? _params;
  bool _loadingParams = false;

  /// 取单重失败的原因: 重量照常能记, 只是不能折算; 显示出来并可重试 (ADR-151)。
  Object? _paramsError;
  bool _piecesEdited = false;
  bool _rememberTare = false;
  bool _busy = false;
  String? _submitError;

  @override
  FormDraftSpec get formDraftSpec =>
      (_permission == Perm.stockWeightManage
              ? FormDraftCatalog.weighCountManage
              : _permission == Perm.stockDocEdit
              ? FormDraftCatalog.weighCountDocument
              : _permission == Perm.warehouseInboundStockIn
              ? FormDraftCatalog.weighCountInbound
              : FormDraftCatalog.weighCountRead)
          .spec();
  @override
  bool get formDraftEnabled => ref.read(authenticatedScopeProvider) != null;
  @override
  bool get formDraftUsesRouterGuard => false;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  bool get formDraftBusy => _busy;
  @override
  bool get formDraftCanReplaySubmission => _frozenResult != null;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  Iterable<Listenable> get formDraftListenables => [
    ..._gross,
    _tare,
    _pieces,
    _sampleQty,
    _sampleWeight,
    _adoptedQty,
  ];
  bool get _current =>
      mounted &&
      !_ownerRetired &&
      _ownerCurrent() &&
      formDraftIdentityIsCurrent;
  @override
  Map<String, dynamic> captureFormDraft() => {
    'request': _req.toDraftJson(),
    'gross': [for (final c in _gross) c.text],
    'tare': _tare.text,
    'pieces': _pieces.text,
    'sampleQty': _sampleQty.text,
    'sampleWeight': _sampleWeight.text,
    'adoptedQty': _adoptedQty.text,
    'adoptedOriginalInput': _adoptedOriginalInput,
    'adoptedEdited': _adoptedEdited,
    'adoptionSource': _adoptionSource,
    'units': _units.toJson(),
    'piecesEdited': _piecesEdited,
    'rememberTare': _rememberTare,
    'openedAt': _openedAt,
    'sampleSent': _sampleSent?.toJson(),
    'profileSent': _profileSent?.toJson(),
    'sampleConfirmed': _sampleConfirmed,
    'profileConfirmed': _profileConfirmed,
    'outcomeUnknown': _outcomeUnknown,
    'result': _frozenResult == null
        ? null
        : {
            'net': _frozenResult!.netKgText,
            'gross': _frozenResult!.grossKgText,
            'tare': _frozenResult!.tareKgText,
            'qty':
                _frozenResult!.qtyExact ??
                financeExactDecimal(_frozenResult!.qty),
            'qtyBase':
                _frozenResult!.qtyBaseExact ??
                financeExactDecimal(_frozenResult!.qtyBase),
            'qtyFromWeight': _frozenResult!.qtyFromWeight,
            'qtyEstimateNote': _frozenResult!.qtyEstimateNote,
          },
    'qtyChoice': _qtyChoice?.toJson(),
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (!const DeepCollectionEquality().equals(
      data['request'],
      _req.toDraftJson(),
    )) {
      throw StateError('称重草稿的货品、仓库、单位或原数量不一致');
    }
    final gross = data['gross'];
    if (gross is! List || gross.isEmpty || gross.length > 1000) {
      throw StateError('原称重次数缺失');
    }
    for (final c in _gross) {
      c.dispose();
    }
    _gross.clear();
    for (final v in gross) {
      _gross.add(_listen(TextEditingController(text: v as String)));
    }
    _tare.text = data['tare'] as String? ?? '';
    _pieces.text = data['pieces'] as String? ?? '';
    _sampleQty.text = data['sampleQty'] as String? ?? '';
    _sampleWeight.text = data['sampleWeight'] as String? ?? '';
    _draftUnits = WeightUnitsPrefs.fromJson(data['units']);
    _piecesEdited = data['piecesEdited'] == true;
    _rememberTare = data['rememberTare'] == true;
    _openedAt = (data['openedAt'] as num?)?.toInt() ?? _openedAt;
    _qtyChoice = BusinessPrecisionChoice.parse(data['qtyChoice']);
    _adoptedEdited = data['adoptedEdited'] == true;
    _adoptionSource = data['adoptionSource'] as String?;
    _adoptedQty.text = data['adoptedQty'] as String? ?? '';
    _adoptedOriginalInput = data['adoptedOriginalInput'] as String?;
    if (data['sampleSent'] case final Map<Object?, Object?> raw) {
      _sampleSent = WeightSampleRequest.fromJson(
        Map<String, dynamic>.from(raw),
      );
    }
    if (data['profileSent'] case final Map<Object?, Object?> raw) {
      _profileSent = WeightProfileUpdate.fromJson(
        Map<String, dynamic>.from(raw),
      );
    }
    _sampleConfirmed = data['sampleConfirmed'] == true;
    _profileConfirmed = data['profileConfirmed'] == true;
    _outcomeUnknown = data['outcomeUnknown'] == true;
    if (data['result'] case final Map<Object?, Object?> raw) {
      final net = financeExactDecimal(raw['net']);
      if (net == null) throw StateError('原净重请求不完整');
      _frozenResult = WeighCountResult(
        netKg: double.parse(net),
        netKgExact: net,
        grossKg: double.tryParse(raw['gross']?.toString() ?? ''),
        grossKgExact: raw['gross'] as String?,
        tareKg: double.tryParse(raw['tare']?.toString() ?? ''),
        tareKgExact: raw['tare'] as String?,
        qty: double.tryParse(raw['qty']?.toString() ?? ''),
        qtyExact: raw['qty'] as String?,
        qtyBase: double.tryParse(raw['qtyBase']?.toString() ?? ''),
        qtyBaseExact: raw['qtyBase'] as String?,
        qtyFromWeight: raw['qtyFromWeight'] == true,
        qtyEstimateNote: raw['qtyEstimateNote'] as String?,
      );
    }
    if (_frozenResult == null) _refreshAdoption();
  }

  late final WeighCountRequest _sourceRequest;
  WeighCountRequest get _req => _sourceRequest;
  @override
  void didUpdateWidget(covariant WeighCountPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!const DeepCollectionEquality().equals(
      oldWidget.request.toDraftJson(),
      widget.request.toDraftJson(),
    )) {
      _ownerRetired = true;
      invalidateFormDraftIdentity();
    } else if (!identical(oldWidget.request.params, widget.request.params) &&
        _frozenResult == null) {
      _params = widget.request.params;
      _changed();
    }
  }

  @override
  void initState() {
    super.initState();
    _sourceRequest = widget.request;
    _adoptedQty.addListener(() => _quantityEpoch++);
    _ownerCurrent = captureReadOwner(ref);
    final permissions = ref.read(currentPermissionsProvider);
    _permission = permissions.contains(Perm.stockWeightManage)
        ? Perm.stockWeightManage
        : permissions.contains(Perm.stockDocEdit)
        ? Perm.stockDocEdit
        : permissions.contains(Perm.warehouseInboundStockIn)
        ? Perm.warehouseInboundStockIn
        : Perm.stockView;
    listenReadOwner(ref, () {
      if (mounted) setState(() => _ownerRetired = true);
    });
    final units = ref.read(warehouseWeightUnitsPrefsProvider);
    _draftUnits = units;
    ref.listenManual(warehouseWeightUnitsPrefsProvider, (_, next) {
      if (!_current || _frozenResult != null) return;
      final old = _units;
      void convert(TextEditingController c, WeightUnit from, WeightUnit to) {
        if (from == to) return;
        final input = parseWithSuffix(c.text, from);
        if (input != null) c.text = to.editText(input.kgText);
      }

      for (final c in [..._gross, _tare]) {
        convert(c, old.entry, next.entry);
      }
      convert(_sampleWeight, old.sample, next.sample);
      setState(() => _draftUnits = next);
      markFormDraftChanged();
    });
    final initial = _req.initialNetKg;
    _gross.add(
      _listen(
        TextEditingController(
          text: initial == null || initial <= 0
              ? ''
              : units.entry.editText(_req.initialNetKgExact ?? initial),
        ),
      ),
    );
    _params = _req.params;
    _refreshAdoption();
    if (initial == null) _prefillTare(units.entry);
    for (final c in [_tare, _sampleQty, _sampleWeight]) {
      _listen(c);
    }
    _pieces.addListener(_changed);
    if (_params == null) _loadParams();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await initializeFormDraft();
      if (_current) setState(() => _ready = true);
    });
  }

  TextEditingController _listen(TextEditingController c) {
    c.addListener(_changed);
    return c;
  }

  void _changed() {
    _quantityEpoch++;
    _refreshAdoption();
    if (mounted) setState(() => _submitError = null);
  }

  String get _quantitySource =>
      '$_netKgText|${_sampleQty.text}|${_sampleWeight.text}|'
      '${_params?.goodsId}|${_params?.supplierId}|${_params?.logMean}|'
      '${_params?.lotPrior}|${_params?.effectiveDf}|${_params?.effectiveGamma}|${_params?.scaleResKg}|${_params?.massFactorKgText}|'
      '${_req.unitRateExact ?? _req.unitRate}';

  WeightQuantityAdoption _computedAdoption() => resolveWeightQuantityAdoption(
    netKg: _netKgText,
    unitRate: _req.unitRateExact ?? _req.unitRate.toString(),
    exactMassFactorKg: _params?.isExact == true
        ? _params?.massFactorKgText
        : null,
    estimate: _netKg == null ? null : _estimate(_netKg!, _sample),
    choice: _qtyChoice,
  );

  void _refreshAdoption() {
    if (_frozenResult != null) return;
    final source = _quantitySource;
    if (_adoptionSource != source) {
      _qtyChoice = null;
      _adoptionSource = source;
    }
    // Actual count input remains authoritative as weights/profile change.
    if (!_adoptedEdited) {
      final text = _computedAdoption().qty ?? '';
      if (_adoptedQty.text != text) _adoptedQty.text = text;
    }
  }

  void _prefillTare(WeightUnit entry) {
    final tare = _params?.prefillTareKg;
    final tareText = _params?.prefillTareKgText;
    if (tare == null || tare <= 0 || _tare.text.isNotEmpty) return;
    _tare.text = entry.editText(tareText ?? tare);
    if (!_piecesEdited) _pieces.text = '${_gross.length}';
  }

  Future<void> _loadParams() async {
    setState(() {
      _loadingParams = true;
      _paramsError = null;
    });
    try {
      final line = WeightParamsLine(
        goodsId: _req.goodsId,
        supplierId: _req.supplierId,
        warehouseId: _req.warehouseId,
        colorId: _req.colorId,
      );
      final result = await ref.read(weightRepositoryProvider).params([line]);
      if (!_current) return;
      setState(() {
        _params = result.of(line);
        _loadingParams = false;
        _quantityEpoch++;
        _refreshAdoption();
      });
      if (_req.initialNetKg == null) {
        _prefillTare(ref.read(warehouseWeightUnitsPrefsProvider).entry);
      }
    } catch (e) {
      // 取不到单重参数也能记重量 (重量从不阻断), 只是不能折算; 原因要让人看见。
      if (mounted) {
        setState(() {
          _loadingParams = false;
          _paramsError = e;
        });
      }
    }
  }

  @override
  void dispose() {
    for (final c in [
      ..._gross,
      _tare,
      _pieces,
      _sampleQty,
      _sampleWeight,
      _adoptedQty,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  // ---- 计算 ----

  WeightUnitsPrefs get _units =>
      _draftUnits ?? ref.read(warehouseWeightUnitsPrefsProvider);

  double? _kgOf(TextEditingController c, WeightUnit unit) {
    final raw = c.text.trim();
    if (raw.isEmpty) return null;
    return parseWithSuffix(raw, unit)?.kg;
  }

  bool _invalid(TextEditingController c, WeightUnit unit) =>
      c.text.trim().isNotEmpty && parseWithSuffix(c.text, unit) == null;

  String? get _grossKgText {
    final values = [
      for (final controller in _gross)
        if (parseWithSuffix(controller.text, _units.entry) case final input?)
          input.kgText,
    ];
    return values.isEmpty
        ? null
        : financeExactTrimmed(financeExactSumTexts(values));
  }

  double? get _grossKg => double.tryParse(_grossKgText ?? '');
  double get _piecesCount => double.tryParse(_pieces.text.trim()) ?? 0;
  String? get _tareKgText {
    final per = parseWithSuffix(_tare.text, _units.entry)?.kgText;
    final pieces = financeExactDecimal(_pieces.text);
    if (per == null ||
        pieces == null ||
        pieces.startsWith('-') ||
        financeExactTrimmed(pieces) == '0') {
      return null;
    }
    return financeExactTrimmed(financeExactMultiplyTexts([per, pieces]));
  }

  double? get _tareKg => double.tryParse(_tareKgText ?? '');
  String? get _netKgText {
    final gross = _grossKgText;
    if (gross == null) return null;
    final value = financeExactTrimmed(
      financeExactSumTexts([
        gross,
        financeExactMultiplyTexts([_tareKgText ?? '0', '-1']),
      ]),
    );
    return value == null || value == '0' || value.startsWith('-')
        ? null
        : value;
  }

  double? get _netKg => double.tryParse(_netKgText ?? '');

  WeightSampleInput? get _sample {
    final n = double.tryParse(_sampleQty.text.trim());
    final w = _kgOf(_sampleWeight, _units.sample);
    if (n == null ||
        !n.isFinite ||
        n <= 0 ||
        w == null ||
        !w.isFinite ||
        w <= 0) {
      return null;
    }
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

  bool _canFill(CountEstimate? estimate, WeightSampleInput? sample) {
    final actual = financeExactDecimal(_adoptedQty.text);
    if (_adoptedEdited && actual != null && !actual.startsWith('-')) {
      return true;
    }
    final p = _params;
    if (p != null && p.isExact) return true;
    if (estimate == null) return false;
    if (sample?.sufficient ?? false) return true;
    return _tier(estimate, sample) != WeightTier.red;
  }

  // ---- 提交 ----

  bool get _validInputs {
    if (_gross.any((c) => _invalid(c, _units.entry)) ||
        _invalid(_tare, _units.entry) ||
        _invalid(_sampleWeight, _units.sample)) {
      return false;
    }
    if (_tare.text.trim().isNotEmpty &&
        (_piecesCount <= 0 || !_piecesCount.isFinite)) {
      return false;
    }
    if ((_sampleQty.text.trim().isNotEmpty ||
            _sampleWeight.text.trim().isNotEmpty) &&
        _sample == null) {
      return false;
    }
    return true;
  }

  String? get _inputGuidance {
    if (_tare.text.trim().isNotEmpty &&
        (_piecesCount <= 0 || !_piecesCount.isFinite)) {
      return '填写包装重量后，请填写箱 / 袋数量。';
    }
    if ((_sampleQty.text.trim().isNotEmpty ||
            _sampleWeight.text.trim().isNotEmpty) &&
        _sample == null) {
      return '抽样要同时填写“数了多少”和“这些有多重”；不用抽样时清空这两项。';
    }
    return null;
  }

  Future<WeightQuantityAdoption?> _resolveAdoption() async {
    final epoch = _quantityEpoch, source = _quantitySource;
    final actual = _adoptedQty.text;
    WeightQuantityAdoption calculate() {
      if (!_adoptedEdited) return _computedAdoption();
      final quantity = financeExactDivideTexts(
        actual,
        '1',
        choiceScale: _qtyChoice?.scale,
        choiceRounding: _qtyChoice?.rounding,
      );
      return WeightQuantityAdoption(
        qty: quantity.text,
        baseQty: financeExactTrimmed(
          financeExactMultiplyTexts([
            quantity.text,
            _req.unitRateExact ?? _req.unitRate.toString(),
          ]),
        ),
        reason: quantity.text == null ? quantity.reason : null,
      );
    }

    bool current() =>
        _current &&
        ![
          ..._gross,
          _tare,
          _pieces,
          _sampleQty,
          _sampleWeight,
          _adoptedQty,
        ].any(
          (c) => c.value.composing.isValid && !c.value.composing.isCollapsed,
        ) &&
        epoch == _quantityEpoch &&
        source == _quantitySource &&
        actual == _adoptedQty.text;
    var result = calculate();
    if (result.reason != null) {
      final choice = await BusinessPrecisionCoordinator.instance.ask(
        BusinessPrecisionRequirement(
          key: 'weight.count-quantity',
          groupKey: 'weight.count-quantity',
          label: '本次称重数量换算；称重估算仍保留原来源',
          maxScale: 24,
          reason: result.reason!,
        ),
        isCurrent: current,
      );
      if (!current() || choice == null) return null;
      _qtyChoice = choice;
      await saveFormDraftNow();
      if (!current()) return null;
      result = calculate();
    }
    if (!current() || result.qty == null || result.qty!.startsWith('-')) {
      return null;
    }
    _adoptedQty.text = result.qty!;
    return result;
  }

  Future<void> _submit({required bool fillQty}) async {
    if (!_current || !_ready || _busy || _resolvingQty) return;
    final net = _netKg;
    if (net == null || !_validInputs) return;
    final sample = _sample, estimate = _estimate(net, _sample);
    if (_frozenResult == null) {
      WeightQuantityAdoption? adoption;
      if (fillQty) {
        _resolvingQty = true;
        try {
          adoption = await _resolveAdoption();
        } finally {
          _resolvingQty = false;
        }
        if (!_current || adoption == null) return;
      }
      final base = adoption?.baseQty, qty = adoption?.qty;
      _frozenResult = WeighCountResult(
        netKg: net,
        netKgExact: _netKgText,
        grossKg: _grossKg,
        grossKgExact: _grossKgText,
        tareKg: _tareKg,
        tareKgExact: _tareKgText,
        qty: double.tryParse(qty ?? ''),
        qtyExact: qty,
        qtyBase: double.tryParse(base ?? ''),
        qtyBaseExact: base,
        qtyFromWeight: fillQty,
        qtyEstimateNote: fillQty && estimate != null
            ? '按称重推算 ${formatWeighQtyRange(estimate, integer: _integerQty, unitName: _req.baseUnitName)}'
            : null,
      );
    }
    setState(() {
      _busy = true;
      _submitError = null;
    });
    try {
      WeighCountSample? saved;
      final scope = formDraftEnabled
          ? await captureFormDraftRequestScope()
          : null;
      Future<void> effects() async {
        if (sample != null || _sampleSent != null) {
          saved = await _saveSample(sample);
        }
        if (_rememberTare) await _saveDefaultTare();
      }

      await runFormDraftSubmission(
        () => scope == null ? effects() : scope.run(effects),
      );
      if (!_current) return;
      final original = _frozenResult!;
      await completeFormDraft();
      if (!_current) return;
      setState(() => _busy = false);
      widget.onSubmit(
        WeighCountResult(
          netKg: original.netKg,
          netKgExact: original.netKgText,
          grossKg: original.grossKg,
          grossKgExact: original.grossKgText,
          tareKg: original.tareKg,
          tareKgExact: original.tareKgText,
          qty: original.qty,
          qtyExact: original.qtyExact,
          qtyBase: original.qtyBase,
          qtyBaseExact: original.qtyBaseExact,
          qtyFromWeight: original.qtyFromWeight,
          sample: saved,
          qtyEstimateNote: original.qtyEstimateNote,
        ),
      );
    } catch (e) {
      if (!_current) return;
      final known =
          !_outcomeUnknown &&
          e is ApiException &&
          ((e.code == 'PRECISION_CHOICE_REQUIRED' &&
                  e.details?['notWritten'] == true) ||
              e.httpStatus == 400 ||
              (e.httpStatus == 422 && e.code != 'PRECISION_CHOICE_REQUIRED'));
      setState(() {
        _busy = false;
        _outcomeUnknown = !known;
        if (known && !_sampleConfirmed && !_profileConfirmed) {
          _frozenResult = null;
          _sampleSent = null;
          _profileSent = null;
        }
        _submitError = _outcomeUnknown
            ? '保存结果待核对，原称重、数量和请求已保留；只能重试原请求。'
            : (e is ApiException ? e.message : '本次尚未完成，原输入已保留');
      });
      await saveFormDraftNow();
    }
  }

  bool get _canSaveSample =>
      _req.canSaveSample ?? ref.read(weightSampleAllowedProvider);

  Future<WeighCountSample> _saveSample(WeightSampleInput? sample) async {
    if (!_canSaveSample) {
      return WeighCountSample(
        qty: sample!.qty,
        weightKg: sample.weightKg,
        saved: false,
      );
    }
    final unit = _units.sample;
    if (_sampleSent == null) {
      final parsed = parseWithSuffix(_sampleWeight.text, unit)!;
      _sampleSent = WeightSampleRequest(
        qty: sample!.qty,
        qtyExact: financeExactDecimal(_sampleQty.text),
        weight: parsed.value,
        weightExact: parsed.numberText,
        weightUnitCode: parsed.unit.code,
        supplierId: _req.supplierId,
        warehouseId: _req.warehouseId,
        remark: _req.sampleRemark ?? '称重计数抽样',
        idempotencyKey: businessIdempotencyKey(
          'weight-sample',
          '${_req.goodsId}|${financeExactDecimal(_sampleQty.text)}|${parsed.numberText}|${parsed.unit.code}|$_openedAt',
        ),
      );
      await saveFormDraftNow();
    }
    GoodsWeightDetail? detail;
    if (!_sampleConfirmed) {
      detail = await ref
          .read(weightRepositoryProvider)
          .recordSample(_req.goodsId, _sampleSent!);
      if (!_current) throw StateError('称重窗口已失效');
      _sampleConfirmed = true;
      await saveFormDraftNow();
    }
    return WeighCountSample(
      qty: _sampleSent!.qty,
      weightKg: double.parse(
        WeightUnit.fromCode(
          _sampleSent!.weightUnitCode,
        ).toKgText(_sampleSent!.weightExact)!,
      ),
      saved: true,
      detail: detail,
    );
  }

  Future<void> _saveDefaultTare() async {
    if (_profileConfirmed) return;
    final per = parseWithSuffix(_tare.text, _units.entry)?.kgText;
    if (per == null || per == '0') return;
    final repo = ref.read(weightRepositoryProvider);
    if (_profileSent == null) {
      final detail = await repo.goods(_req.goodsId);
      if (!_current) throw StateError('称重窗口已失效');
      _profileSent = WeightProfileUpdate.from(
        detail.profile,
      ).copyWith(defaultTareKg: double.parse(per), defaultTareKgExact: per);
      await saveFormDraftNow();
    }
    await repo.updateProfile(_req.goodsId, _profileSent!);
    if (!_current) throw StateError('称重窗口已失效');
    _profileConfirmed = true;
    await saveFormDraftNow();
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
      _adoptedEdited = false;
      _adoptedOriginalInput = null;
      _adoptedQty.clear();
      _adoptionSource = null;
      _qtyChoice = null;
      _submitError = null;
    });
  }

  // ---- 界面 ----

  @override
  Widget build(BuildContext context) {
    ref.watch(warehouseWeightUnitsPrefsProvider);
    if (!_current) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('身份、权限或来源已变化；原称重草稿保留，请关闭后重新进入。'),
          if (widget.onCancel != null)
            Align(
              alignment: Alignment.centerRight,
              child: UtenCloseButton(onPressed: widget.onCancel),
            ),
        ],
      );
    }
    final units = _units;
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
        if (_paramsError case final error?)
          Builder(
            builder: (context) {
              final l10n =
                  Localizations.of<AppLocalizations>(
                    context,
                    AppLocalizations,
                  ) ??
                  AppLocalizationsZh();
              return Padding(
                padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                child: UtenInlineNotice(
                  key: const Key('weigh-count-params-error'),
                  level: UtenInlineNoticeLevel.warning,
                  message: l10n.weightParamsLoadFailed(
                    weightParamsErrorReason(error, l10n),
                  ),
                  trailing: TextButton(
                    onPressed: _busy || _frozenResult != null
                        ? null
                        : _loadParams,
                    child: Text(l10n.commonRetry),
                  ),
                ),
              );
            },
          ),
        if (_req.mode == WeighCountContext.outbound) _outboundTarget(theme),
        if (redTier &&
            !_loadingParams &&
            _req.mode != WeighCountContext.outbound) ...[
          UtenInlineNotice(
            key: const ValueKey('weigh-count-red-banner'),
            level: UtenInlineNoticeLevel.warning,
            message:
                '单重数据不足, 请数 ${params?.effectiveSuggestedSampleSize ?? WeightPredictor.suggestedSampleSize()} '
                '${_req.baseUnitName ?? '个'}放上秤，再填下面两个数；也可以只记重量。',
          ),
          const SizedBox(height: UtenSpacing.s12),
        ],
        ..._grossRows(units.entry),
        ExpansionTile(
          key: const ValueKey('weigh-count-packaging-options'),
          tilePadding: EdgeInsets.zero,
          title: const Text('扣除包装 / 分多次称重'),
          subtitle: (_tareKg ?? 0) > 0
              ? Text('已扣包装 ${formatWeight(_tareKg!)}')
              : null,
          initiallyExpanded: _tare.text.isNotEmpty,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                key: const ValueKey('weigh-count-add-gross'),
                onPressed: _busy || _frozenResult != null ? null : _addWeighing,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('再称一批，重量相加'),
              ),
            ),
            _tareRow(units.entry),
            if (_canManageTare) _rememberTareRow(),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        _netLine(theme, units),
        const SizedBox(height: UtenSpacing.s16),
        ExpansionTile(
          key: const ValueKey('weigh-count-sampling-options'),
          tilePadding: EdgeInsets.zero,
          title: Text(
            _req.mode == WeighCountContext.outbound
                ? '想核对得更准？数几个，称一下'
                : '数几个，称一下（校准单件重量）',
          ),
          initiallyExpanded: redTier && _req.mode != WeighCountContext.outbound,
          children: [_sampleSection(theme, units.sample, sample)],
        ),
        const SizedBox(height: UtenSpacing.s12),
        if (_inputGuidance case final guidance?)
          Text(
            guidance,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.error,
            ),
          ),
        if (net != null && _req.mode != WeighCountContext.outbound)
          _resultSection(theme, net, estimate, tier, sample),
        if (net != null && _req.mode == WeighCountContext.outbound) ...[
          ?_outboundWarning(net),
          ExpansionTile(
            key: const ValueKey('weigh-count-details'),
            tilePadding: EdgeInsets.zero,
            title: const Text('查看估算依据与数量范围'),
            children: [_resultSection(theme, net, estimate, tier, sample)],
          ),
        ],
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
      return withFormDraft(
        Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            body,
            const SizedBox(height: UtenSpacing.s16),
            actions,
          ],
        ),
      );
    }
    return withFormDraft(
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Flexible(child: SingleChildScrollView(child: body)),
          const SizedBox(height: UtenSpacing.s16),
          actions,
        ],
      ),
    );
  }

  bool get _canManageTare => ref.watch(weightManageAllowedProvider);

  double? get _outboundExpectedKg {
    final needed = _req.currentQtyBase;
    if (needed == null || !needed.isFinite || needed <= 0) return null;
    final params = _params;
    if (params?.isExact == true) return params!.expectedKgFor(needed);
    final sample = _sample;
    if (sample?.sufficient == true) {
      return params?.expectationFor(needed, sample: sample)?.expectedWeightKg ??
          needed * sample!.weightKg / sample.qty;
    }
    return _req.expectedWeightKg ??
        params?.suggestionFor(needed, mode: WeightCaptureMode.outbound)?.kg ??
        params?.expectedKgFor(needed);
  }

  Widget _outboundTarget(ThemeData theme) {
    final params = _params;
    final needed = _req.currentQtyBase;
    if (needed == null || needed <= 0) {
      return const SizedBox.shrink();
    }
    final expectedKg = _outboundExpectedKg;
    if (expectedKg == null || !expectedKg.isFinite || expectedKg <= 0) {
      return const Padding(
        padding: EdgeInsets.only(bottom: UtenSpacing.s12),
        child: Text('暂时没有可靠参考重量，可以直接填写实际称重。'),
      );
    }
    final integer = _integerQty;
    final String text;
    if (params?.isExact == true) {
      final kg = needed * params!.massFactorKg!;
      text =
          '需要 ${formatWeighQtyWithUnit(needed, unitName: _req.baseUnitName, integer: false)} '
          '→ 净重 ${formatWeight(kg)} (精确换算)';
    } else {
      final tare = _tareKg ?? 0;
      final needText = formatWeighQtyWithUnit(
        needed,
        unitName: _req.baseUnitName,
        integer: integer,
      );
      final buffer = StringBuffer()
        ..write('本次出库 $needText，预计净重约 ${formatWeight(expectedKg)}');
      if (tare > 0) {
        buffer
          ..write(' + 皮重 ${formatWeight(tare)} ')
          ..write('→ 秤上应显示约 ${formatWeight(expectedKg + tare)}');
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

  Widget? _outboundWarning(double net) {
    final suggestion = _params?.suggestionFor(
      _req.currentQtyBase,
      mode: WeightCaptureMode.outbound,
    );
    final expected = _outboundExpectedKg;
    if (expected == null || expected <= 0) return null;
    final reference = WeightSuggestion(
      kg: expected,
      source: _req.expectedWeightSource ?? suggestion?.source ?? '本次出库参考重量',
      tolerancePct: suggestion?.tolerancePct ?? 5,
    );
    if (!reference.differsFrom(net)) return null;
    return UtenInlineNotice(
      key: const ValueKey('weigh-count-reference-warning'),
      level: UtenInlineNoticeLevel.warning,
      message:
          '数值可能有问题：预计约 ${formatWeight(expected)}，实际 ${formatWeight(net)}。请核对数量、重量单位和包装；确认无误仍可填入。',
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
                enabled: !_busy && _frozenResult == null,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: _req.mode == WeighCountContext.outbound
                        ? (_gross.length == 1
                              ? '实际称了多重（秤上读数）'
                              : '第 ${i + 1} 批秤上读数')
                        : (_gross.length == 1 ? '整批秤上读数' : '第 ${i + 1} 批秤上读数'),
                    suffixText: entry.symbol,
                    error: utenFieldError(
                      _invalid(_gross[i], entry) ? weightInputErrorText : null,
                    ),
                  ),
                  info: i == 0
                      ? (_req.mode == WeighCountContext.outbound
                            ? '按本次出库数量估算重量，称完填入秤上的实际读数即可。'
                            : '称一下整批物品，系统按单件重量估算数量。数量仍可人工核对。')
                      : null,
                ),
              ),
            ),
            if (_gross.length > 1)
              IconButton(
                tooltip: '删掉这次称重',
                onPressed: _busy || _frozenResult != null
                    ? null
                    : () => _removeWeighing(i),
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
          enabled: !_busy && _frozenResult == null,
          decoration: UtenInputDecoration(
            InputDecoration(
              labelText: '每个空箱 / 空袋多重',
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
          enabled: !_busy && _frozenResult == null,
          keyboardType: TextInputType.number,
          onChanged: (_) => _piecesEdited = true,
          decoration: const UtenInputDecoration(
            InputDecoration(labelText: '箱 / 袋数量', suffixText: '个'),
          ),
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
    onChanged: _busy || _frozenResult != null
        ? null
        : (v) => setState(() => _rememberTare = v ?? false),
    title: const Text('下次自动填这个包装重量'),
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
        Text('先数出一小把，再只称这一小把（不含包装）。', style: theme.textTheme.bodySmall),
        const SizedBox(height: UtenSpacing.s4),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('weigh-count-sample-qty'),
                controller: _sampleQty,
                enabled: !_busy && _frozenResult == null,
                keyboardType: TextInputType.number,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: '数了多少',
                    hintText: '建议 $suggested',
                    suffixText: unitName,
                  ),
                ),
              ),
            ),
            const SizedBox(width: UtenSpacing.s8),
            Expanded(
              child: TextField(
                key: const ValueKey('weigh-count-sample-weight'),
                controller: _sampleWeight,
                enabled: !_busy && _frozenResult == null,
                decoration: UtenInputDecoration(
                  InputDecoration(
                    labelText: '这些有多重',
                    error: utenFieldError(
                      _invalid(_sampleWeight, sampleUnit)
                          ? weightInputErrorText
                          : null,
                    ),
                    suffixIcon: _SampleUnitMenu(
                      unit: sampleUnit,
                      onSelected: (next) {
                        if (_frozenResult != null) return;
                        ref
                            .read(warehouseWeightUnitsPrefsProvider.notifier)
                            .setSample(next);
                      },
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
      final qty = _computedAdoption().qty;
      children.add(
        Text(
          '= ${qty ?? '待选择精度'}${_req.lineUnitName ?? unitName ?? ''} (按重量精确换算)',
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
      final n = estimate.estimatedQty;
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
      final exactUpTo = estimate.exactUpToQty;
      final hint = <String>[
        if (basis.isNotEmpty) '依据: ${basis.join(' · ')}',
        if (exactUpTo.isFinite && exactUpTo >= 1)
          '超过 ${formatWeighQtyWithUnit(math.max(1.0, exactUpTo.floorToDouble()), unitName: unitName ?? '个', integer: true)}时称重计数只是估算',
      ];
      if (hint.isNotEmpty) {
        final result = children.removeLast();
        children.add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: result),
              UtenFieldHintIcon(
                key: const ValueKey('weigh-count-exact-hint'),
                info: hint.join('；'),
              ),
            ],
          ),
        );
      }
    }
    final deviation = _deviationChip();
    if (deviation != null) children.add(deviation);
    if (_req.mode == WeighCountContext.count ||
        _req.mode == WeighCountContext.receipt) {
      children.add(
        TextField(
          key: const ValueKey('weigh-count-quantity'),
          controller: _adoptedQty,
          enabled: !_busy && _frozenResult == null,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) {
            _adoptedEdited = true;
            _adoptedOriginalInput = _adoptedQty.text;
            _qtyChoice = null;
            _quantityEpoch++;
            setState(() {});
          },
          decoration: UtenInputDecoration(
            InputDecoration(
              labelText:
                  '采用数量${_req.lineUnitName == null ? '' : ' (${_req.lineUnitName})'}',
              suffixIcon: const UtenFieldHintIcon(
                info:
                    '按称重估算保留模型有效位；确认后作为本次数量输入。可填写实际清点数量；整件请填写实际整数。除不尽或超字段精度时选择保留位数和是否四舍五入。',
              ),
            ),
          ),
        ),
      );
    }
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
    if (_frozenResult != null) {
      return Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          ?cancel,
          UtenButton(
            key: const ValueKey('weigh-count-recover'),
            onPressed: _busy
                ? null
                : () => _submit(fillQty: _frozenResult!.qtyFromWeight),
            isLoading: _busy,
            child: Text(
              _frozenResult!.qtyFromWeight ? '核对原请求：数量和重量' : '核对原请求：只记重量',
            ),
          ),
        ],
      );
    }
    final hasNet = _ready && net != null && !_busy && _validInputs;
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
        if (hasNet && canFill) {
          warning = const UtenFieldHintIcon(
            key: ValueKey('weigh-count-fill-warning'),
            info: '按称重改数量: 将按估算数量入账, 影响对账',
          );
        }
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
            onPressed: _busy || _frozenResult != null ? null : _reset,
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
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: UtenSpacing.s8,
      runSpacing: UtenSpacing.s8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [?cancel, ...buttons, ?warning],
    );
  }
}

/// 抽样重量输入框里的单位切换 (「克▾」), 选择记为用户抽样单位偏好。
class _SampleUnitMenu extends StatelessWidget {
  const _SampleUnitMenu({required this.unit, required this.onSelected});

  final WeightUnit unit;
  final ValueChanged<WeightUnit> onSelected;

  @override
  Widget build(BuildContext context) => UtenDropdownScrollScope(
    child: PopupMenuButton<WeightUnit>(
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
    ),
  );
}
