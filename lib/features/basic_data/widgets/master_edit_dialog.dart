// 主档通用编辑（货品/模具/客户/供应商 新建 + 编辑 共用）。
//
// 各主档字段集不同，但表单交互一致：调用方按 [MasterFieldDef] 列表提供字段，
// 可用 [MasterFieldDef.group] 分段；固定值（如 categoryId）走 [fixedValues] 随提交
// 带上、不渲染输入框。
//
// 容器自适应（参照 showUtenPickerSheet）：compact 底部抽屉 / medium+ 居中面板。
// 字段双列分组（compact 退单列），底部按钮居中。提交回调返回是否成功，成功则自关。
import 'package:flutter/material.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';

/// 主档字段值类型：文本 / 整数 / 金额（double）/ 下拉选择。
enum MasterFieldType { text, integer, money, select }

/// 下拉选项（select 类型用）：[value] 提交值、[label] 展示文案。
/// 颜色/单位选择器：value = legacy_id 字符串、label = 名称。
class MasterSelectOption {
  const MasterSelectOption({required this.value, required this.label});

  final String value;
  final String label;
}

/// 状态字段固定选项（使用/禁用），10 个主档共用。配合后端 CHECK(status IN ('使用','禁用'))。
const List<MasterSelectOption> kMasterStatusOptions = [
  MasterSelectOption(value: '使用', label: '使用'),
  MasterSelectOption(value: '禁用', label: '禁用'),
];

/// 主档字段定义。
class MasterFieldDef {
  const MasterFieldDef({
    required this.key,
    required this.label,
    this.type = MasterFieldType.text,
    this.required = false,
    this.hint,
    this.group,
    this.options,
    this.selectInteger = false,
    this.readOnly = false,
  });

  /// 与后端 SaveRequest 字段名对齐（如 name / colorLegacyId）。
  final String key;

  /// 中文标签。
  final String label;

  final MasterFieldType type;

  /// 是否必填（label 后附 *，提交时空则报错）。
  final bool required;

  final String? hint;

  /// 字段所属分组：表单按此分段、双列展示。null 归入「其他」。
  final String? group;

  /// select 类型的下拉选项（其他类型忽略）。
  final List<MasterSelectOption>? options;

  /// select 提交值是否按整数解析（颜色/单位 legacy_id = true，提交 JSON 数字）。
  final bool selectInteger;

  /// 只读字段（如编号）：禁用展示、不参与提交。
  /// 编辑时显既有值；新建时值为空 → 显 [hint]（如「保存后自动生成」）。
  final bool readOnly;
}

typedef MasterSubmit = Future<bool> Function(Map<String, dynamic> body);

/// 自适应弹出主档编辑表单：compact 底部抽屉 / medium+ 居中面板。
///
/// [onSubmit] 返回 true 关闭、false 保持打开（仿 CategoryEditDialog 范式）。
Future<void> showMasterEditDialog({
  required BuildContext context,
  required String title,
  required List<MasterFieldDef> fields,
  required MasterSubmit onSubmit,
  Map<String, String> initialValues = const <String, String>{},
  Map<String, dynamic> fixedValues = const <String, dynamic>{},
}) {
  final body = _MasterEditBody(
    title: title,
    fields: fields,
    initialValues: initialValues,
    fixedValues: fixedValues,
    onSubmit: onSubmit,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(UtenRadius.lg),
        ),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: body,
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (ctx) => Dialog(
      shape: const RoundedRectangleBorder(borderRadius: UtenRadius.xxlAll),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(ctx).height * 0.88,
        ),
        child: body,
      ),
    ),
  );
}

class _MasterEditBody extends StatefulWidget {
  const _MasterEditBody({
    required this.title,
    required this.fields,
    required this.initialValues,
    required this.fixedValues,
    required this.onSubmit,
  });

  final String title;
  final List<MasterFieldDef> fields;
  final Map<String, String> initialValues;
  final Map<String, dynamic> fixedValues;
  final MasterSubmit onSubmit;

  @override
  State<_MasterEditBody> createState() => _MasterEditBodyState();
}

class _MasterEditBodyState extends State<_MasterEditBody> {
  late final Map<String, TextEditingController> _controllers;

