// UtenEmployeePicker - 抽屉式人员选择器（通用组件）
//
// 触发形态与 UtenDepartmentPicker 对齐：只读输入框样式 field
//（显示选中人姓名 + 部门），点击拉开抽屉：
// - compact：showModalBottomSheet（isScrollControlled，约 85% 屏高）
// - medium/expanded：右侧滑入的 420 宽 end drawer 面板（showGeneralDialog）
//
// 抽屉内：标题行 + 关闭、UtenSearchBar（内置 300ms 防抖）调 loader、
// 可滚动结果列表（姓名 + 部门副标题），点选即关。
// 数据由调用方通过 loader 提供，本组件不关心 token / 接口来源。
import 'package:flutter/material.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../core/responsive/breakpoint.dart';
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
    this.hint = '请选择被访人',
    this.validator,
    this.departmentName,
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
      selectedId: _selected?.id,
      departmentName: widget.departmentName,
    );
    final UtenEmployeePickerItem? result;
    if (context.breakpoint.isCompact) {
      result = await showModalBottomSheet<UtenEmployeePickerItem>(
        context: context,
        isScrollControlled: true,
        builder: (ctx) => Padding(
          padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
          child: SizedBox(
            height: MediaQuery.sizeOf(ctx).height * 0.85,
            child: sheet,
          ),
        ),
      );
    } else {
      result = await showGeneralDialog<UtenEmployeePickerItem>(
        context: context,
        barrierDismissible: true,
        barrierLabel: MaterialLocalizations.of(
          context,
        ).modalBarrierDismissLabel,
        barrierColor: Colors.black54,
        transitionDuration: const Duration(milliseconds: 250),
        pageBuilder: (ctx, _, _) => Align(
          alignment: Alignment.centerRight,
          child: Material(
            color: Theme.of(ctx).colorScheme.surface,
            child: SizedBox(width: 420, height: double.infinity, child: sheet),
          ),
        ),
        transitionBuilder: (ctx, anim, _, child) => SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
          child: child,
        ),
      );
    }
    final r = result;
    if (r != null && mounted) {
      setState(() => _selected = r);
      _fieldKey.currentState?.didChange(_selected);
      widget.onChanged(r);
    }
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
              decoration: InputDecoration(
                labelText: widget.label,
                hintText: widget.hint,
                enabled: widget.enabled,
                errorText: field.errorText,
                prefixIcon: const Icon(Icons.person_search_rounded),
                suffixIcon: Icon(
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
    this.selectedId,
    this.departmentName,
  });

  final UtenEmployeePickerLoader loader;
  final String? selectedId;
  final String? departmentName;

  @override
  State<_EmployeePickerSheet> createState() => _EmployeePickerSheetState();
}

class _EmployeePickerSheetState extends State<_EmployeePickerSheet> {
  String _keyword = '';
  bool _loading = true;
  Object? _error;
  List<UtenEmployeePickerItem> _items = const [];

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
                      '选择被访人',
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
              ? const UtenEmpty(
                  icon: Icons.person_off_outlined,
                  message: '未找到匹配的人员',
                )
              : ListView.separated(
                  itemCount: _items.length,
                  separatorBuilder: (_, _) =>
                      const Divider(height: 1, indent: 16, endIndent: 16),
                  itemBuilder: (context, i) {
                    final e = _items[i];
                    final isSelected = e.id == widget.selectedId;
                    return ListTile(
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
                      onTap: () => Navigator.of(context).pop(e),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
