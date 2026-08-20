// CategoryEditDialog - 货品/模具/客户/供应商 分类 新增/编辑 对话框。
//
// 仿 department_page._showCreateDialog 的 AlertDialog 范式，但抽成独立组件：
// - 字段：编号前缀、名称、备注、父级；分类身份始终是系统 UUID；
// - 父级通过树形选择子弹层挑选，预校验「不能选自己 / 不能选自己的后代」；
// - 新增态在「名称」下提供常用分类建议（[suggestions]），一键填入，降低起名门槛；
// - 提交按钮用 UtenActionButton（自带 loading + 防连点）。
//
// 提交通过 onSubmit 回调上抛，由页面执行真正的仓储调用并返回是否成功；
// 成功时对话框自行关闭。
import 'package:flutter/material.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../core/responsive/dialog_size.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../../../shared/widgets/uten_location_field.dart';
import '../models/product_category_node.dart';
import 'uten_category_tree_view.dart';

class CategoryEditResult {
  const CategoryEditResult({
    required this.name,
    required this.codePrefix,
    required this.remark,
    this.parentId,
    this.version,
  });

  final String name;
  final String codePrefix;
  final String remark;
  final int? version;

  /// 新建时是所选父级；编辑时仅在父级实际改变后非空。
  final String? parentId;
}

class CategoryEditDialog extends StatefulWidget {
  const CategoryEditDialog({
    super.key,
    required this.tree,
    required this.onSubmit,
    this.initialParent,
    this.editing,
    this.onPreviewPrefixChange,
  });

  /// 全树，用于父级挑选子弹层。
  final List<ProductCategoryNode> tree;

  /// 新建模式下的默认父级（可空=顶级）。
  final ProductCategoryNode? initialParent;

  /// 编辑模式：传入现有详情。非 null 时为编辑态（code 只读）。
  final ProductCategoryDetail? editing;

  /// 编辑时前缀发生变化才调用；返回影响数量并在提交前二次确认。
  final Future<CategoryPrefixPreview> Function(
    String requestedPrefix,
    String? requestedParentId,
  )?
  onPreviewPrefixChange;

  /// 提交回调：返回 true 表示成功（对话框关闭），false 表示失败（保持打开）。
  final Future<bool> Function(CategoryEditResult result) onSubmit;

  @override
  State<CategoryEditDialog> createState() => _CategoryEditDialogState();
}

