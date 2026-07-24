// 主档通用编辑对话框（货品/模具/客户/供应商 新建 + 编辑 共用）。
//
// 各主档字段集不同，但表单交互一致：调用方按 [MasterFieldDef] 列表提供字段，
// 固定值（如 categoryId）走 [fixedValues] 随提交带上、不渲染输入框。
// 提交回调返回是否成功，成功则对话框自关（仿 CategoryEditDialog 范式）。
import 'package:flutter/material.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../core/theme/uten_tokens.dart';

/// 主档字段值类型：文本 / 整数 / 金额（double）。
enum MasterFieldType { text, integer, money }

/// 主档字段定义。
class MasterFieldDef {
  const MasterFieldDef({
    required this.key,
    required this.label,
    this.type = MasterFieldType.text,
    this.required = false,
    this.hint,
  });

  /// 与后端 SaveRequest 字段名对齐（如 name / fullName / credit）。
  final String key;

  /// 中文标签。
  final String label;

  final MasterFieldType type;

  /// 是否必填（label 后附 *，提交时空则报错）。
  final bool required;

  final String? hint;
}

class MasterEditDialog extends StatefulWidget {
  const MasterEditDialog({
    super.key,
    required this.title,
    required this.fields,
    required this.onSubmit,
    this.initialValues = const <String, String>{},
    this.fixedValues = const <String, dynamic>{},
  });

  final String title;
  final List<MasterFieldDef> fields;

  /// 编辑态回填：key → 字符串初值（新建态为空）。
  final Map<String, String> initialValues;

  /// 固定值：随提交带上、不渲染输入框（如 categoryId = 当前分类）。
  final Map<String, dynamic> fixedValues;

  /// 提交回调：返回 true 关闭对话框，false 保持打开。
  final Future<bool> Function(Map<String, dynamic> body) onSubmit;

  @override
  State<MasterEditDialog> createState() => _MasterEditDialogState();
}

class _MasterEditDialogState extends State<MasterEditDialog> {
  late final Map<String, TextEditingController> _controllers;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final f in widget.fields)
        f.key: TextEditingController(text: widget.initialValues[f.key] ?? ''),
    };
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
      }
    }
    setState(() => _error = null);
    final ok = await widget.onSubmit(body);
    if (!mounted) return;
    if (ok) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final f in widget.fields) ...[
              TextField(
                controller: _controllers[f.key],
                keyboardType: f.type == MasterFieldType.text
                    ? TextInputType.text
                    : const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: f.required ? '${f.label} *' : f.label,
                  hintText: f.hint,
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
            ],
            if (_error != null)
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'), // TODO(l10n): 补 arb
        ),
        UtenActionButton(
          label: const Text('保存'), // TODO(l10n): 补 arb
          onAction: _submit,
        ),
      ],
    );
  }
}
