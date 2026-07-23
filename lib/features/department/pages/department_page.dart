// 部门管理页（真实后端 + 响应式 + 组件库）
// compact：部门树作为抽屉，点部门看详情/员工
// medium/expanded：左侧部门树（DepartmentTree）+ 右侧详情与员工卡片（UtenPersonCard）
// 文档：docs/03-页面/部门管理页.md
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/cards/uten_person_card.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../shared/models/paged_result.dart';
import '../../employee/models/employee_api_models.dart';
import '../../employee/repositories/employee_repository.dart';
import '../../employee/widgets/employee_status_badge.dart';
import '../models/department_node.dart';
import '../repositories/department_repository.dart';
import '../widgets/department_tree.dart';

class DepartmentPage extends ConsumerStatefulWidget {
  const DepartmentPage({super.key});

  @override
  ConsumerState<DepartmentPage> createState() => _DepartmentPageState();
}

class _DepartmentPageState extends ConsumerState<DepartmentPage> {
  static const _levels = ['公司', '决策层', '管理中心', '一级部门', '二级班组', '三级科室'];

  List<DepartmentNode>? _tree;
  String? _selectedId;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  Future<void> _load() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final tree = await ref.read(departmentRepositoryProvider).tree();
      if (!mounted) return;
      setState(() {
        _tree = tree;
        _selectedId = _selectedId ?? _firstLeaf(tree)?.id;
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
        _error = '加载失败';
        _loading = false;
      });
    }
  }

  DepartmentNode? _firstLeaf(List<DepartmentNode> nodes) {
    for (final n in nodes) {
      if (n.children.isEmpty) return n;
      final leaf = _firstLeaf(n.children);
      if (leaf != null) return leaf;
    }
    return null;
  }

  DepartmentNode? _findById(List<DepartmentNode> nodes, String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
      final f = _findById(n.children, id);
      if (f != null) return f;
    }
    return null;
  }

  Future<void> _showCreateDialog({String? parentId}) async {
    final nameCtl = TextEditingController();
    final codeCtl = TextEditingController();
    String level = '二级班组';
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: const Text('新增部门'),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: codeCtl, decoration: const InputDecoration(labelText: '部门编码', hintText: '如 DEPT-XX')),
              const SizedBox(height: 12),
              TextField(controller: nameCtl, decoration: const InputDecoration(labelText: '部门名称')),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                value: level,
                decoration: const InputDecoration(labelText: '层级'),
                items: _levels.map((l) => DropdownMenuItem(value: l, child: Text(l))).toList(),
                onChanged: (v) => setSt(() => level = v ?? level),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
          ],
        ),
      ),
    );
    if (result != true) return;
    if (codeCtl.text.trim().isEmpty || nameCtl.text.trim().isEmpty) {
      _toast('编码与名称必填');
      return;
    }
    try {
      await ref.read(departmentRepositoryProvider).create(DepartmentSaveInput(
            code: codeCtl.text.trim(),
            name: nameCtl.text.trim(),
            level: level,
            parentId: parentId,
          ));
      _toast('已创建');
      await _load();
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _delete(DepartmentNode node) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除部门'),
        content: Text('确认删除「${node.name}」？仅无子部门且无员工的叶子部门可删。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(departmentRepositoryProvider).delete(node.id);
      _toast('已删除');
      if (_selectedId == node.id) _selectedId = null;
      await _load();
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bp = context.breakpoint;
    final tree = _tree ?? const <DepartmentNode>[];
    final selected = _selectedId == null ? null : _findById(tree, _selectedId!);

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = UtenEmpty.error(message: _error, actionLabel: '重试', onAction: _load);
    } else if (bp == UtenBreakpoint.compact) {
      body = selected == null
          ? UtenEmpty(
              icon: Icons.account_tree_outlined,
              message: '选择部门',
              description: '点右上角图标打开部门树',
            )
          : _DetailPane(ref: ref, nodeId: selected.id, onDelete: () => _delete(selected));
    } else {
      body = Row(children: [
        SizedBox(
          width: 300,
          child: DepartmentTree(
            nodes: tree,
            selectedId: _selectedId,
            onSelect: (id) => setState(() => _selectedId = id),
            onDelete: _delete,
          ),
        ),
        Container(width: 1, color: theme.colorScheme.outlineVariant),
        Expanded(
          child: selected == null
              ? const Center(child: Text('请选择左侧部门'))
              : _DetailPane(ref: ref, nodeId: selected.id, onDelete: () => _delete(selected)),
        ),
      ]);
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('部门管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: '新增部门',
            onPressed: () => _showCreateDialog(parentId: _selectedId),
          ),
          IconButton(icon: const Icon(Icons.refresh_rounded), tooltip: '刷新', onPressed: _load),
          if (bp == UtenBreakpoint.compact)
            Builder(
              builder: (scaffoldCtx) => IconButton(
                icon: const Icon(Icons.account_tree_rounded),
                tooltip: '部门树',
                onPressed: () => Scaffold.of(scaffoldCtx).openEndDrawer(),
              ),
            ),
        ],
      ),
      endDrawer: bp == UtenBreakpoint.compact
          ? Drawer(
              child: SafeArea(
                child: DepartmentTree(
                  nodes: tree,
                  selectedId: _selectedId,
                  onSelect: (id) {
                    setState(() => _selectedId = id);
                    Navigator.of(context).pop();
                  },
                  onDelete: _delete,
                ),
              ),
            )
          : null,
      body: SafeArea(child: body),
    );
  }
}