  /// select 字段的当前选中值（key → 选项 value，未选为 null）。其他类型用 [_controllers]。
  final Map<String, String?> _selectValues = {};
  String? _error;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final f in widget.fields)
        if (f.type != MasterFieldType.select)
          f.key: TextEditingController(text: widget.initialValues[f.key] ?? ''),
    };
    for (final f in widget.fields) {
      if (f.type == MasterFieldType.select) {
        // 初始值不在选项里（如对应记录已删）→ 视为未选，避免 Dropdown 断言。
        final init = widget.initialValues[f.key];
        final vals = {
          for (final o in (f.options ?? const <MasterSelectOption>[])) o.value,
        };
        _selectValues[f.key] =
            (init != null && init.isNotEmpty && vals.contains(init))
            ? init
            : null;
      }
    }
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _submit() async {
    final body = Map<String, dynamic>.from(widget.fixedValues);
    for (final f in widget.fields) {
      if (f.readOnly) continue; // 只读字段（编号）不上送：新建服务端生成、编辑保留
      // select 类型：从 _selectValues 取，按 selectInteger 决定提交 int 还是 String。
      if (f.type == MasterFieldType.select) {
        final sv = _selectValues[f.key];
        if (f.required && (sv == null || sv.isEmpty)) {
          setState(() => _error = '请选择「${f.label}」'); // TODO(l10n): 补 arb
          return;
        }
        if (sv == null || sv.isEmpty) {
          body[f.key] = null;
        } else if (f.selectInteger) {
          final v = int.tryParse(sv);
          if (v == null) {
            setState(() => _error = '「${f.label}」值非法'); // TODO(l10n): 补 arb
            return;
          }
          body[f.key] = v;
        } else {
          body[f.key] = sv;
        }
        continue;
      }
      final raw = _controllers[f.key]!.text.trim();
      if (f.required && raw.isEmpty) {
        setState(() => _error = '请填写「${f.label}」'); // TODO(l10n): 补 arb
        return;
      }
      if (raw.isEmpty) {
        body[f.key] = null; // 空串统一存 null，保持与老库 nullable 一致
        continue;
      }
      switch (f.type) {
        case MasterFieldType.integer:
          final v = int.tryParse(raw);
          if (v == null) {
            setState(() => _error = '「${f.label}」需为整数'); // TODO(l10n): 补 arb
            return;
          }
          body[f.key] = v;
        case MasterFieldType.money:
          final v = double.tryParse(raw);
          if (v == null) {
            setState(() => _error = '「${f.label}」需为数字'); // TODO(l10n): 补 arb
            return;
          }
          body[f.key] = v;
        case MasterFieldType.text:
          body[f.key] = raw;
        case MasterFieldType.select:
          // select 已在循环顶部处理，此处不可达（满足 switch 穷尽）。
          break;
      }
    }
    setState(() => _error = null);
    // 兜底：onSubmit 内部通常已自带成功/失败通知；此处只兜未捕获异常，防止静默失败。
    late final bool ok;
    try {
      ok = await widget.onSubmit(body);
    } catch (e) {
      if (!mounted) return;
      context.appApiError(e);
      return;
    }
    if (!mounted) return;
    if (ok) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final twoColumn = !context.breakpoint.isCompact;

    // 按 group 声明顺序分段（null → 「其他」）。
    final groupOrder = <String>[];
    final groups = <String, List<MasterFieldDef>>{};
    for (final f in widget.fields) {
      final g = f.group ?? '其他'; // TODO(l10n): 补 arb
      (groups[g] ??= <MasterFieldDef>[]).add(f);
      if (!groupOrder.contains(g)) groupOrder.add(g);
    }

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _header(theme),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < groupOrder.length; i++) ...[
                    if (i > 0) const SizedBox(height: UtenSpacing.s20),
                    UtenSectionHeader(title: groupOrder[i], subdued: true),
                    const SizedBox(height: UtenSpacing.s12),
                    _fieldGrid(groups[groupOrder[i]]!, twoColumn),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      _error!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          _actions(),
        ],
      ),
    );
  }

  Widget _header(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s16,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.title,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close_rounded),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _fieldGrid(List<MasterFieldDef> fields, bool twoColumn) {
    if (!twoColumn) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final f in fields) ...[
            _field(f),
            const SizedBox(height: UtenSpacing.s12),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < fields.length; i += 2)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _field(fields[i])),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(
                  child: i + 1 < fields.length
                      ? _field(fields[i + 1])
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _field(MasterFieldDef f) {
    if (f.readOnly) return _readOnlyField(f);
    if (f.type == MasterFieldType.select) return _selectField(f);
    return TextField(
      controller: _controllers[f.key],
      keyboardType: f.type == MasterFieldType.text
          ? TextInputType.text
          : const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: f.required ? '${f.label} *' : f.label,
        hintText: f.hint,
      ),
    );
  }

  /// 只读字段（编号）：禁用展示。编辑时显既有值；新建时空值显 [MasterFieldDef.hint]。
  Widget _readOnlyField(MasterFieldDef f) {
    final ctl = _controllers[f.key];
    final empty = ctl == null || ctl.text.isEmpty;
    return TextField(
      controller: ctl,
      enabled: false,
      decoration: InputDecoration(
        labelText: f.label,
        hintText: empty ? (f.hint ?? '') : null,
      ),
    );
  }

  /// select 字段：UtenDropdownField（Overlay 弹层，对齐全站下拉；根治溢出）。
  /// required → 不显示「不选」（强制选）；非 required → allowClear 可清空回 null。
  /// initialValue 已在 initState sanitize（不在选项里→null）。
  Widget _selectField(MasterFieldDef f) {
    final options = f.options ?? const <MasterSelectOption>[];
    return UtenDropdownField(
      label: f.label,
      required: f.required,
      value: _selectValues[f.key],
      allowClear: !f.required,
      hintText: f.hint,
      items: [
        for (final o in options)
          UtenDropdownItem(value: o.value, label: o.label),
      ],
      onChanged: (v) => setState(() => _selectValues[f.key] = v),
    );
  }

  Widget _actions() {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'), // TODO(l10n): 补 arb
          ),
          const SizedBox(width: UtenSpacing.s12),
          UtenActionButton(
            label: const Text('保存'), // TODO(l10n): 补 arb
            onAction: _submit,
          ),
        ],
      ),
    );
  }
}
