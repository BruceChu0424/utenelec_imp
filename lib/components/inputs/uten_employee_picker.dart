// UtenEmployeePicker - 抽屉式人员选择器（通用组件）
//
// 触发形态与 UtenDepartmentPicker 对齐：只读输入框样式 field
//（显示选中人姓名 + 部门），点击拉开抽屉：
// - compact：约 85% 屏高的底部抽屉；
// - medium/expanded：右侧滑入的 420dp end drawer。
// 响应式展示壳统一复用 showUtenAdaptivePanel。
//
// 抽屉内：标题行 + 关闭、UtenSearchBar（内置 300ms 防抖）调 loader、
// 可滚动结果列表（姓名 + 部门副标题），点选即关。
// 数据由调用方通过 loader 提供，本组件不关心 token / 接口来源。
import 'package:flutter/material.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../layout/uten_adaptive_panel.dart';
import '../layout/uten_picker_confirm_bar.dart';
import 'required_field_decoration.dart';
import 'uten_search_bar.dart';

/// 人员候选项：id / 姓名 / 部门名。
class UtenEmployeePickerItem {
  const UtenEmployeePickerItem({
    required this.id,
    required this.name,
    this.departmentName,
  });

  final String id;
  final String name;
  final String? departmentName;
}

/// 候选加载器：keyword 为 null/空表示不过滤。
typedef UtenEmployeePickerLoader =
    Future<List<UtenEmployeePickerItem>> Function(String? keyword);

class UtenEmployeePicker extends StatefulWidget {
  const UtenEmployeePicker({
    super.key,
    required this.loader,
    required this.onChanged,
    this.initial,
    this.enabled = true,
    this.label,
    this.hint = '请选择员工',
    this.validator,
    this.departmentName,
    this.sheetTitle = '选择员工',
    this.allowClear = false,
    this.emptyMessage = '未找到匹配的人员',
    this.emptyDescription,
    this.required = false,
  });

  /// 候选加载器（抽屉内搜索时调用）。
  final UtenEmployeePickerLoader loader;

  /// 选中变化回调。
  final ValueChanged<UtenEmployeePickerItem?> onChanged;

  /// 初始选中。
  final UtenEmployeePickerItem? initial;

  final bool enabled;
  final String? label;
  final String hint;

  /// 表单校验（返回错误文案或 null）。
  final String? Function(UtenEmployeePickerItem? value)? validator;

  /// 已选部门名（抽屉副标题展示，便于确认"在哪个部门里找人"）。
  final String? departmentName;

  final String sheetTitle;

  final bool allowClear;

  /// 未输入搜索词且候选为空时的业务空态；搜索无命中仍使用通用提示。
  final String emptyMessage;
  final String? emptyDescription;

  /// 是否必填：标签后显红 *；未选且启用时输入框描红边。
  final bool required;

  @override
  State<UtenEmployeePicker> createState() => _UtenEmployeePickerState();
}

class _UtenEmployeePickerState extends State<UtenEmployeePicker> {
  final _fieldKey = GlobalKey<FormFieldState<UtenEmployeePickerItem?>>();
  UtenEmployeePickerItem? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.initial;
  }

  @override
  void didUpdateWidget(UtenEmployeePicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initial != oldWidget.initial) {
      _selected = widget.initial;
    }
  }

  Future<void> _open() async {
    final sheet = _EmployeePickerSheet(
      loader: widget.loader,
      title: widget.sheetTitle,
      selectedId: _selected?.id,
      departmentName: widget.departmentName,
      emptyMessage: widget.emptyMessage,
      emptyDescription: widget.emptyDescription,
    );
    final result = await showUtenAdaptivePanel<UtenEmployeePickerItem>(
      context: context,
      builder: (_) => sheet,
    );
    final r = result;
    if (r != null && mounted) {
      setState(() => _selected = r);
      _fieldKey.currentState?.didChange(_selected);
      widget.onChanged(r);
    }
  }

  void _clear() {
    setState(() => _selected = null);
    _fieldKey.currentState?.didChange(null);
    widget.onChanged(null);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sel = _selected;
    final String? display = sel == null
        ? null
        : (sel.departmentName == null
              ? sel.name
              : '${sel.name}(${sel.departmentName})');
    final requiredEmpty = widget.enabled && widget.required && sel == null;

    return FormField<UtenEmployeePickerItem?>(
      key: _fieldKey,
      initialValue: _selected,
      validator: widget.validator == null
          ? null
          : (_) => widget.validator!(_selected),
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: widget.enabled ? _open : null,
            borderRadius: BorderRadius.circular(10),
            child: InputDecorator(
              isEmpty: display == null,
              decoration: applyRequiredEmpty(
                InputDecoration(
                  label: widget.label == null
                      ? null
                      : requiredLabel(
                          widget.label!,
                          theme,
                          required: widget.required,
                          base: theme.inputDecorationTheme.labelStyle,
                        ),
                  hintText: widget.hint,
                  enabled: widget.enabled,
                  errorText: field.errorText,
                  prefixIcon: const Icon(Icons.person_search_rounded),
                  suffixIcon: sel != null && widget.allowClear
                      ? IconButton(
                          tooltip: '清除选择',
                          onPressed: widget.enabled ? _clear : null,
                          icon: const Icon(Icons.clear_rounded),
                        )
                      : Icon(
                          Icons.unfold_more_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: theme.colorScheme.outline),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: theme.colorScheme.outline),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(
                      color: theme.colorScheme.primary,
                      width: 2,
                    ),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                ),
                theme,
                requiredEmpty: requiredEmpty,
              ),
              child: display == null
                  ? null
                  : Text(display, overflow: TextOverflow.ellipsis),
            ),
          ),
        ],
      ),
    );
  }
}

