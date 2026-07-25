// DepartmentEditDialog - 部门 新增/编辑 对话框。
//
// 范式照 basic_data 的 CategoryEditDialog，仅领域差异：
// - 树用 UtenDepartmentTreeView（保留 level 徽标）；
// - 父级仅可选 kSelectableDepartmentLevels（一级/二级/三级），骨架层灰显仅展开；
// - 新节点 level 由父级推导（_childDeptLevel）；
// - 编辑态不能移到根、不能挂到自身/子树下。
//
// 提交通过 onSubmit 回调上抛，由页面执行真正的仓储调用并返回是否成功；
// 成功时对话框自行关闭。替代了部门页内联的 _showCreateDialog/_showEditDialog。
import 'package:flutter/material.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/widgets/uten_location_field.dart';
import '../models/department_node.dart';
import 'uten_department_tree_view.dart';

/// 对话框收集到的字段（新建时 code 必填，编辑时 code 为 null 不上送）。
class DepartmentEditResult {
  const DepartmentEditResult({
    this.code,
    required this.name,
    this.parentId,
    required this.level,
  });

  final String? code;
  final String name;
  final String? parentId;

  /// 由父级推导出的新节点 level（新建上送；编辑态后端按新父级重算，忽略此值）。
  final String level;
}

class DepartmentEditDialog extends StatefulWidget {
  const DepartmentEditDialog({
    super.key,
    required this.tree,
    required this.onSubmit,
    this.initialParent,
    this.editing,
    this.suggestions = const <String>[],
  });

  /// 全树，用于父级挑选子弹层。
  final List<DepartmentNode> tree;

  /// 新建模式下的默认父级（可空=公司顶层）。
  final DepartmentNode? initialParent;

  /// 编辑模式：传入现有详情。非 null 时为编辑态（code 只读）。
  final DepartmentInfo? editing;

  /// 新建模式下展示的常用部门名称建议，点击即填入「名称」。编辑态忽略。
  final List<String> suggestions;

  /// 提交回调：返回 true 表示成功（对话框关闭），false 表示失败（保持打开）。
  final Future<bool> Function(DepartmentEditResult result) onSubmit;

  @override
  State<DepartmentEditDialog> createState() => _DepartmentEditDialogState();
}

