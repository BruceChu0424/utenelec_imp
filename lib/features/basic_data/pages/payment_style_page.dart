// 收付款类别管理页（基础资料 · 邻接+物化路径树）。
//
// 仿 product_category_page 的「左树 + 右详情」范式，但 UtenCategoryTreeView 强绑
// ProductCategoryNode 不能复用，本页自带极简递归树渲染（ExpansionTile 风格）。
// 6 大类（ACCOUNT/LIABILITY/EQUITY/EXPENSE/INCOME/METHOD）通过顶部分组切换：
// 选大类 → tree(category=) 过滤；右详情卡 + CRUD（内联 _PaymentStyleEditDialog）。
// 查看全员可见，编辑按 payment_style:edit 显隐。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/widgets/master_detail_card.dart';
import '../models/payment_style_node.dart';
import '../repositories/payment_style_repository.dart';
import '../widgets/uten_category_tree_view.dart';

class PaymentStylePage extends ConsumerStatefulWidget {
  const PaymentStylePage({super.key});

  @override
  ConsumerState<PaymentStylePage> createState() => _PaymentStylePageState();
}

class _PaymentStylePageState extends ConsumerState<PaymentStylePage> {
  PaymentStyleCategory _category = PaymentStyleCategory.expense;
  List<PaymentStyleNode> _tree = const [];
  String? _selectedId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains('payment_style:edit');

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tree = await ref
          .read(paymentStyleRepositoryProvider)
          .tree(category: _category.value);
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _selectedId = _selectedId == null && tree.isNotEmpty
            ? tree.first.id
            : _selectedId;
        // 选中的 id 在新大类下可能不存在，兜底选第一个。
        if (_selectedId != null && _findById(_tree, _selectedId!) == null) {
          _selectedId = tree.isNotEmpty ? tree.first.id : null;
        }
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载类别树失败，请稍后重试';
        _loading = false;
      });
    }
  }

  PaymentStyleNode? _findById(List<PaymentStyleNode> nodes, String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
      final f = _findById(n.children, id);
      if (f != null) return f;
    }
    return null;
  }

  void _switchCategory(PaymentStyleCategory c) {
    if (c == _category) return;
    setState(() {
      _category = c;
      _selectedId = null;
    });
    _load();
  }

  // ---- CRUD ---------------------------------------------------------------

  void _showCreate({PaymentStyleNode? parent}) {
    showDialog<void>(
      context: context,
      builder: (_) => _PaymentStyleEditDialog(
        tree: _tree,
        category: _category,
        initialParent: parent,
        onSubmit: (r) => _doCreate(r),
      ),
    );
  }

  Future<bool> _doCreate(_EditResult r) async {
    try {
      await ref.read(paymentStyleRepositoryProvider).create(PaymentStyleSaveInput(
            code: '', // 服务端自动生成（SK 前缀），前端不收集
            name: r.name,
            category: _category.value,
            parentId: r.parentId,
            receipt: r.receipt,
            payment: r.payment,
            departmental: r.departmental,
            status: r.status,
          ));
      if (!mounted) return false;
      context.appSuccess('类别已创建');
      await _load();
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      context.appError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      context.appError('创建失败，请稍后重试');
      return false;
    }
  }

  void _showEdit(PaymentStyleDetail detail) {
    showDialog<void>(
      context: context,
      builder: (_) => _PaymentStyleEditDialog(
        tree: _tree,
        category: _category,
        editing: detail,
        onSubmit: (r) => _doUpdate(detail.id, r),
      ),
    );
  }

  Future<bool> _doUpdate(String id, _EditResult r) async {
    try {
      await ref.read(paymentStyleRepositoryProvider).update(
            id,
            PaymentStyleUpdateInput(
              name: r.name,
              parentId: r.parentId,
              receipt: r.receipt,
              payment: r.payment,
              departmental: r.departmental,
              status: r.status,
            ),
          );
      if (!mounted) return false;
      context.appSuccess('类别已更新');
      await _load();
      return true;
    } on ApiException catch (e) {
      if (!mounted) return false;
      context.appError(e.message);
      return false;
    } catch (_) {
      if (!mounted) return false;
      context.appError('更新失败，请稍后重试');
      return false;
    }
  }

  Future<void> _delete(PaymentStyleNode node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除类别'),
        content: Text(
          '确定删除「${node.name}」吗？若存在子类别或被引用，删除可能失败。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: UtenColors.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(paymentStyleRepositoryProvider).delete(node.id);
      if (!mounted) return;
      context.appSuccess('类别已删除');
      if (_selectedId == node.id) _selectedId = null;
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      context.appError(e.message);
    } catch (_) {
      if (!mounted) return;
      context.appError('删除失败，请稍后重试');
    }
  }

  // ---- 树渲染 -------------------------------------------------------------

  Widget _buildTree({required void Function(String id) onSelect}) {
    final theme = Theme.of(context);
    // 复用 UtenCategoryTreeView<PaymentStyleNode>：与货品/模具/客户/供应商左树
    // 完全一致（搜索 / 点行展开 / 选中高亮 / code 排序 / 子节点数徽标），
    // 不再自带递归树渲染。顶部 6 大类切换条由本页 build 维护（页面级过滤）。
    return UtenCategoryTreeView<PaymentStyleNode>(
      nodes: _tree,
      selectedIds: {?_selectedId},
      expandOnRowTap: true,
      onNodeTap: (node) => onSelect(node.id),
      trailingBuilder: (node) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (node.hasChildren)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Text(
                '${node.children.length}',
                style: TextStyle(
                    fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          if (_canEdit)
            InkWell(
              onTap: () => _delete(node),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.delete_outline,
                    size: 16, color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
        ],
      ),
    );
  }

  // _treeTile 已移除：树渲染改由 UtenCategoryTreeView<PaymentStyleNode> 统一负责。

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bp = context.breakpoint;
    final selected =
        _selectedId == null ? null : _findById(_tree, _selectedId!);

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _load,
      );
    } else {
      body = Column(
        children: [
          // 大类切换条
          Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(
                UtenSpacing.s8, UtenSpacing.s8, UtenSpacing.s8, UtenSpacing.s4),
            child: Wrap(
              spacing: 6,
              children: [
                for (final c in PaymentStyleCategory.values)
                  ChoiceChip(
                    label: Text(c.label),
                    selected: c == _category,
                    onSelected: (_) => _switchCategory(c),
                  ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: bp == UtenBreakpoint.compact
                ? (selected == null
                    ? const UtenEmpty(
                        icon: Icons.account_tree_outlined,
                        message: '请选择类别查看详情',
                      )
                    : UtenContentContainer(
                        child: _DetailPane(
                          nodeId: selected.id,
                          canEdit: _canEdit,
                          onAddChild: () => _showCreate(parent: selected),
                          onEdit: _showEdit,
                          onDelete: () => _delete(selected),
                        ),
                      ))
                : Row(
                    children: [
                      SizedBox(
                        width: 300,
                        child: _tree.isEmpty
                            ? const UtenEmpty(
                                icon: Icons.account_tree_outlined,
                                message: '暂无类别',
                              )
                            : _buildTree(
                                onSelect: (id) =>
                                    setState(() => _selectedId = id),
                              ),
                      ),
                      Container(
                          width: 1,
                          color: theme.colorScheme.outlineVariant),
                      Expanded(
                        child: selected == null
                            ? Center(
                                child: Text(
                                  '请选择左侧类别查看详情',
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                      color: theme
                                          .colorScheme.onSurfaceVariant),
                                ),
                              )
                            : _DetailPane(
                                nodeId: selected.id,
                                canEdit: _canEdit,
                                onAddChild: () =>
                                    _showCreate(parent: selected),
                                onEdit: _showEdit,
                                onDelete: () => _delete(selected),
                              ),
                      ),
                    ],
                  ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '收付款类别',
        leading: UtenBackButton(
          onPressed: () => backTo(context, defaultPath: RouteName.basicinfo),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: SafeArea(child: body),
    );
  }
}

/// 类别详情面板：拉 detail 渲染 MasterDetailCard。
class _DetailPane extends ConsumerStatefulWidget {
  const _DetailPane({
    required this.nodeId,
    required this.canEdit,
    required this.onAddChild,
    required this.onEdit,
    required this.onDelete,
  });

  final String nodeId;
  final bool canEdit;
  final VoidCallback onAddChild;
  final void Function(PaymentStyleDetail detail) onEdit;
  final VoidCallback onDelete;

  @override
  ConsumerState<_DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends ConsumerState<_DetailPane> {
  PaymentStyleDetail? _detail;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_DetailPane old) {
    super.didUpdateWidget(old);
    if (old.nodeId != widget.nodeId) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await ref.read(paymentStyleRepositoryProvider).detail(widget.nodeId);
      if (!mounted) return;
      setState(() {
        _detail = d;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = '加载类别详情失败';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    final d = _detail;
    if (d == null) {
      return Center(
        child: Text(
          '未选择类别',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      );
    }
    final hPad = context.breakpoint.isCompact ? 0.0 : UtenSpacing.s16;
    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(hPad, UtenSpacing.s16, hPad, UtenSpacing.s16),
      child: MasterDetailCard(
        title: d.name,
        icon: Icons.account_tree_outlined,
        subtitle: '编码 ${d.code} · ${PaymentStyleCategory.labelOf(d.category)} · 层级 L${d.level}',
        stats: [
          MasterDetailStat('子类别数', '${d.childCount}'),
          MasterDetailStat('父级', d.parentName),
          MasterDetailStat('收款/付款',
              '${d.receipt ? '是' : '否'} / ${d.payment ? '是' : '否'}'),
          MasterDetailStat('状态', d.status),
          MasterDetailStat('旧编码', d.legacyId?.toString()),
        ],
        path: d.path.isEmpty ? null : d.path,
        canEdit: widget.canEdit,
        onAddChild: widget.onAddChild,
        onEdit: () {
          if (_detail != null) widget.onEdit(_detail!);
        },
        onDelete: widget.onDelete,
      ),
    );
  }
}

/// 编辑对话框收集到的字段（code 不收集：新建服务端自动生成、编辑保留既有）。
class _EditResult {
  const _EditResult({
    required this.name,
    this.parentId,
    this.receipt = false,
    this.payment = false,
    this.departmental = false,
    this.status,
  });

  final String name;
  final String? parentId;
  final bool receipt;
  final bool payment;
  final bool departmental;
  final String? status;
}

/// 收付款类别 新增/编辑 对话框（极简版：编码/名称/父级/收付款方向/状态）。
class _PaymentStyleEditDialog extends StatefulWidget {
  const _PaymentStyleEditDialog({
    required this.tree,
    required this.category,
    required this.onSubmit,
    this.initialParent,
    this.editing,
  });

  final List<PaymentStyleNode> tree;
  final PaymentStyleCategory category;
  final PaymentStyleNode? initialParent;
  final PaymentStyleDetail? editing;
  final Future<bool> Function(_EditResult result) onSubmit;

  @override
  State<_PaymentStyleEditDialog> createState() =>
      _PaymentStyleEditDialogState();
}

class _PaymentStyleEditDialogState extends State<_PaymentStyleEditDialog> {
  late final TextEditingController _codeCtl;
  late final TextEditingController _nameCtl;
  PaymentStyleNode? _parent;
  bool _receipt = false;
  bool _payment = false;
  bool _departmental = false;
  String? _status;
  String? _formError;

  bool get _isEdit => widget.editing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.editing;
    _codeCtl = TextEditingController(text: e?.code ?? '');
    _nameCtl = TextEditingController(text: e?.name ?? '');
    _receipt = e?.receipt ?? false;
    _payment = e?.payment ?? false;
    _departmental = e?.departmental ?? false;
    _status = e?.status;
    if (e != null && e.parentId != null) {
      _parent = _findById(widget.tree, e.parentId!);
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

  PaymentStyleNode? _findById(List<PaymentStyleNode> nodes, String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
      final f = _findById(n.children, id);
      if (f != null) return f;
    }
    return null;
  }

  Future<void> _submit() async {
    if (_nameCtl.text.trim().isEmpty) {
      setState(() => _formError = '请输入类别名称');
      return;
    }
    setState(() => _formError = null);
    final ok = await widget.onSubmit(_EditResult(
      name: _nameCtl.text.trim(),
      parentId: _parent?.id,
      receipt: _receipt,
      payment: _payment,
      departmental: _departmental,
      status: _status,
    ));
    if (!mounted) return;
    if (ok) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? '编辑类别' : '新增类别（${widget.category.label}）'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _codeCtl,
              enabled: false,
              decoration: InputDecoration(
                labelText: '编码',
                hintText: _isEdit ? null : '保存后自动生成',
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            TextField(
              controller: _nameCtl,
              decoration: const InputDecoration(labelText: '名称 *'),
            ),
            const SizedBox(height: UtenSpacing.s12),
            DropdownButtonFormField<String?>(
              initialValue: _parent?.id,
              decoration: const InputDecoration(labelText: '父级'),
              items: [
                const DropdownMenuItem<String?>(child: Text('— 顶级 —')),
                ..._flatOptions(widget.tree),
              ],
              onChanged: (v) {
                setState(() {
                  _parent = v == null ? null : _findById(widget.tree, v);
                });
              },
            ),
            const SizedBox(height: UtenSpacing.s12),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('收款类别'),
              value: _receipt,
              onChanged: (v) => setState(() => _receipt = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('付款类别'),
              value: _payment,
              onChanged: (v) => setState(() => _payment = v),
            ),
            SwitchListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('部门核算'),
              value: _departmental,
              onChanged: (v) => setState(() => _departmental = v),
            ),
            DropdownButtonFormField<String?>(
              initialValue: _status,
              decoration: const InputDecoration(labelText: '状态'),
              items: const [
                DropdownMenuItem<String?>(child: Text('— 不选 —')),
                DropdownMenuItem<String?>(value: '使用', child: Text('使用')),
                DropdownMenuItem<String?>(value: '禁用', child: Text('禁用')),
              ],
              onChanged: (v) => setState(() => _status = v),
            ),
            if (_formError != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(_formError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          onPressed: _submit,
          child: Text(_isEdit ? '保存' : '创建'),
        ),
      ],
    );
  }

  /// 树扁平化为下拉项（带缩进表示层级）。
  List<DropdownMenuItem<String?>> _flatOptions(List<PaymentStyleNode> nodes,
      {int depth = 0}) {
    final out = <DropdownMenuItem<String?>>[];
    for (final n in nodes) {
      out.add(DropdownMenuItem<String?>(
        value: n.id,
        child: Text('${'  ' * depth}${n.name}'),
      ));
      if (n.hasChildren) {
        out.addAll(_flatOptions(n.children, depth: depth + 1));
      }
    }
    return out;
  }
}
