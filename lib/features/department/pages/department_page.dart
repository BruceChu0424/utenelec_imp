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
import '../../../core/l10n/gen/app_localizations.dart';
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
  // Backend option codes are unchanged; labels come from l10n at build time.
  static const _levelCodes = ['公司', '决策层', '管理中心', '一级部门', '二级班组', '三级科室'];

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
        _error = AppLocalizations.of(context).departmentLoadFailed;
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

  String _levelLabel(AppLocalizations l10n, String code) => switch (code) {
    '公司' => l10n.departmentLevelCompany,
    '决策层' => l10n.departmentLevelDecision,
    '管理中心' => l10n.departmentLevelManagement,
    '一级部门' => l10n.departmentLevelPrimary,
    '二级班组' => l10n.departmentLevelSecondary,
    '三级科室' => l10n.departmentLevelTertiary,
    _ => code,
  };

  Future<void> _showCreateDialog({String? parentId}) async {
    final l10n = AppLocalizations.of(context);
    final nameCtl = TextEditingController();
    final codeCtl = TextEditingController();
    String level = '二级班组';
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(l10n.departmentDialogAddTitle),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: codeCtl,
                  decoration: InputDecoration(
                    labelText: l10n.departmentFieldCode,
                    hintText: l10n.departmentFieldCodeHint,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtl,
                  decoration: InputDecoration(
                    labelText: l10n.departmentFieldName,
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  value: level,
                  decoration: InputDecoration(
                    labelText: l10n.departmentFieldLevel,
                  ),
                  items: _levelCodes
                      .map(
                        (c) => DropdownMenuItem(
                          value: c,
                          child: Text(_levelLabel(l10n, c)),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => setSt(() => level = v ?? level),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(l10n.commonCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(l10n.departmentCreate),
            ),
          ],
        ),
      ),
    );
    if (result != true) return;
    if (codeCtl.text.trim().isEmpty || nameCtl.text.trim().isEmpty) {
      _toast(l10n.departmentRequireCodeAndName);
      return;
    }
    try {
      await ref
          .read(departmentRepositoryProvider)
          .create(
            DepartmentSaveInput(
              code: codeCtl.text.trim(),
              name: nameCtl.text.trim(),
              level: level,
              parentId: parentId,
            ),
          );
      _toast(l10n.departmentCreated);
      await _load();
    } on ApiException catch (e) {
      _toast(e.message);
    }
  }

  Future<void> _delete(DepartmentNode node) async {
    final l10n = AppLocalizations.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.departmentDialogDeleteTitle),
        content: Text(l10n.departmentDeleteConfirm(node.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l10n.commonCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l10n.departmentDelete),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ref.read(departmentRepositoryProvider).delete(node.id);
      _toast(l10n.departmentDeleted);
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
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final bp = context.breakpoint;
    final tree = _tree ?? const <DepartmentNode>[];
    final selected = _selectedId == null ? null : _findById(tree, _selectedId!);

    Widget body;
    if (_loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (_error != null) {
      body = UtenEmpty.error(
        message: _error,
        actionLabel: l10n.commonRetry,
        onAction: _load,
      );
    } else if (bp == UtenBreakpoint.compact) {
      body = selected == null
          ? UtenEmpty(
              icon: Icons.account_tree_outlined,
              message: l10n.departmentEmpty,
              description: l10n.departmentEmptyHint,
            )
          : _DetailPane(
              ref: ref,
              nodeId: selected.id,
              onDelete: () => _delete(selected),
            );
    } else {
      body = Row(
        children: [
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
                ? Center(child: Text(l10n.departmentEmptySelect))
                : _DetailPane(
                    ref: ref,
                    nodeId: selected.id,
                    onDelete: () => _delete(selected),
                  ),
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.departmentTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_rounded),
            tooltip: l10n.departmentTooltipAdd,
            onPressed: () => _showCreateDialog(parentId: _selectedId),
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: l10n.departmentTooltipRefresh,
            onPressed: _load,
          ),
          if (bp == UtenBreakpoint.compact)
            Builder(
              builder: (scaffoldCtx) => IconButton(
                icon: const Icon(Icons.account_tree_rounded),
                tooltip: l10n.departmentTooltipTree,
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
  const _DetailPane({
    required this.ref,
    required this.nodeId,
    required this.onDelete,
  });

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
        _error = AppLocalizations.of(context).departmentLoadFailed;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: l10n.commonRetry,
        onAction: _load,
      );
    }
    final info = _info;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (info != null) ...[
          UtenCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  info.name,
                  style: theme.textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.departmentLevelAndCode(info.level, info.code),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    _stat(
                      l10n,
                      l10n.departmentStatEmployees,
                      info.employeeCount,
                    ),
                    _stat(l10n, l10n.departmentStatChildren, info.childCount),
                    if (info.managerName != null)
                      _stat(l10n, l10n.departmentStatManager, info.managerName),
                    if (info.parentName != null)
                      _stat(l10n, l10n.departmentStatParent, info.parentName),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
        ],
        Text(
          l10n.departmentEmployeesHeader(_employees.length),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        if (_employees.isEmpty)
          UtenEmpty(
            icon: Icons.people_outline_rounded,
            message: l10n.departmentEmployeesEmpty,
          )
        else
          for (final e in _employees)
            UtenPersonCard(
              title: e.fullName,
              subtitle:
                  '${e.code} · ${e.departmentName ?? ''} · ${e.positionName ?? ''}',
              avatarText: e.fullName,
              trailing: EmployeeStatusBadge(status: e.status),
              onTap: () => context.push('/employee/${e.id}'),
            ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _stat(AppLocalizations l10n, String label, Object? value) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        l10n.departmentStatValue(label, value ?? '—'),
        style: theme.textTheme.bodySmall,
      ),
    );
  }
}
