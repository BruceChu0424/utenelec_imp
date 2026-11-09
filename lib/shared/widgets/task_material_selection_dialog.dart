// 任务物料弹窗(选物料去领料)：「我的车间任务」与「委外任务中心」物料列点开的同一个弹窗壳，
// 唯一维护入口。
//
// 只读两件服务端事实：逐种物料明细([loadMaterials]) 与每种物料交给领料页的来源
// ([loadDrawTargets]，车间是另一次领料预览，委外由同一次明细读出)。勾选 = 选出要去领的物料，
// 本弹窗不提交任何写操作——「去领料（N 种）」把所选物料的来源交回调用方，由各自的领料页
// 逐行填写数量、核对库存后提交(分批领料由领料页完成)。
//
// 守住读取的身份与代次：账号/会话/读取范围一变就整体退休(关闭弹窗、不发布旧结果)；两次读取
// 先后到达都不会误清已保留的勾选。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_busy_overlay.dart';
import '../../components/feedback/uten_dialog.dart';
import '../../core/network/read_scope_revision.dart';
import '../../core/theme/uten_tokens.dart';
import '../../core/ui/human_error_message.dart';
import '../auth/account_action_owner.dart';
import 'task_material_cards.dart';

/// 打开任务物料弹窗；返回所选物料交给领料页的来源 id，取消/退休返回 null。
Future<Set<String>?> showTaskMaterialSelectionDialog<T>(
  BuildContext context, {
  required TaskMaterialSelectionDialog<T> dialog,
}) =>
    UtenDialog.showAndWaitForExit<Set<String>>(context, builder: (_) => dialog);

class TaskMaterialSelectionDialog<T> extends ConsumerStatefulWidget {
  const TaskMaterialSelectionDialog({
    super.key,
    required this.dialogKey,
    required this.title,
    required this.compactTitle,
    required this.keyPrefix,
    required this.cardKeyPrefix,
    required this.selectKeyPrefix,
    required this.loadMaterials,
    required this.entryOf,
    required this.isShort,
    required this.canRequestDraw,
    this.loadDrawTargets,
    this.drawTargetsOf,
    this.isCurrent,
    this.ownerChanges,
  }) : assert(
         (loadDrawTargets == null) != (drawTargetsOf == null),
         '领料来源要么另读一次，要么从物料明细推出',
       );

  final Key dialogKey;

  /// 标题带任务身份(不另写副标题)；矮窗口用 [compactTitle] 省地方。
  final String title;
  final String compactTitle;

  /// 控件 key 前缀：`$keyPrefix-select-all` / `-continue` / `-facts-retry` /
  /// `-preview-retry` / `-preview-loading`。
  final String keyPrefix;
  final String cardKeyPrefix;
  final String selectKeyPrefix;

  final Future<List<T>> Function(WidgetRef ref) loadMaterials;
  final TaskMaterialEntry Function(T material) entryOf;

  /// 缺料筛选：本物料还有缺口。
  final bool Function(T material) isShort;

  /// 账号与任务允许从这里去领料(调用方的权限门)。为假时只读，不读领料来源。
  final bool canRequestDraw;

  /// 另读一次领料来源：物料 id → 交给领料页的来源 id。
  final Future<Map<String, Set<String>>> Function(WidgetRef ref)?
  loadDrawTargets;

  /// 从物料明细直接推出领料来源(同一次读取已带「本次可领」)。
  final Map<String, Set<String>> Function(List<T> materials)? drawTargetsOf;

  final bool Function()? isCurrent;
  final Listenable? ownerChanges;

  @override
  ConsumerState<TaskMaterialSelectionDialog<T>> createState() =>
      _TaskMaterialSelectionDialogState<T>();
}

