// 货品详情「成本预算」页签：18 项成本字段表单（对照老系统 002.jpg 成本预算页签）。
//
// 自动汇总（2026-08-01）：材料合计 sourceE 由 BOM 聚合（后端 GoodsBomService.recalcSourceE，
// 自制件取其 cTotal、采购/委外取 price）→ 经 [materialTotal] 传入，只读显示；下游
// 成品价 = 材料 + 6 项加工费；人工/损耗/厂租费 = 成品价 × 对应比率%；成本价 = 成品价 +
// 三项费；生产利润 = 成本价 × 生产利率%；出厂价 = 成本价 + 生产利润。比率与加工费手填，
// 其余只读自动算。
//
// 保存走货品主档 PUT（GoodsSaveRequest 已含成本字段）：基础字段从 detail 全量回传
// （后端 apply 全量覆盖，缺字段会被置 null），成本字段取表单值。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/goods_node.dart';
import '../repositories/goods_repository.dart';

/// 成本字段定义（key 与后端 GoodsSaveRequest 对齐）。
class _CostField {
  const _CostField(
    this.key,
    this.label, {
    this.percent = false,
    this.derived = false,
  });

  final String key;
  final String label;
  final bool percent; // 比率字段（%）
  final bool derived; // 派生（自动算，只读）
}

const _costFields = [
  _CostField('sourceE', '材料合计', derived: true),
  _CostField('machiningE', '加工费'),
  _CostField('incidentalE', '杂费'),
  _CostField('lacquerE', '喷漆、朔费'),
  _CostField('platingE', '电镀费'),
  _CostField('casingE', '包装费'),
  _CostField('polishE', '抛光费'),
  _CostField('total', '成品价', derived: true),
  _CostField('workRate', '人工比率', percent: true),
  _CostField('workE', '人工费', derived: true),
  _CostField('lostRate', '损耗比率', percent: true),
  _CostField('lostE', '损耗费', derived: true),
  _CostField('rentRate', '厂租比率', percent: true),
  _CostField('rentE', '厂房租金', derived: true),
  _CostField('makeRate', '生产利率', percent: true),
  _CostField('makeE', '生产利润', derived: true),
  _CostField('cTotal', '成本价', derived: true),
  _CostField('gTotal', '出厂价', derived: true),
];

/// 手填（可编辑）字段：6 项加工费 + 4 项比率。
const _inputKeys = {
  'machiningE',
  'incidentalE',
  'lacquerE',
  'platingE',
  'casingE',
  'polishE',
  'workRate',
  'lostRate',
  'rentRate',
  'makeRate',
};

final _costNumberPattern = RegExp(r'^\d{0,14}(?:\.\d{0,4})?$');
final _costNumberFormatter = TextInputFormatter.withFunction((
  oldValue,
  newValue,
) {
  if (newValue.text.isEmpty || _costNumberPattern.hasMatch(newValue.text)) {
    return newValue;
  }
  return oldValue;
});

class GoodsCostTab extends ConsumerStatefulWidget {
  const GoodsCostTab({
    super.key,
    required this.detail,
    required this.canEdit,
    this.materialTotal,
    this.onSaved,
  });

  final GoodsDetail detail;
  final bool canEdit;

  /// BOM 聚合的「材料合计」(sourceE)——由父弹窗传入（= 最新 goods.sourceE）。
  /// 变化时只读刷新 sourceE 并重算下游；null 时回退 detail.sourceE。
  final double? materialTotal;
  final VoidCallback? onSaved;

  @override
  ConsumerState<GoodsCostTab> createState() => _GoodsCostTabState();
}

