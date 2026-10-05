// 车间内料仓设置 · 机台与容器 (ADR-131 §5.1 第 4 条)。
//
// 批量新增 (台数 21、编号前缀、每台容器: 干燥机料斗 50 公斤、储料桶 100 公斤, 都可改);
// 个别机台单独改、停用、删除 (盘点用过的只能停用)。
// 勾选多行后改任一勾选行的单元格 = 对全部勾选行生效 (编号与名称除外, 它们是每台机自己的);
// 看到的勾选 = 提交的内容。改完点"保存修改"一次提交。
import '../../../../components/layout/uten_floating_action_group.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../../components/buttons/uten_button.dart';
import '../../../../components/feedback/uten_busy_overlay.dart';
import '../../../../components/feedback/uten_empty.dart';
import '../../../../components/layout/uten_editable_grid.dart';
import '../../../../core/l10n/gen/app_localizations.dart';
import '../../../../core/network/api_exception.dart';
import '../../../../core/theme/uten_tokens.dart';
import '../../../../core/ui/app_notification.dart';
import '../models/workshop_material_models.dart';
import '../repositories/workshop_material_repository.dart';
import 'workshop_material_labels.dart';

/// 批量新增默认的容器。
const wmDefaultContainers = <({String name, double capacityQty})>[
  (name: '干燥机料斗', capacityQty: 50),
  (name: '储料桶', capacityQty: 100),
];

class WmMachineRow extends EditableGridRow {
  WmMachineRow(this.machine)
    : name = TextEditingController(text: machine.name),
      model = TextEditingController(text: machine.model ?? ''),
      tonnage = TextEditingController(
        text: machine.tonnage == null ? '' : wmQty(machine.tonnage),
      ),
      sortOrder = TextEditingController(text: '${machine.sortOrder}'),
      enabled = ValueNotifier<bool>(machine.enabled) {
    for (final c in machine.containers) {
      capacity[c.name] = TextEditingController(
        text: wmQty(c.capacityQty, maxDecimals: 4),
      );
    }
  }

  final WmMachine machine;
  final TextEditingController name;
  final TextEditingController model;
  final TextEditingController tonnage;
  final TextEditingController sortOrder;
  final ValueNotifier<bool> enabled;

  /// 容器名 → 容量输入。
  final Map<String, TextEditingController> capacity = {};

  TextEditingController capacityFor(String containerName) =>
      capacity.putIfAbsent(containerName, TextEditingController.new);

  WmContainer? container(String containerName) {
    for (final c in machine.containers) {
      if (c.name == containerName) return c;
    }
    return null;
  }

  bool get machineDirty =>
      name.text.trim() != machine.name ||
      model.text.trim() != (machine.model ?? '') ||
      wmParseQty(tonnage.text) != machine.tonnage ||
      int.tryParse(sortOrder.text.trim()) != machine.sortOrder ||
      enabled.value != machine.enabled;

  @override
  void dispose() {
    name.dispose();
    model.dispose();
    tonnage.dispose();
    sortOrder.dispose();
    enabled.dispose();
    for (final c in capacity.values) {
      c.dispose();
    }
    super.dispose();
  }
}

class WmMachinesTab extends ConsumerStatefulWidget {
  const WmMachinesTab({
    super.key,
    required this.workshopId,
    required this.workshopName,
  });

  final String workshopId;
  final String workshopName;

  @override
  ConsumerState<WmMachinesTab> createState() => _WmMachinesTabState();
}

class _WmMachinesTabState extends ConsumerState<WmMachinesTab> {
  final _grid = UtenEditableGridController<WmMachineRow>();
  final _nonce = const Uuid().v4();
  List<String> _containerNames = const [];
  bool _loading = true;
  String? _error;
  String? _busyTitle;