class _TaskMaterialSelectionDialogState<T>
    extends ConsumerState<TaskMaterialSelectionDialog<T>> {
  late final AccountActionOwner _owner;
  ModalRoute<Set<String>>? _route;
  List<T>? _materials;
  Map<String, Set<String>>? _targets;
  final Set<String> _selectedIds = {};
  bool _loading = true;
  bool _targetsLoading = false;
  bool _invalidated = false;
  String? _materialError;
  String? _targetsError;

  /// 重试按钮的加载弹窗标题；非空时弹窗内不再叠加自己的进度条(同一动作只一个等待件)。
  String? _retrying;
  String _filter = 'all';
  int _materialsGeneration = 0;
  int _targetsGeneration = 0;

  String _key(String name) => '${widget.keyPrefix}-$name';

  bool get _separateTargets => widget.loadDrawTargets != null;

  @override
  void initState() {
    super.initState();
    _owner = AccountActionOwner(
      ref,
      isCurrent: widget.isCurrent,
      targetChanges: widget.ownerChanges,
      onInvalidated: _invalidate,
    );
    ref.listenManual(readScopeRevisionProvider, (previous, next) {
      if (previous != next) _invalidate();
    });
    _loadMaterials();
    if (widget.canRequestDraw && _separateTargets) _loadTargets();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of<Set<String>>(context);
  }

  @override
  void dispose() {
    _owner.dispose();
    super.dispose();
  }

  bool get _current => mounted && !_invalidated && _owner.isCurrent;

  void _invalidate() {
    if (!mounted || _invalidated) return;
    setState(() {
      _invalidated = true;
      _materials = null;
      _targets = null;
      _selectedIds.clear();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final route = _route;
      if (mounted && route != null && route.isActive) {
        route.navigator?.removeRoute(route);
      }
    });
  }

  Future<void> _loadMaterials() async {
    final generation = ++_materialsGeneration;
    setState(() {
      _loading = true;
      _materialError = null;
    });
    try {
      final materials = await widget.loadMaterials(ref);
      if (!_current || generation != _materialsGeneration) return;
      setState(() {
        _materials = materials;
        if (widget.canRequestDraw && !_separateTargets) {
          _targets = widget.drawTargetsOf!(materials);
        }
        _retainValidSelection();
      });
    } catch (caughtError) {
      if (!_current || generation != _materialsGeneration) return;
      setState(
        () => _materialError = humanErrorMessage(caughtError) ?? '物料明细加载失败',
      );
    } finally {
      if (_current && generation == _materialsGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _loadTargets() async {
    final generation = ++_targetsGeneration;
    setState(() {
      _targetsLoading = true;
      _targetsError = null;
    });
    try {
      final targets = await widget.loadDrawTargets!(ref);
      if (!_current || generation != _targetsGeneration) return;
      setState(() {
        _targets = targets;
        _retainValidSelection();
      });
    } catch (caughtError) {
      if (!_current || generation != _targetsGeneration) return;
      setState(
        () => _targetsError = humanErrorMessage(caughtError) ?? '可领物料核对失败',
      );
    } finally {
      if (_current && generation == _targetsGeneration) {
        setState(() => _targetsLoading = false);
      }
    }
  }

  /// 重试按钮按全站口径接入加载弹窗；读取本身仍守代次，迟到结果不发布。
  Future<void> _retry(String title, Future<void> Function() read) async {
    if (_retrying != null || !_current) return;
    setState(() => _retrying = title);
    try {
      await read();
    } finally {
      if (mounted) setState(() => _retrying = null);
    }
  }

  /// 可勾选 = 服务端给了领料来源、且确实是本任务明细里的物料。
  Set<String> get _selectableIds {
    final materials = _materials;
    final targets = _targets;
    if (materials == null || targets == null) return const {};
    final ids = {for (final material in materials) widget.entryOf(material).id};
    return {
      for (final entry in targets.entries)
        if (entry.value.isNotEmpty && ids.contains(entry.key)) entry.key,
    };
  }

  void _retainValidSelection() {
    // 两次读取可能先后到达；任一权威输入未到时不清掉已保留的勾选。
    if (_materials != null && _targets != null) {
      _selectedIds.retainAll(_selectableIds);
    }
  }

  bool get _canSelect =>
      widget.canRequestDraw &&
      !_loading &&
      !_targetsLoading &&
      _retrying == null &&
      _materialError == null &&
      _targetsError == null &&
      _current;

  void _continueToDraw() {
    if (!_canSelect || _selectedIds.isEmpty) return;
    final ids = {for (final id in _selectedIds) ...?_targets?[id]};
    if (ids.isNotEmpty) Navigator.of(context).pop(ids);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shortWindow =
        MediaQuery.sizeOf(context).height -
            MediaQuery.viewInsetsOf(context).bottom <
        480;
    final selectable = _selectableIds;
    final materials = _materials ?? <T>[];
    final visibleMaterials = materials
        .where(
          (material) => switch (_filter) {
            'drawable' => selectable.contains(widget.entryOf(material).id),
            'short' => widget.isShort(material),
            _ => true,
          },
        )
        .toList(growable: false);
    final allSelected =
        selectable.isNotEmpty && selectable.every(_selectedIds.contains);
    final retrying = _retrying;
    return UtenAlertDialog(
      key: widget.dialogKey,
      maxWidth: 1040,
      scrollable: false,
      insetPadding: shortWindow ? const EdgeInsets.all(UtenSpacing.s12) : null,
      titlePadding: shortWindow ? const EdgeInsets.all(UtenSpacing.s12) : null,
      contentPadding: shortWindow
          ? const EdgeInsets.fromLTRB(12, 0, 12, 8)
          : null,
      actionsPadding: shortWindow ? const EdgeInsets.all(UtenSpacing.s8) : null,
      title: Semantics(
        header: true,
        child: Text(shortWindow ? widget.compactTitle : widget.title),
      ),
      headingIcon: shortWindow ? null : Icons.inventory_2_outlined,
      showCloseButton: true,
      content: _invalidated
          ? const SizedBox.shrink()
          : SizedBox(
              width: 1040,
              height: 560,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (retrying != null) UtenBusyOverlay(title: retrying),
                  if (_materials != null) ...[
                    Wrap(
                      spacing: UtenSpacing.s8,
                      runSpacing: UtenSpacing.s4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final (value, label) in [
                          ('all', '全部 ${materials.length}'),
                          if (widget.canRequestDraw)
                            ('drawable', '可领 ${selectable.length}'),
                          (
                            'short',
                            '缺料 ${materials.where(widget.isShort).length}',
                          ),
                        ])
                          ChoiceChip(
                            label: Text(label),
                            selected: _filter == value,
                            onSelected: (_) => setState(() => _filter = value),
                          ),
                        if (widget.canRequestDraw)
                          TextButton.icon(
                            key: Key(_key('select-all')),
                            onPressed: !_canSelect || selectable.isEmpty
                                ? null
                                : () => setState(() {
                                    if (allSelected) {
                                      _selectedIds.clear();
                                    } else {
                                      _selectedIds.addAll(selectable);
                                    }
                                  }),
                            icon: Icon(
                              allSelected
                                  ? Icons.check_box_rounded
                                  : Icons.check_box_outline_blank_rounded,
                            ),
                            label: Text(allSelected ? '取消全选' : '全选可领'),
                          ),
                      ],
                    ),
                    const SizedBox(height: UtenSpacing.s12),
                  ],
                  Expanded(
                    child: _loading
                        ? (retrying != null
                              ? const SizedBox.shrink()
                              : const Padding(
                                  padding: EdgeInsets.all(UtenSpacing.s24),
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                ))
                        : _materialError != null
                        ? _retryRow(
                            _materialError!,
                            () => _retry('正在重新读取物料明细', _loadMaterials),
                            key: Key(_key('facts-retry')),
                          )
                        : visibleMaterials.isEmpty
                        ? Padding(
                            padding: const EdgeInsets.all(UtenSpacing.s24),
                            child: Text(
                              materials.isEmpty ? '本任务无需领料' : '暂无对应物料',
                              style: theme.textTheme.bodyMedium,
                              textAlign: TextAlign.center,
                            ),
                          )
                        : TaskMaterialCards(
                            entries: [
                              for (final material in visibleMaterials)
                                widget.entryOf(material),
                            ],
                            keyPrefix: widget.cardKeyPrefix,
                            selectKeyPrefix: widget.selectKeyPrefix,
                            showAllInitially: true,
                            scrollable: true,
                            selectableIds: _canSelect ? selectable : const {},
                            selectedIds: _selectedIds,
                            onSelectedIdsChanged: !widget.canRequestDraw
                                ? null
                                : (next) {
                                    if (!_canSelect) return;
                                    setState(() {
                                      _selectedIds
                                        ..clear()
                                        ..addAll(next.intersection(selectable));
                                    });
                                  },
                          ),
                  ),
                  if (_targetsLoading && retrying == null)
                    LinearProgressIndicator(key: Key(_key('preview-loading'))),
                  if (_targetsError != null)
                    _retryRow(
                      _targetsError!,
                      () => _retry('正在重新核对可领物料', _loadTargets),
                      key: Key(_key('preview-retry')),
                    ),
                ],
              ),
            ),
      actions: [
        UtenButton(
          type: UtenButtonType.secondary,
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        if (widget.canRequestDraw)
          UtenButton(
            key: Key(_key('continue')),
            icon: Icons.inventory_2_outlined,
            onPressed: _canSelect && _selectedIds.isNotEmpty
                ? _continueToDraw
                : null,
            child: Text('去领料（${_selectedIds.length} 种）'),
          ),
      ],
    );
  }

  Widget _retryRow(String message, VoidCallback onRetry, {required Key key}) =>
      Row(
        children: [
          Expanded(child: Text(message)),
          TextButton(key: key, onPressed: onRetry, child: const Text('重试')),
        ],
      );
}
