import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_floating_window.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_search_bar.dart';
import '../../../core/ui/app_notification.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_panel_header.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/department_node.dart';
import '../../../shared/models/employee_reference.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/widgets/business_employee_picker.dart';
import '../../../shared/widgets/uten_department_picker.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../providers/production_department_provider.dart';
import 'delivery_processing_repository.dart';

/// The same real workshop task surface is reachable from a shipment or the workshop page.
class DeliveryProcessingTasksButton extends ConsumerStatefulWidget {
  const DeliveryProcessingTasksButton({
    super.key,
    this.shipmentId,
    this.onChanged,
  });
  final String? shipmentId;
  final FutureOr<void> Function()? onChanged;
  @override
  ConsumerState<DeliveryProcessingTasksButton> createState() =>
      _TasksButtonState();
}

class _TasksButtonState extends ConsumerState<DeliveryProcessingTasksButton> {
  OverlayEntry? _entry;
  final _windowKey = GlobalKey<UtenFloatingWindowState>();
  void _close() {
    final entry = _entry;
    _entry = null;
    entry?.remove();
    entry?.dispose();
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  void _open() {
    if (_entry != null) {
      _windowKey.currentState?.expand();
      return;
    }
    _entry = OverlayEntry(
      builder: (_) => Positioned.fill(
        child: _TasksWindow(
          shipmentId: widget.shipmentId,
          windowKey: _windowKey,
          onClose: _close,
          onChanged: widget.onChanged,
        ),
      ),
    );
    Overlay.of(context, rootOverlay: true).insert(_entry!);
  }

  @override
  Widget build(BuildContext context) {
    final allowed =
        ref.watch(isSuperAdminProvider) ||
        ref
            .watch(currentPermissionsProvider)
            .contains(Perm.productionExecutionView);
    if (!allowed) return const SizedBox.shrink();
    return UtenButton(
      type: UtenButtonType.tonal,
      onPressed: _open,
      child: const Text('交付件加工任务'),
    );
  }
}

class _TasksWindow extends ConsumerStatefulWidget {
  const _TasksWindow({
    this.shipmentId,
    required this.windowKey,
    required this.onClose,
    this.onChanged,
  });
  final String? shipmentId;
  final GlobalKey<UtenFloatingWindowState> windowKey;
  final VoidCallback onClose;
  final FutureOr<void> Function()? onChanged;
  @override
  ConsumerState<_TasksWindow> createState() => _TasksWindowState();
}

class _TasksWindowState extends ConsumerState<_TasksWindow> {
  final _listRead = ScopedPagedRead<DeliveryProcessingTask>(
    idOf: (task) => task.id,
  );
  final _quantity = TextEditingController(),
      _evidence = TextEditingController();
  final _search = TextEditingController();
  final _filters = <String, String?>{};
  final _targetFilters = <String, String?>{};
  StateSetter? _panelSetState;
  VoidCallback? _closePanel;
  bool _panelOpen = false;
  void _update(VoidCallback action) {
    if (!mounted) return;
    setState(action);
    _panelSetState?.call(() {});
  }

  DeliveryProcessingPage? _page;
  DeliveryProcessingTask? _selected;
  List<Map<String, dynamic>> _warehouses = const [];
  List<DepartmentNode> _workshops = const [];
  String? _warehouseId, _workshopId, _responsibleId, _error;
  bool _busy = false;
  int _generation = 0;
  late SensitiveReadBoundary _boundary;
  ProviderSubscription<SensitiveReadBoundary>? _subscription;
  DeliveryProcessingRepository get _repository =>
      ref.read(deliveryProcessingRepositoryProvider);
  PendingDeliveryProcessingAction? get _pending =>
      _selected == null ? null : _repository.pending[_selected!.id];
  bool get _current =>
      mounted && ref.read(sensitiveReadBoundaryProvider) == _boundary;

  @override
  void initState() {
    super.initState();
    _boundary = ref.read(sensitiveReadBoundaryProvider);
    _quantity.addListener(_inputsChanged);
    _evidence.addListener(_inputsChanged);
    _subscription = ref.listenManual(sensitiveReadBoundaryProvider, (_, next) {
      if (mounted && next != _boundary) widget.onClose();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_current) unawaited(_load());
    });
  }