  WorkshopMaterialRepository get _repo =>
      ref.read(workshopMaterialRepositoryProvider);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _grid.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final machines = await _repo.machines(widget.workshopId);
      if (!mounted) return;
      _apply(machines);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e.message;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '加载机台失败, 请重试';
        });
      }
    }
  }

  void _apply(List<WmMachine> machines) {
    final sorted = [...machines]
      ..sort((a, b) {
        final bySort = a.sortOrder.compareTo(b.sortOrder);
        return bySort != 0 ? bySort : a.code.compareTo(b.code);
      });
    // 容器列 = 全部机台的容器名 (按首次出现的排序号)。
    final order = <String, int>{};
    for (final m in sorted) {
      for (final c in m.containers) {
        order.putIfAbsent(c.name, () => c.sortOrder * 1000 + order.length);
      }
    }
    final names = order.keys.toList()
      ..sort((a, b) => order[a]!.compareTo(order[b]!));
    setState(() {
      _containerNames = names;
      _grid.replaceAll([for (final m in sorted) WmMachineRow(m)]);
      _loading = false;
    });
  }

  /// 本行已勾选且还有别的勾选行 → 全部勾选行; 否则只有本行。
  List<WmMachineRow> _targets(WmMachineRow row) {
    final selected = _grid.selectedRows;
    if (!_grid.isSelected(row) || selected.length < 2) return [row];
    return selected;
  }

  TextField _batchField(
    WmMachineRow row,
    TextEditingController Function(WmMachineRow r) controllerOf, {
    required Key key,
    bool numeric = false,
  }) => TextField(
    key: key,
    controller: controllerOf(row),
    enabled: _busyTitle == null,
    textAlign: numeric ? TextAlign.right : TextAlign.start,
    keyboardType: numeric
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text,
    decoration: const InputDecoration(isDense: true),
    onChanged: (text) {
      for (final target in _targets(row)) {
        if (target == row) continue;
        controllerOf(target).text = text;
      }
    },
  );

  List<EditableGridColumn<WmMachineRow>> _columns(AppLocalizations l10n) => [
    EditableGridColumn<WmMachineRow>(
      key: 'code',
      label: '编号',
      width: 100,
      textOf: (r) => r.machine.code,
      cellBuilder: (_, r) => Text(r.machine.code),
    ),
    EditableGridColumn<WmMachineRow>(
      key: 'name',
      label: '名称',
      width: 140,
      required: true,
      frozenTextOf: (r) => r.name.text,
      cellBuilder: (_, r) => RequiredCellFrame(
        listenable: r.name,
        isEmpty: () => r.name.text.trim().isEmpty,
        child: TextField(
          key: Key('wm-machine-name-${r.machine.id}'),
          controller: r.name,
          enabled: _busyTitle == null,
          decoration: const InputDecoration(isDense: true),
        ),
      ),
    ),
    EditableGridColumn<WmMachineRow>(
      key: 'model',
      label: '型号',
      width: 120,
      frozenTextOf: (r) => r.model.text,
      cellBuilder: (_, r) => _batchField(
        r,
        (x) => x.model,
        key: Key('wm-machine-model-${r.machine.id}'),
      ),
    ),
    EditableGridColumn<WmMachineRow>(
      key: 'tonnage',
      exactValueOf: (row) => row.tonnage.text,
      exactListenableOf: (row) => row.tonnage,
      label: '吨位',
      width: 90,
      numeric: true,
      frozenTextOf: (r) => r.tonnage.text,
      cellBuilder: (_, r) => _batchField(
        r,
        (x) => x.tonnage,
        key: Key('wm-machine-tonnage-${r.machine.id}'),
        numeric: true,
      ),
    ),
    for (final containerName in _containerNames)
      EditableGridColumn<WmMachineRow>(
        key: 'cap-$containerName',
        label: '$containerName (${l10n.wmKg})',
        width: 130,
        numeric: true,
        frozenTextOf: (r) => r.capacityFor(containerName).text,
        cellBuilder: (_, r) => _batchField(
          r,
          (x) => x.capacityFor(containerName),
          key: Key('wm-machine-cap-${r.machine.id}-$containerName'),
          numeric: true,
        ),
      ),
    EditableGridColumn<WmMachineRow>(
      key: 'enabled',
      label: '启用',
      width: 80,
      textOf: (r) => r.enabled.value ? '启用' : '停用',
      cellBuilder: (_, r) => ValueListenableBuilder<bool>(
        valueListenable: r.enabled,
        builder: (context, value, _) => Switch(
          key: Key('wm-machine-enabled-${r.machine.id}'),
          value: value,
          onChanged: _busyTitle != null
              ? null
              : (next) {
                  for (final target in _targets(r)) {
                    target.enabled.value = next;
                  }
                },
        ),
      ),
    ),
    EditableGridColumn<WmMachineRow>(
      key: 'sortOrder',
      exactValueOf: (row) => row.sortOrder.text,
      exactListenableOf: (row) => row.sortOrder,
      label: '排序',
      width: 80,
      numeric: true,
      frozenTextOf: (r) => r.sortOrder.text,
      cellBuilder: (_, r) => TextField(
        controller: r.sortOrder,
        enabled: _busyTitle == null,
        textAlign: TextAlign.right,
        keyboardType: TextInputType.number,
        decoration: const InputDecoration(isDense: true),
      ),
    ),
  ];

  Future<void> _save() async {
    final machineItems = <Map<String, dynamic>>[];
    final containerItems = <Map<String, dynamic>>[];
    for (final r in _grid.rows) {
      if (r.name.text.trim().isEmpty) {
        context.appWarning('「${r.machine.code}」的名称不能空着');
        return;
      }
      if (r.machineDirty) {
        machineItems.add({
          'id': r.machine.id,
          'expectedVersion': r.machine.rowVersion,
          'name': r.name.text.trim(),
          'model': r.model.text.trim().isEmpty ? null : r.model.text.trim(),
          'tonnage': wmParseQty(r.tonnage.text),
          'enabled': r.enabled.value,
          'sortOrder': int.tryParse(r.sortOrder.text.trim()) ?? 0,
        });
      }
      for (var i = 0; i < _containerNames.length; i++) {
        final containerName = _containerNames[i];
        final text = r.capacity[containerName]?.text.trim() ?? '';
        final existing = r.container(containerName);
        if (text.isEmpty) continue;
        final qty = wmParseQty(text);
        if (qty == null || qty <= 0) {
          context.appWarning('「${r.machine.code} $containerName」的容量要大于 0');
          return;
        }
        if (existing != null && existing.capacityQty == qty) continue;
        containerItems.add({
          'id': existing?.id,
          'machineId': r.machine.id,
          'expectedVersion': existing?.rowVersion,
          'name': containerName,
          'capacityQty': qty,
          'enabled': existing?.enabled ?? true,
          'sortOrder': existing?.sortOrder ?? i,
        });
      }
    }
    if (machineItems.isEmpty && containerItems.isEmpty) {
      context.appInfo('没有要保存的修改');
      return;
    }
    setState(() => _busyTitle = '正在保存机台与容器');
    try {
      if (machineItems.isNotEmpty) {
        await _repo.updateMachines(
          machineItems,
          idempotencyKey: wmIdempotencyKey('machines', _nonce, machineItems),
        );
      }
      if (containerItems.isNotEmpty) {
        await _repo.updateContainers(
          containerItems,
          idempotencyKey: wmIdempotencyKey(
            'containers',
            _nonce,
            containerItems,
          ),
        );
      }
      if (!mounted) return;
      setState(() => _busyTitle = null);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.appSuccess(
        '已保存: ${machineItems.length} 台机台, ${containerItems.length} 个容器',
      );
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning(e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning('网络不稳定, 暂时没确认保存结果, 请再点一次保存');
      }
    }
  }

  Future<void> _batchCreate() async {
    final nextNo = _grid.length + 1;
    final input = await showDialog<_BatchCreateInput>(
      context: context,
      builder: (_) => _BatchCreateDialog(startNo: nextNo),
    );
    if (input == null || !mounted) return;
    setState(() => _busyTitle = '正在新增 ${input.count} 台机台');
    try {
      await _repo.createMachines(
        workshopDepartmentId: widget.workshopId,
        count: input.count,
        codePrefix: input.codePrefix,
        startNo: input.startNo,
        containers: input.containers,
        idempotencyKey: wmIdempotencyKey('machines-create', _nonce, {
          'workshop': widget.workshopId,
          'count': input.count,
          'prefix': input.codePrefix,
          'start': input.startNo,
          'containers': [
            for (final c in input.containers) [c.name, c.capacityQty],
          ],
        }),
      );
      if (!mounted) return;
      setState(() => _busyTitle = null);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.appSuccess('已新增 ${input.count} 台机台');
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning(e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning('网络不稳定, 暂时没确认结果, 请刷新看看再决定是否重试');
      }
    }
  }

  Future<void> _delete(WmMachineRow row) async {
    setState(() => _busyTitle = '正在删除机台');
    try {
      await _repo.deleteMachine(
        row.machine.id,
        expectedVersion: row.machine.rowVersion,
      );
      if (!mounted) return;
      setState(() => _busyTitle = null);
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      context.appSuccess('已删除 ${row.machine.code}');
      await _load();
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning(e.message);
      }
    } catch (_) {
      if (mounted) {
        setState(() => _busyTitle = null);
        context.appWarning('网络不稳定, 请刷新看看是否已删除');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    if (_loading && _grid.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && _grid.isEmpty) {
      return UtenEmpty.error(
        message: _error,
        actionLabel: '重试',
        onAction: _load,
      );
    }
    return Stack(
      children: [
        SingleChildScrollView(
          // 末尾留出右下悬浮按钮组的位置 (平台统一: 动作放右下悬浮组, ADR-147)。
          padding: const EdgeInsets.only(
            top: UtenSpacing.s8,
            bottom: UtenFloatingActionGroup.scrollClearance,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${widget.workshopName}: 共 ${_grid.length} 台机。盘点时每台机一张卡, 每个容器点 满 / 半 / 空。'
                '勾选多行后改任一勾选行的型号、吨位、容量或启用, 会对全部勾选行生效。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: UtenSpacing.s8),
              if (_grid.isEmpty)
                const UtenEmpty(
                  icon: Icons.precision_manufacturing_outlined,
                  message: '还没有机台',
                  description: '点"批量新增机台", 一次建好全部机台和每台的容器',
                )
              else
                UtenEditableGrid<WmMachineRow>(
                  tableKey:
                      'features.warehouse.materialbin.widgets.workshop_material_machines_tab.WmMachinesTabState.build.1',
                  key: const Key('wm-machines-grid'),
                  controller: _grid,
                  columns: _columns(l10n),
                  showAddRow: false,
                  selectable: true,
                  deleteConfirmLabel: '删除这台机? 盘点用过的机台只能停用, 不能删除。',
                  onDeleteRow: (row, _) => _delete(row),
                  showColumnSettings: false,
                ),
            ],
          ),
        ),
        PositionedDirectional(
          end: UtenSpacing.s16,
          bottom: UtenSpacing.s16,
          child: UtenFloatingActionGroup(
            children: [
              UtenButton(
                key: const Key('wm-machines-batch-create'),
                type: UtenButtonType.secondary,
                size: UtenButtonSize.large,
                icon: Icons.library_add_outlined,
                onPressed: _busyTitle == null ? _batchCreate : null,
                child: Text(l10n.wmMachinesBatchCreate),
              ),
              if (!_grid.isEmpty)
                UtenButton(
                  key: const Key('wm-machines-save'),
                  size: UtenButtonSize.large,
                  icon: Icons.save_outlined,
                  onPressed: _busyTitle == null ? _save : null,
                  child: Text(l10n.wmMachinesSaveChanges),
                ),
            ],
          ),
        ),
        if (_busyTitle != null) UtenBusyOverlay(title: _busyTitle!),
      ],
    );
  }
}

