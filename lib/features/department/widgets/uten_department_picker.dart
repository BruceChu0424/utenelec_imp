// UtenDepartmentPicker - 统一抽屉式部门选择器（领域组件）
//
// 触发形态：只读输入框样式的 field（显示选中完整路径，placeholder「请选择部门」），
// 点击拉开抽屉：
// - compact：约 85% 屏高的底部抽屉；
// - medium/expanded：右侧滑入的 420dp end drawer。
// 响应式展示壳统一复用 showUtenAdaptivePanel。
//
// 默认人事规则：公司根节点不显示；决策层仅作展开骨架；管理中心和各级业务部门可选。
// 专业业务场景可传 selectablePredicate 收窄范围。单选/多选统一二次操作：点行高亮，
// 底部「取消/确定」确认（requireConfirm=false 可恢复单选点行即关的历史行为）。
// 路径显示：从第一个可选组织节点起用「-」连接。
// 树渲染由全站共享的 UtenDepartmentTreeView 提供。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_toast.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../models/department_node.dart';
import '../repositories/department_repository.dart';
import 'uten_department_tree_view.dart';

/// 选择模式。
enum UtenDepartmentPickerMode { single, multi }

/// 控制当前业务场景中哪些组织节点可以被选中。
typedef DepartmentSelectionPredicate = bool Function(DepartmentNode node);

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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeptSelection &&
          id == other.id &&
          name == other.name &&
          fullPath == other.fullPath &&
          level == other.level;

  @override
  int get hashCode => Object.hash(id, name, fullPath, level);
}

/// 选择器自用的部门树 Provider（与部门管理页共用 Dio 仓库）。
final departmentPickerTreeProvider =
    FutureProvider.autoDispose<List<DepartmentNode>>(
      (ref) => ref.watch(departmentRepositoryProvider).tree(),
    );