  @override
  void dispose() {
    _generation++;
    _listRead.dispose();
    final closePanel = _closePanel;
    _panelSetState = null;
    if (closePanel != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => closePanel());
    }
    _subscription?.close();
    _quantity.dispose();
    _evidence.dispose();
    _search.dispose();
    super.dispose();
  }

  void _inputsChanged() {
    if (mounted) _update(() {});
  }

  Future<DeliveryProcessingPage> _readCompleteTasks() async {
    final repository = _repository;
    final keyword = _search.text.trim();
    final generation = _generation;
    bool ownerCurrent() =>
        _current &&
        identical(repository, _repository) &&
        keyword == _search.text.trim();
    final next = await _listRead.read(
      1,
      scope: [repository, _boundary, widget.shipmentId, keyword],
      isCurrent: () => ownerCurrent() && generation == _generation,
      isOwnerCurrent: ownerCurrent,
      fetchPage: (batch) =>
          repository.list(widget.shipmentId, page: batch, keyword: keyword),
      fetchPageSized: (batch, size) => repository.list(
        widget.shipmentId,
        page: batch,
        size: size,
        keyword: keyword,
      ),
    );
    return next as DeliveryProcessingPage;
  }

  Future<void> _load() async {
    if (_busy) return;
    await _wait('正在读取交付件加工任务', () async {
      final next = await _readCompleteTasks();
      if (!_current) return;
      _update(() {
        _page = next;
        _error = null;
      });
    });
  }

  Future<void> _wait(String title, Future<void> Function() action) async {
    if (_busy || !_current) return;
    final generation = ++_generation;
    _update(() => _busy = true);
    try {
      await UtenBusyOverlay.run(context, title: title, action: action);
    } catch (error) {
      if (mounted && _current && generation == _generation) {
        _update(() => _error = error.toString());
        context.appError(error.toString());
      }
    } finally {
      if (mounted && generation == _generation) _update(() => _busy = false);
    }
  }

  Future<void> _select(DeliveryProcessingTask row) async {
    if (_busy) return;
    await _wait('正在读取加工来源与权限', () async {
      final selected = await _repository.get(row.id);
      if (!_current) return;
      final warehouses = selected.canStart
          ? await _repository.warehouses(row.id)
          : <Map<String, dynamic>>[];
      if (!_current) return;
      final workshops = selected.canAssign
          ? await ref.read(productionWorkshopTreeProvider.future)
          : <DepartmentNode>[];
      if (!_current) return;
      _update(() {
        _selected = selected;
        _targetFilters.clear();
        _warehouses = warehouses;
        _workshops = workshops;
        final pending = _repository.pending[selected.id];
        _warehouseId =
            pending?.body['warehouseId']?.toString() ??
            selected.value('warehouseId');
        _workshopId =
            pending?.body['workshopDepartmentId']?.toString() ??
            selected.value('workshopDepartmentId');
        _responsibleId =
            pending?.body['responsibleEmployeeId']?.toString() ??
            selected.value('responsibleEmployeeId');
        _error = null;
        _quantity.text =
            pending?.body['quantity']?.toString() ?? selected.remaining;
        _evidence.text = pending?.body['evidence']?.toString() ?? '';
      });
    });
    if (_current && _selected?.id == row.id && !_busy) await _showEditor();
  }

  Future<void> _showEditor() async {
    if (_panelOpen) {
      _panelSetState?.call(() {});
      return;
    }
    _update(() => _panelOpen = true);
    try {
      await showUtenAdaptivePanel<void>(
        context: context,
        widthFraction: UtenPanelWidth.form,
        builder: (panelContext) => StatefulBuilder(
          builder: (panelContext, panelSetState) {
            _panelSetState = panelSetState;
            _closePanel = () {
              if (panelContext.mounted &&
                  ModalRoute.of(panelContext)?.isCurrent == true) {
                Navigator.of(panelContext).pop();
              }
            };
            return Material(
              child: SafeArea(
                child: Column(
                  children: [
                    UtenPanelHeader(
                      title: '交付件加工办理',
                      closeButtonKey: const ValueKey(
                        'delivery-processing-panel-close',
                      ),
                      onClose: _busy ? null : _closePanel,
                    ),
                    Expanded(
                      child: _selected == null
                          ? const SizedBox.shrink()
                          : _editor(_selected!),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      );
    } finally {
      _panelSetState = null;
      _closePanel = null;
      if (mounted) _update(() => _panelOpen = false);
    }
  }

  Future<void> _execute(String action, Map<String, dynamic> values) async {
    final selected = _selected;
    if (selected == null || _busy || _pending != null) return;
    await _wait('正在提交加工操作', () async {
      final updated = await _repository.submit(selected, action, values);
      if (!_current) return;
      await widget.onChanged?.call();
      if (!_current) return;
      _update(() {
        _selected = updated;
        _quantity.text = updated.remaining;
        _error = null;
      });
      if (updated.canStart) {
        final warehouses = await _repository.warehouses(updated.id);
        if (!_current) return;
        _update(() => _warehouses = warehouses);
      }
      final next = await _readCompleteTasks();
      if (_current) _update(() => _page = next);
    });
  }

  Future<void> _reconcile() async {
    final pending = _pending;
    if (pending == null) return;
    await _wait('正在核对原加工请求', () async {
      final found = await _repository.reconcile(pending);
      if (!_current) return;
      if (found) {
        await widget.onChanged?.call();
        if (!_current) return;
        final updated = await _repository.get(pending.componentId);
        if (_current) {
          _update(() {
            _selected = updated;
            _quantity.text = updated.remaining;
            _error = null;
          });
        }
      } else {
        if (mounted) context.appWarning('暂未查到已提交记录；如需重试，将沿用原请求和原数量');
      }
    });
  }

  Future<void> _retry() async {
    final pending = _pending;
    if (pending == null) return;
    await _wait('正在用原请求核对加工结果', () async {
      if (await _repository.reconcile(pending)) {
        if (!_current) return;
        await widget.onChanged?.call();
        if (!_current) return;
        final updated = await _repository.get(pending.componentId);
        if (_current) _update(() => _selected = updated);
        return;
      }
      final updated = await _repository.retry(pending);
      if (_current) await widget.onChanged?.call();
      if (_current) {
        _update(() {
          _selected = updated;
          _quantity.text = updated.remaining;
          _error = null;
        });
      }
    });
  }

  String _status(DeliveryProcessingTask task) => switch (task.status) {
    'WAITING' => task.value('issuedAt') == null ? '待仓库发加工' : '待开工',
    'IN_PROGRESS' => '加工中',
    'COMPLETED' => '已完成',
    _ => '待核对',
  };
  Widget _editor(DeliveryProcessingTask task) {
    final locked = _busy || _pending != null;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.name,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Flexible(
                  child: Tooltip(
                    message:
                        '${task.completed} / ${task.required} ${task.unit}',
                    child: Text(
                      '${task.completed} / ${task.required} ${task.unit}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
                const UtenFieldHintIcon(
                  info:
                      '仓库实际发至加工后才能开工，报工只记录定量加工和检验事实；仓库确认收回后才能发货。撤销开工不释放仍在车间的实物。未知提交先核对原请求。',
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 230,
              child: MasterDataTableView<DeliveryProcessingTarget>(
                tableKey: 'production.delivery-processing.targets',
                items: task.processingTargets,
                facets: const {},
                nullCounts: const {},
                filters: _targetFilters,
                onFilterChanged: (key, value) =>
                    _update(() => _targetFilters[key] = value),
                idOf: (target) => target.id,
                emptyMessage: '缺少实际加工对象，请核对交付资料',
                columns: [
                  MasterColumnDef(
                    key: 'name',
                    label: '实际加工对象',
                    width: 190,
                    value: (target) => target.name,
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'code',
                    label: '编号',
                    width: 130,
                    // 2026-11-11 口径：编号列补就地排序（按值筛选此前已开）。
                    sortable: true,
                    value: (target) => target.code,
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'quantity',
                    label: '本任务总要求数量',
                    width: 150,
                    value: (target) => '${target.quantity} ${target.unit}',
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'operations',
                    label: '必要加工',
                    width: 120,
                    value: (target) => target.operations,
                    filterFromRows: true,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (task.canAssign)
                  SizedBox(
                    width: 240,
                    child: UtenDepartmentPicker(
                      mode: UtenDepartmentPickerMode.single,
                      label: '生产车间',
                      enabled: !locked,
                      treeOverride: _workshops,
                      selectablePredicate: isBusinessDepartmentNode,
                      initialSelection: [
                        if (_workshopId != null)
                          DeptSelection(
                            id: _workshopId!,
                            name: task.value('workshopName') ?? '',
                            fullPath: '',
                            level: '',
                          ),
                      ],
                      onChanged: (selection) => _update(
                        () => _workshopId = selection.firstOrNull?.id,
                      ),
                    ),
                  ),
                if (task.canAssign)
                  SizedBox(
                    width: 220,
                    child: BusinessEmployeePicker(
                      purpose: EmployeeReferencePurpose.productionSegmentOwner,
                      selectedId: _responsibleId,
                      label: '负责人',
                      departmentId: _workshopId,
                      enabled: !locked,
                      onChanged: (employee) =>
                          _update(() => _responsibleId = employee?.id),
                    ),
                  ),
                if (task.canStart)
                  SizedBox(
                    width: 250,
                    child: UtenDropdownField(
                      label: '加工来源仓',
                      value: _warehouseId,
                      enabled: !locked,
                      items: [
                        for (final row in _warehouses)
                          UtenDropdownItem(
                            value: row['warehouseId']?.toString(),
                            label:
                                '${row['warehouseName']}（可用 ${row['availableQty']} ${task.unit}）',
                          ),
                      ],
                      onChanged: (value) => _update(() => _warehouseId = value),
                    ),
                  ),
                if (task.canReport)
                  SizedBox(
                    width: 220,
                    child: TextField(
                      key: const ValueKey('delivery-processing-quantity'),
                      controller: _quantity,
                      enabled: !locked,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: UtenInputDecoration(
                        InputDecoration(
                          label: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  '本次完成的交付件数量',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              UtenFieldHintIcon(
                                info: '所报交付件必须已完成表中全部加工对象及必要加工要求，数量以交付件单位计量。',
                              ),
                            ],
                          ),
                          suffixText: task.unit,
                        ),
                      ),
                    ),
                  ),
                if (task.canReport)
                  SizedBox(
                    width: 380,
                    child: TextField(
                      key: const ValueKey('delivery-processing-evidence'),
                      controller: _evidence,
                      enabled: !locked,
                      maxLines: 2,
                      maxLength: 2000,
                      decoration: const UtenInputDecoration(
                        InputDecoration(
                          labelText: '全部加工对象的完成及检验依据',
                          counterText: '',
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_pending != null) ...[
                  UtenButton(
                    onPressed: _busy ? null : _reconcile,
                    child: const Text('核对上次提交'),
                  ),
                  UtenButton(
                    type: UtenButtonType.secondary,
                    onPressed: _busy ? null : _retry,
                    child: const Text('按原请求重试'),
                  ),
                ] else ...[
                  if (task.canAssign)
                    UtenButton(
                      onPressed: locked || _workshopId == null
                          ? null
                          : () => _execute('assignment', {
                              'workshopDepartmentId': _workshopId,
                              'responsibleEmployeeId': _responsibleId,
                            }),
                      child: const Text('保存分配'),
                    ),
                  if (task.canStart)
                    UtenButton(
                      onPressed: locked || _warehouseId == null
                          ? null
                          : () => _execute('start', {
                              'warehouseId': _warehouseId,
                            }),
                      child: const Text('确认实物并开工'),
                    ),
                  if (task.canReport)
                    UtenButton(
                      onPressed:
                          locked ||
                              _quantity.text.trim().isEmpty ||
                              _evidence.text.trim().isEmpty
                          ? null
                          : () => _execute('reports', {
                              'quantity': _quantity.text.trim(),
                              'operation': 'LASER',
                              'evidence': _evidence.text.trim(),
                            }),
                      child: const Text('提交加工报工'),
                    ),
                  if (task.data['canCancelStart'] == true)
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: locked
                          ? null
                          : () => _execute('cancel-start', {}),
                      child: const Text('撤销开工'),
                    ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return Offstage(
      offstage: _panelOpen,
      child: UtenFloatingWindow(
        key: widget.windowKey,
        title: '交付件加工任务',
        initialSize: const Size(1180, 720),
        minSize: const Size(320, 340),
        onClose: () {
          if (!_busy) widget.onClose();
        },
        headerTrailing: const UtenFieldHintIcon(
          info: '按本人车间分配范围显示；只读全量权限不扩大开工或报工范围。',
        ),
        body: Column(
          children: [
            Expanded(
              child: MasterDataTableView<DeliveryProcessingTask>(
                tableKey: 'production.delivery-processing.tasks',
                items: page?.items ?? const [],
                facets: const {},
                nullCounts: const {},
                filters: _filters,
                headerFilterScopeDescription: '表头筛选当前完整加工任务；工具栏按物料或来源单号查询',
                onFilterChanged: (key, value) =>
                    _update(() => _filters[key] = value),
                idOf: (task) => task.id,
                onRowTap: _select,
                error: _error,
                onRetry: () => unawaited(_load()),
                emptyMessage: '暂无本人可办理的交付件加工任务',
                toolbarActions: [
                  SizedBox(
                    width: 240,
                    child: UtenSearchBar(
                      controller: _search,
                      hint: '查找物料或来源出货单',
                      onSubmitted: (_) => unawaited(_load()),
                    ),
                  ),
                  UtenButton(
                    type: UtenButtonType.tonal,
                    onPressed: _busy ? null : _load,
                    child: const Text('刷新'),
                  ),
                ],
                columns: [
                  MasterColumnDef(
                    key: 'action',
                    label: '办理',
                    width: 90,
                    value: (task) => _repository.pending.containsKey(task.id)
                        ? '结果待核对'
                        : '查看',
                    cellBuilder: (_, task) => TextButton(
                      onPressed: _busy ? null : () => _select(task),
                      child: Text(
                        _repository.pending.containsKey(task.id)
                            ? '结果待核对'
                            : '办理',
                      ),
                    ),
                  ),
                  MasterColumnDef(
                    key: 'status',
                    label: '状态',
                    width: 110,
                    value: _status,
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'name',
                    label: '物料名称',
                    width: 220,
                    value: (task) => task.name,
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'code',
                    label: '编号',
                    width: 130,
                    // 2026-11-11 口径：编号/单号列补就地排序（完整任务快照，按值筛选此前已开）。
                    sortable: true,
                    value: (task) => task.code,
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'targets',
                    label: '实际加工对象',
                    width: 260,
                    value: (task) => task.processingTargets
                        .map(
                          (target) =>
                              '${target.code} ${target.name} ${target.quantity} ${target.unit}',
                        )
                        .join('；'),
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'shipment',
                    label: '来源出货单',
                    width: 150,
                    sortable: true,
                    value: (task) => task.value('shipmentNo'),
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'required',
                    label: '要求数量',
                    width: 130,
                    value: (task) => '${task.required} ${task.unit}',
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'completed',
                    label: '已完成数量',
                    width: 130,
                    value: (task) => '${task.completed} ${task.unit}',
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'remaining',
                    label: '待加工数量',
                    width: 130,
                    value: (task) => '${task.remaining} ${task.unit}',
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'warehouse',
                    label: '实物来源仓',
                    width: 150,
                    value: (task) => task.value('warehouseName'),
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'workshop',
                    label: '生产车间',
                    width: 150,
                    value: (task) => task.value('workshopName'),
                    filterFromRows: true,
                  ),
                  MasterColumnDef(
                    key: 'owner',
                    label: '负责人',
                    width: 130,
                    value: (task) => task.value('responsibleName'),
                    filterFromRows: true,
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
