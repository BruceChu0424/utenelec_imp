import 'package:collection/collection.dart';
import '../../drafts/form_draft_mixin.dart';
import '../../drafts/form_draft_catalog.dart';
import '../../auth/permissions.dart';
import '../../providers/authenticated_scope_provider.dart';
import '../../formatters/exact_decimal.dart';
// 称样校准弹窗 (ADR-135 §6.2, review/product.md §1.3): 数一小把放上秤, 记一条 SAMPLE,
// 服务端同步重算后回传最新单重详情。
//
// - 供应商可空 (默认带入到货供应商); 数量「建议至少 N 个」; 重量 + 抽样单位 (默认克,
//   单独记忆); 皮重 (托盘/容器, 可选); 备注。
// - 实时一行「本次单重 2.310 g; 当前 2.298 g (+0.5%)」; 与当前单重差异超过 3 倍标准差时
//   提示「差异较大: 换了供应商/批次?」并给勾选「从本次起作为新批次(旧数据降权)」。
// - 权限: warehouse_inbound:stock_in 或 stock_doc:edit 或 stock:weight:manage。
// - 入口: 采集表格行菜单 (主要是到货行)、流水面板「单重学习」、库存分析「单重学习」批量表。
import '../../../components/inputs/uten_dropdown_scroll_scope.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../auth/read_owner_fence.dart';
import '../../providers/export_context_epoch_provider.dart';
import '../weight_params.dart';
import '../weight_predictor.dart';
import '../weight_prefs.dart';
import '../weight_unit.dart';
import 'weight_grid_column.dart';
import 'weight_params_load_notice.dart';
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
  String? resumeDraftId,
}) {
  // DialogRoute builds on the next frame. Pin the owner before that gap so a
  // scope change while opening cannot adopt the old row's title or supplier.
  final ownerEpoch = ProviderScope.containerOf(
    context,
    listen: false,
  ).read(exportContextEpochProvider);
  return showDialog<GoodsWeightDetail>(
    context: context,
    barrierDismissible: false,
    builder: (_) => _WeightSampleDialog(
      ownerEpoch: ownerEpoch,
      resumeDraftId: resumeDraftId,
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
}

class _WeightSampleDialog extends ConsumerStatefulWidget {
  const _WeightSampleDialog({
    required this.ownerEpoch,
    required this.goodsId,
    required this.goodsTitle,
    required this.baseUnitName,
    required this.supplierId,
    required this.supplierName,
    required this.supplierOptions,
    required this.warehouseId,
    required this.params,
    required this.remark,
    this.resumeDraftId,
  });

  final int ownerEpoch;
  final String? resumeDraftId;
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

class _WeightSampleDialogState extends ConsumerState<_WeightSampleDialog>
    with FormDraftMixin<_WeightSampleDialog> {
  final _qty = TextEditingController();
  final _weight = TextEditingController();
  final _tare = TextEditingController();
  late final TextEditingController _remark;
  int _openedAt = DateTime.now().microsecondsSinceEpoch;
  WeightSampleRequest? _sent;
  bool _draftInitialized = false;
  late String _draftPermission;
  WeightUnit? _inputUnit;

  /// 按 (货品, 供应商) 取过的参数。
  final Map<WeightParamsIdentity, WeightParams?> _paramsByKey = {};

  /// 取当前单重失败的原因; 只影响对比行, 不妨碍称样, 但要让人看见并可重试。
  Object? _paramsError;
  String? _supplierId;
  bool _newRegime = false;
  bool _busy = false;
  String? _error;
  late final bool Function() _ownerCurrent;
  bool _ownerInvalid = false;
  bool _saveOutcomeUnknown = false;

  @override
  FormDraftSpec get formDraftSpec =>
      (_draftPermission == Perm.warehouseInboundStockIn
              ? FormDraftCatalog.weightSampleInbound
              : _draftPermission == Perm.stockWeightManage
              ? FormDraftCatalog.weightSampleManage
              : FormDraftCatalog.weightSampleDocument)
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
  bool get formDraftCanReplaySubmission => _sent != null;
  @override
  String? get formDraftResumeId => widget.resumeDraftId;
  @override
  Iterable<Listenable> get formDraftListenables => [
    _qty,
    _weight,
    _tare,
    _remark,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'goodsId': widget.goodsId,
    'goodsTitle': widget.goodsTitle,
    'baseUnitName': widget.baseUnitName,
    'warehouseId': widget.warehouseId,
    'supplierId': _supplierId,
    'supplierName': widget.supplierName,
    'qty': _qty.text,
    'weight': _weight.text,
    'tare': _tare.text,
    'remark': _remark.text,
    'unit': _sampleUnit.code,
    'newRegime': _newRegime,
    'openedAt': _openedAt,
    'sent': _sent?.toJson(),
    'outcomeUnknown': _saveOutcomeUnknown,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    if (data['goodsId'] != widget.goodsId ||
        data['warehouseId'] != widget.warehouseId) {
      throw StateError('称样草稿的货品或仓库不一致');
    }
    _qty.text = data['qty'] as String? ?? '';
    _weight.text = data['weight'] as String? ?? '';
    _tare.text = data['tare'] as String? ?? '';
    _remark.text = data['remark'] as String? ?? '';
    _inputUnit = WeightUnit.parse(data['unit']?.toString());
    _supplierId = data['supplierId'] as String?;
    _newRegime = data['newRegime'] == true;
    _openedAt = (data['openedAt'] as num?)?.toInt() ?? _openedAt;
    if (data['sent'] case final Map<Object?, Object?> raw) {
      final body = Map<String, dynamic>.from(raw);
      final restored = WeightSampleRequest.fromJson(body);
      if (!const DeepCollectionEquality().equals(restored.toJson(), body) ||
          restored.supplierId != _supplierId ||
          restored.warehouseId != widget.warehouseId) {
        throw StateError('原称样请求不完整，保留原草稿待核对');
      }
      _sent = restored;
    }
    _saveOutcomeUnknown = data['outcomeUnknown'] == true || _sent != null;
  }

  String get _unitName => widget.baseUnitName ?? '个';

  @override
  void initState() {
    super.initState();
    final permissions = ref.read(currentPermissionsProvider);
    _draftPermission = permissions.contains(Perm.stockWeightManage)
        ? Perm.stockWeightManage
        : permissions.contains(Perm.stockDocEdit)
        ? Perm.stockDocEdit
        : Perm.warehouseInboundStockIn;
    _ownerCurrent = captureReadOwner(ref);
    _ownerInvalid = ref.read(exportContextEpochProvider) != widget.ownerEpoch;
    _supplierId = widget.supplierId;
    _inputUnit = ref.read(warehouseWeightUnitsPrefsProvider).sample;
    _remark = TextEditingController(text: widget.remark ?? '');
    final given = widget.params;
    if (given != null) {
      _paramsByKey[_identity(widget.supplierId)] = given;
    }
    for (final c in [_qty, _weight, _tare]) {
      c.addListener(_changed);
    }
    listenReadOwner(ref, _invalidateOwner);
    _ensureParams();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await initializeFormDraft();
      if (_isCurrent) setState(() => _draftInitialized = true);
    });
  }

  bool get _isCurrent =>
      mounted &&
      !_ownerInvalid &&
      _ownerCurrent() &&
      formDraftIdentityIsCurrent;

  void _invalidateOwner() {
    if (!mounted || _ownerInvalid) return;
    setState(() {
      _ownerInvalid = true;
      _saveOutcomeUnknown = _busy;
      _busy = false;
      _error = null;
      _paramsError = null;
      _paramsByKey.clear();
      _supplierId = null;
    });
    for (final controller in [_qty, _weight, _tare, _remark]) {
      controller.clear();
    }
  }

  void _changed() {
    if (_isCurrent) setState(() => _error = null);
  }

  WeightParamsIdentity _identity(String? supplierId) => WeightParamsLine(
    goodsId: widget.goodsId,
    supplierId: supplierId,
  ).paramsIdentity;

  WeightParams? get _params => _paramsByKey[_identity(_supplierId)];

  Future<void> _ensureParams() async {
    if (!_isCurrent) return;
    final key = _identity(_supplierId);
    if (_paramsByKey.containsKey(key)) return;
    _paramsByKey[key] = null;
    try {
      final result = await ref.read(weightRepositoryProvider).params([
        WeightParamsLine(goodsId: widget.goodsId, supplierId: _supplierId),
      ]);
      if (!_isCurrent) return;
      setState(() {
        _paramsByKey[key] = result.params[key];
        _paramsError = null;
      });
    } catch (e) {
      // 取不到当前单重只影响对比行, 不妨碍称样; 但不再静默 (ADR-151)。
      if (!_isCurrent) return;
      setState(() {
        _paramsByKey.remove(key);
        _paramsError = e;
      });
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
      _inputUnit ?? ref.read(warehouseWeightUnitsPrefsProvider).sample;

  double? get _qtyValue {
    final v = double.tryParse(_qty.text.trim());
    return v == null || v <= 0 ? null : v;
  }

  WeightInput? get _grossInput => parseWithSuffix(_weight.text, _sampleUnit);
  WeightInput? get _tareInput => parseWithSuffix(_tare.text, _sampleUnit);

  bool _invalid(TextEditingController c) =>
      c.text.trim().isNotEmpty && parseWithSuffix(c.text, _sampleUnit) == null;

  /// 净重 (千克)。
  String? get _netKgText {
    final gross = _grossInput;
    if (gross == null) return null;
    final tare = _tareInput?.kgText ?? '0';
    final net = financeExactTrimmed(
      financeExactSumTexts([
        gross.kgText,
        financeExactMultiplyTexts([tare, '-1']),
      ]),
    );
    return net == null || net == '0' || net.startsWith('-') ? null : net;
  }

  double? get _netKg => double.tryParse(_netKgText ?? '');

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
    if (!_isCurrent || !ref.read(weightSampleAllowedProvider)) return;
    final sample = _sample;
    final gross = _grossInput;
    if (_busy) return;
    if (_sent == null && (sample == null || gross == null)) {
      setState(() => _error = '请填写数量和重量 (扣皮后要大于 0)');
      return;
    }
    // The domain stores kg. Preserve the exact gross-minus-tare product instead
    // of dividing it back into a potentially repeating lb/oz decimal.
    final tareKgText = _tareInput?.kgText;
    final tareKg = double.tryParse(tareKgText ?? '');
    final netText = _sent?.weightExact ?? _netKgText!;
    final netValue = double.parse(netText);
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      _sent ??= WeightSampleRequest(
        qty: sample!.qty,
        qtyExact: financeExactDecimal(_qty.text),
        weight: netValue,
        weightExact: netText,
        weightUnitCode: 'KG',
        tareKg: tareKg,
        tareKgExact: tareKgText,
        supplierId: _supplierId,
        warehouseId: widget.warehouseId,
        newRegime: _newRegime,
        remark: _remark.text,
        idempotencyKey: businessIdempotencyKey(
          'weight-sample',
          '${widget.goodsId}|${_supplierId ?? ''}|${financeExactDecimal(_qty.text)}|'
              '$netText|KG|${tareKgText ?? ''}|$_newRegime|$_openedAt',
        ),
      );
      final scope = formDraftEnabled
          ? await captureFormDraftRequestScope()
          : null;
      Future<GoodsWeightDetail> send() => ref
          .read(weightRepositoryProvider)
          .recordSample(widget.goodsId, _sent!);
      final detail = await runFormDraftSubmission(
        () => scope == null
            ? send()
            : scope.run(
                () => ref
                    .read(weightRepositoryProvider)
                    .recordSample(widget.goodsId, _sent!),
              ),
      );
      if (!mounted || !_isCurrent) return;
      await completeFormDraft();
      if (mounted && _isCurrent) Navigator.of(context).pop(detail);
    } catch (e) {
      if (!_isCurrent) return;
      setState(() {
        _busy = false;
        final definite =
            !_saveOutcomeUnknown &&
            e is ApiException &&
            (e.httpStatus == 400 ||
                (e.httpStatus == 422 &&
                    (e.code != 'PRECISION_CHOICE_REQUIRED' ||
                        e.details?['notWritten'] == true)) ||
                (e.httpStatus == 409 && e.code == 'CONFLICT'));
        if (definite) _sent = null;
        _saveOutcomeUnknown = _sent != null;
        _error = _saveOutcomeUnknown
            ? '称样结果待核对；原输入和请求已保留，只能按原请求重试。'
            : (e is ApiException ? e.message : '保存失败, 请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_isCurrent) {
      return UtenAlertDialog(
        title: const Text('称样窗口已失效'),
        showCloseButton: true,
        closeButtonKey: const ValueKey('weight-sample-close-invalid'),
        onClose: () => Navigator.of(context).pop(),
        content: Text(
          _saveOutcomeUnknown || _busy
              ? '账号、服务器或权限已变化。保存请求可能已完成，请先核对结果，勿重复提交。'
              : '账号、服务器或权限已变化，请关闭后重新打开。',
        ),
      );
    }
    final theme = Theme.of(context);
    final allowed = ref.watch(weightSampleAllowedProvider);
    ref.watch(warehouseWeightUnitsPrefsProvider);
    final sampleUnit = _sampleUnit;
    final editable = !_busy && !_saveOutcomeUnknown;
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

    return withFormDraft(
      UtenAlertDialog(
        scrollable: false,
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
                          key: const Key('weight-sample-params-error'),
                          level: UtenInlineNoticeLevel.warning,
                          message: l10n.weightParamsLoadFailed(
                            weightParamsErrorReason(error, l10n),
                          ),
                          trailing: TextButton(
                            onPressed: _busy ? null : _ensureParams,
                            child: Text(l10n.commonRetry),
                          ),
                        ),
                      );
                    },
                  ),
                if (supplierItems.isNotEmpty) ...[
                  UtenDropdownField(
                    key: const ValueKey('weight-sample-supplier'),
                    label: '供应商',
                    hintText: '可不选',
                    value: _supplierId,
                    items: supplierItems,
                    enabled: editable,
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
                  enabled: editable,
                  keyboardType: TextInputType.number,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: '数量 *',
                      hintText: '建议至少 $suggested $_unitName',
                      suffixText: _unitName,
                    ),
                  ),
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  key: const ValueKey('weight-sample-weight'),
                  controller: _weight,
                  enabled: editable,
                  decoration: UtenInputDecoration(
                    InputDecoration(
                      labelText: '重量 *',
                      error: utenFieldError(
                        _invalid(_weight) ? weightInputErrorText : null,
                      ),
                      suffixIcon: UtenDropdownScrollScope(
                        child: PopupMenuButton<WeightUnit>(
                          key: const ValueKey('weight-sample-unit'),
                          tooltip: '抽样重量单位',
                          initialValue: sampleUnit,
                          onSelected: editable
                              ? (unit) {
                                  final previous = _sampleUnit;
                                  for (final c in [_weight, _tare]) {
                                    final input = parseWithSuffix(
                                      c.text,
                                      previous,
                                    );
                                    if (input != null) {
                                      c.text = unit.editText(input.kgText);
                                    }
                                  }
                                  setState(() => _inputUnit = unit);
                                  ref
                                      .read(
                                        warehouseWeightUnitsPrefsProvider
                                            .notifier,
                                      )
                                      .setSample(unit);
                                  markFormDraftChanged();
                                }
                              : null,
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
                ),
                const SizedBox(height: UtenSpacing.s12),
                TextField(
                  key: const ValueKey('weight-sample-tare'),
                  controller: _tare,
                  enabled: editable,
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
                  enabled: editable,
                  maxLength: 200,
                  decoration: const UtenInputDecoration(
                    InputDecoration(labelText: '备注', counterText: ''),
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
                    onChanged: !editable
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
            onPressed:
                allowed &&
                    _draftInitialized &&
                    (sample != null || _sent != null) &&
                    !_busy
                ? _save
                : null,
            child: Text(_saveOutcomeUnknown ? '按原请求核对称样' : '保存称样'),
          ),
        ],
      ),
    );
  }

  Widget _liveLine(
    ThemeData theme,
    WeightSampleInput? sample,
    WeightParams? params,
  ) {
    final current = params?.currentUnitWeightKg;
    final currentText = params?.currentUnitWeightKgText;
    final parts = <String>[];
    if (sample != null) {
      final unitWeight = financeExactDivideTexts(
        _netKgText,
        financeExactDecimal(_qty.text),
      ).text;
      parts.add(
        unitWeight == null
            ? '本次单重=净重÷数量（换算待选精度）'
            : '本次单重 ${formatUnitWeight(unitWeight)}',
      );
      if (current != null && current > 0) {
        final relative = financeExactDivideTexts(
          unitWeight,
          currentText,
        ).text;
        final pct = relative == null
            ? null
            : financeExactMultiplyTexts([
                financeExactSumTexts([relative, '-1']),
                '100',
              ]);
        parts.add(
          '当前 ${formatUnitWeight(currentText)} (${pct == null ? '差异比率待选精度' : formatSignedPct(pct)})',
        );
      }
    } else if (current != null) {
      parts.add('当前 ${formatUnitWeight(currentText)}');
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
}
