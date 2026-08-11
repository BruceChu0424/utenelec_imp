// 数字+单位复合字段：厚度/单重这类"数值+计量单位"字段共用一个字段格位
// （前半只能填数字，后半下拉选单位，不额外新增独立输入框行）。
// 单位下拉复用货品「单位」主档字典（[unitDictProvider]），支持内联新建新单位。
import 'package:flutter/material.dart';

import '../../../components/inputs/uten_dropdown_field.dart';
import 'master_edit_dialog.dart' show MasterSelectOption;

class NumberUnitField extends StatefulWidget {
  const NumberUnitField({
    super.key,
    required this.label,
    required this.numberKey,
    required this.unitKey,
    required this.unitOptions,
    required this.onChanged,
    this.numberInitial,
    this.unitInitial,
    this.onAddUnit,
  });

  final String label;

  /// 提交 body 的数字字段 key（如 'thickness'）。
  final String numberKey;

  /// 提交 body 的单位字段 key（如 'thicknessUnitLegacyId'）。
  final String unitKey;

  final String? numberInitial;
  final String? unitInitial;
  final List<MasterSelectOption> unitOptions;

  /// 单位下拉内联新建（复用货品单位主档 showUnitAddSheet）。
  final Future<String?> Function()? onAddUnit;

  /// 回写复合值：{numberKey: double?, unitKey: int?}。
  final void Function(Map<String, dynamic> value) onChanged;

  @override
  State<NumberUnitField> createState() => _NumberUnitFieldState();
}

class _NumberUnitFieldState extends State<NumberUnitField> {
  late final TextEditingController _ctl;
  String? _unit;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.numberInitial ?? '');
    _unit = widget.unitInitial;
    // MasterEditForm 对 custom 字段的初值只按原始字符串记账；若用户全程不碰这个复合字段就直接保存，
    // 需要在首帧后补一次真正的 {numberKey,unitKey} 回写，否则 buildBody 会把初值字符串整个塞进
    // numberKey、且 unitKey 从未提交，编辑态保存会把已有单位悄悄清空。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _emit();
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _emit() {
    final raw = _ctl.text.trim();
    widget.onChanged({
      widget.numberKey: raw.isEmpty ? null : double.tryParse(raw),
      widget.unitKey: _unit == null ? null : int.tryParse(_unit!),
    });
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          flex: 3,
          child: TextField(
            controller: _ctl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: widget.label),
            onChanged: (_) => _emit(),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          flex: 2,
          child: UtenDropdownField(
            hintText: '单位',
            value: _unit,
            items: [
              for (final o in widget.unitOptions)
                UtenDropdownItem(value: o.value, label: o.label),
            ],
            onChanged: (v) => setState(() {
              _unit = v;
              _emit();
            }),
            addNewLabel: widget.onAddUnit == null ? null : '添加单位',
            onAddNew: widget.onAddUnit == null
                ? null
                : () async {
                    final v = await widget.onAddUnit!();
                    if (v != null) {
                      setState(() {
                        _unit = v;
                        _emit();
                      });
                    }
                  },
          ),
        ),
      ],
    );
  }
}
