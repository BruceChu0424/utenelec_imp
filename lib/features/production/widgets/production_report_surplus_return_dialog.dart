// 报工收尾「清点剩余物料」弹窗(V583 余料退仓，ADR-129 §2.7 实盘收尾)。
//
// 只在**最后一次报工**(本行报满或勾了完结)且本工单还有账面可用的料时弹出，
// 逐料填写按实物清点的**实际剩余**(预填账面剩余，0 可填，不超过账面可用)。
// 选「退回仓库」时本次用料 = 账面可用 - 实际剩余、退仓数量 = 实际剩余，
// BOM 真实使用数量据此学习，不再是计划单耗的回声；选「留在车间」照旧，不记清点数。
// 账面可用只算领料领来的料：车间直送过来还没领用的料(未领直送料)不在其中，不计入
// 实际剩余，退回仓库时一并退回，这时退仓数量 = 实际剩余 + 未领直送料。
//
// 这里只收集意愿与清点数，不发任何请求：退仓申请一提交就冻结领料过账额度，而实耗要到
// 日报审核时才登记，先冻后结会让实耗撞「超过准确原领料未耗用数量」。所以意愿随日报保存，
// 审核时服务端按当时的账面可用先结实耗、再按实际剩余发退料单。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/production_execution_planning.dart';

/// 弹窗里的一条「本工单账面还有可用」的物料需求。
class SurplusReturnCandidate {
  const SurplusReturnCandidate({
    required this.demandId,
    required this.goodsName,
    required this.availableToSettleQty,
    required this.estimatedLeftoverQty,
    required this.unitName,
    this.colorName,
    this.segmentLabel,
    this.undrawnDirectLotQty = 0,
  });

  final String demandId;
  final String goodsName;

  /// 账面可用(基本单位)：实际剩余的上限。
  final double availableToSettleQty;

  /// 纸面剩余 = 账面可用 - 本次填的用料，只作「实际剩余」的预填。
  final double estimatedLeftoverQty;
  final String unitName;
  final String? colorName;
  final String? segmentLabel;

  /// 未领直送料(基本单位)：车间直送过来还没领用的料，不在账面可用里、不计入实际剩余，
  /// 退回仓库时一并退回。
  final double undrawnDirectLotQty;
}

/// 收尾选择。退回仓库时带每条需求按实物清点的实际剩余(基本单位)；留在车间不带。
class SurplusReturnResult {
  const SurplusReturnResult({
    required this.returnToWarehouse,
    this.countedByDemandId = const {},
  });

  final bool returnToWarehouse;
  final Map<String, double> countedByDemandId;
}

/// 账面可用减去一个数量(本次用料或实际剩余)，基本量 4 位小数、不小于 0。
/// 纸面剩余与实盘后的本次用料共用这一个口径，页面与服务端审核算出同一个数。
double closeOutDifference(double availableQty, double deductedQty) {
  final difference = availableQty - deductedQty;
  return difference <= 0 ? 0 : (difference * 10000).roundToDouble() / 10000;
}

final _quantityTypingPattern = RegExp(r'^\d*\.?\d{0,4}$');

/// 报工数量输入(实际剩余、不良数)共用：只接受非负数、最多 4 位小数；
/// 不合格的按键保留原值，不截断成别的数。
final productionQuantityInputFormatter = TextInputFormatter.withFunction(
  (oldValue, newValue) =>
      _quantityTypingPattern.hasMatch(newValue.text) ? newValue : oldValue,
);

/// 实际剩余的唯一校验口径：必填、不小于 0、最多 4 位小数、不超过账面可用。
String? countedLeftoverIssue(String text, double availableQty) {
  final raw = text.trim();
  if (raw.isEmpty) return '请填写实际剩余，用完了填 0';
  if (!isValidProductionPlanningQuantityText(raw)) {
    return '请填写不小于 0、最多 4 位小数的数量';
  }
  if (double.parse(raw) - availableQty > 0.0000001) {
    return '不能超过账面可用 ${formatProductionPlanningQuantity(availableQty)}；'
        '实物比账面多，说明之前的报工多记了用料，请先关闭本窗口核对用料';
  }
  return null;
}

/// 实盘收尾写回用料行：清点过的需求 本次用料 = 账面可用 - 实际剩余，并带上实际剩余，
/// 与服务端审核同一口径；原来没有用料行的需求补一行，其余行原样。
/// [savedCounted] 是台账读不到时原样带回的草稿行上已登记的实际剩余，随行保留。
List<Map<String, dynamic>> applySurplusCounts(
  Iterable<Map<String, dynamic>> lines, {
  required Iterable<SurplusReturnCandidate> candidates,
  required Map<String, double> counted,
  Map<String, double> savedCounted = const {},
}) {
  final byDemand = <String, Map<String, dynamic>>{
    for (final line in lines) line['demandId'] as String: {...line},
  };
  savedCounted.forEach(
    (demandId, qty) => byDemand[demandId]?['countedLeftoverQty'] = qty,
  );
  for (final candidate in candidates) {
    final qty = counted[candidate.demandId];
    if (qty == null) continue;
    byDemand[candidate.demandId] = {
      'demandId': candidate.demandId,
      'qtyBase': closeOutDifference(candidate.availableToSettleQty, qty),
      'countedLeftoverQty': qty,
    };
  }
  return byDemand.values.toList();
}

