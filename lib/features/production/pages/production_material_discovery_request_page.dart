import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';
import '../../../core/router/route_names.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/inputs/uten_table_cell_action.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../basic_data/models/goods_node.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../models/production_execution_workbench.dart';
import '../repositories/production_material_discovery_request_repository.dart';
import '../repositories/production_execution_workbench_repository.dart';

/// Optional workshop suggestions stay attached to one exact work order.
class DiscoveryRequestMaterialRow {
  DiscoveryRequestMaterialRow({required this.id, required this.task});

  final String id;
  final ProductionExecutionWorkbenchSegment task;
  final values = <String, dynamic>{};
  final qty = TextEditingController();

  bool get isEmpty => values['goodsId'] == null && qty.text.trim().isEmpty;
  String label(String field) {
    final value = (values[field] as String?)?.trim();
    return value == null || value.isEmpty ? '—' : value;
  }

  void selectGoods(GoodsListItem goods) {
    final sameGoods = values['goodsId'] == goods.id;
    if (!sameGoods || values['unitId'] != goods.unitId) qty.clear();
    values.addAll({
      'goodsId': goods.id,
      'goodsCode': goods.code,
      'goodsName': goods.name,
      'spec': goods.spec,
      'colorId': sameGoods ? values['colorId'] : goods.colorId,
      'colorName': sameGoods ? values['colorName'] : goods.colorName,
      'unitId': goods.unitId,
      'unitName': goods.unitName,
      'stockPlace': goods.stockPlace,
    });
  }

  Map<String, dynamic> toRequest() {
    if (values['goodsId'] == null || values['unitId'] == null) {
      throw const FormatException('请选择材料，并确认货品已设置基本单位');
    }
    final input = qty.text.trim();
    final amount = double.tryParse(input);
    if (input.isNotEmpty &&
        (amount == null ||
            !amount.isFinite ||
            amount <= 0 ||
            !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(input))) {
      throw const FormatException('领料数量须大于 0，最多 4 位小数；暂不确定时可以留空');
    }
    return {
      'goodsId': values['goodsId'],
      'colorId': values['colorId'],
      'unitId': values['unitId'],
      if (input.isNotEmpty) 'qty': input,
    };
  }

  void dispose() => qty.dispose();
}

class ProductionMaterialDiscoveryRequestPage extends ConsumerStatefulWidget {
  const ProductionMaterialDiscoveryRequestPage({
    super.key,
    this.tasks = const [],
    this.segmentIds = const [],
    this.segmentCodes = const [],
  });
  final List<ProductionExecutionWorkbenchSegment> tasks;
  final List<String> segmentIds;
  final List<String> segmentCodes;
  static const route = '/production/material-discovery-request';
  static String location(List<ProductionExecutionWorkbenchSegment> tasks) =>
      Uri(
        path: route,
        queryParameters: {
          'segmentIds': tasks.map((task) => task.segmentId).join(','),
          'segmentCodes': tasks.map((task) => task.segmentCode).join(','),
        },
      ).toString();
  @override
  ConsumerState<ProductionMaterialDiscoveryRequestPage> createState() =>
      _RequestState();
}

