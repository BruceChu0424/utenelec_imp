import 'package:flutter/material.dart';

import '../../../core/theme/uten_tokens.dart';

/// 一条反查结果的分来源明细。不同来源的数量绝不相加。
class WhereUsedSourceBreakdown extends StatelessWidget {
  const WhereUsedSourceBreakdown({super.key, required this.row});

  final Map<String, dynamic> row;

  @override
  Widget build(BuildContext context) {
    final currentBom = _asBool(row['__currentBom']);
    final invalidBom = _asBool(row['__invalidBom']);
    final executionCount = _asNum(row['executionSegmentCount']);
    final executionEvidenceCount = _asNum(row['__executionEvidenceCount']);
    final executionSubcontractEvidenceCount = _asNum(
      row['__executionSubcontractEvidenceCount'],
    );
    final legacyPlanCount = _asNum(row['legacyPlanCount'] ?? row['planCount']);
    final legacyEvidenceCount = _asNum(row['__legacyEvidenceCount']);
    final subcontractOrderCount = _asNum(row['subcontractOrderCount']);
    final subcontractIssueCount = _asNum(row['subcontractIssueCount']);
    final subcontractOrderEvidenceCount = _asNum(
      row['__subcontractOrderEvidenceCount'],
    );
    final subcontractIssueEvidenceCount = _asNum(
      row['__subcontractIssueEvidenceCount'],
    );
    final hasExecution = executionEvidenceCount > 0 || executionCount > 0;
    final hasLegacy =
        legacyEvidenceCount > 0 ||
        legacyPlanCount > 0 ||
        row['totalQty'] != null;
    final hasLegacySubcontract =
        subcontractOrderEvidenceCount > 0 || subcontractIssueEvidenceCount > 0;
    final hasSubcontract =
        hasLegacySubcontract || executionSubcontractEvidenceCount > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _SourceSection(
          key: const Key('where-used-source-overview'),
          icon: Icons.badge_outlined,
          title: '产成品与来源',
          subtitle: '名称、规格、分类和状态来自查询时货品主档',
          metrics: [
            _Metric('关系来源', _display(row['sources'] ?? '旧生产快照')),
            _Metric('规格', _display(row['spec'])),
            _Metric('分类', _display(row['categoryName'])),
            _Metric('主档状态', _goodsStatus(row)),
          ],
        ),
        const SizedBox(height: UtenSpacing.s20),
        if (currentBom) ...[
          _SourceSection(
            key: const Key('where-used-current-bom-section'),
            icon: Icons.account_tree_outlined,
            title: '当前理论 BOM',
            subtitle: '查询时仍有效；日期筛选不影响本区',
            metrics: [
              _Metric('关系', _display(row['bomRelation'])),
              _Metric(
                '直接单套用量',
                _asBool(row['__currentDirect'])
                    ? _display(row['__currentDirectQty'])
                    : '间接关系不合并路径用量',
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s20),
        ],
        if (invalidBom) ...[
          _SourceSection(
            key: const Key('where-used-bom-issue-section'),
            icon: Icons.warning_amber_rounded,
            title: 'BOM 用量异常',
            subtitle: '存在零数或负数用量路径，已从“当前理论 BOM”有效关系中排除',
            metrics: [
              _Metric('关系', _display(row['bomRelation'])),
              const _Metric('处理状态', '需修正 BOM 用量后才能作为当前关系'),
            ],
          ),
          const SizedBox(height: UtenSpacing.s20),
        ],
        if (hasExecution) ...[
          _SourceSection(
            key: const Key('where-used-execution-demand-section'),
            icon: Icons.precision_manufacturing_outlined,
            title: '新生产履约需求',
            subtitle: executionCount > 0
                ? '按执行段冻结到具体产成品，是新系统可归属的有效生产需求'
                : '仅有已释放、红冲、中止、取消或未审核证据，不计入有效需求汇总',
            metrics: [
              _Metric('全部归属段证据', _display(executionEvidenceCount)),
              _Metric('执行段数', _display(executionCount)),
              _Metric('需求量', _display(row['__executionRequiredQty'])),
              _Metric(
                '单产品需求范围',
                _range(
                  row['__executionPerProductMin'],
                  row['__executionPerProductMax'],
                ),
              ),
              _Metric('首次需求', _display(row['__executionFirstUsed'])),
              _Metric(
                '最近需求',
                _display(row['__executionLastUsed'] ?? row['lastUsed']),
              ),
              _Metric('其中委外段', _display(row['__executionSubcontractSegments'])),
              _Metric(
                '其中委外需求量',
                _display(row['__executionSubcontractRequiredQty']),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s20),
        ],
        if (hasLegacy) ...[
          _SourceSection(
            key: const Key('where-used-legacy-production-section'),
            icon: Icons.history_rounded,
            title: '旧生产排产快照',
            subtitle: legacyPlanCount > 0
                ? '冻结的 BOM 展开与领退字段；不是当前 BOM，也不是实际消耗量'
                : '仅有未审核、红冲、中止、取消或孤立快照证据，不计入有效数量汇总',
            metrics: [
              _Metric('全部快照证据', _display(legacyEvidenceCount)),
              _Metric('计划单数', _display(legacyPlanCount)),
              _Metric('计划明细数', _display(row['__legacyProductionLineCount'])),
              _Metric(
                '展开需求量',
                _display(row['legacyRequiredQty'] ?? row['totalQty']),
              ),
              _Metric(
                '历史单套用量范围',
                _range(
                  row['__legacyDqtyMin'] ?? row['dqty'],
                  row['__legacyDqtyMax'] ?? row['dqty'],
                ),
              ),
              _Metric('已领料', _display(row['__legacyIssuedQty'])),
              _Metric('已退料', _display(row['__legacyReturnedQty'])),
              _Metric(
                '净领料',
                _difference(
                  row['__legacyIssuedQty'],
                  row['__legacyReturnedQty'],
                ),
              ),
              _Metric('首次使用', _display(row['__legacyFirstUsed'])),
              _Metric(
                '最近使用',
                _display(row['__legacyLastUsed'] ?? row['lastUsed']),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s20),
        ],
        if (hasSubcontract) ...[
          if (hasLegacySubcontract) ...[
            const _QualityNotice(),
            const SizedBox(height: UtenSpacing.s12),
          ],
          _SourceSection(
            key: const Key('where-used-subcontract-section'),
            icon: Icons.factory_outlined,
            title: '委外历史证据',
            subtitle:
                subcontractOrderCount > 0 ||
                    subcontractIssueCount > 0 ||
                    _asNum(row['__executionSubcontractSegments']) > 0
                ? '需求段、成本快照与发料痕迹分开；旧发料数量仅供追溯'
                : '仅有未审核、红冲或取消证据，不计入有效数量汇总',
            metrics: [
              _Metric('委外需求段证据', _display(executionSubcontractEvidenceCount)),
              _Metric('委外成本证据', _display(subcontractOrderEvidenceCount)),
              _Metric('委外订货单', _display(subcontractOrderCount)),
              _Metric('委外订货明细', _display(row['__subcontractOrderLineCount'])),
              _Metric('委外展开需求量', _display(row['__subcontractRequiredQty'])),
              _Metric(
                '委外单套用量范围',
                _range(
                  row['__subcontractUnitQtyMin'],
                  row['__subcontractUnitQtyMax'],
                ),
              ),
              _Metric('委外发料证据', _display(subcontractIssueEvidenceCount)),
              _Metric('发料单数', _display(subcontractIssueCount)),
              _Metric('发料痕迹数量(待核)', _display(row['__subcontractIssueQty'])),
              _Metric('退料痕迹数量(待核)', _display(row['__subcontractReturnedQty'])),
              _Metric('损耗痕迹数量(待核)', _display(row['__subcontractWastedQty'])),
              _Metric('首次记录', _display(row['__subcontractFirstUsed'])),
              _Metric('最近记录', _display(row['__subcontractLastUsed'])),
            ],
          ),
        ],
        if (!currentBom &&
            !invalidBom &&
            !hasExecution &&
            !hasLegacy &&
            !hasSubcontract)
          const _SourceUnavailable(),
      ],
    );
  }
}

class _SourceSection extends StatelessWidget {
  const _SourceSection({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.metrics,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final List<_Metric> metrics;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      container: true,
      label: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: theme.colorScheme.primary),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          LayoutBuilder(
            builder: (context, constraints) {
              final count = constraints.maxWidth >= 680
                  ? 4
                  : constraints.maxWidth >= 320
                  ? 2
                  : 1;
              final width =
                  (constraints.maxWidth - UtenSpacing.s8 * (count - 1)) / count;
              return Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s8,
                children: [
                  for (final metric in metrics)
                    SizedBox(
                      width: width,
                      child: Container(
                        padding: const EdgeInsets.all(UtenSpacing.s12),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHigh,
                          borderRadius: UtenRadius.lgAll,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              metric.label,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            const SizedBox(height: UtenSpacing.s4),
                            SelectableText(
                              metric.value,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _QualityNotice extends StatelessWidget {
  const _QualityNotice();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Text(
        '旧委外发料迁移数据仍待重导、重迁和业务复核；这里只把它作为“曾有关联”的历史证据，'
        '数量不可直接用于库存或财务结算。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onTertiaryContainer,
          height: 1.45,
        ),
      ),
    );
  }
}

class _SourceUnavailable extends StatelessWidget {
  const _SourceUnavailable();

  @override
  Widget build(BuildContext context) => const Text('该行没有可展示的来源明细。');
}

class _Metric {
  const _Metric(this.label, this.value);

  final String label;
  final String value;
}

String _goodsStatus(Map<String, dynamic> row) {
  final flags = <String>[
    if (_display(row['__goodsStatus']) != '—') _display(row['__goodsStatus']),
    if (_asBool(row['__autoCreated'])) '历史占位',
    if (_asBool(row['__goodsDeleted'])) '已软删除',
  ];
  return flags.isEmpty ? '—' : flags.join(' · ');
}

String _range(Object? minimum, Object? maximum) {
  final minText = _display(minimum);
  final maxText = _display(maximum);
  if (minText == '—' && maxText == '—') return '—';
  if (minText == maxText || maxText == '—') return minText;
  if (minText == '—') return maxText;
  return '$minText ～ $maxText';
}

String _difference(Object? left, Object? right) {
  if (left == null && right == null) return '—';
  return _display(_asNum(left) - _asNum(right));
}

double _asNum(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

bool _asBool(Object? value) =>
    value == true || value?.toString().toLowerCase() == 'true';

String _display(Object? value) {
  if (value == null) return '—';
  if (value is num) {
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value
        .toStringAsFixed(4)
        .replaceFirst(RegExp(r'0+$'), '')
        .replaceFirst(RegExp(r'\.$'), '');
  }
  final text = value.toString().trim();
  return text.isEmpty ? '—' : text;
}