/// 返回选择；关掉弹窗(null) = 回到报工表核对，不保存。
Future<SurplusReturnResult?> showProductionReportSurplusReturnDialog(
  BuildContext context, {
  required List<SurplusReturnCandidate> candidates,
}) => showDialog<SurplusReturnResult>(
  context: context,
  builder: (_) => _SurplusReturnDialog(candidates: candidates),
);

class _SurplusReturnDialog extends StatefulWidget {
  const _SurplusReturnDialog({required this.candidates});

  final List<SurplusReturnCandidate> candidates;

  @override
  State<_SurplusReturnDialog> createState() => _SurplusReturnDialogState();
}

class _SurplusReturnDialogState extends State<_SurplusReturnDialog> {
  late final Map<String, TextEditingController> _counted = {
    for (final candidate in widget.candidates)
      candidate.demandId: TextEditingController(
        text: formatProductionPlanningQuantity(candidate.estimatedLeftoverQty),
      ),
  };

  /// 点过灰的「退回仓库」后，空着的格也给出原因。
  bool _attempted = false;

  @override
  void dispose() {
    for (final controller in _counted.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String? _issue(SurplusReturnCandidate candidate) => countedLeftoverIssue(
    _counted[candidate.demandId]!.text,
    candidate.availableToSettleQty,
  );

  void _returnToWarehouse() => Navigator.pop(
    context,
    SurplusReturnResult(
      returnToWarehouse: true,
      countedByDemandId: {
        for (final candidate in widget.candidates)
          candidate.demandId: double.parse(
            _counted[candidate.demandId]!.text.trim(),
          ),
      },
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valid = widget.candidates.every(
      (candidate) => _issue(candidate) == null,
    );
    return AlertDialog(
      title: const Text('清点剩余物料'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('这是本工单的最后一次报工，下面这些料账面上还有可用：'),
              const SizedBox(height: UtenSpacing.s12),
              // 不同物料单位不同，**不给合计数字**：把千克和个加起来是假数。
              for (final candidate in widget.candidates)
                _candidateRow(theme, candidate),
              Container(
                padding: const EdgeInsets.all(UtenSpacing.s8),
                decoration: BoxDecoration(
                  color: theme.colorScheme.tertiaryContainer.withValues(
                    alpha: .55,
                  ),
                  borderRadius: UtenRadius.smAll,
                ),
                child: Text(
                  '按实物清点填写还剩多少。退回仓库时：本次用料 = 账面可用 - 实际剩余，'
                  '退仓数量 = 实际剩余；BOM 真实使用数量据此学习。\n'
                  '车间直送过来、还没领用的料(未领直送料)不算在账面可用里，不要计入'
                  '实际剩余；如有，退回仓库时一并退回，这时退仓数量 = 实际剩余 + 未领直送料。\n'
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
          onPressed: () => Navigator.pop(
            context,
            const SurplusReturnResult(returnToWarehouse: false),
          ),
          child: const Text('留在车间'),
        ),
        UtenButton(
          key: const Key('report-surplus-return-confirm'),
          icon: Icons.assignment_return_outlined,
          onPressed: valid ? _returnToWarehouse : null,
          onDisabledTap: () => setState(() => _attempted = true),
          child: const Text('退回仓库'),
        ),
      ],
    );
  }

  Widget _candidateRow(ThemeData theme, SurplusReturnCandidate candidate) {
    final controller = _counted[candidate.demandId]!;
    final issue = _issue(candidate);
    final colorName = candidate.colorName?.trim();
    return Padding(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${[candidate.goodsName, if (colorName != null && colorName.isNotEmpty) colorName].join(' · ')}'
                  '${candidate.segmentLabel == null ? '' : '(${candidate.segmentLabel})'}',
                  style: theme.textTheme.bodyMedium,
                ),
                const SizedBox(height: UtenSpacing.s4),
                Text(
                  '账面可用 '
                  '${formatProductionPlanningQuantity(candidate.availableToSettleQty)} '
                  '${candidate.unitName}',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (candidate.undrawnDirectLotQty > 0.0000001)
                  Text(
                    '另有未领直送料 '
                    '${formatProductionPlanningQuantity(candidate.undrawnDirectLotQty)} '
                    '${candidate.unitName}，退回仓库时一并退回，不要计入实际剩余',
                    key: ValueKey(
                      'report-surplus-direct-lot-${candidate.demandId}',
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: UtenSpacing.s12),
          SizedBox(
            width: 160,
            child: UtenInput(
              key: ValueKey('report-surplus-counted-${candidate.demandId}'),
              label: '实际剩余',
              required: true,
              hint: '0',
              controller: controller,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              inputFormatters: [productionQuantityInputFormatter],
              info: '按基本单位填写实物清点的剩余量，用完了填 0',
              errorMessage: controller.text.trim().isEmpty && !_attempted
                  ? null
                  : issue,
              onChanged: (_) => setState(() {}),
            ),
          ),
          const SizedBox(width: UtenSpacing.s8),
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
            child: Text(candidate.unitName),
          ),
        ],
      ),
    );
  }
}
