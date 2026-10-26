import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/master_name_provider.dart';
import '../../../shared/providers/sensitive_read_boundary_provider.dart';
import '../../../shared/widgets/warehouse_picker_panel.dart';
import '../../../shared/widgets/warehouse_selection.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../core/ui/action_feedback.dart';
import '../models/goods_node.dart';
import '../models/goods_field_edit_policy.dart';
import '../providers/color_unit_dict.dart';
import '../repositories/goods_repository.dart';
import 'master_edit_dialog.dart';
import 'master_inline_edit.dart';
import 'mould_picker_field.dart';

/// Column keys describe presentation; field keys always carry UUID/API values.
Map<String, MasterInlineField<GoodsListItem>> goodsInlineFields(
  BuildContext context,
  WidgetRef ref,
) {
  final permissions = ref.watch(currentPermissionsProvider);
  final colors = ref.watch(colorDictProvider).value ?? const [];
  final units = ref.watch(unitDictProvider).value ?? const [];
  // Shared across lazily activated unit cells, rather than remapping the whole
  // dictionary for every rendered row.
  final unitOptions = [
    for (final unit in units)
      UtenDropdownItem(
        value: unit.id,
        label: unit.name ?? unit.code ?? unit.id,
      ),
  ];
  MasterInlineField<GoodsListItem> text(
    String key,
    String? Function(GoodsListItem) read, {
    bool required = false,
  }) => MasterInlineField(key: key, read: read, required: required);
  MasterInlineField<GoodsListItem> number(
    String key,
    num? Function(GoodsListItem) read,
  ) => MasterInlineField(
    key: key,
    read: read,
    type: MasterFieldType.money,
    validate: (value) =>
        value != null && (num.tryParse(value.toString()) ?? 0) < 0
        ? '不能小于 0'
        : null,
  );
  final fields = <String, MasterInlineField<GoodsListItem>>{
    'name': text('name', (g) => g.name, required: true),
    'nameEn': MasterInlineField(
      key: 'nameEn',
      read: (g) => g.nameEn,
      validate: (value) =>
          (value?.toString().length ?? 0) > kGoodsNameEnMaxLength
          ? '英文名称不能超过 $kGoodsNameEnMaxLength 个字符'
          : null,
    ),
    'model': text('model', (g) => g.model),
    'spec': text('spec', (g) => g.spec),
    'series': text('series', (g) => g.series),
    'cNumber': text('cNumber', (g) => g.cNumber),
    'material': text('material', (g) => g.material),
    'paper': text('paper', (g) => g.paper),
    'rearInsertCode': text('rearInsertCode', (g) => g.rearInsertCode),
    'stockPlace': text('stockPlace', (g) => g.stockPlace),
    'sourceType': MasterInlineField(
      key: 'sourceType',
      read: (g) => g.sourceType,
      required: true,
      type: MasterFieldType.select,
      options: kGoodsSourceTypeOptions,
    ),
    'colorLegacyId': MasterInlineField(
      key: 'colorId',
      read: (g) => g.colorId,
      type: MasterFieldType.select,
      options: [
        for (final color in colors)
          MasterSelectOption(
            value: color.id,
            label: color.name ?? color.code ?? color.id,
          ),
      ],
    ),
    'unitLegacyId': MasterInlineField(
      key: 'unitId',
      read: (g) => g.unitId,
      type: MasterFieldType.custom,
      required: true,
      cellBuilder: (context, row, field) => _GoodsInlineUnitField(
        row: row,
        value: field.initialValue,
        options: unitOptions,
        onChanged: field.onChanged,
      ),
    ),
    'owningWarehouse': MasterInlineField(
      key: 'owningWarehouseId',
      read: (g) => g.owningWarehouseId,
      type: MasterFieldType.custom,
      cellBuilder: (context, row, field) => _GoodsInlineWarehouseField(
        value: field.initialValue,
        initialLabel: row.owningWarehouseName,
        ref: ref,
        onChanged: field.onChanged,
      ),
    ),
    'mouldName': MasterInlineField(
      key: 'mouldId',
      read: (row) => row.mouldId,
      type: MasterFieldType.custom,
      cellBuilder: (context, row, field) => MouldPickerField(
        initialValue: field.initialValue,
        initialDisplayId: row.mouldId,
        initialDisplay: [
          row.mouldCode,
          row.mouldName,
        ].whereType<String>().join(' '),
        readBoundary: ref.read(sensitiveReadBoundaryProvider),
        onChanged: field.onChanged,
      ),
    ),
    'minOrderQty': number('minOrderQty', (g) => g.minOrderQty),
    'orderMultipleQty': number('orderMultipleQty', (g) => g.orderMultipleQty),
    if (permissions.contains(Perm.goodsPriceEdit)) ...{
      'price': number('price', (g) => g.price),
      'discount': number('discount', (g) => g.discount),
    },
  };
  return {
    for (final entry in fields.entries)
      if (GoodsFieldEditPolicy.canEditField(entry.value.key, permissions))
        entry.key: entry.value,
  };
}

