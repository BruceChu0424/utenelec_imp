// 部门树 + 员工选择器：先选部门（未展开的分类树），点部门列出该部门（含子部门）的人员，
// 也可直接搜索姓名/工号跨部门找人。左树 + 右人员列表布局仿 uten_goods_picker.dart。
//
// 问题 #6：模具「保管人」原来是纯搜索平铺列表，改成"先浏览部门再挑人"，更贴近老员工的
// 使用习惯（不知道该搜什么名字时，按部门找人更直观）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/inputs/uten_employee_picker.dart' show UtenEmployeePickerItem;
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../department/models/department_node.dart';
import '../../department/widgets/uten_department_picker.dart' show departmentPickerTreeProvider;
import '../../department/widgets/uten_department_tree_view.dart';
import '../repositories/employee_repository.dart';

/// 弹出「部门树 + 员工」选择器，返回所选员工；取消返回 null。
Future<UtenEmployeePickerItem?> showUtenDepartmentEmployeePicker(
  BuildContext context,
  WidgetRef ref, {
  String title = '选择员工',
}) async {
  List<DepartmentNode> tree;
  try {
    tree = await ref.read(departmentPickerTreeProvider.future);
  } catch (_) {
    if (context.mounted) context.appError('部门树加载失败，请稍后重试');
    return null;
  }
  if (!context.mounted) return null;
  final sheet = _DeptEmployeePickerSheet(tree: tree, title: title);
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<UtenEmployeePickerItem>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(UtenRadius.lg)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(height: MediaQuery.sizeOf(ctx).height * 0.85, child: sheet),
      ),
    );
  }
  return showGeneralDialog<UtenEmployeePickerItem>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (ctx, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(ctx).colorScheme.surface,
        child: SizedBox(width: 720, height: double.infinity, child: sheet),
      ),
    ),
    transitionBuilder: (ctx, anim, _, child) => SlideTransition(
      position: Tween<Offset>(begin: const Offset(1, 0), end: Offset.zero)
          .animate(CurvedAnimation(parent: anim, curve: Curves.easeOutCubic)),
      child: child,
    ),
  );
}

class _DeptEmployeePickerSheet extends ConsumerStatefulWidget {
  const _DeptEmployeePickerSheet({required this.tree, required this.title});
  final List<DepartmentNode> tree;
  final String title;

  @override
  ConsumerState<_DeptEmployeePickerSheet> createState() =>
      _DeptEmployeePickerSheetState();
}