class _CategoryEditDialogState extends State<CategoryEditDialog> {
  late final TextEditingController _prefixCtl;
  late final TextEditingController _nameCtl;
  late final TextEditingController _remarkCtl;
  ProductCategoryNode? _parent;
  String? _formError;

  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _prefixCtl = TextEditingController(text: e?.codePrefix ?? '');
    _nameCtl = TextEditingController(text: e?.name ?? '');
    _remarkCtl = TextEditingController(text: e?.remark ?? e?.code ?? '');
    // 编辑态：用详情里的 parentId 在树里反查父节点；新建态：用传入的默认父级。
    if (e != null) {
      if (e.parentId != null) {
        _parent = _findById(widget.tree, e.parentId!);
      }
    } else {
      _parent = widget.initialParent;
    }
  }

  @override
  void dispose() {
    _prefixCtl.dispose();
    _nameCtl.dispose();
    _remarkCtl.dispose();
    super.dispose();
  }

  /// 新节点将落在的层级（根=0，子=父+1）。
  int get _resultLevel => (_parent?.level ?? -1) + 1;

  ProductCategoryNode? _findById(List<ProductCategoryNode> nodes, String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
      final f = _findById(n.children, id);
      if (f != null) return f;
    }
    return null;
  }

  /// node 是否为 selfId 自身或其后代。
  bool _isSelfOrDescendant(ProductCategoryNode node, String selfId) {
    if (node.id == selfId) return true;
    for (final c in node.children) {
      if (_isSelfOrDescendant(c, selfId)) return true;
    }
    return false;
  }

  String? _validate() {
    final prefix = _prefixCtl.text.trim();
    if (prefix.isNotEmpty &&
        !RegExp(r'^[A-Za-z][A-Za-z0-9]{0,7}$').hasMatch(prefix)) {
      return '编号前缀须以字母开头，只能包含 1–8 位字母或数字';
    }
    if (_nameCtl.text.trim().isEmpty) {
      return '请输入分类名称'; // TODO(l10n): 补 arb
    }
    // 编辑态：新父级不能是自身或自身的后代（否则成环）。
    // 注意：要在「自身的子树」里找新父级 id —— 旧代码写成在父级子树里找自身，
    // 而自身本就是父级的子节点 → 恒为 true，导致只改名字也误报。仅改名字时父级未变，
    // 父级不在自身子树内 → 不报错。
    final selfId = widget.editing?.id;
    if (_isEdit && selfId != null && _parent != null) {
      final selfNode = _findById(widget.tree, selfId);
      if (selfNode != null && _isSelfOrDescendant(selfNode, _parent!.id)) {
        return '不能将分类移动到自身或其子分类下'; // TODO(l10n): 补 arb
      }
    }
    return null;
  }

  Future<bool> _confirmPrefixImpact(String requestedPrefix) async {
    final callback = widget.onPreviewPrefixChange;
    final editing = widget.editing;
    if (callback == null || editing == null) return true;
    final parentChanged = _parent?.id != editing.parentId;
    if (!parentChanged &&
        requestedPrefix == (editing.codePrefix ?? '').toUpperCase()) {
      return true;
    }

    late final CategoryPrefixPreview preview;
    try {
      preview = await callback(requestedPrefix, _parent?.id);
    } catch (e) {
      if (mounted) context.appApiError(e, fallback: '改号影响预览失败，请重试');
      return false;
    }
    if (!mounted) return false;
    if (preview.conflicts > 0) {
      final samples = preview.conflictSamples.isEmpty
          ? ''
          : '：${preview.conflictSamples.join('、')}';
      context.appError('发现 ${preview.conflicts} 个编号冲突$samples，请先调整前缀');
      return false;
    }
    if (preview.affectedRecords == 0) return true;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded),
            SizedBox(width: UtenSpacing.s8),
            Text('确认批量改号'),
          ],
        ),
        content: Text(
          '生效前缀将变为 ${preview.resultingEffectivePrefix}，'
          '会修改 ${preview.affectedRecords} 条当前主档编号。'
          '${preview.customOrLegacyRecords > 0 ? ' 其中 ${preview.customOrLegacyRecords} 条手工或历史编号也会纳入新的统一规则。' : ''}'
          '${preview.descendantOverrides > 0 ? ' ${preview.descendantOverrides} 个下级分类有自己的前缀，不受影响。' : ''}\n\n'
          '订单等关联仍使用系统 UUID；已审核单据继续显示当时的编号快照。',
        ),
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('返回检查'),
          ),
          UtenButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('确认改号'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _submit() async {
    final err = _validate();
    if (err != null) {
      setState(() => _formError = err);
      return;
    }
    setState(() => _formError = null);
    final prefix = _prefixCtl.text.trim().toUpperCase();
    if (!await _confirmPrefixImpact(prefix)) return;
    if (!mounted) return;
    final result = CategoryEditResult(
      name: _nameCtl.text.trim(),
      codePrefix: prefix,
      remark: _remarkCtl.text.trim(),
      version: widget.editing?.version,
      parentId: _isEdit && _parent?.id == widget.editing?.parentId
          ? null
          : _parent?.id,
    );
    // 兜底：onSubmit 内部通常已自带成功/失败通知；此处只兜未捕获异常，防止静默失败。
    late final bool ok;
    try {
      ok = await widget.onSubmit(result);
    } catch (e) {
      if (!mounted) return;
      context.appApiError(e);
      return;
    }
    if (!mounted) return;
    if (ok) Navigator.of(context).pop();
  }

  Future<void> _pickParent() async {
    final selfId = widget.editing?.id;
    // 自身节点（编辑态）：在自身子树内判定候选父级，禁用自身及其后代（否则成环）。
    final selfNode = selfId == null ? null : _findById(widget.tree, selfId);
    final result = await showUtenPickerSheet<ProductCategoryNode>(
      context: context,
      title: _isEdit ? '选择上级分类' : '选择添加位置', // TODO(l10n): 补 arb
      rootLabel: '顶级分类', // TODO(l10n): 补 arb
      showRootOption: !_isEdit, // 编辑不支持移到根（后端 parentId=null 视为不改），新建可加顶级
      initialSelection: (node: _parent, isRoot: _parent == null),
      childBuilder: (ctx, pendingSelection, onSelect, onSelectRoot) =>
          UtenCategoryTreeView(
            mode: UtenCategoryTreeMode.single,
            nodes: widget.tree,
            selectedIds: {pendingSelection?.node?.id ?? ''},
            nodeEnabledPredicate: (n) {
              // 编辑态：禁用自身及其后代（选后代当父级会成环）。新建态全部可选。
              if (selfNode == null) return true;
              return !_isSelfOrDescendant(selfNode, n.id);
            },
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
        _isEdit ? '编辑分类' : '新增分类', // TODO(l10n): 补 arb
      ),
      // 显式三档宽度（compact 近全屏 / medium 收窄 / expanded 560）：
      // 前缀 helper 文案较长，Material 默认窄弹窗换行严重。
      insetPadding: utenDialogInsetPadding(context),
      content: SizedBox(
        width: utenDialogWidth(context, 560),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              UtenLocationField(
                pathLabel: _parent?.name,
                rootLabel: '顶级分类', // TODO(l10n): 补 arb
                resultLevelLabel: 'L$_resultLevel',
                headingLabel: _isEdit ? '上级分类' : '添加位置',
                onTap: _pickParent,
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _prefixCtl,
                textCapitalization: TextCapitalization.characters,
                maxLength: 8,
                decoration: const InputDecoration(
                  labelText: '编号前缀',
                  hintText: '例如 V6',
                  helperText:
                      '留空继承最近上级。显式前缀是全系统专用 token，'
                      '忽略大小写且终身保留；保存以服务端事务校验为准。'
                      '若返回 409 冲突，当前输入会保留供修改。',
                  helperMaxLines: 3,
                  counterText: '',
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _nameCtl,
                decoration: const InputDecoration(
                  labelText: '名称', // TODO(l10n): 补 arb
                ),
              ),
              const SizedBox(height: UtenSpacing.s12),
              TextField(
                controller: _remarkCtl,
                minLines: 2,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: '备注',
                  helperText: '旧分类编码已迁移到这里，可按业务需要修改',
                ),
              ),
              if (_formError != null) ...[
                const SizedBox(height: UtenSpacing.s12),
                Text(
                  _formError!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ],
          ),
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