class _DepartmentEditDialogState extends State<DepartmentEditDialog> {
  late final TextEditingController _codeCtl;
  late final TextEditingController _nameCtl;
  DepartmentNode? _parent;
  String? _formError;

  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _codeCtl = TextEditingController(text: e?.code ?? '');
    _nameCtl = TextEditingController(text: e?.name ?? '');
    // 编辑态：用详情里的 parentId 在树里反查父节点；新建态：用传入的默认父级。
    if (e != null) {
      if (e.parentId != null) _parent = _findById(widget.tree, e.parentId!);
    } else {
      _parent = widget.initialParent;
    }
  }

  @override
  void dispose() {
    _codeCtl.dispose();
    _nameCtl.dispose();
    super.dispose();
  }

  /// 新节点将落在的层级（由父级推导）。
  String get _resultLevel => _childDeptLevel(_parent?.level);

  DepartmentNode? _findById(List<DepartmentNode> nodes, String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
      final f = _findById(n.children, id);
      if (f != null) return f;
    }
    return null;
  }

  /// node 是否为 selfId 自身或其后代。
  bool _isSelfOrDescendant(DepartmentNode node, String selfId) {
    if (node.id == selfId) return true;
    for (final c in node.children) {
      if (_isSelfOrDescendant(c, selfId)) return true;
    }
    return false;
  }

  String? _validate() {
    if (!_isEdit && _codeCtl.text.trim().isEmpty) {
      return '请输入部门编码'; // TODO(l10n): 补 arb
    }
    if (_nameCtl.text.trim().isEmpty) {
      return '请输入部门名称'; // TODO(l10n): 补 arb
    }
    final selfId = widget.editing?.id;
    if (_isEdit && selfId != null && _parent != null) {
      if (_isSelfOrDescendant(_parent!, selfId)) {
        return '不能将部门移动到自身或其子部门下'; // TODO(l10n): 补 arb
      }
    }
    return null;
  }

  Future<void> _submit() async {
    final err = _validate();
    if (err != null) {
      setState(() => _formError = err);
      return;
    }
    setState(() => _formError = null);
    final result = DepartmentEditResult(
      code: _isEdit ? null : _codeCtl.text.trim(),
      name: _nameCtl.text.trim(),
      parentId: _parent?.id,
      level: _resultLevel,
    );
    final ok = await widget.onSubmit(result);
    if (!mounted) return;
    if (ok) Navigator.of(context).pop();
  }

  void _applySuggestion(String s) {
    setState(() {
      _nameCtl.text = s;
      _nameCtl.selection = TextSelection.collapsed(offset: s.length);
    });
  }

  Future<void> _pickParent() async {
    final selfId = widget.editing?.id;
    final result = await showUtenPickerSheet<DepartmentNode>(
      context: context,
      title: _isEdit ? '选择上级部门' : '选择添加位置', // TODO(l10n): 补 arb
      rootLabel: '公司', // TODO(l10n): 补 arb
      showRootOption: !_isEdit, // 编辑不支持移到根（后端 parentId=null 视为不改），新建可加顶层
      childBuilder: (ctx, onSelect, onSelectRoot) => UtenDepartmentTreeView(
        nodes: widget.tree,
        mode: UtenDepartmentTreeMode.single,
        selectedIds: {_parent?.id ?? ''},
        // 仅可选层级（一级/二级/三级）能被选为父级；编辑态排除自身及后代。
        nodeEnabledPredicate: (n) =>
            kSelectableDepartmentLevels.contains(n.level) &&
            (selfId == null || !_isSelfOrDescendant(n, selfId)),
        onToggleSelect: onSelect,
        initiallyExpandDepth: 2,
      ),
    );
    if (!mounted || result == null) return;
    setState(() => _parent = result.isRoot ? null : result.node);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(
        _isEdit ? '编辑部门' : '新增部门', // TODO(l10n): 补 arb
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            UtenLocationField(
              pathLabel: _parent?.name,
              rootLabel: '公司', // TODO(l10n): 补 arb
              resultLevelLabel: _resultLevel,
              onTap: _pickParent,
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _codeCtl,
              readOnly: _isEdit,
              decoration: InputDecoration(
                labelText: '编码', // TODO(l10n): 补 arb
                hintText: _isEdit ? null : '如 HR-01（创建后不可修改）', // TODO(l10n): 补 arb
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _nameCtl,
              decoration: const InputDecoration(
                labelText: '名称', // TODO(l10n): 补 arb
              ),
            ),
            if (!_isEdit && widget.suggestions.isNotEmpty) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                '常用部门名称，点击填入', // TODO(l10n): 补 arb
                style: theme.textTheme.labelSmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s4,
                children: [
                  for (final s in widget.suggestions)
                    ActionChip(
                      label: Text(s),
                      onPressed: () => _applySuggestion(s),
                    ),
                ],
              ),
            ],
            if (_formError != null) ...[
              const SizedBox(height: UtenSpacing.s12),
              Text(
                _formError!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'), // TODO(l10n): 补 arb
        ),
        UtenActionButton(
          label: Text(_isEdit ? '保存' : '创建'), // TODO(l10n): 补 arb
          onAction: _submit,
        ),
      ],
    );
  }
}

/// 由父部门层级推导新部门的层级（公司/根→一级；一级→二级；二级→三级；三级封顶）。
///
/// 后端信任前端 level（不推导），故此处保证 level 与父级一致，杜绝旧版「下拉框
/// 随便选 level、却挂在任意父级下」的不一致。从 department_page 搬来，供本组件复用。
String _childDeptLevel(String? parentLevel) {
  switch (parentLevel) {
    case null:
    case '公司':
    case '决策层':
    case '管理中心':
      return '一级部门';
    case '一级部门':
      return '二级班组';
    case '二级班组':
      return '三级科室';
    case '三级科室':
      return '三级科室'; // 已最深，不再细分
    default:
      return '二级班组';
  }
}
