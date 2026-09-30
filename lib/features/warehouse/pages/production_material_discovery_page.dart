import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_field_codec.dart';
import '../models/warehouse_form_draft_codec.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/idempotency_key.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/models/production_material_discovery.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../basic_data/models/goods_node.dart';
import '../providers/warehouse_count_refresh.dart';
import '../repositories/production_material_discovery_repository.dart';

class DiscoveryMaterialRow extends EditableGridRow {
  DiscoveryMaterialRow({Map<String, dynamic>? initial}) {
    if (initial != null) {
      values.addAll(initial);
      qty.text = initial['qty']?.toString() ?? '';
    }
  }
  final values = <String, dynamic>{};
  static int _nextId = 0;
  final String id = 'discovery-material-${_nextId++}';
  final qty = TextEditingController();
  String label(String field) {
    final value = (values[field] as String?)?.trim();
    return value == null || value.isEmpty ? '—' : value;
  }

  DiscoveryMaterialRow clone() =>
      DiscoveryMaterialRow(initial: {...values, 'qty': qty.text});
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

  String? get quantityError {
    final input = qty.text.trim();
    final amount = double.tryParse(input);
    if (input.isEmpty) return '需要填写领料数量';
    if (amount == null ||
        !amount.isFinite ||
        amount <= 0 ||
        !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(input)) {
      return '数量须大于 0，最多 4 位小数';
    }
    return null;
  }

  List<String> get validationErrors => [
    if (values['goodsId'] == null) '需要填写材料',
    if (values['goodsId'] != null && values['unitId'] == null) '材料缺少基本单位',
    ?quantityError,
    if (values['warehouseId'] == null) '需要选择实际发料仓',
  ];
  Map<String, dynamic>? toRequest() {
    if (validationErrors.isNotEmpty) {
      return null;
    }
    return {
      'goodsId': values['goodsId'],
      'colorId': values['colorId'],
      'unitId': values['unitId'],
      'warehouseId': values['warehouseId'],
      'qty': qty.text.trim(),
    };
  }

  @override
  void dispose() {
    qty.dispose();
    super.dispose();
  }
}

/// The request defines a frozen material set; the resulting DRAW still needs issue.
class ProductionMaterialDiscoveryPage extends ConsumerStatefulWidget {
  const ProductionMaterialDiscoveryPage({super.key, required this.requestId});
  static const route = '/warehouse/material-discovery/:requestId';
  final String requestId;
  @override
  ConsumerState<ProductionMaterialDiscoveryPage> createState() =>
      _DiscoveryPageState();
}