/// 部门详情 + 该部门（含子部门）员工卡片。
class _DetailPane extends StatefulWidget {
  const _DetailPane({required this.ref, required this.nodeId, required this.onDelete});

  final WidgetRef ref;
  final String nodeId;
  final VoidCallback onDelete;

  @override
  State<_DetailPane> createState() => _DetailPaneState();
}

class _DetailPaneState extends State<_DetailPane> {
  DepartmentInfo? _info;
  List<EmployeeSummary> _employees = const [];
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
      final dept = widget.ref.read(departmentRepositoryProvider);
      final emp = widget.ref.read(employeeRepositoryProvider);
      final results = await Future.wait([
        dept.detail(widget.nodeId),
        emp.list(departmentId: widget.nodeId, includeSubtree: true, size: 200),
      ]);
      if (!mounted) return;
      final info = results[0] as DepartmentInfo;
      final page = results[1] as PagedResult<EmployeeSummary>;
      setState(() {
        _info = info;
        _employees = page.items;
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
        _error = '加载失败';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return UtenEmpty.error(message: _error, actionLabel: '重试', onAction: _load);
    final info = _info;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (info != null) ...[
          UtenCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(info.name, style: theme.textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w700)),
              const SizedBox(height: 4),
              Text('${info.level} · 编码 ${info.code}',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              const SizedBox(height: 12),
              Wrap(spacing: 12, runSpacing: 8, children: [
                _stat('员工', info.employeeCount),
                _stat('子部门', info.childCount),
                if (info.managerName != null) _stat('负责人', info.managerName),
                if (info.parentName != null) _stat('上级', info.parentName),
              ]),
            ]),
          ),
          const SizedBox(height: 16),
        ],
        Text('员工（${_employees.length}）', style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if (_employees.isEmpty)
          const UtenEmpty(icon: Icons.people_outline_rounded, message: '该部门（含子部门）暂无员工')
        else
          for (final e in _employees)
            UtenPersonCard(
              title: e.fullName,
              subtitle: '${e.code} · ${e.departmentName ?? ''} · ${e.positionName ?? ''}',
              avatarText: e.fullName,
              trailing: EmployeeStatusBadge(status: e.status),
              onTap: () => context.push('/employee/${e.id}'),
            ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _stat(String label, Object? value) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(8)),
      child: Text('$label：$value', style: theme.textTheme.bodySmall),
    );
  }
}
