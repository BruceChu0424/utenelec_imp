// UtenPositionPicker - 岗位联动选择（依赖已选部门）
//
// 输入 departmentId；未选部门时禁用并提示「请先选择部门」。
// 数据：GET /org/departments/{deptId}/positions，点击时按需拉取。
// 选项按 level 分组（「领导层」组排最前，带分区标题）；空数据提示联系 HR。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_exception.dart';
import '../../../components/layout/uten_picker_confirm_bar.dart';
import '../models/position.dart';
import '../repositories/position_repository.dart';

/// 「领导层」固定排第一组（部级节点的岗位 = 领导层）。
const kLeaderPositionLevel = '领导层';

class UtenPositionPicker extends ConsumerStatefulWidget {
  const UtenPositionPicker({
    super.key,
    required this.departmentId,
    required this.onChanged,
    this.value,
    this.enabled = true,
    this.label,
  });

  /// 联动部门 id；为 null 时禁用并提示「请先选择部门」。
  final String? departmentId;

  /// 当前选中岗位。
  final Position? value;

  /// 选中/清除回调。
  final ValueChanged<Position?> onChanged;

  final bool enabled;
  final String? label;

  @override
  ConsumerState<UtenPositionPicker> createState() => _UtenPositionPickerState();
}

class _UtenPositionPickerState extends ConsumerState<UtenPositionPicker> {
  Position? _value;

  bool get _hasDept =>
      widget.departmentId != null && widget.departmentId!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _value = widget.value;
  }

  @override
  void didUpdateWidget(UtenPositionPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) _value = widget.value;
    // 部门切换后旧岗位失效，清空（由调用方通过 onChanged 同步自身状态）。
    if (widget.departmentId != oldWidget.departmentId && _value != null) {
      _value = null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) widget.onChanged(null);
      });
    }
  }

  Future<void> _open() async {
    final deptId = widget.departmentId;
    if (deptId == null || deptId.isEmpty) return;
    final result = await showModalBottomSheet<Position>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(ctx).bottom),
        child: SizedBox(
          height: MediaQuery.sizeOf(ctx).height * 0.6,
          child: _PositionListSheet(
            departmentId: deptId,
            selectedId: _value?.id,
          ),
        ),
      ),
    );
    if (result != null && mounted) {
      setState(() => _value = result);
      widget.onChanged(result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.enabled && _hasDept;
    final display = _value?.name;
    final hint = _hasDept ? '请选择岗位' : '请先选择部门';
    return InkWell(
      onTap: enabled ? _open : null,
      borderRadius: BorderRadius.circular(10),
      child: InputDecorator(
        isEmpty: display == null,
        decoration: InputDecoration(
          labelText: widget.label,
          hintText: hint,
          enabled: enabled,
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
            borderSide: BorderSide(color: theme.colorScheme.primary, width: 2),
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
    );
  }
}

/// 岗位列表抽屉：按 level 分组，「领导层」在最前。
class _PositionListSheet extends ConsumerStatefulWidget {
  const _PositionListSheet({required this.departmentId, this.selectedId});

  final String departmentId;
  final String? selectedId;

  @override
  ConsumerState<_PositionListSheet> createState() => _PositionListSheetState();
}

class _PositionListSheetState extends ConsumerState<_PositionListSheet> {
  List<Position>? _positions;
  String? _error;

  /// 已点选（高亮）的岗位；底部「确定」才 pop 返回（二次操作契约）。
  Position? _picked;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await ref
          .read(positionRepositoryProvider)
          .listByDepartment(widget.departmentId);
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

  /// 分组：领导层在最前，其余按出现顺序；组内按 sortOrder。
  List<({String level, List<Position> items})> _group(List<Position> all) {
    final order = <String>[];
    final byLevel = <String, List<Position>>{};
    for (final p in all) {
      final key = p.level.isEmpty ? '其他' : p.level;
      if (!byLevel.containsKey(key)) {
        byLevel[key] = [];
        order.add(key);
      }
      byLevel[key]!.add(p);
    }
    order.sort((a, b) {
      if (a == kLeaderPositionLevel) return -1;
      if (b == kLeaderPositionLevel) return 1;
      return 0;
    });
    return [
      for (final level in order)
        (
          level: level,
          items: byLevel[level]!
            ..sort((a, b) => (a.sortOrder ?? 0).compareTo(b.sortOrder ?? 0)),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final positions = _positions;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '选择岗位',
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
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '该部门暂无岗位，请联系 HR 添加',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.only(bottom: 16),
                  children: [
                    for (final group in _group(positions)) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                        child: Text(
                          group.level,
                          style: theme.textTheme.labelLarge?.copyWith(
                            color: group.level == kLeaderPositionLevel
                                ? theme.colorScheme.primary
                                : theme.colorScheme.onSurfaceVariant,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      for (final p in group.items)
                        ListTile(
                          dense: true,
                          selected: p.id == (_picked?.id ?? widget.selectedId),
                          title: Text(p.name),
                          subtitle: p.code.isEmpty ? null : Text(p.code),
                          trailing: p.id == (_picked?.id ?? widget.selectedId)
                              ? Icon(
                                  Icons.check_circle_rounded,
                                  size: 18,
                                  color: theme.colorScheme.primary,
                                )
                              : null,
                          onTap: () => setState(() => _picked = p),
                        ),
                    ],
                  ],
                ),
        ),
        UtenPickerConfirmBar(
          selectedCount: _picked == null ? 0 : 1,
          selectedLabel: _picked?.name,
          onConfirm: () => Navigator.of(context).pop(_picked),
        ),
      ],
    );
  }
}
