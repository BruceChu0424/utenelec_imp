// 报工收尾「余料退回仓库？」确认弹窗(V583)。
//
// 只在**最后一次报工**(本行报满或勾了完结)且确实还有料没登记成消耗时弹出。
// 填 0 / 没有差额 = 不弹、不建单、不打扰仓库。
//
// 这里只收集意愿，不发任何请求：退仓申请一提交就冻结领料过账额度，而实耗要到日报
// 审核时才登记，先冻后结会让实耗撞「超过准确原领料未耗用数量」。所以意愿随日报保存，
// 审核时服务端先结实耗、再按当时的剩余可退量发退料单。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_tokens.dart';

/// 弹窗里展示的一条「还没登记成消耗」的物料。
class SurplusReturnCandidate {
  const SurplusReturnCandidate({
    required this.goodsName,
    required this.remainingQty,
    required this.unitName,
    this.colorName,
    this.segmentLabel,
  });

  final String goodsName;
  final double remainingQty;
  final String unitName;
  final String? colorName;
  final String? segmentLabel;
}

/// 返回 true = 退回仓库；false / null = 留待后续生产。
Future<bool?> showProductionReportSurplusReturnDialog(
  BuildContext context, {
  required List<SurplusReturnCandidate> candidates,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) {
      final theme = Theme.of(dialogContext);
      return AlertDialog(
        title: const Text('还有料没用完'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('这是本工单的最后一次报工，按你填的实际用料，下面这些料还剩着：'),
                const SizedBox(height: UtenSpacing.s12),
                for (final candidate in candidates)
                  Padding(
                    padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                    child: Text(
                      // 不同物料单位不同，**不给合计数字**：把千克和个加起来是假数。
                      '${[candidate.goodsName, if (candidate.colorName?.trim().isNotEmpty == true) candidate.colorName!.trim()].join(' · ')}'
                      '：${_quantityText(candidate.remainingQty)} '
                      '${candidate.unitName}'
                      '${candidate.segmentLabel == null ? '' : '(${candidate.segmentLabel})'}',
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                const SizedBox(height: UtenSpacing.s8),
                Container(
                  padding: const EdgeInsets.all(UtenSpacing.s8),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.tertiaryContainer.withValues(
                      alpha: .55,
                    ),
                    borderRadius: UtenRadius.smAll,
                  ),
                  child: Text(
                    '选「退回仓库」：日报审核通过后自动开退料单，由原领料仓库点收，'
                    '仓库收到才会加回库存。\n'
                    '选「留在车间」：这些料继续算在本工单账上，本工单会一直处于未完工状态。',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          UtenButton(
            type: UtenButtonType.secondary,
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('留在车间'),
          ),
          UtenButton(
            key: const Key('report-surplus-return-confirm'),
            icon: Icons.assignment_return_outlined,
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('退回仓库'),
          ),
        ],
      );
    },
  );
}

String _quantityText(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value
          .toStringAsFixed(4)
          .replaceFirst(RegExp(r'0+$'), '')
          .replaceFirst(RegExp(r'\.$'), '');
