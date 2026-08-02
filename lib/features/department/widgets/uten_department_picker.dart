// UtenDepartmentPicker - 统一抽屉式部门选择器（领域组件）
//
// 触发形态：只读输入框样式的 field（显示选中完整路径，placeholder「请选择部门」），
// 点击拉开抽屉：
// - compact：showModalBottomSheet（isScrollControlled，约 85% 屏高）
// - medium/expanded：右侧滑入的 420 宽 end drawer 面板（showGeneralDialog）
//
// 可选规则：公司根节点不显示；决策层/管理中心仅作展开骨架（灰显、不可选）；
// 一级部门/二级班组/三级科室可选。单选点选即关；多选带 Checkbox + 底部操作条。
// 路径显示：从一级部门起用「-」连接（如 PMC运营部-采购部）。
// 树渲染由全站共享的 UtenDepartmentTreeView 提供。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_toast.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../core/responsive/breakpoint.dart';
import '../models/department_node.dart';
import '../repositories/department_repository.dart';
import 'uten_department_tree_view.dart';

/// 选择模式。
enum UtenDepartmentPickerMode { single, multi }

/// 选中项：id / 名称 / 完整路径（一级部门起「-」连接）/ 层级。
class DeptSelection {
  const DeptSelection({
    required this.id,
    required this.name,
    required this.fullPath,
    required this.level,
  });

  final String id;
  final String name;
  final String fullPath;
  final String level;
}

/// 选择器自用的部门树 Provider（与部门管理页共用 Dio 仓库）。
final departmentPickerTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>(
      (ref) => ref.watch(departmentRepositoryProvider).tree(),
    );

/// 由整棵树构建「可选节点 id → DeptSelection」映射。
/// 路径从第一个一级部门节点起收集，用「-」连接。
Map<String, DeptSelection> buildDeptSelectionMap(List<DepartmentNode> tree) {
  final out = <String, DeptSelection>{};
  void walk(List<DepartmentNode> nodes, List<String> chain) {
    for (final n in nodes) {
      final selectable = kSelectableDepartmentLevels.contains(n.level);
      final nextChain = selectable ? [...chain, n.name] : chain;
      if (selectable) {
        out[n.id] = DeptSelection(
          id: n.id,
          name: n.name,
          fullPath: nextChain.join('-'),
          level: n.level,
        );
      }
      walk(n.children, nextChain);
    }
  }

  walk(tree, const []);
  return out;
}

class UtenDepartmentPicker extends ConsumerStatefulWidget {
  const UtenDepartmentPicker({
    super.key,
    required this.mode,
    required this.onChanged,
    this.initialSelection = const [],
    this.enabled = true,
    this.label,
    this.hint = '请选择部门',
    this.validator,
    this.badgeCountFor,
    this.treeOverride,
    this.requireConfirm = false,
    this.expandOnRowTap = false,
    this.initiallyExpandedIds = const {},
  });

  /// 单选 / 多选。
  final UtenDepartmentPickerMode mode;

  /// 初始选中。允许只给 id（fullPath 留空），树加载后自动解析路径显示。
  final List<DeptSelection> initialSelection;

  /// 选中变化回调（单选为单元素列表；多选在点「确定」时触发）。
  final ValueChanged<List<DeptSelection>> onChanged;

  final bool enabled;
  final String? label;
  final String hint;

  /// 表单校验（返回错误文案或 null）。
  final String? Function(List<DeptSelection> selection)? validator;

  /// 树节点旁的数量徽标（如已配角色数），返回 null/0 不显示。
  final int? Function(String departmentId)? badgeCountFor;

  /// 外部传入的树（如访客端目录）。非 null 时不再请求
  /// departmentPickerTreeProvider（员工 token 接口）。
  final List<DepartmentNode>? treeOverride;

  /// 单选模式下是否需要底部「确定」二次确认（而非点行即选中并关闭）。
  /// 多选模式恒需确认，此项无效。默认 false 保持历史行为（各既有调用点零回归）。
  final bool requireConfirm;