/// 由整棵树构建「可选节点 id → DeptSelection」映射。
/// 路径从第一个符合当前选择策略的节点起收集，用「-」连接。
Map<String, DeptSelection> buildDeptSelectionMap(
  List<DepartmentNode> tree, {
  DepartmentSelectionPredicate? selectablePredicate,
}) {
  final canSelect = selectablePredicate ?? isOperationalDepartmentNode;
  final out = <String, DeptSelection>{};
  void walk(List<DepartmentNode> nodes, List<String> chain) {
    for (final n in nodes) {
      final selectable = canSelect(n);
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

/// 直接拉出部门选择面板（宽屏右侧滑入 / 窄屏底部抽屉），不经过表单字段壳。
/// 供表格单元格等非表单场景点开即选；返回 null = 用户取消。
/// [requireConfirm] 为 false 时单选点行即选定返回（与旧居中弹窗行为一致）。
Future<List<DeptSelection>?> showUtenDepartmentPickerPanel(
  BuildContext context, {
  required List<DepartmentNode> tree,
  UtenDepartmentPickerMode mode = UtenDepartmentPickerMode.single,
  List<DeptSelection> initialSelection = const [],
  bool requireConfirm = false,
  bool expandOnRowTap = false,
  Set<String> initiallyExpandedIds = const {},
  DepartmentSelectionPredicate selectablePredicate =
      isOperationalDepartmentNode,
}) {
  return showUtenAdaptivePanel<List<DeptSelection>>(
    context: context,
    builder: (_) => _DepartmentPickerSheet(
      mode: mode,
      tree: tree,
      initialSelection: initialSelection,
      requireConfirm: requireConfirm,
      expandOnRowTap: expandOnRowTap,
      initiallyExpandedIds: initiallyExpandedIds,
      selectablePredicate: selectablePredicate,
    ),
  );
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
    this.requireConfirm = true,
    this.expandOnRowTap = false,
    this.initiallyExpandedIds = const {},
    this.selectablePredicate,
    this.allowClear = false,
    this.clearLabel = '清除部门',
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

  /// 单选模式下是否需要底部「取消/确定」二次确认（而非点行即选中并关闭）。
  /// 多选模式恒需确认，此项无效。默认 true（全站滑窗统一二次操作契约）。
  final bool requireConfirm;

  /// 点击行文字是否同时展开/收起子部门（默认仅点左侧箭头展开，避免误触选中态收起）。
  final bool expandOnRowTap;

  /// 额外强制默认展开的节点 id（如"只展开生产部，同级其它部门保持折叠"）。
  final Set<String> initiallyExpandedIds;

  /// 节点可选策略。默认允许管理中心和各级业务部门；车间等专业场景应显式收窄。
  final DepartmentSelectionPredicate? selectablePredicate;

  /// 是否允许把当前选择清空。默认关闭，保持既有必选业务交互不变。
  final bool allowClear;

  /// 清除按钮的辅助说明；页面可按筛选语义改成“显示全部可管理范围”。
  final String clearLabel;

  @override
  ConsumerState<UtenDepartmentPicker> createState() =>
      _UtenDepartmentPickerState();
}

class _UtenDepartmentPickerState extends ConsumerState<UtenDepartmentPicker> {
  final _fieldKey = GlobalKey<FormFieldState<List<DeptSelection>>>();
  List<DeptSelection> _selection = const [];
  List<DepartmentNode>? _latestTree;

  bool get _isMulti => widget.mode == UtenDepartmentPickerMode.multi;
  DepartmentSelectionPredicate get _canSelect =>
      widget.selectablePredicate ?? isOperationalDepartmentNode;

  @override
  void initState() {
    super.initState();
    _selection = List.of(widget.initialSelection);
    // treeOverride 场景：树已就绪，同步解析初始选中的完整路径
    //（initState 内不能 setState，直接赋值即可）。
    final override = widget.treeOverride;
    _latestTree = override;
    if (override != null) {
      final resolved = _resolvedSelection(override);
      if (resolved != null) _selection = resolved;
    }
  }

  @override
  void didUpdateWidget(UtenDepartmentPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_sameSelection(widget.initialSelection, oldWidget.initialSelection)) {
      _selection = _mergeIncomingSelection(widget.initialSelection);
      _fieldKey.currentState?.didChange(_selection);
    }
    final override = widget.treeOverride;
    if (override != null) _latestTree = override;
    if ((override != null && override != oldWidget.treeOverride) ||
        widget.selectablePredicate != oldWidget.selectablePredicate) {
      // didUpdateWidget runs while the parent Form is rebuilding. Resolving
      // here calls FormField.didChange, which would mark that Form dirty in
      // the middle of its own build (for example when an async treeOverride
      // changes from loading to data). Defer the synchronization one frame.
      final tree = override ?? _latestTree ?? const <DepartmentNode>[];
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _resolveSelection(tree);
      });
    }
  }

  bool _sameSelection(List<DeptSelection> a, List<DeptSelection> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// 外部只传 id 的占位值时，保留组件已解析出的名称和路径，避免父级 rebuild 后显示变空。
  List<DeptSelection> _mergeIncomingSelection(List<DeptSelection> incoming) {
    return [
      for (final next in incoming)
        () {
          DeptSelection? current;
          for (final item in _selection) {
            if (item.id == next.id) {
              current = item;
              break;
            }
          }
          return DeptSelection(
            id: next.id,
            name: next.name.isNotEmpty ? next.name : current?.name ?? '',
            fullPath: next.fullPath.isNotEmpty
                ? next.fullPath
                : current?.fullPath ?? '',
            level: next.level.isNotEmpty ? next.level : current?.level ?? '',
          );
        }(),
    ];
  }

  /// 用树把选中项中缺路径的项解析成完整 DeptSelection；无变化返回 null。
  List<DeptSelection>? _resolvedSelection(List<DepartmentNode> tree) {
    if (_selection.isEmpty) return null;
    final map = buildDeptSelectionMap(tree, selectablePredicate: _canSelect);
    var changed = false;
    final resolved = <DeptSelection>[];
    for (final s in _selection) {
      final fromTree = map[s.id];
      if (fromTree != null && fromTree != s) {
        resolved.add(fromTree);
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
    if (!widget.enabled) return;
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
    _latestTree = tree;
    final resolved = _resolvedSelection(tree);
    if (resolved != null) {
      setState(() => _selection = resolved);
      _fieldKey.currentState?.didChange(_selection);
    }
    final sheet = _DepartmentPickerSheet(
      mode: widget.mode,
      tree: tree,
      initialSelection: _selection,
      badgeCountFor: widget.badgeCountFor,
      requireConfirm: widget.requireConfirm,
      expandOnRowTap: widget.expandOnRowTap,
      initiallyExpandedIds: widget.initiallyExpandedIds,
      selectablePredicate: _canSelect,
    );
    final result = await showUtenAdaptivePanel<List<DeptSelection>>(
      context: context,
      builder: (_) => sheet,
    );
    final r = result;
    if (r != null && mounted) {
      setState(() => _selection = r);
      _fieldKey.currentState?.didChange(_selection);
      widget.onChanged(r);
    }
  }

  void _clearSelection() {
    if (_selection.isEmpty) return;
    setState(() => _selection = const []);
    _fieldKey.currentState?.didChange(_selection);
    widget.onChanged(_selection);
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
      final tree = ref.watch(departmentPickerTreeProvider).valueOrNull;
      if (tree != null) {
        _latestTree = tree;
        if (_resolvedSelection(tree) != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _resolveSelection(tree);
          });
        }
      }
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
      builder: (field) => Semantics(
        button: true,
        enabled: widget.enabled,
        label: widget.label ?? widget.hint,
        value: display ?? widget.hint,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: widget.enabled ? _open : null,
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                isEmpty: display == null,
                decoration: utenPickerFieldDecoration(
                  context,
                  labelText: widget.label,
                  hintText: widget.hint,
                  enabled: widget.enabled,
                  errorMessage: field.errorText,
                  suffixIcon: display != null && widget.allowClear
                      ? IconButton(
                          key: const ValueKey('uten-department-picker-clear'),
                          tooltip: widget.clearLabel,
                          onPressed: widget.enabled ? _clearSelection : null,
                          icon: const Icon(Icons.clear_rounded),
                        )
                      : Icon(
                          Icons.unfold_more_rounded,
                          color: theme.colorScheme.onSurfaceVariant,
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
      ),
    );
  }
}

/// 部门与岗位选择字段共享的外观，保持相同触控高度和错误文本布局。
InputDecoration utenPickerFieldDecoration(
  BuildContext context, {
  String? labelText,
  required String hintText,
  required bool enabled,
  String? errorMessage,
  Widget? suffixIcon,
}) {
  final theme = Theme.of(context);
  final radius = BorderRadius.circular(10);
  return UtenInputDecoration(
    InputDecoration(
      labelText: labelText,
      hintText: hintText,
      enabled: enabled,
      error: utenFieldError(errorMessage),
      isDense: true,
      suffixIcon: suffixIcon,
      suffixIconConstraints: suffixIcon == null
          ? null
          : const BoxConstraints(minWidth: 48, minHeight: 48),
      border: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: theme.colorScheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: theme.colorScheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: radius,
        borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
  );
}

/// 抽屉内容：标题 + 共享组织树（UtenDepartmentTreeView）+ （多选）底部操作条。
class _DepartmentPickerSheet extends StatefulWidget {
  const _DepartmentPickerSheet({
    required this.mode,
    required this.tree,
    required this.initialSelection,
    this.badgeCountFor,
    this.requireConfirm = true,
    this.expandOnRowTap = false,
    this.initiallyExpandedIds = const {},
    required this.selectablePredicate,
  });

  final UtenDepartmentPickerMode mode;
  final List<DepartmentNode> tree;
  final List<DeptSelection> initialSelection;
  final int? Function(String departmentId)? badgeCountFor;
  final bool requireConfirm;
  final bool expandOnRowTap;
  final Set<String> initiallyExpandedIds;
  final DepartmentSelectionPredicate selectablePredicate;

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
    _selectionMap = buildDeptSelectionMap(
      widget.tree,
      selectablePredicate: widget.selectablePredicate,
    );
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
        style: theme.textTheme.labelSmall?.copyWith(
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
            nodeEnabledPredicate: widget.selectablePredicate,
          ),
        ),
        if (_isMulti || widget.requireConfirm)
          UtenPickerConfirmBar(
            selectedCount: _selected.length,
            selectedLabel: _isMulti || _selected.isEmpty
                ? null
                : _selected.values.first.name,
            onClear: _isMulti ? () => setState(_selected.clear) : null,
            confirmLabel: _isMulti ? '确定(${_selected.length})' : '确定',
            onConfirm: () => Navigator.of(context).pop(
              _isMulti ? _selected.values.toList() : [_selected.values.first],
            ),
          ),
      ],
    );
  }
}