/// 抽屉内容：标题 + 搜索 + 结果列表（点选即关）。
class _EmployeePickerSheet extends StatefulWidget {
  const _EmployeePickerSheet({
    required this.loader,
    required this.title,
    required this.emptyMessage,
    this.selectedId,
    this.departmentName,
    this.emptyDescription,
  });

  final UtenEmployeePickerLoader loader;
  final String title;
  final String? selectedId;
  final String? departmentName;
  final String emptyMessage;
  final String? emptyDescription;

  @override
  State<_EmployeePickerSheet> createState() => _EmployeePickerSheetState();
}

class _EmployeePickerSheetState extends State<_EmployeePickerSheet> {
  String _keyword = '';
  bool _loading = true;
  Object? _error;
  List<UtenEmployeePickerItem> _items = const [];

  /// 已点选（高亮）的人员；底部「确定」才 pop 返回（二次操作契约）。
  UtenEmployeePickerItem? _picked;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final kw = _keyword.trim();
      final items = await widget.loader(kw.isEmpty ? null : kw);
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (widget.departmentName != null)
                      Text(
                        widget.departmentName!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: UtenSearchBar(
            hint: '搜索姓名 / 工号',
            onChanged: (v) {
              _keyword = v;
              _load();
            },
          ),
        ),
        Expanded(
          child: _loading
              ? const UtenSkeletonList()
              : _error != null
              ? UtenEmpty.error(
                  message: '$_error',
                  actionLabel: '重试',
                  onAction: _load,
                )
              : _items.isEmpty
              ? UtenEmpty(
                  icon: Icons.person_off_outlined,
                  message: _keyword.trim().isEmpty
                      ? widget.emptyMessage
                      : '未找到匹配的人员',
                  description: _keyword.trim().isEmpty
                      ? widget.emptyDescription
                      : null,
                )
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, i) {
                    final e = _items[i];
                    final picked = e.id == _picked?.id;
                    final isSelected = picked || e.id == widget.selectedId;
                    return ListTile(
                      selected: isSelected,
                      leading: isSelected
                          ? Icon(
                              Icons.check_rounded,
                              color: theme.colorScheme.primary,
                            )
                          : Icon(
                              Icons.person_outline_rounded,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                      title: Text(e.name),
                      subtitle: e.departmentName == null
                          ? null
                          : Text(e.departmentName!),
                      trailing: picked
                          ? Icon(
                              Icons.check_circle_rounded,
                              size: 20,
                              color: theme.colorScheme.primary,
                            )
                          : null,
                      onTap: () => setState(() => _picked = e),
                    );
                  },
                ),
        ),
        UtenPickerConfirmBar(
          selectedCount: _picked == null ? 0 : 1,
          selectedLabel: _picked == null
              ? null
              : (_picked!.departmentName == null
                    ? _picked!.name
                    : '${_picked!.name}(${_picked!.departmentName})'),
          onConfirm: () => Navigator.of(context).pop(_picked),
        ),
      ],
    );
  }
}