class _GoodsCostTabState extends ConsumerState<GoodsCostTab>
    with AutomaticKeepAliveClientMixin {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers;
  bool _saving = false;
  String? _error;
  bool _computing = false; // 防 _recompute 写入触发监听递归

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    final d = widget.detail;
    final initial = <String, double?>{
      'sourceE': widget.materialTotal ?? d.sourceE,
      'machiningE': d.machiningE,
      'incidentalE': d.incidentalE,
      'lacquerE': d.lacquerE,
      'platingE': d.platingE,
      'casingE': d.casingE,
      'polishE': d.polishE,
      'total': d.total,
      'workRate': d.workRate,
      'workE': d.workE,
      'lostRate': d.lostRate,
      'lostE': d.lostE,
      'rentRate': d.rentRate,
      'rentE': d.rentE,
      'makeRate': d.makeRate,
      'makeE': d.makeE,
      'cTotal': d.cTotal,
      'gTotal': d.gTotal,
    };
    _controllers = {
      for (final f in _costFields)
        f.key: TextEditingController(text: initial[f.key]?.toString() ?? ''),
    };
    // 手填字段改动 → 重算下游（派生字段无监听，写入不会递归）。
    for (final k in _inputKeys) {
      _controllers[k]!.addListener(_onInputChanged);
    }
  }

  @override
  void didUpdateWidget(covariant GoodsCostTab old) {
    super.didUpdateWidget(old);
    // BOM 变动后父弹窗刷新 _detail → materialTotal(=sourceE) 变化 → 刷新 sourceE + 重算。
    if (widget.materialTotal != old.materialTotal) {
      _controllers['sourceE']!.text = (widget.materialTotal ?? 0)
          .toStringAsFixed(2);
      _recompute();
    }
  }

  @override
  void dispose() {
    for (final k in _inputKeys) {
      _controllers[k]?.removeListener(_onInputChanged);
    }
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _onInputChanged() => _recompute();

  double _num(String key) =>
      double.tryParse(_controllers[key]!.text.trim()) ?? 0;

  /// 重算派生字段（保留用户填的比率/加工费，只覆写派生项）。
  /// 内部用 double 不舍入，仅在写回 controller 显示时 toStringAsFixed(2)。
  void _recompute() {
    if (_computing) return;
    _computing = true;
    try {
      final src = _num('sourceE');
      final total =
          src +
          _num('machiningE') +
          _num('incidentalE') +
          _num('lacquerE') +
          _num('platingE') +
          _num('casingE') +
          _num('polishE');
      final workE = total * _num('workRate') / 100;
      final lostE = total * _num('lostRate') / 100;
      final rentE = total * _num('rentRate') / 100;
      final cTotal = total + workE + lostE + rentE;
      final makeE = cTotal * _num('makeRate') / 100;
      final gTotal = cTotal + makeE;
      final derived = {
        'total': total,
        'workE': workE,
        'lostE': lostE,
        'rentE': rentE,
        'cTotal': cTotal,
        'makeE': makeE,
        'gTotal': gTotal,
      };
      for (final e in derived.entries) {
        _controllers[e.key]!.text = _fmt(e.value);
      }
    } finally {
      _computing = false;
    }
  }

  String _fmt(double v) => v.toStringAsFixed(2);

  String? _validateCostField(_CostField field, String? rawValue) {
    final raw = rawValue?.trim() ?? '';
    if (raw.isEmpty) return null;
    final value = double.tryParse(raw);
    if (value == null || !value.isFinite) {
      return '请输入有效数字';
    }
    if (value < 0) {
      return '${field.label}不能为负数';
    }
    if (field.percent && value > 100) {
      return '${field.label}必须在 0% 到 100% 之间';
    }
    if (!_costNumberPattern.hasMatch(raw)) {
      return '最多 14 位整数、4 位小数';
    }
    return null;
  }

  Future<void> _save() async {
    FocusScope.of(context).unfocus();
    if (!(_formKey.currentState?.validate() ?? false)) {
      setState(() => _error = '请先修正标红的成本字段后再保存');
      return;
    }
    final cost = <String, double?>{};
    for (final f in _costFields) {
      final raw = _controllers[f.key]!.text.trim();
      if (raw.isEmpty) {
        cost[f.key] = null;
        continue;
      }
      final v = double.tryParse(raw);
      if (v == null) {
        setState(() => _error = '「${f.label}」需为数字'); // TODO(l10n): 补 arb
        return;
      }
      cost[f.key] = v;
    }
    // 基础字段全量回传（后端 apply 全量覆盖；缺哪个哪个被清 null）。
    final d = widget.detail;
    final body = <String, dynamic>{
      'categoryId': d.categoryId,
      'name': d.name,
      'code': d.code,
      'shortName': d.shortName,
      'model': d.model,
      'spec': d.spec,
      'price': d.price,
      'discount': d.discount,
      'material': d.material,
      'thickness': d.thickness,
      'mWeight': d.mWeight,
      'pack': d.pack,
      'pieces': d.pieces,
      'status': d.status,
      'series': d.series,
      'stockPlace': d.stockPlace,
      'sourceType': d.sourceType,
      if (d.version != null) 'version': d.version,
      ...goodsUuidFirstReferenceBody(d),
      ...cost,
    };
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref
          .read(goodsRepositoryProvider)
          .update(d.id, normalizeGoodsUuidFirstBody(body));
      if (!mounted) return;
      context.appSuccess('成本预算已保存'); // TODO(l10n): 补 arb
      widget.onSaved?.call();
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '保存失败，请稍后重试'); // TODO(l10n): 补 arb
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context); // AutomaticKeepAliveClientMixin
    final theme = Theme.of(context);
    final twoColumn = !context.breakpoint.isCompact;
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.canEdit
                        ? '材料合计由组件自动汇总(自制件取其成本价)，其余比率/加工费可编辑；灰色字段为自动计算'
                        : '各项成本(只读)', // TODO(l10n): 补 arb
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s12),
                  if (twoColumn)
                    for (var i = 0; i < _costFields.length; i += 2)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                        child: Row(
                          children: [
                            Expanded(child: _field(theme, _costFields[i])),
                            const SizedBox(width: UtenSpacing.s12),
                            Expanded(
                              child: i + 1 < _costFields.length
                                  ? _field(theme, _costFields[i + 1])
                                  : const SizedBox.shrink(),
                            ),
                          ],
                        ),
                      )
                  else
                    for (final f in _costFields)
                      Padding(
                        padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
                        child: _field(theme, f),
                      ),
                  if (_error != null) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        _error!,
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
        if (widget.canEdit) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                UtenButton(
                  icon: Icons.save_outlined,
                  isLoading: _saving,
                  onPressed: _save,
                  child: const Text('保存成本预算'), // TODO(l10n): 补 arb
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _field(ThemeData theme, _CostField f) {
    return TextFormField(
      key: ValueKey('goods-cost-${f.key}'),
      controller: _controllers[f.key],
      // 派生字段只读（自动算，不可改）；手填字段受 canEdit 控制。
      readOnly: f.derived,
      enabled: f.derived ? true : widget.canEdit,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: f.derived ? null : [_costNumberFormatter],
      validator: (value) => _validateCostField(f, value),
      errorBuilder: utenTextFieldErrorBuilder,
      decoration: InputDecoration(
        labelText: f.percent ? '${f.label}(%)' : f.label,
        helper: f.derived
            ? null
            : UtenFieldMessage.helper(
                f.percent ? '0% 到 100%，最多 4 位小数' : '非负金额，最多 4 位小数',
              ),
        border: const OutlineInputBorder(),
        isDense: true,
        // 派生字段浅底色，提示"自动计算"。
        filled: f.derived,
        fillColor: f.derived ? theme.colorScheme.surfaceContainerHigh : null,
      ),
    );
  }
}