  /// 点击行文字是否同时展开/收起子部门（默认仅点左侧箭头展开，避免误触选中态收起）。
  final bool expandOnRowTap;

  /// 额外强制默认展开的节点 id（如"只展开生产部，同级其它部门保持折叠"）。
  final Set<String> initiallyExpandedIds;

  @override
  ConsumerState<UtenDepartmentPicker> createState() =>
      _UtenDepartmentPickerState();
}

class _UtenDepartmentPickerState extends ConsumerState<UtenDepartmentPicker> {
  final _fieldKey = GlobalKey<FormFieldState<List<DeptSelection>>>();
  List<DeptSelection> _selection = const [];

  bool get _isMulti => widget.mode == UtenDepartmentPickerMode.multi;

  @override
  void initState() {
    super.initState();
    _selection = List.of(widget.initialSelection);
    // treeOverride 场景：树已就绪，同步解析初始选中的完整路径
    //（initState 内不能 setState，直接赋值即可）。
    final override = widget.treeOverride;
    if (override != null) {
      final resolved = _resolvedSelection(override);
      if (resolved != null) _selection = resolved;
    }
  }

  @override
  void didUpdateWidget(UtenDepartmentPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.initialSelection != oldWidget.initialSelection) {
      _selection = List.of(widget.initialSelection);
    }
    final override = widget.treeOverride;
    if (override != null && override != oldWidget.treeOverride) {
      _resolveSelection(override);
    }
  }

  /// 用树把选中项中缺路径的项解析成完整 DeptSelection；无变化返回 null。
  List<DeptSelection>? _resolvedSelection(List<DepartmentNode> tree) {
    if (_selection.isEmpty) return null;
    final map = buildDeptSelectionMap(tree);
    var changed = false;
    final resolved = <DeptSelection>[];
    for (final s in _selection) {
      if (s.fullPath.isEmpty && map.containsKey(s.id)) {
        resolved.add(map[s.id]!);
        changed = true;
      } else {
        resolved.add(s);
      }
    }
    return changed ? resolved : null;
  }

  /// 树就绪后，把 initialSelection 中缺路径的项解析成完整 DeptSelection。
  void _resolveSelection(List<DepartmentNode> tree) {
    final resolved = _resolvedSelection(tree);
    if (resolved != null && mounted) {
      setState(() => _selection = resolved);
      _fieldKey.currentState?.didChange(_selection);
    }
  }

  Future<void> _open() async {
    List<DepartmentNode> tree;
    final override = widget.treeOverride;
    if (override != null) {
      tree = override;
    } else {
      try {
        tree = await ref.read(departmentPickerTreeProvider.future);
      } catch (_) {
        if (mounted) UtenToast.error(context, '部门树加载失败，请稍后重试');
        return;
      }
    }
    if (!mounted) return;
    final sheet = _DepartmentPickerSheet(
      mode: widget.mode,
      tree: tree,
      initialSelection: _selection,
      badgeCountFor: widget.badgeCountFor,
      requireConfirm: widget.requireConfirm,
      expandOnRowTap: widget.expandOnRowTap,
      initiallyExpandedIds: widget.initiallyExpandedIds,
    );
    final List<DeptSelection>? result;
    if (context.breakpoint.isCompact) {
      result = await showModalBottomSheet<List<DeptSelection>>(
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
      result = await showGeneralDialog<List<DeptSelection>>(
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
      setState(() => _selection = r);
      _fieldKey.currentState?.didChange(_selection);
      widget.onChanged(r);
    }
  }

  void _removeChip(DeptSelection s) {
    setState(() => _selection = _selection.where((e) => e.id != s.id).toList());
    _fieldKey.currentState?.didChange(_selection);
    widget.onChanged(_selection);
  }

  @override
  Widget build(BuildContext context) {
    // treeOverride 场景：树由外部传入，不监听员工端部门树 Provider。
    if (widget.treeOverride == null) {
      ref.listen(departmentPickerTreeProvider, (_, next) {
        final tree = next.valueOrNull;
        if (tree != null) _resolveSelection(tree);
      });
    }
    final theme = Theme.of(context);
    final String? display = _selection.isEmpty
        ? null
        : _isMulti
        ? '已选 ${_selection.length} 个部门'
        : (_selection.first.fullPath.isNotEmpty
              ? _selection.first.fullPath
              : _selection.first.name);

    return FormField<List<DeptSelection>>(
      key: _fieldKey,
      initialValue: _selection,
      validator: widget.validator == null
          ? null
          : (_) => widget.validator!(_selection),
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
          if (_isMulti && _selection.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final s in _selection)
                    InputChip(
                      label: Text(s.name),
                      onDeleted: widget.enabled ? () => _removeChip(s) : null,
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 抽屉内容：标题 + 共享组织树（UtenDepartmentTreeView）+ （多选）底部操作条。
class _DepartmentPickerSheet extends StatefulWidget {
  const _DepartmentPickerSheet({
    required this.mode,
    required this.tree,
    required this.initialSelection,
    this.badgeCountFor,
    this.requireConfirm = false,
    this.expandOnRowTap = false,
    this.initiallyExpandedIds = const {},
  });

  final UtenDepartmentPickerMode mode;
  final List<DepartmentNode> tree;
  final List<DeptSelection> initialSelection;
  final int? Function(String departmentId)? badgeCountFor;
  final bool requireConfirm;
  final bool expandOnRowTap;
  final Set<String> initiallyExpandedIds;

  @override
  State<_DepartmentPickerSheet> createState() => _DepartmentPickerSheetState();
}

class _DepartmentPickerSheetState extends State<_DepartmentPickerSheet> {
  late final Map<String, DeptSelection> _selectionMap;
  late final Map<String, DeptSelection> _selected;

  bool get _isMulti => widget.mode == UtenDepartmentPickerMode.multi;

  @override
  void initState() {
    super.initState();
    _selectionMap = buildDeptSelectionMap(widget.tree);
    _selected = {for (final s in widget.initialSelection) s.id: s};
  }

  void _onToggleSelect(DepartmentNode node) {
    final sel = _selectionMap[node.id];
    if (sel == null) return;
    if (_isMulti) {
      setState(() {
        if (_selected.containsKey(node.id)) {
          _selected.remove(node.id);
        } else {
          _selected[node.id] = sel;
        }
      });
    } else if (widget.requireConfirm) {
      setState(() {
        _selected
          ..clear()
          ..[node.id] = sel;
      });
    } else {
      Navigator.of(context).pop([sel]);
    }
  }

  Widget? _badge(DepartmentNode node) {
    final theme = Theme.of(context);
    final badge = widget.badgeCountFor?.call(node.id);
    if (badge == null || badge <= 0) return null;
    return Container(
      margin: const EdgeInsets.only(right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$badge',
        style: TextStyle(
          fontSize: 10,
          color: theme.colorScheme.onPrimaryContainer,
        ),
      ),
    );
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
                child: Text(
                  '选择部门',
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
        ),
        Expanded(
          child: UtenDepartmentTreeView(
            nodes: widget.tree,
            mode: _isMulti
                ? UtenDepartmentTreeMode.multi
                : UtenDepartmentTreeMode.single,
            selectedIds: _selected.keys.toSet(),
            onToggleSelect: _onToggleSelect,
            trailingBuilder: widget.badgeCountFor == null ? null : _badge,
            expandOnRowTap: widget.expandOnRowTap,
            initiallyExpandedIds: widget.initiallyExpandedIds,
          ),
        ),
        if (_isMulti || widget.requireConfirm)
          UtenBottomActionBar(
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _isMulti ? '已选 ${_selected.length} 项' : '请选择后点击确定',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => setState(_selected.clear),
                  child: const Text('清空'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _selected.isEmpty
                      ? null
                      : () => Navigator.of(context).pop(
                          _isMulti
                              ? _selected.values.toList()
                              : [_selected.values.single],
                        ),
                  child: const Text('确定'),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