class _DiscoveryPageState extends ConsumerState<ProductionMaterialDiscoveryPage>
    with FormDraftMixin<ProductionMaterialDiscoveryPage> {
  final _grid = UtenEditableGridController<DiscoveryMaterialRow>();
  ProductionMaterialDiscoveryDetail? _detail;
  bool _loading = true, _saving = false, _uncertain = false;
  bool _initializedRows = false;
  bool _validationShown = false;
  String? _error;
  List<Map<String, dynamic>>? _submittedItems;
  String? _key;
  bool _submissionPending = false;
  @override
  bool get formDraftBusy => _saving || _uncertain;
  @override
  bool get formDraftUseCurrentRoute => false;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.warehouseDiscovery.spec(
    title: '填写领料材料',
    route: ProductionMaterialDiscoveryPage.route.replaceFirst(
      ':requestId',
      widget.requestId,
    ),
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    _grid,
    for (final row in _grid.rows) row.qty,
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'detail': _detail == null ? null : discoveryDraftFacts(_detail!),
    'rows': [
      for (final row in _grid.rows) {'values': row.values, 'qty': row.qty.text},
    ],
    'selected': draftGridSelection(_grid),
    'key': _key,
    'uncertain': _uncertain || _submissionPending,
    'submittedItems': _submittedItems,
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    final source = draftMap(data['detail']);
    if (source['requestId'] != widget.requestId) {
      throw const FormatException('材料申请来源不一致');
    }
    _uncertain = data['uncertain'] == true;
    if (_uncertain) {
      _detail = ProductionMaterialDiscoveryDetail.fromJson(source);
    } else if (_detail?.canConfigure != true ||
        _detail?.version != source['version']) {
      throw const FormatException('原材料申请已变化；填写草稿保留，请核对最新任务');
    }
    _key = data['key'] as String?;
    _submittedItems = data['submittedItems'] == null
        ? null
        : draftMaps(data['submittedItems']);
    _grid.replaceAll([
      for (final item in draftMaps(data['rows']))
        DiscoveryMaterialRow(initial: draftMap(item['values']))
          ..qty.text = draftText(item, 'qty'),
    ]);
    restoreDraftGridSelection(_grid, data['selected']);
    _initializedRows = true;
    _error = _uncertain ? '上次提交结果尚未确认，请原样重试或查询处理结果。' : null;
    if (mounted) setState(() {});
  }

  bool get _canWrite =>
      ref.read(isSuperAdminProvider) ||
      (ref.read(currentPermissionsProvider).contains(Perm.stockDocIssue) &&
          ref.read(currentPermissionsProvider).contains(Perm.stockDocApprove));
  bool get _editable =>
      _canWrite && _detail?.canConfigure == true && !_saving && !_uncertain;
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
    if (_saving) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(productionMaterialDiscoveryRepositoryProvider)
          .detail(widget.requestId);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        if (!detail.canConfigure) {
          _uncertain = false;
          _grid.replaceAll(
            detail.items.map((e) => DiscoveryMaterialRow(initial: e)),
          );
          invalidateWarehouseTaskCounts(ref);
        } else if (!_initializedRows) {
          _grid.replaceAll(
            detail.suggestedItems.isEmpty
                ? [DiscoveryMaterialRow()]
                : detail.suggestedItems.map(
                    (item) => DiscoveryMaterialRow(initial: item),
                  ),
          );
        }
        _initializedRows = true;
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is ApiException
              ? e.message
              : AppLocalizations.of(context).materialDiscoveryLoadFailed,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        await initializeFormDraft();
      }
    }
  }

  Future<void> _pickGoods(DiscoveryMaterialRow row) async {
    if (!_editable) return;
    final goods = await showUtenGoodsPicker(
      context,
      ref,
      scope: UtenGoodsPickerScope.component,
    );
    if (!mounted || goods == null || !_grid.rows.contains(row) || !_editable) {
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

  Future<void> _pickWarehouse(DiscoveryMaterialRow row) async {
    if (!_editable) return;
    try {
      final names = ref.read(masterNameServiceProvider);
      await names.ensureWarehousesLoaded();
      if (!mounted || !_grid.rows.contains(row) || !_editable) return;
      final selected = await showUtenWarehousePickerPanel(
        context,
        hierarchy: names.warehouseHierarchy,
        initialWarehouseId: row.values['warehouseId'] as String?,
        title: AppLocalizations.of(context).materialDiscoveryWarehouse,
      );
      if (!mounted ||
          selected == null ||
          !_grid.rows.contains(row) ||
          !_editable) {
        return;
      }
      setState(
        () => row.values.addAll({
          'warehouseId': selected.id,
          'warehouseName': selected.label,
        }),
      );
    } catch (e) {
      if (mounted) context.appApiError(e);
    }
  }

  Future<void> _save() async {
    if (_saving || !_canWrite || _detail?.canConfigure != true) return;
    final l10n = AppLocalizations.of(context);
    if (!_uncertain) {
      final rows = _grid.rows.map((row) => row.toRequest()).toList();
      if (rows.isEmpty || rows.length > 100 || rows.any((row) => row == null)) {
        setState(() {
          _validationShown = true;
          _error = rows.isEmpty || rows.length > 100
              ? '请填写 1 至 100 行材料'
              : '第 ${rows.indexWhere((row) => row == null) + 1} 行：${_grid.rows[rows.indexWhere((row) => row == null)].validationErrors.join('；')}';
        });
        context.appWarning(l10n.materialDiscoveryInvalid);
        return;
      }
      _submittedItems = rows.cast<Map<String, dynamic>>();
      _key = businessIdempotencyKey(
        'material-discovery',
        jsonEncode([widget.requestId, _detail!.version, _submittedItems]),
      );
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      _submissionPending = true;
      await saveFormDraftNow();
      final saved = await ref
          .read(productionMaterialDiscoveryRepositoryProvider)
          .configure(
            id: widget.requestId,
            version: _detail!.version,
            idempotencyKey: _key!,
            items: _submittedItems!,
          );
      await completeFormDraft();
      if (!mounted) return;
      setState(() {
        _detail = saved;
        _uncertain = false;
        _grid.replaceAll(
          saved.items.map((e) => DiscoveryMaterialRow(initial: e)),
        );
      });
      invalidateWarehouseTaskCounts(ref);
      context.appSuccess(l10n.materialDiscoverySaved);
    } catch (e) {
      if (!mounted) return;
      final rejected =
          e is ApiException &&
          e.httpStatus != null &&
          e.httpStatus! >= 400 &&
          e.httpStatus! < 500;
      setState(() {
        _uncertain = !rejected;
        _error = rejected ? e.message : l10n.materialDiscoveryUncertain;
      });
    } finally {
      _submissionPending = false;
      if (mounted) setState(() => _saving = false);
    }
  }

  void _addRow() {
    if (!_editable) return;
    if (_grid.rows.length >= 100) {
      context.appWarning('每个申请最多填写 100 行材料');
      return;
    }
    setState(() => _grid.addRow(DiscoveryMaterialRow()));
  }

  void _removeRow(DiscoveryMaterialRow row) {
    if (!_editable) return;
    setState(() => _grid.removeRows([row]));
  }

  String get _productionDescription {
    final detail = _detail;
    if (detail == null) return '';
    return '${detail.productName} · ${detail.productCode}\n${detail.plannedQty} ${detail.productUnitName} · ${detail.planNo} · ${detail.segmentCode}';
  }

  List<MasterColumnDef<DiscoveryMaterialRow>> _columns(
    AppLocalizations l10n,
  ) => [
    MasterColumnDef(
      key: 'goods',
      label: '${l10n.materialDiscoveryPick} *',
      width: 220,
      value: (row) => row.values['goodsName'] as String? ?? '需要填写',
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => TextButton(
        key: ValueKey('discovery-goods-${row.id}'),
        onPressed: _editable ? () => _pickGoods(row) : null,
        style: row.values['goodsId'] == null
            ? TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              )
            : null,
        child: Text(row.values['goodsName'] as String? ?? '需要填写'),
      ),
    ),
    MasterColumnDef(
      key: 'goodsCode',
      label: l10n.materialDiscoveryCode,
      width: 120,
      value: (row) => row.label('goodsCode'),
    ),
    MasterColumnDef(
      key: 'colorName',
      label: l10n.materialDiscoveryColor,
      width: 100,
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
      label: l10n.materialDiscoveryUnit,
      width: 80,
      value: (row) => row.label('unitName'),
    ),
    MasterColumnDef(
      key: 'stockPlace',
      label: '参考库位',
      info: '货品资料中的参考库位；实际发料仓仍需仓管确认。',
      width: 130,
      value: (row) => row.label('stockPlace'),
    ),
    MasterColumnDef(
      key: 'qty',
      label: '${l10n.materialDiscoveryQuantity} *',
      width: 180,
      type: 'number',
      value: (row) => row.qty.text,
      cellBuilderHandlesSemantics: true,
      cellBuilder: (context, row) => ValueListenableBuilder<TextEditingValue>(
        valueListenable: row.qty,
        builder: (context, _, _) => TextField(
          key: ValueKey('discovery-qty-${_grid.rows.indexOf(row)}'),
          controller: row.qty,
          readOnly: !_editable,
          textAlign: TextAlign.right,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: applyRequiredEmpty(
            UtenInputDecoration(
              InputDecoration(
                isDense: true,
                hintText: '需要填写',
                error: _validationShown && row.quantityError != null
                    ? UtenFieldMessage.error(row.quantityError!)
                    : null,
              ),
            ),
            Theme.of(context),
            requiredEmpty: _editable && row.qty.text.trim().isEmpty,
          ),
        ),
      ),
    ),
    MasterColumnDef(
      key: 'warehouse',
      label: '${l10n.materialDiscoveryWarehouse} *',
      width: 200,
      value: (row) => row.values['warehouseName'] as String? ?? '需要填写',
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) => TextButton(
        key: ValueKey('discovery-warehouse-${row.id}'),
        onPressed: _editable ? () => _pickWarehouse(row) : null,
        style: row.values['warehouseId'] == null
            ? TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.error,
              )
            : null,
        child: Text(row.values['warehouseName'] as String? ?? '需要填写'),
      ),
    ),
    MasterColumnDef(
      key: 'usedFor',
      label: '用于生产',
      width: 270,
      value: (_) => _productionDescription,
      cellBuilder: (_, _) => Text(_productionDescription),
    ),
    if (_detail?.canConfigure == true)
      MasterColumnDef(
        key: 'actions',
        label: '材料行',
        width: 100,
        value: (_) => '',
        cellBuilderHandlesSemantics: true,
        cellBuilder: (_, row) => IconButton(
          key: ValueKey('discovery-remove-${row.id}'),
          tooltip: '删除此行材料',
          onPressed: _editable ? () => _removeRow(row) : null,
          icon: const Icon(Icons.remove_circle_outline),
        ),
      ),
  ];

  Widget _header(
    AppLocalizations l10n,
    ProductionMaterialDiscoveryDetail? detail,
  ) => Padding(
    padding: const EdgeInsets.all(UtenSpacing.s16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (detail != null) ...[
          Text(
            '领料申请号：${detail.requestNo.trim().isEmpty ? '—' : detail.requestNo}',
            key: const Key('discovery-request-number'),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            '${detail.planNo} · ${detail.segmentCode}',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          Text(
            '用于生产：${detail.productName} · ${detail.productCode} · ${detail.plannedQty} ${detail.productUnitName} · ${detail.workshopName}',
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            detail.canConfigure
                ? l10n.materialDiscoveryHelp
                : l10n.materialDiscoveryDone,
          ),
          if (detail.canConfigure && detail.suggestedItems.isNotEmpty)
            Text(l10n.materialDiscoveryPrefilledHelp),
          if (detail.canConfigure && !_canWrite)
            Text(l10n.materialDiscoveryNoPermission),
          if (detail.canConfigure)
            const Text('标有 * 的材料、数量和实际发料仓为必填；确认后继续正常领料。'),
        ],
        if (_error != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          Text(
            _error!,
            key: const Key('discovery-validation-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ],
        if (detail == null || _uncertain || _error != null)
          Align(
            alignment: Alignment.centerLeft,
            child: UtenButton(
              onPressed: _loading || _saving ? null : _load,
              child: Text(
                detail != null
                    ? l10n.materialDiscoveryCheck
                    : l10n.materialDiscoveryRetry,
              ),
            ),
          ),
        for (final document in _drawDocuments(detail))
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: UtenButton(
                key: ValueKey('discovery-open-draw-${document.id}'),
                onPressed: () => context.push('/warehouse/DRAW/${document.id}'),
                child: Text(
                  document.billNo.trim().isEmpty
                      ? l10n.materialDiscoveryOpenDraw
                      : '${l10n.materialDiscoveryOpenDraw} ${document.billNo} · ${document.warehouseName.trim().isEmpty ? '—' : document.warehouseName}',
                ),
              ),
            ),
          ),
      ],
    ),
  );

  List<ProductionMaterialDiscoveryDrawDocument> _drawDocuments(
    ProductionMaterialDiscoveryDetail? detail,
  ) {
    if (detail == null) return const [];
    final documents = {
      for (final document in detail.drawDocuments) document.id: document,
    };
    for (final id in detail.drawDocIds) {
      documents.putIfAbsent(
        id,
        () => ProductionMaterialDiscoveryDrawDocument(id: id, billNo: ''),
      );
    }
    return documents.values.toList(growable: false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final detail = _detail;
    return withFormDraft(
      PopScope(
        canPop: !_saving && !_uncertain,
        child: Scaffold(
          appBar: UtenAppBar(
            title: l10n.materialDiscoveryTitle,
            showBackButton: true,
          ),
          body: _loading && detail == null
              ? const Center(child: CircularProgressIndicator())
              : UtenContentContainer(
                  child: UtenCollapsingHeaderScrollView(
                    collapsingHeader: _header(l10n, detail),
                    body: MasterDataTableView<DiscoveryMaterialRow>(
                      tableKey:
                          'features.warehouse.pages.production_material_discovery_page.DiscoveryPageState.build.1',
                      key: const Key('discovery-material-table'),
                      primary: true,
                      enableTextSelection: false,
                      columns: _columns(l10n),
                      items: List.unmodifiable(_grid.rows),
                      rowKeyOf: (row) => row.id,
                      rowColor: (row) =>
                          _validationShown && row.validationErrors.isNotEmpty
                          ? Theme.of(
                              context,
                            ).colorScheme.errorContainer.withValues(alpha: .35)
                          : null,
                      facets: const {},
                      nullCounts: const {},
                      filters: const {},
                      onFilterChanged: (_, _) {},
                      bottomContentPadding:
                          UtenFloatingActionGroup.scrollClearance,
                      showFullscreenToggle: false,
                      toolbarActions: [
                        if (detail?.canConfigure == true && _canWrite)
                          UtenButton(
                            key: const Key('discovery-add'),
                            type: UtenButtonType.secondary,
                            icon: Icons.add,
                            onPressed: _editable ? _addRow : null,
                            child: const Text('添加材料'),
                          ),
                      ],
                      emptyMessage: detail?.canConfigure == true
                          ? '请添加本次需要领取的材料'
                          : '暂无材料明细',
                    ),
                  ),
                ),
          floatingActionButtonAnimator:
              FloatingActionButtonAnimator.noAnimation,
          floatingActionButton: detail?.canConfigure == true && _canWrite
              ? UtenButton(
                  key: const Key('discovery-save'),
                  type: UtenButtonType.danger,
                  isLoading: _saving,
                  onPressed: _loading ? null : _save,
                  child: Text(
                    _uncertain
                        ? l10n.materialDiscoveryRetry
                        : l10n.materialDiscoverySave,
                  ),
                )
              : null,
        ),
      ),
    );
  }
}