class _BatchCreateInput {
  const _BatchCreateInput({
    required this.count,
    required this.codePrefix,
    required this.startNo,
    required this.containers,
  });

  final int count;
  final String codePrefix;
  final int startNo;
  final List<({String name, double capacityQty})> containers;
}

class _ContainerDraft {
  _ContainerDraft(String name, double? capacity)
    : name = TextEditingController(text: name),
      capacity = TextEditingController(
        text: capacity == null ? '' : wmQty(capacity),
      );

  final TextEditingController name;
  final TextEditingController capacity;

  void dispose() {
    name.dispose();
    capacity.dispose();
  }
}

class _BatchCreateDialog extends StatefulWidget {
  const _BatchCreateDialog({required this.startNo});

  final int startNo;

  @override
  State<_BatchCreateDialog> createState() => _BatchCreateDialogState();
}

class _BatchCreateDialogState extends State<_BatchCreateDialog> {
  final _count = TextEditingController(text: '21');
  final _prefix = TextEditingController();
  late final _startNo = TextEditingController(text: '${widget.startNo}');
  final _containers = [
    for (final c in wmDefaultContainers) _ContainerDraft(c.name, c.capacityQty),
  ];
  String? _error;

  @override
  void dispose() {
    _count.dispose();
    _prefix.dispose();
    _startNo.dispose();
    for (final c in _containers) {
      c.dispose();
    }
    super.dispose();
  }

