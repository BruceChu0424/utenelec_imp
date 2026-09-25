import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_editable_grid.dart';
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
import '../../basic_data/providers/color_unit_dict.dart';
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
  final qty = TextEditingController();
  DiscoveryMaterialRow clone() =>
      DiscoveryMaterialRow(initial: {...values, 'qty': qty.text});
  Map<String, dynamic>? toRequest() {
    final amount = double.tryParse(qty.text.trim());
    if (values['goodsId'] == null ||
        values['unitId'] == null ||
        values['warehouseId'] == null ||
        amount == null ||
        !amount.isFinite ||
        amount <= 0 ||
        !RegExp(r'^\d+(\.\d{1,4})?$').hasMatch(qty.text.trim())) {
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
  final String requestId;
  @override
  ConsumerState<ProductionMaterialDiscoveryPage> createState() =>
      _DiscoveryPageState();
}

class _DiscoveryPageState
    extends ConsumerState<ProductionMaterialDiscoveryPage> {
  final _grid = UtenEditableGridController<DiscoveryMaterialRow>();
  ProductionMaterialDiscoveryDetail? _detail;
  bool _loading = true, _saving = false, _uncertain = false;
  String? _error;
  List<Map<String, dynamic>>? _submittedItems;
  String? _key;
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
        } else if (_grid.rows.isEmpty) {
          _grid.addRow(DiscoveryMaterialRow());
        }
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
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickGoods(DiscoveryMaterialRow row) async {
    if (!_editable) return;
    final goods = await showUtenGoodsPicker(
      context,
      ref,
      scope: UtenGoodsPickerScope.component,
    );
    if (!mounted || goods == null || !_grid.rows.contains(row)) return;
    if (goods.unitId == null) {
      context.appWarning(
        AppLocalizations.of(context).materialDiscoveryMissingUnit,
      );
      return;
    }
    setState(() {
      row.values.addAll({
        'goodsId': goods.id,
        'goodsCode': goods.code,
        'goodsName': goods.name,
        'colorId': goods.colorId,
        'colorName': goods.colorName,
        'unitId': goods.unitId,
        'unitName': goods.unitName,
      });
    });
  }

  Future<void> _pickWarehouse(DiscoveryMaterialRow row) async {
    if (!_editable) return;
    try {
      final names = ref.read(masterNameServiceProvider);
      await names.ensureWarehousesLoaded();
      if (!mounted || !_grid.rows.contains(row)) return;
      final selected = await showUtenWarehousePickerPanel(
        context,
        hierarchy: names.warehouseHierarchy,
        initialWarehouseId: row.values['warehouseId'] as String?,
        title: AppLocalizations.of(context).materialDiscoveryWarehouse,
      );
      if (!mounted || selected == null || !_grid.rows.contains(row)) return;
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
      final saved = await ref
          .read(productionMaterialDiscoveryRepositoryProvider)
          .configure(
            id: widget.requestId,
            version: _detail!.version,
            idempotencyKey: _key!,
            items: _submittedItems!,
          );
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
      if (mounted) setState(() => _saving = false);
    }
  }

  List<EditableGridColumn<DiscoveryMaterialRow>> _columns(
    AppLocalizations l10n,
  ) => [
    EditableGridColumn(
      key: 'goods',
      label: l10n.materialDiscoveryPick,
      width: 220,
      required: true,
      textOf: (row) => row.values['goodsName'] as String? ?? '',
      cellBuilder: (context, row) => TextButton(
        onPressed: _editable ? () => _pickGoods(row) : null,
        child: Text(
          row.values['goodsName'] as String? ?? l10n.materialDiscoveryPick,
        ),
      ),
    ),
    for (final field in [
      ('goodsCode', l10n.materialDiscoveryCode),
      ('unitName', l10n.materialDiscoveryUnit),
    ])
      EditableGridColumn(
        key: field.$1,
        label: field.$2,
        width: 100,
        textOf: (row) => row.values[field.$1] as String? ?? '',
        cellBuilder: (_, row) => Text(row.values[field.$1] as String? ?? '—'),
      ),
    EditableGridColumn(
      key: 'colorName',
      label: l10n.materialDiscoveryColor,
      width: 120,
      textOf: (row) => row.values['colorName'] as String? ?? '',
      cellBuilder: (_, row) => !_editable
          ? Text(row.values['colorName'] as String? ?? '—')
          : Consumer(
              builder: (context, ref, _) {
                final colors = ref.watch(colorDictProvider);
                return colors.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => TextButton(
                    onPressed: () => ref.invalidate(colorDictProvider),
                    child: Text(l10n.materialDiscoveryRetry),
                  ),
                  data: (items) {
                    final selected = row.values['colorId'] as String?;
                    return UtenDropdownField(
                      key: ValueKey(
                        'discovery-color-${_grid.rows.indexOf(row)}',
                      ),
                      value: selected,
                      dense: true,
                      items: [
                        if (selected != null &&
                            !items.any((color) => color.id == selected))
                          UtenDropdownItem(
                            value: selected,
                            label: row.values['colorName'] as String? ?? '—',
                            visible: false,
                          ),
                        for (final color in items)
                          UtenDropdownItem(
                            value: color.id,
                            label: color.name ?? '—',
                            enabled: color.status != '停用',
                          ),
                      ],
                      onChanged: (value) {
                        if (!_editable) return;
                        setState(
                          () => row.values.addAll({
                            'colorId': value,
                            'colorName': items
                                .where((color) => color.id == value)
                                .firstOrNull
                                ?.name,
                          }),
                        );
                      },
                    );
                  },
                );
              },
            ),
    ),
    EditableGridColumn(
      key: 'qty',
      label: l10n.materialDiscoveryQuantity,
      width: 140,
      required: true,
      numeric: true,
      textOf: (row) => row.qty.text,
      listenableOf: (row) => row.qty,
      cellBuilder: (_, row) => TextField(
        key: ValueKey('discovery-qty-${_grid.rows.indexOf(row)}'),
        controller: row.qty,
        readOnly: !_editable,
        textAlign: TextAlign.right,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
      ),
    ),
    EditableGridColumn(
      key: 'warehouse',
      label: l10n.materialDiscoveryWarehouse,
      width: 220,
      required: true,
      textOf: (row) => row.values['warehouseName'] as String? ?? '',
      cellBuilder: (_, row) => TextButton(
        onPressed: _editable ? () => _pickWarehouse(row) : null,
        child: Text(
          row.values['warehouseName'] as String? ??
              l10n.materialDiscoveryWarehouse,
        ),
      ),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final detail = _detail;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        appBar: UtenAppBar(
          title: l10n.materialDiscoveryTitle,
          showBackButton: true,
        ),
        body: _loading && detail == null
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                child: UtenContentContainer(
                  child: Padding(
                    padding: const EdgeInsets.all(UtenSpacing.s16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (detail != null) ...[
                          Text(
                            '${detail.planNo} · ${detail.segmentCode}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text(
                            '${detail.productCode} ${detail.productName} · ${detail.plannedQty} ${detail.productUnitName} · ${detail.workshopName}',
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                          Text(
                            detail.canConfigure
                                ? l10n.materialDiscoveryHelp
                                : l10n.materialDiscoveryDone,
                          ),
                          if (detail.canConfigure && !_canWrite)
                            Text(l10n.materialDiscoveryNoPermission),
                          const SizedBox(height: UtenSpacing.s16),
                          AbsorbPointer(
                            absorbing: !_editable,
                            child: UtenEditableGrid<DiscoveryMaterialRow>(
                              controller: _grid,
                              columns: _columns(l10n),
                              createBlankRow: DiscoveryMaterialRow.new,
                              cloneRow: (row) => row.clone(),
                              showAddRow: _editable,
                              showRowDelete: _editable,
                              selectionEnabled: _editable,
                            ),
                          ),
                        ],
                        if (_error != null) ...[
                          const SizedBox(height: UtenSpacing.s12),
                          Text(
                            _error!,
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.error,
                            ),
                          ),
                        ],
                        if (detail == null || _uncertain || _error != null)
                          UtenButton(
                            onPressed: _loading || _saving ? null : _load,
                            child: Text(
                              detail != null
                                  ? l10n.materialDiscoveryCheck
                                  : l10n.materialDiscoveryRetry,
                            ),
                          ),
                        for (final drawId in detail?.drawDocIds ?? <String>[])
                          Padding(
                            padding: const EdgeInsets.only(top: UtenSpacing.s8),
                            child: UtenButton(
                              onPressed: () =>
                                  context.push('/warehouse/DRAW/$drawId'),
                              child: Text(l10n.materialDiscoveryOpenDraw),
                            ),
                          ),
                        const SizedBox(height: 100),
                      ],
                    ),
                  ),
                ),
              ),
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
    );
  }
}