class _DeptEmployeePickerSheetState
    extends ConsumerState<_DeptEmployeePickerSheet> {
  String? _selectedDeptId;
  String? _selectedDeptName;
  final _keywordCtl = TextEditingController();
  Timer? _debounce;
  bool _loading = false;
  String? _error;
  List<UtenEmployeePickerItem> _items = const [];

  @override
  void dispose() {
    _keywordCtl.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onDeptTap(DepartmentNode node) {
    setState(() {
      _selectedDeptId = node.id;
      _selectedDeptName = node.name;
    });
    _reload();
  }

  void _onKeywordChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), _reload);
  }

  Future<void> _reload() async {
    final kw = _keywordCtl.text.trim();
    final deptId = _selectedDeptId;
    if (kw.isEmpty && deptId == null) {
      setState(() {
        _items = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final res = await ref.read(employeeRepositoryProvider).list(
            size: 50,
            search: kw.isEmpty ? null : kw,
            departmentId: kw.isEmpty ? deptId : null,
            includeSubtree: true,
          );
      if (!mounted) return;
      setState(() {
        _items = [
          for (final e in res.items)
            UtenEmployeePickerItem(
              id: e.id,
              name: e.fullName,
              departmentName: [
                if (e.departmentName != null) e.departmentName!,
                '工号${e.code}',
              ].join(' · '),
            ),
        ];
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载人员失败，请稍后重试';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final treeWidth = context.breakpoint.isCompact ? 150.0 : 240.0;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: Row(
            children: [
              SizedBox(
                width: treeWidth,
                child: UtenDepartmentTreeView(
                  nodes: widget.tree,
                  showSearch: false,
                  initiallyExpandDepth: 0,
                  selectedIds: _selectedDeptId == null ? const {} : {_selectedDeptId!},
                  nodeEnabledPredicate: (_) => true,
                  onNodeTap: _onDeptTap,
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(child: _buildRightPane(theme)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildRightPane(ThemeData theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: TextField(
            controller: _keywordCtl,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              hintText: '搜索姓名/工号（跨部门）',
              isDense: true,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onChanged: _onKeywordChanged,
          ),
        ),
        if (_selectedDeptName != null && _keywordCtl.text.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '部门：$_selectedDeptName',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          ),
        Expanded(child: _buildList(theme)),
      ],
    );
  }

  Widget _buildList(ThemeData theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2.5));
    }
    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: theme.colorScheme.error),
          textAlign: TextAlign.center,
        ),
      );
    }
    if (_items.isEmpty) {
      final hasQuery =
          _keywordCtl.text.trim().isNotEmpty || _selectedDeptId != null;
      return Center(
        child: Text(
          hasQuery ? '无匹配人员' : '请选择左侧部门或输入姓名/工号搜索',
          style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      itemCount: _items.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (ctx, i) {
        final e = _items[i];
        return ListTile(
          title: Text(e.name),
          subtitle: e.departmentName == null ? null : Text(e.departmentName!),
          onTap: () => Navigator.of(context).pop(e),
        );
      },
    );
  }
}

/// 只读展示 + 点击打开 [showUtenDepartmentEmployeePicker] 的表单字段
/// （MasterFieldDef.customBuilder 场景，如模具「保管人」；只提交员工 id，
/// 展示名由本组件自行持有——同 packaging_picker_field.dart 的静态 ctx.initialValue 注释）。
class DepartmentEmployeePickerField extends StatefulWidget {
  const DepartmentEmployeePickerField({
    super.key,
    required this.label,
    required this.hint,
    required this.initialId,
    required this.initialName,
    required this.onChanged,
    required this.onPick,
    this.allowClear = true,
  });

  final String label;
  final String hint;
  final String? initialId;
  final String? initialName;

  /// 回写提交值（员工 id 字符串或 null）。
  final void Function(dynamic value) onChanged;

  /// 打开部门树+员工选择器，取消返回 null。
  final Future<UtenEmployeePickerItem?> Function() onPick;

  final bool allowClear;

  @override
  State<DepartmentEmployeePickerField> createState() =>
      _DepartmentEmployeePickerFieldState();
}

class _DepartmentEmployeePickerFieldState
    extends State<DepartmentEmployeePickerField> {
  late final TextEditingController _ctl;
  String? _id;

  @override
  void initState() {
    super.initState();
    _id = (widget.initialId == null || widget.initialId!.isEmpty)
        ? null
        : widget.initialId;
    _ctl = TextEditingController(text: widget.initialName ?? '');
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _set(UtenEmployeePickerItem? item) {
    setState(() {
      _id = item?.id;
      _ctl.text = item?.name ?? '';
    });
    widget.onChanged(_id);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TextField(
      controller: _ctl,
      readOnly: true,
      decoration: InputDecoration(
        labelText: widget.label,
        hintText: widget.hint,
        prefixIcon: const Icon(Icons.person_search_rounded),
        suffixIcon: _id != null && widget.allowClear
            ? IconButton(
                tooltip: '清除选择',
                icon: const Icon(Icons.clear_rounded),
                onPressed: () => _set(null),
              )
            : Icon(
                Icons.unfold_more_rounded,
                color: theme.colorScheme.onSurfaceVariant,
              ),
      ),
      onTap: () async {
        final item = await widget.onPick();
        if (item != null) _set(item);
      },
    );
  }
}
