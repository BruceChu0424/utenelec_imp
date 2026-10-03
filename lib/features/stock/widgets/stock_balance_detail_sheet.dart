// 库存余额详情只读；目标数量/重量统一到即时库存的盘点模式送审。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/measurement/weight_prefs.dart';
import '../../../shared/measurement/widgets/weight_text.dart';
import '../models/stock_query.dart';

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
  final sheet = _StockBalanceDetailSheet(
    balance: balance,
    goodsName: goodsName,
    unitName: unitName,
    warehouseName: warehouseName,
    colorName: colorName,
    weightExact: weightExact,
    onViewMovements: onViewMovements,
  );
  if (context.breakpoint.isCompact) {
    return showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheetContext) => SizedBox(
        height: MediaQuery.sizeOf(sheetContext).height * 0.9,
        child: sheet,
      ),
    );
  }
  return showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: Colors.black54,
    transitionDuration: const Duration(milliseconds: 250),
    pageBuilder: (dialogContext, _, _) => Align(
      alignment: Alignment.centerRight,
      child: Material(
        color: Theme.of(dialogContext).colorScheme.surface,
        child: SizedBox(width: 460, height: double.infinity, child: sheet),
      ),
    ),
    transitionBuilder: (_, animation, _, child) => SlideTransition(
      position: Tween<Offset>(
        begin: const Offset(1, 0),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
      child: child,
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
        ref.watch(isSuperAdminProvider) ||
        permissions.contains(Perm.stockCountSubmit);
    final display = ref.watch(warehouseWeightUnitsPrefsProvider).display;
    final theme = Theme.of(context);
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
                Expanded(
                  child: Text('库存余额详情', style: theme.textTheme.titleLarge),
                ),
                IconButton(
                  tooltip: '关闭',
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
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
                _info('基本单位', unitName),
                _info('当前数量', qty),
                _info(
                  '库存重量',
                  formatWeightValue(
                    balance.weight,
                    display: display,
                    estimated: balance.weightEstimated,
                  ),
                ),
                if (balance.weightEstimated)
                  const Text('库存重量包含估算值；如需修正，请记录实盘重量并送审。'),
                if (weightExact) const Text('此货品按重量计量，库存重量随数量和单位换算。'),
                if (balance.lastMovementDate != null)
                  _info(
                    '最后变动',
                    balance.lastMovementDate!.replaceFirst('T', ' '),
                  ),
                const SizedBox(height: UtenSpacing.s16),
                const Text('数量和重量变更由盘点审批处理。普通仓由财务审核，车间内料仓由仓库审核，批准前库存保持不变。'),
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

  Widget _info(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 90, child: Text(label)),
        Expanded(child: Text(value)),
      ],
    ),
  );
}