class _RequestState
    extends ConsumerState<ProductionMaterialDiscoveryRequestPage>
    with FormDraftMixin<ProductionMaterialDiscoveryRequestPage> {
  List<ProductionExecutionWorkbenchSegment> _tasks = const [];
  bool _loadingSources = false;
  bool _sourceChanged = false;
  bool _submissionPending = false;
  bool _saving = false, _uncertain = false;
  final _completed = <String>{};
  final _rows = <DiscoveryRequestMaterialRow>[];
  final _submittedItems = <String, List<Map<String, dynamic>>>{};
  final _keys = <String, String>{};
  int _nextRow = 0;
  String? _error;

  @override
  bool get formDraftBusy => _saving || _uncertain;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.productionDiscovery.spec(
    title: '新建车间材料领料申请',
    route: _tasks.isEmpty
        ? Uri(
            path: ProductionMaterialDiscoveryRequestPage.route,
            queryParameters: {
              'segmentIds': widget.segmentIds.join(','),
              'segmentCodes': widget.segmentCodes.join(','),
            },
          ).toString()
        : ProductionMaterialDiscoveryRequestPage.location(_tasks),
  );
  @override
  Iterable<Listenable> get formDraftListenables => _rows.map((row) => row.qty);
  @override
  Map<String, dynamic> captureFormDraft() => {
    'tasks': [
      for (final task in _tasks)
        {
          'segmentId': task.segmentId,
          'segmentCode': task.segmentCode,
          'planId': task.planId,
          'planNo': task.planNo,
          'lockVersion': task.lockVersion,
          'workshopDepartmentId': task.workshopDepartmentId,
          'workshopName': task.workshopName,
          'productCode': task.productCode,
          'productName': task.productName,
          'productColorName': task.productColorName,
          'productUnitName': task.productUnitName,
          'plannedQty': task.plannedQty,
        },
    ],
    'rows': [
      for (final row in _rows)
        {
          'id': row.id,
          'segmentId': row.task.segmentId,
          'values': row.values,
          'qty': row.qty.text,
        },
    ],
    'nextRow': _nextRow,
    'completed': _completed.toList()..sort(),
    'submittedItems': _submittedItems,
    'keys': _keys,
    'uncertain': _uncertain || _submissionPending,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final saved = draftMaps(
      data['tasks'],
    ).map(ProductionExecutionWorkbenchSegment.fromJson).toList();
    _uncertain = data['uncertain'] == true;
    _sourceChanged =
        !_uncertain &&
        saved.any(
          (old) => !_tasks.any(
            (fresh) =>
                fresh.segmentId == old.segmentId &&
                fresh.lockVersion == old.lockVersion,
          ),
        );
    _tasks = saved;
    for (final row in _rows) {
      row.dispose();
    }
    _rows.clear();
    for (final item in draftMaps(data['rows'])) {
      final task = _tasks
          .where((task) => task.segmentId == item['segmentId'])
          .firstOrNull;
      if (task == null) throw const FormatException('材料行缺少原车间任务，无法安全恢复');
      _rows.add(
        DiscoveryRequestMaterialRow(id: draftText(item, 'id'), task: task)
          ..values.addAll(draftMap(item['values']))
          ..qty.text = draftText(item, 'qty'),
      );
    }
    _nextRow = (data['nextRow'] as num?)?.toInt() ?? _rows.length;
    _completed
      ..clear()
      ..addAll(draftStrings(data['completed']));
    _submittedItems
      ..clear()
      ..addAll({
        for (final entry in draftMap(data['submittedItems']).entries)
          entry.key: draftMaps(entry.value),
      });
    _keys
      ..clear()
      ..addAll({
        for (final entry in draftMap(data['keys']).entries)
          entry.key: entry.value as String,
      });
    _error = _sourceChanged
        ? '原车间任务已变化，草稿内容保留，请返回任务中心核对来源后重新申请。'
        : _uncertain
        ? '上次提交结果尚未确认，请重试原申请；已完成的任务不会重复提交。'
        : null;
    if (mounted) setState(() {});
  }

  bool get _canWrite =>
      ref.read(isSuperAdminProvider) ||
      (ref
              .read(currentPermissionsProvider)
              .contains(Perm.productionExecutionView) &&
          ref
              .read(currentPermissionsProvider)
              .contains(Perm.productionExecutionStart));

  bool _editable(DiscoveryRequestMaterialRow row) =>
      _canWrite &&
      !_saving &&
      !_uncertain &&
      !_completed.contains(row.task.segmentId);

  @override
  void initState() {
    super.initState();
    _tasks = widget.tasks;
    _loadingSources = _tasks.isEmpty && widget.segmentIds.isNotEmpty;
    for (final task in widget.tasks) {
      _rows.add(_newRow(task));
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _initializeSources());
  }

  Future<void> _initializeSources() async {
    if (_tasks.isEmpty && widget.segmentIds.isNotEmpty) {
      setState(() => _loadingSources = true);
      try {
        if (widget.segmentIds.length > 50 ||
            widget.segmentCodes.length != widget.segmentIds.length) {
          throw const FormatException('车间任务来源参数不完整');
        }
        final repository = ref.read(
          productionExecutionWorkbenchRepositoryProvider,
        );
        final loaded = <ProductionExecutionWorkbenchSegment>[];
        for (var index = 0; index < widget.segmentIds.length; index++) {
          final page = await repository.workshopTasks(
            segmentCode: widget.segmentCodes[index],
            size: 200,
          );
          final task = page.items
              .where((row) => row.segmentId == widget.segmentIds[index])
              .firstOrNull;
          if (task == null || !task.canRequestMaterialDiscovery) {
            throw const FormatException('原车间任务已变化或当前账号无权申请领料');
          }
          loaded.add(task);
        }
        if (!mounted) return;
        _tasks = loaded;
        for (final task in loaded) {
          _rows.add(_newRow(task));
        }
      } catch (error) {
        if (mounted) {
          setState(() {
            _sourceChanged = true;
            _error = '$error';
          });
        }
      } finally {
        if (mounted) setState(() => _loadingSources = false);
      }
    }
    if (mounted) await initializeFormDraft();
  }

  DiscoveryRequestMaterialRow _newRow(
    ProductionExecutionWorkbenchSegment task,
  ) => DiscoveryRequestMaterialRow(
    id: '${task.segmentId}-${_nextRow++}',
    task: task,
  );

  @override
  void dispose() {
    for (final row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  Future<void> _pickGoods(DiscoveryRequestMaterialRow row) async {
    if (!_editable(row)) return;
    final goods = await showUtenGoodsPicker(
      context,
      ref,
      scope: UtenGoodsPickerScope.component,
    );
    if (!mounted || goods == null || !_rows.contains(row) || !_editable(row)) {
      return;
    }
    if (goods.unitId == null) {
      context.appWarning(
        AppLocalizations.of(context).materialDiscoveryMissingUnit,
      );
      return;
    }
    setState(() => row.selectGoods(goods));
  }

  void _addRow(DiscoveryRequestMaterialRow row) {
    if (!_editable(row)) return;
    if (_rows
            .where((item) => item.task.segmentId == row.task.segmentId)
            .length >=
        100) {
      context.appWarning('每个车间任务最多填写 100 行材料');
      return;
    }
    setState(() => _rows.insert(_rows.indexOf(row) + 1, _newRow(row.task)));
  }

  void _removeRow(DiscoveryRequestMaterialRow row) {
    if (!_editable(row)) return;
    setState(() {
      if (_rows
              .where((item) => item.task.segmentId == row.task.segmentId)
              .length ==
          1) {
        row.values.clear();
        row.qty.clear();
      } else {
        _rows.remove(row);
        row.dispose();
      }
    });
  }

  void _prepareSubmission() {
    if (_tasks.isEmpty) throw const FormatException('请返回我的车间任务选择需要领料的任务');
    for (final task in _tasks) {
      if (_completed.contains(task.segmentId)) continue;
      final materials = <Map<String, dynamic>>[];
      final identities = <String>{};
      for (final row in _rows.where(
        (row) => row.task.segmentId == task.segmentId,
      )) {
        if (row.isEmpty) continue;
        final material = row.toRequest();
        if (!identities.add(
          jsonEncode([material['goodsId'], material['colorId']]),
        )) {
          throw FormatException('${task.segmentCode} 的同材料、同颜色重复，请合并数量');
        }
        materials.add(material);
      }
      _submittedItems[task.segmentId] = materials;
      _keys[task.segmentId] = businessIdempotencyKey(
        'discovery-request',
        jsonEncode([task.segmentId, task.lockVersion, materials]),
      );
    }
  }

  Future<void> _submit() async {
    if (_saving || _loadingSources || _sourceChanged || !_canWrite) return;
    if (!_uncertain) {
      try {
        _prepareSubmission();
      } on FormatException catch (e) {
        setState(() => _error = e.message);
        context.appWarning(e.message);
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      _submissionPending = true;
      await saveFormDraftNow();
      for (final task in _tasks) {
        if (_completed.contains(task.segmentId)) continue;
        await ref
            .read(productionMaterialDiscoveryRequestRepositoryProvider)
            .request(
              task.segmentId,
              task.lockVersion,
              _keys[task.segmentId]!,
              items: _submittedItems[task.segmentId]!,
            );
        _completed.add(task.segmentId);
        await saveFormDraftNow();
      }
      await completeFormDraft();
      if (!mounted) return;
      context.appSuccess(
        AppLocalizations.of(context).materialDiscoveryRequestSent,
      );
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop(true);
      } else {
        context.go(RouteName.productionWorkshopTasks);
      }
    } catch (e) {
      if (mounted) {
        final rejected =
            e is ApiException &&
            e.httpStatus != null &&
            e.httpStatus! >= 400 &&
            e.httpStatus! < 500;
        context.appApiError(e);
        setState(() {
          _uncertain = !rejected;
          _error = rejected
              ? e.message
              : AppLocalizations.of(context).materialDiscoveryUncertain;
        });
      }
    } finally {
      _submissionPending = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  List<MasterColumnDef<DiscoveryRequestMaterialRow>> get _columns => [
    MasterColumnDef(
      key: 'submissionStatus',
      label: '提交状态',
      width: 72,
      value: (row) => _completed.contains(row.task.segmentId)
          ? '已提交'
          : (_uncertain || _sourceChanged ? '待核对' : '待提交'),
    ),
    MasterColumnDef(
      key: 'task',
      label: '车间任务',
      width: 150,
      value: (row) => row.task.segmentCode,
    ),
    MasterColumnDef(
      key: 'planNo',
      label: '生产计划',
      width: 150,
      value: (row) => row.task.planNo,
    ),
    MasterColumnDef(
      key: 'workshop',
      label: '领料车间',
      width: 140,
      value: (row) => row.task.workshopName ?? '—',
    ),
    MasterColumnDef(
      key: 'productName',
      label: '生产货品',
      width: 160,
      value: (row) => row.task.productName ?? '—',
    ),
    MasterColumnDef(
      key: 'productCode',
      label: '货品编号',
      width: 120,
      value: (row) => row.task.productCode ?? '—',
    ),
    MasterColumnDef(
      key: 'productColor',
      label: '货品颜色',
      width: 100,
      value: (row) => row.task.productColorName ?? '—',
    ),
    MasterColumnDef(
      key: 'plannedQty',
      label: '计划产量',
      width: 120,
      value: (row) =>
          '${row.task.plannedQty} ${row.task.productUnitName ?? ''}',
    ),
    MasterColumnDef(
      key: 'goodsName',
      label: '领料材料（选填）',
      width: 200,
      value: (row) => row.values['goodsName'] as String? ?? '',
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => UtenTableCellAction(
        key: ValueKey('discovery-request-goods-${row.id}'),
        label: row.values['goodsName'] as String? ?? '选择材料（可留空）',
        onPressed: _editable(row) ? () => _pickGoods(row) : null,
      ),
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: '材料编号',
      width: 120,
      value: (row) => row.label('goodsCode'),
    ),
    MasterColumnDef(
      key: 'colorName',
      label: '材料颜色',
      width: 130,
      value: (row) => row.label('colorName'),
    ),
    MasterColumnDef(
      key: 'spec',
      label: '规格',
      width: 140,
      value: (row) => row.label('spec'),
    ),
    MasterColumnDef(
      key: 'unitName',
      label: '单位',
      width: 80,
      value: (row) => row.label('unitName'),
    ),
    MasterColumnDef(
      key: 'stockPlace',
      label: '参考库位',
      info: '货品资料中的参考库位；实际发料仓由仓库确认。',
      width: 130,
      value: (row) => row.label('stockPlace'),
    ),
    MasterColumnDef(
      key: 'qty',
      label: '领料数量（选填）',
      width: 170,
      type: 'number',
      value: (row) => row.qty.text,
      exactValueOf: (row) => row.qty.text,
      exactListenableOf: (row) => row.qty,
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => TextField(
        key: ValueKey('discovery-request-qty-${row.id}'),
        controller: row.qty,
        readOnly: !_editable(row),
        enabled: row.values['goodsId'] != null,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: const UtenInputDecoration(
          InputDecoration(isDense: true, hintText: '可由仓库补充'),
        ),
      ),
    ),
    MasterColumnDef(
      key: 'actions',
      label: '材料行',
      width: 136,
      value: (_) => '',
      cellBuilderHandlesSemantics: true,
      // 2026-10-06 行高统一口径：编辑表行高由 39 高的输入控件定，行内图标钮
      // 关掉 IconButton 主题的最小 40 尺寸，改为 16 图标紧凑形态。
      cellBuilder: (_, row) => Wrap(
        children: [
          IconButton(
            key: ValueKey('discovery-request-add-${row.id}'),
            tooltip: '为此任务添加材料',
            onPressed: _editable(row) ? () => _addRow(row) : null,
            style: IconButton.styleFrom(
              minimumSize: Size.zero,
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            iconSize: 16,
            icon: const Icon(Icons.add),
          ),
          IconButton(
            key: ValueKey('discovery-request-remove-${row.id}'),
            tooltip: '清除此行材料',
            onPressed: _editable(row) ? () => _removeRow(row) : null,
            style: IconButton.styleFrom(
              minimumSize: Size.zero,
              padding: EdgeInsets.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
            iconSize: 16,
            icon: const Icon(Icons.remove_circle_outline),
          ),
        ],
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return withFormDraft(
      PopScope(
        canPop: !_loadingSources && !_saving && !_uncertain,
        child: Scaffold(
          appBar: UtenAppBar(
            title: l10n.materialDiscoveryRequestTitle,
            showBackButton: true,
          ),
          body: Stack(
            children: [
              UtenContentContainer(
                child: UtenCollapsingHeaderScrollView(
                  collapsingHeader: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Theme(
                          data: theme.copyWith(
                            textTheme: theme.textTheme.copyWith(
                              bodySmall: theme.textTheme.bodySmall?.copyWith(
                                color: UtenInlineNoticeLevel.error.accent,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          child: const UtenInlineNotice(
                            key: Key(
                              'discovery-request-missing-material-notice',
                            ),
                            level: UtenInlineNoticeLevel.error,
                            message: '下方工单尚缺领料信息。材料和数量可选填；不清楚可直接提交，由仓库补充。',
                          ),
                        ),
                        if (!_canWrite) const Text('当前账号没有提交车间领料申请的权限'),
                        if (_error != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              _error!,
                              key: const Key('discovery-request-error'),
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  body: MasterDataTableView<DiscoveryRequestMaterialRow>(
                    tableKey:
                        'features.production.pages.production_material_discovery_request_page.RequestState.build.1',
                    key: const Key('discovery-request-table'),
                    primary: true,
                    enableTextSelection: false,
                    columns: _columns,
                    items: List.unmodifiable(_rows),
                    rowKeyOf: (row) => row.id,
                    facets: const {},
                    nullCounts: const {},
                    filters: const {},
                    onFilterChanged: (_, _) {},
                    bottomContentPadding:
                        UtenFloatingActionGroup.scrollClearance,
                    showFullscreenToggle: false,
                    emptyMessage: '请返回我的车间任务选择需要领料的任务',
                  ),
                ),
              ),
              if (_loadingSources || _saving)
                UtenBusyOverlay(
                  semanticsKey: Key(
                    _loadingSources
                        ? 'discovery-request-loading'
                        : 'discovery-request-saving',
                  ),
                  title: _loadingSources ? '正在加载领料申请' : '正在提交领料申请',
                  description: _loadingSources
                      ? '正在核对所选工单及领料信息。'
                      : '正在提交所选工单，请勿重复操作。',
                ),
            ],
          ),
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
          floatingActionButton: UtenButton(
            key: const Key('discovery-request-submit'),
            type: UtenButtonType.danger,
            isLoading: _saving,
            onPressed:
                _canWrite &&
                    _tasks.isNotEmpty &&
                    !_loadingSources &&
                    !_sourceChanged
                ? _submit
                : null,
            child: Text(_uncertain ? '重试提交申请' : l10n.materialDiscoverySend),
          ),
        ),
      ),
    );
  }
}