class _GoodsInlineWarehouseField extends StatefulWidget {
  const _GoodsInlineWarehouseField({
    required this.value,
    required this.initialLabel,
    required this.ref,
    required this.onChanged,
  });
  final String? value;
  final String? initialLabel;
  final WidgetRef ref;
  final ValueChanged<dynamic> onChanged;

  @override
  State<_GoodsInlineWarehouseField> createState() =>
      _GoodsInlineWarehouseFieldState();
}

class _GoodsInlineWarehouseFieldState
    extends State<_GoodsInlineWarehouseField> {
  bool _opening = false;
  String? _label;

  Future<void> _pick() async {
    if (_opening) return;
    setState(() => _opening = true);
    final boundary = widget.ref.read(sensitiveReadBoundaryProvider);
    try {
      final names = widget.ref.read(masterNameServiceProvider);
      await names.ensureWarehousesLoaded();
      if (!mounted ||
          widget.ref.read(sensitiveReadBoundaryProvider) != boundary) {
        return;
      }
      final result = await showUtenWarehousePickerPanel(
        context,
        hierarchy: names.warehouseHierarchy,
        use: WarehouseUse.goodIn,
        initialWarehouseId: widget.value,
        title: '选择所属仓库',
      );
      if (!mounted ||
          widget.ref.read(sensitiveReadBoundaryProvider) != boundary ||
          result == null) {
        return;
      }
      setState(() => _label = result.label);
      widget.onChanged(result.id);
    } catch (error) {
      if (mounted &&
          widget.ref.read(sensitiveReadBoundaryProvider) == boundary) {
        context.appApiError(error);
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: TextButton(
          onPressed: _opening ? null : _pick,
          child: Text(
            _label ??
                widget.initialLabel ??
                (widget.value == null ? '选择仓库' : '更换所属仓库'),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      if (widget.value != null && widget.value!.isNotEmpty)
        IconButton(
          tooltip: '清空所属仓库',
          onPressed: _opening
              ? null
              : () {
                  setState(() => _label = '选择仓库');
                  widget.onChanged(null);
                },
          icon: const Icon(Icons.clear_rounded, size: 18),
        ),
    ],
  );
}

/// Quantity-unit mutability is a server capability, fetched only in edit mode.
/// Failed or outdated capability reads leave the cell read-only.
final _inlineUnitCapability = FutureProvider.autoDispose
    .family<GoodsDetail, (String, int?)>((ref, key) {
      ref.watch(sensitiveReadBoundaryProvider);
      return ref.read(goodsRepositoryProvider).detail(key.$1);
    });

class _GoodsInlineUnitField extends ConsumerWidget {
  const _GoodsInlineUnitField({
    required this.row,
    required this.value,
    required this.options,
    required this.onChanged,
  });
  final GoodsListItem row;
  final String? value;
  final List<UtenDropdownItem> options;
  final ValueChanged<dynamic> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final capability = ref.watch(_inlineUnitCapability((row.id, row.version)));
    final detail = capability.value;
    if (detail == null && !capability.hasError) {
      final message = masterEditText(
        context,
        '正在核对基本单位',
        'Checking the basic unit',
        '기본 단위 확인 중',
      );
      final status = masterEditText(context, '核对中', 'Checking', '확인 중');
      return Semantics(
        liveRegion: true,
        label: message,
        child: Tooltip(
          message: message,
          child: UtenButton(
            key: ValueKey('goods-inline-unit-check-${row.id}'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.small,
            isLoading: true,
            child: Text('${row.unitName ?? '—'} · $status'),
          ),
        ),
      );
    }
    if (detail == null ||
        !detail.writable ||
        detail.quantityUnitLocked ||
        detail.version != row.version) {
      final message = capability.hasError
          ? '无法核对基本单位，请刷新重试'
          : detail?.quantityUnitLocked == true
          ? '已有数量记录或组装引用，基本单位已固定'
          : detail == null
          ? '正在核对基本单位'
          : '资料已有变化，请刷新后编辑';
      return Tooltip(message: message, child: Text(row.unitName ?? '—'));
    }
    return UtenDropdownField(
      value: value,
      dense: true,
      items: options,
      onChanged: onChanged,
    );
  }
}
