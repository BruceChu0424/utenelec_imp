import 'package:uten_imp/components/buttons/uten_close_button.dart';
import '../../../components/inputs/uten_field_hint_icon.dart';
import '../../../components/layout/uten_section_header.dart';
// 库存余额详情只读；目标数量/重量统一到即时库存的盘点模式送审。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/china_datetime.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../models/stock_query.dart';
import '../../../shared/stock_inventory/measurement_hold.dart';

/// Returns true only when the user asks to open the inventory count page.
Future<bool?> showStockBalanceDetailSheet({
  required BuildContext context,
  required BalanceRow balance,
  required String goodsName,
  required String unitName,
  required String warehouseName,
  required String colorName,
  bool weightExact = false,
  required VoidCallback onViewMovements,
}) {
  return showUtenAdaptivePanel<bool>(
    context: context,
    compactHeightFactor: 0.9,
    drawerWidth: 460,
    builder: (_) => _StockBalanceDetailSheet(
      balance: balance,
      goodsName: goodsName,
      unitName: unitName,
      warehouseName: warehouseName,
      colorName: colorName,
      weightExact: weightExact,
      onViewMovements: onViewMovements,
    ),
  );
}

class _StockBalanceDetailSheet extends ConsumerWidget {
  const _StockBalanceDetailSheet({
    required this.balance,
    required this.goodsName,
    required this.unitName,
    required this.warehouseName,
    required this.colorName,
    required this.weightExact,
    required this.onViewMovements,
  });
  final BalanceRow balance;
  final String goodsName, unitName, warehouseName, colorName;
  final bool weightExact;
  final VoidCallback onViewMovements;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final permissions = ref.watch(currentPermissionsProvider);
    final canCount =
        !balance.measurementPending &&
        balance.availableKnown &&
        (ref.watch(isSuperAdminProvider) ||
            permissions.contains(Perm.stockCountSubmit));
    final display = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    final qty = balance.qty == null
        ? '未知'
        : balance.qty!.toStringAsFixed(4).replaceFirst(RegExp(r'\.?0+$'), '');
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Row(
              children: [
                const Expanded(
                  child: UtenSectionHeader(
                    title: '库存余额详情',
                    info: '数量和重量变更由盘点审批处理。普通仓由财务审核，车间内料仓由仓库审核，批准前库存保持不变。',
                  ),
                ),
                UtenCloseButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              children: [
                _info('货品', goodsName),
                _info('仓库', warehouseName),
                _info('颜色', colorName),
                _info(
                  '基本单位',
                  balance.measurementPending
                      ? measurementHoldLabel(balance.measurementHoldReason)
                      : unitName,
                ),
                _info(balance.measurementPending ? '账面数量' : '当前数量', qty),
                if (balance.measurementPending)
                  Text(
                    '${balance.measurementNotice}。主档补单位不代表原账计量已经核验，需真实核验后解除。',
                  ),
                _info(
                  '库存重量',
                  formatWeightValue(
                    balance.weight,
                    display: display,
                    estimated: balance.weightEstimated,
                  ),
                  info: [
                    if (balance.weightEstimated) '库存重量包含估算值；如需修正，请记录实盘重量并送审。',
                    if (weightExact && !balance.measurementPending)
                      '此货品按重量计量，库存重量随数量和单位换算。',
                  ].join('\n\n'),
                ),
                if (balance.lastMovementDate != null)
                  _info(
                    '最后变动',
                    ChinaDateTime.formatIsoInstant(
                      balance.lastMovementDate,
                      fallback: '—',
                      seconds: true,
                    ),
                  ),
                if (balance.measurementPending) ...[
                  const SizedBox(height: UtenSpacing.s16),
                  const Text('该历史账面数的计量依据待核，普通盘点差量不能自动确认原单位或解除计量待核。'),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s16),
            child: Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s8,
              children: [
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: () {
                    Navigator.pop(context);
                    onViewMovements();
                  },
                  child: const Text('查看流水'),
                ),
                if (canCount)
                  UtenButton(
                    key: const Key('stock-balance-open-count'),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('到即时库存盘点送审'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _info(String label, String value, {String? info}) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 90,
          child: Row(
            children: [
              Flexible(child: Text(label)),
              if (info?.isNotEmpty == true)
                UtenFieldHintIcon(info: info, dense: true),
            ],
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}