  void _confirm() {
    final count = int.tryParse(_count.text.trim());
    final startNo = int.tryParse(_startNo.text.trim());
    if (count == null || count < 1 || count > 200) {
      setState(() => _error = '台数请填 1 到 200');
      return;
    }
    if (startNo == null || startNo < 0) {
      setState(() => _error = '起始号请填 0 或更大的整数');
      return;
    }
    final containers = <({String name, double capacityQty})>[];
    final names = <String>{};
    for (final c in _containers) {
      final name = c.name.text.trim();
      final capacity = wmParseQty(c.capacity.text);
      if (name.isEmpty && c.capacity.text.trim().isEmpty) continue;
      if (name.isEmpty || capacity == null || capacity <= 0) {
        setState(() => _error = '每个容器都要填名称和大于 0 的容量');
        return;
      }
      if (!names.add(name)) {
        setState(() => _error = '容器「$name」重复了');
        return;
      }
      containers.add((name: name, capacityQty: capacity));
    }
    if (containers.isEmpty) {
      setState(() => _error = '每台机至少要有一个容器');
      return;
    }
    Navigator.of(context).pop(
      _BatchCreateInput(
        count: count,
        codePrefix: _prefix.text.trim(),
        startNo: startNo,
        containers: containers,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('批量新增机台'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: UtenSpacing.s12,
                runSpacing: UtenSpacing.s12,
                children: [
                  SizedBox(
                    width: 100,
                    child: TextField(
                      key: const Key('wm-batch-count'),
                      controller: _count,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '台数'),
                    ),
                  ),
                  SizedBox(
                    width: 150,
                    child: TextField(
                      key: const Key('wm-batch-prefix'),
                      controller: _prefix,
                      decoration: const InputDecoration(labelText: '编号前缀 (选填)'),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: TextField(
                      key: const Key('wm-batch-start'),
                      controller: _startNo,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '起始号'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s16),
              Text('每台机的容器', style: theme.textTheme.titleSmall),
              for (var i = 0; i < _containers.length; i++)
                Padding(
                  padding: const EdgeInsets.only(top: UtenSpacing.s8),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          key: Key('wm-batch-container-name-$i'),
                          controller: _containers[i].name,
                          decoration: const InputDecoration(labelText: '容器名称'),
                        ),
                      ),
                      const SizedBox(width: UtenSpacing.s8),
                      SizedBox(
                        width: 120,
                        child: TextField(
                          key: Key('wm-batch-container-capacity-$i'),
                          controller: _containers[i].capacity,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: const InputDecoration(
                            labelText: '容量 (公斤)',
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: '去掉这个容器',
                        onPressed: _containers.length <= 1
                            ? null
                            : () => setState(() {
                                _containers.removeAt(i).dispose();
                              }),
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                    ],
                  ),
                ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(
                    () => _containers.add(_ContainerDraft('', null)),
                  ),
                  icon: const Icon(Icons.add),
                  label: const Text('加一个容器'),
                ),
              ),
              if (_error != null)
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        UtenButton(
          key: const Key('wm-batch-confirm'),
          onPressed: _confirm,
          child: const Text('新增'),
        ),
      ],
    );
  }
}
