// PositionManagerSheet - 部门岗位管理（HR 增删改）
//
// 从部门管理页的部门节点「岗位」入口打开。列出该部门岗位（按 sortOrder），
// 支持添加（编码 + 名称 + 职级 + 排序号）、改名/改级/改序、删除（二次确认）。
// 接口：GET/POST /org/departments/{deptId}/positions，PUT/DELETE /org/positions/{id}。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/feedback/uten_toast.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/auth/permissions.dart';
import '../models/department_node.dart';
import '../models/position.dart';
import '../repositories/position_repository.dart';

/// 职级常用建议。
const kPositionLevelSuggestions = ['领导层', '班组管理', '员工'];

/// 打开部门岗位管理抽屉（仅一级部门/二级班组/三级科室节点应提供入口）。
Future<void> showPositionManagerSheet(
  BuildContext context,
  DepartmentNode node,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.75,
        child: PositionManagerSheet(node: node),
      ),
    ),
  );
}

class PositionManagerSheet extends ConsumerStatefulWidget {
  const PositionManagerSheet({super.key, required this.node});

  final DepartmentNode node;

  @override
  ConsumerState<PositionManagerSheet> createState() =>
      _PositionManagerSheetState();
}

class _PositionManagerSheetState extends ConsumerState<PositionManagerSheet> {
  List<Position>? _positions;
  String? _error;

  PositionRepository get _repo => ref.read(positionRepositoryProvider);
  bool get _canEdit =>
      ref.read(currentPermissionsProvider).contains(Perm.departmentEdit);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _repo.listByDepartment(widget.node.id);
      list.sort((a, b) => (a.sortOrder ?? 0).compareTo(b.sortOrder ?? 0));
      if (!mounted) return;
      setState(() {
        _positions = list;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _error = '岗位加载失败，请稍后重试');
    }
  }

  Future<void> _showEditDialog({Position? position}) async {
    if (!_canEdit) return;
    final isCreate = position == null;
    final codeCtl = TextEditingController(text: position?.code ?? '');
    final nameCtl = TextEditingController(text: position?.name ?? '');
    final levelCtl = TextEditingController(text: position?.level ?? '');
    final sortCtl = TextEditingController(
      text: position?.sortOrder?.toString() ?? '',
    );
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(isCreate ? '添加岗位' : '编辑岗位'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (isCreate) ...[
                  TextField(
                    controller: codeCtl,
                    decoration: const InputDecoration(
                      labelText: '岗位编码 *',
                      hintText: '如 BUYER-01',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: '岗位名称 *'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: levelCtl,
                  decoration: const InputDecoration(labelText: '职级'),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final s in kPositionLevelSuggestions)
                      ActionChip(
                        label: Text(s),
                        visualDensity: VisualDensity.compact,
                        onPressed: () => setSt(() => levelCtl.text = s),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: sortCtl,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(labelText: '排序号'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(isCreate ? '添加' : '保存'),
            ),
          ],
        ),
      ),
    );
    if (saved != true || !mounted) return;
    final name = nameCtl.text.trim();
    if (name.isEmpty || (isCreate && codeCtl.text.trim().isEmpty)) {
      UtenToast.warning(context, '请填写必填项（编码/名称）');
      return;
    }
    final level = levelCtl.text.trim();
    final sort = int.tryParse(sortCtl.text.trim());
    try {
      if (isCreate) {
        await _repo.create(
          widget.node.id,
          PositionSaveInput(
            code: codeCtl.text.trim(),
            name: name,
            level: level.isEmpty ? null : level,
            sortOrder: sort,
          ),
        );
      } else {
        await _repo.update(
          position.id,
          PositionUpdateInput(
            name: name,
            level: level.isEmpty ? null : level,
            sortOrder: sort,
          ),
        );
      }
      if (!mounted) return;
      UtenToast.success(context, isCreate ? '岗位已添加' : '岗位已保存');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      UtenToast.error(context, e.message);
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '保存失败，请稍后重试');
    }
  }

  Future<void> _delete(Position p) async {
    if (!_canEdit) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除岗位'),
        content: Text('确定删除岗位「${p.name}」吗？删除后不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _repo.delete(p.id);
      if (!mounted) return;
      UtenToast.success(context, '岗位已删除');
      await _load();
    } on ApiException catch (e) {
      if (!mounted) return;
      UtenToast.error(context, e.message);
    } catch (_) {
      if (!mounted) return;
      UtenToast.error(context, '删除失败，请稍后重试');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final canEdit = ref
        .watch(currentPermissionsProvider)
        .contains(Perm.departmentEdit);
    final positions = _positions;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.node.name} · 岗位',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (canEdit)
                IconButton(
                  icon: const Icon(Icons.add_rounded),
                  tooltip: '添加岗位',
                  onPressed: () => _showEditDialog(),
                ),
              IconButton(
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
        Expanded(
          child: positions == null && _error == null
              ? const Center(child: CircularProgressIndicator())
              : _error != null
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(_error!, style: theme.textTheme.bodyMedium),
                      const SizedBox(height: 8),
                      TextButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                )
              : positions!.isEmpty
              ? Center(
                  child: Text(
                    canEdit ? '暂无岗位，点右上角「+」添加' : '暂无岗位',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: positions.length,
                  itemBuilder: (context, i) {
                    final p = positions[i];
                    return ListTile(
                      dense: true,
                      leading: Container(
                        width: 28,
                        height: 28,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          '${p.sortOrder ?? i + 1}',
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                      title: Text(p.name),
                      subtitle: Text(
                        [
                          if (p.level.isNotEmpty) p.level,
                          if (p.code.isNotEmpty) p.code,
                        ].join(' · '),
                      ),
                      trailing: canEdit
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(
                                    Icons.edit_outlined,
                                    size: 18,
                                  ),
                                  tooltip: '编辑',
                                  onPressed: () => _showEditDialog(position: p),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                  tooltip: '删除',
                                  onPressed: () => _delete(p),
                                ),
                              ],
                            )
                          : null,
                    );
                  },
                ),
        ),
      ],
    );
  }
}
