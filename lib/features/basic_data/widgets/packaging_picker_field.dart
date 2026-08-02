// 包装字段：点击后打开右滑窗（仅展示货品资料下「原材料」分类），选中需点击确认/取消
// 才生效（showUtenGoodsPicker requireConfirm 模式），选中后把材料名称写入 pack 文本。
//
// StatefulWidget 持有本地值：MasterEditForm 的 customBuilder 每次 onChanged 后都会用同一份
// 静态 ctx.initialValue 重新构建（详见 NumberUnitField 同类注释），必须靠自身 state 记账，
// 否则选中后一 setState 就被冲回旧值。
import 'package:flutter/material.dart';

class PackagingPickerField extends StatefulWidget {
  const PackagingPickerField({
    super.key,
    required this.initialValue,
    required this.onChanged,
    required this.onPick,
  });

  final String? initialValue;

  /// 回写提交值（pack 字段，字符串或 null）。
  final void Function(dynamic value) onChanged;

  /// 打开货品选择器（原材料分类，二次确认），取消返回 null。
  final Future<String?> Function() onPick;

  @override
  State<PackagingPickerField> createState() => _PackagingPickerFieldState();
}

class _PackagingPickerFieldState extends State<PackagingPickerField> {
  late final TextEditingController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.initialValue ?? '');
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(String? v) {
    setState(() => _ctl.text = v ?? '');
    widget.onChanged(v);
  }

  @override
  Widget build(BuildContext context) {
    final hasValue = _ctl.text.isNotEmpty;
    return TextField(
      controller: _ctl,
      readOnly: true,
      decoration: InputDecoration(
        labelText: '包装',
        hintText: '点击从原材料中选择',
        suffixIcon: hasValue
            ? IconButton(
                icon: const Icon(Icons.close_rounded, size: 18),
                tooltip: '清除',
                onPressed: () => _set(null),
              )
            : const Icon(Icons.chevron_right_rounded),
      ),
      onTap: () async {
        final name = await widget.onPick();
        if (name != null) _set(name);
      },
    );
  }
}
