import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../core/formatters/exact_number_text.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/subcontract_material_quantity.dart';

class SubcontractMaterialShortage {
  const SubcontractMaterialShortage._(
    this._materials, {
    required this.canContinueFull,
    required this.canUseAvailable,
    required this.token,
  });

  final List<_MaterialShortageRow> _materials;
  final bool canContinueFull;
  final bool canUseAvailable;
  final String? token;

  static SubcontractMaterialShortage? fromError(ApiException error) {
    final details = error.details;
    if (!error.hasResponseCode ||
        error.httpStatus != 409 ||
        error.code != 'CONFLICT' ||
        details?['kind'] != 'SUBCONTRACT_MATERIAL_SHORTAGE') {
      return null;
    }
    final rawMaterials = details!['materials'];
    if (rawMaterials is! List || rawMaterials.isEmpty) return null;
    final materials = <_MaterialShortageRow>[];
    for (final row in rawMaterials) {
      if (row is! Map) return null;
      final requiredQty = exactNumberDisplay(row['requiredQtyExact']);
      final availableQty = exactNumberDisplay(
        row['availableQtyExact'],
        groupThousands: true,
      );
      final rawCap = row['cappedQtyExact'];
      final cappedQty = exactNumberDisplay(rawCap);
      if (requiredQty == null ||
          availableQty == null ||
          (rawCap != null && cappedQty == null)) {
        return null;
      }
      final rawUnit = row['unitName'];
      final unit = rawUnit is String ? rawUnit : '';
      final base = exactNumberDisplay(row['baseQtyExact']);
      materials.add(
        _MaterialShortageRow(
          name: [
            row['goodsName'],
            row['goodsCode'],
            row['colorName'],
          ].whereType<String>().where((value) => value.isNotEmpty).join(' · '),
          required: formatSubcontractMaterialQtyBreakdown(
            baseQty: base,
            lossQty: exactNumberDisplay(row['requiredLossQtyExact']),
            totalQty: requiredQty,
            unitName: unit,
          ),
          available: '$availableQty $unit'.trimRight(),
          cap: cappedQty == null
              ? null
              : '${exactNumberDisplay(cappedQty, groupThousands: true)} $unit'
                    .trimRight(),
          cappedBreakdown: cappedQty == null
              ? null
              : formatSubcontractMaterialQtyBreakdown(
                  baseQty: base,
                  lossQty: exactNumberDisplay(row['cappedLossQtyExact']),
                  totalQty: cappedQty,
                  unitName: unit,
                ),
        ),
      );
    }
    final token = details['token'];
    return SubcontractMaterialShortage._(
      materials,
      canContinueFull: details['canContinueFull'] == true,
      canUseAvailable: details['canUseAvailable'] == true,
      token: token is String && token.isNotEmpty ? token : null,
    );
  }

  Future<String?> show(BuildContext context) {
    final canContinue = token != null && canContinueFull;
    final canCap = token != null && canUseAvailable;
    final single = _materials.length == 1 ? _materials.single : null;
    final cap = single?.cap;
    final availableLabel = cap == null ? '按可用量下单' : '按 $cap下单';
    return UtenDialog.showAndWaitForExit<String>(
      context,
      builder: (dialogContext) => UtenAlertDialog(
        title: UtenDialogHeading(
          title: UtenDialogTitleWithHint(
            title: Text(canContinue || canCap ? '委外备料不足' : '物料不足，暂不能下单'),
            info: canCap ? '按原预算继续可在补货后领剩余量。按可用量下单会下调领料上限。两种选择的成品订货量相同。' : null,
          ),
          icon: Icons.warning_amber_rounded,
        ),
        content: SelectionArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final (index, material) in _materials.indexed) ...[
                if (index > 0) const Divider(height: UtenSpacing.s24),
                Text(
                  material.name.isEmpty ? '直属物料' : material.name,
                  style: Theme.of(dialogContext).textTheme.titleSmall,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Wrap(
                  spacing: UtenSpacing.s16,
                  runSpacing: UtenSpacing.s4,
                  children: [
                    _ShortageQuantity(
                      label: '领料数量',
                      value: material.required,
                      hint: '按成品订货量、BOM 单耗和允许损耗计算的领料上限。',
                    ),
                    _ShortageQuantity(
                      label: '仓库最多可领',
                      value: material.available,
                      hint: '按本单可用库存计算，已扣除其他订单的占用。',
                    ),
                    if (material.cappedBreakdown case final breakdown?
                        when canCap)
                      _ShortageQuantity(
                        label: '按可用量下单',
                        value: breakdown,
                        hint: '调整后的基础用量与损耗量，按本次可用库存确定。',
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(canContinue || canCap ? '返回修改' : '返回'),
          ),
          if (canContinue)
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: () => Navigator.pop(dialogContext, 'CONTINUE_FULL'),
              child: const Text('按原预算继续'),
            ),
          if (canCap)
            UtenButton(
              onPressed: () => Navigator.pop(dialogContext, 'USE_AVAILABLE'),
              child: Text(availableLabel),
            ),
        ],
      ),
    );
  }
}

class _MaterialShortageRow {
  const _MaterialShortageRow({
    required this.name,
    required this.required,
    required this.available,
    required this.cap,
    required this.cappedBreakdown,
  });

  final String name;
  final String required;
  final String available;
  final String? cap;
  final String? cappedBreakdown;
}

class _ShortageQuantity extends StatelessWidget {
  const _ShortageQuantity({
    required this.label,
    required this.value,
    required this.hint,
  });

  final String label;
  final String value;
  final String hint;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(child: Text(label)),
          UtenFieldHintIcon(info: hint, dense: true),
        ],
      ),
      Text(value, style: Theme.of(context).textTheme.titleLarge),
    ],
  );
}
