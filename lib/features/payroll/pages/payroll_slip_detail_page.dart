// 工资条详情页
// 文档：docs/03-页面/工资条详情页.md（待写）
//
// 响应式：全断点套 UtenContentContainer.narrow（maxWidth 1120）——
// 外壳只收敛到 1600，详情页需自行钳窄居中

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/io/file_saver.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../models/payroll_download.dart';
import '../models/payroll_item.dart';
import '../models/payroll_slip.dart';
import '../providers/payroll_providers.dart';

class PayrollSlipDetailPage extends ConsumerStatefulWidget {
  const PayrollSlipDetailPage({super.key, required this.slipId});

  final String slipId;

  @override
  ConsumerState<PayrollSlipDetailPage> createState() =>
      _PayrollSlipDetailPageState();
}

class _PayrollSlipDetailPageState extends ConsumerState<PayrollSlipDetailPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _markViewed());
  }

  Future<void> _markViewed() async {
    try {
      await markPayrollViewed(ref, widget.slipId);
    } catch (error) {
      if (mounted) context.appError('查看状态记录失败：$error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = ref.watch(payrollDetailProvider(widget.slipId));

    return Scaffold(
      appBar: const UtenAppBar(title: '工资条详情', showBackButton: true),
      body: detail.when(
        loading: () => const _LoadingView(),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          actionLabel: '重试',
          onAction: () => ref.invalidate(payrollDetailProvider(widget.slipId)),
        ),
        data: (slip) => _DetailContent(slip: slip),
      ),
    );
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(40),
        child: UtenSkeleton(width: 200),
      ),
    );
  }
}

class _DetailContent extends ConsumerWidget {
  const _DetailContent({required this.slip});
  final PayrollSlip slip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final earnings = slip.items
        .where((i) => i.type == PayrollItemType.earning)
        .toList();
    final deductions = slip.items
        .where((i) => i.type == PayrollItemType.deduction)
        .toList();

    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(payrollDetailProvider(slip.id));
              await ref.read(payrollDetailProvider(slip.id).future);
            },
            // narrow 容器：compact 提供 gutter，medium+ 把内容钳到 1120 居中
            child: UtenContentContainer.narrow(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
                children: [
                  // 头部 - 大金额展示
                  _buildHero(theme),
                  const SizedBox(height: UtenSpacing.s16),

                  // 状态信息
                  UtenCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        UtenInfoRow(label: '所属期间', value: slip.periodLabelZh),
                        UtenInfoRow(label: '员工工号', value: slip.employeeCode),
                        UtenInfoRow(
                          label: '发布日期',
                          value: _formatDate(slip.publishedAt),
                        ),
                        UtenInfoRow(
                          label: '查看时间',
                          value: slip.viewedAt != null
                              ? _formatDateTime(slip.viewedAt)
                              : '—',
                          showDivider: false,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),

                  // 应发明细
                  const UtenSectionHeader(
                    title: '应发明细',
                    icon: Icons.add_circle_outline_rounded,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  UtenCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        for (var i = 0; i < earnings.length; i++)
                          UtenInfoRow(
                            label: earnings[i].name,
                            value:
                                '+ ¥ ${earnings[i].amount.toStringAsFixed(2)}',
                            showDivider: i != earnings.length - 1,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),

                  // 扣除明细
                  const UtenSectionHeader(
                    title: '扣除明细',
                    icon: Icons.remove_circle_outline_rounded,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  UtenCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        for (var i = 0; i < deductions.length; i++)
                          UtenInfoRow(
                            label: deductions[i].name,
                            value:
                                '- ¥ ${deductions[i].amount.toStringAsFixed(2)}',
                            showDivider: i != deductions.length - 1,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),

                  // 合计
                  const UtenSectionHeader(
                    title: '合计',
                    icon: Icons.calculate_outlined,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  UtenCard(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      children: [
                        UtenInfoRow(
                          label: '应发合计',
                          value: '¥ ${slip.grossIncome.toStringAsFixed(2)}',
                        ),
                        UtenInfoRow(
                          label: '扣除合计',
                          value: '¥ ${slip.totalDeduction.toStringAsFixed(2)}',
                        ),
                        UtenInfoRow(
                          label: '实发金额',
                          value: '¥ ${slip.netIncome.toStringAsFixed(2)}',
                          isImportant: true,
                          showDivider: false,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),

                  // 备注
                  if (slip.remark != null) ...[
                    UtenCard(
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 18,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              slip.remark!,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: UtenSpacing.s16),
                  ],

                  // 声明
                  Container(
                    padding: const EdgeInsets.all(UtenSpacing.s12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerLow,
                      borderRadius: UtenRadius.lgAll,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.lock_outline_rounded,
                          size: 14,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            '工资信息属于个人隐私，请妥善保管，请勿截图外传。',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                ],
              ),
            ),
          ),
        ),

        // 底部下载按钮
        UtenBottomActionBar(
          child: UtenActionButton(
            isExpanded: true,
            icon: Icons.download_outlined,
            label: const Text('下载工资条'),
            loadingLabel: const Text('生成中…'),
            onAction: () async {
              try {
                final bytes = await downloadPayrollSlip(ref, slip.id);
                if (!hasPdfSignature(bytes)) {
                  throw const FormatException('服务器返回的文件不是有效 PDF');
                }
                final savedPath = await saveBytes(
                  bytes,
                  payrollPdfFilename(
                    period: slip.periodLabel,
                    employeeCode: slip.employeeCode,
                  ),
                );
                if (context.mounted) {
                  context.appSuccess('工资条已保存：$savedPath');
                }
              } catch (error) {
                if (context.mounted) {
                  context.appError('下载失败：$error');
                }
              }
            },
          ),
        ),
      ],
    );
  }

  Widget _buildHero(ThemeData theme) {
    return UtenCard(
      padding: const EdgeInsets.all(UtenSpacing.s24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 期间 + 状态
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                slip.periodLabelZh,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              UtenStatusBadge(
                label: slip.status.label,
                type: slip.status == PayrollSlipStatus.downloaded
                    ? UtenStatusBadgeType.success
                    : UtenStatusBadgeType.neutral,
                icon: slip.status == PayrollSlipStatus.downloaded
                    ? Icons.check_circle_rounded
                    : null,
              ),
            ],
          ),
          const SizedBox(height: 24),
          // 实发金额（displayMedium 大字号 + tabular figures）
          Text(
            '实发金额',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '¥',
                style: theme.textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                slip.netIncome.toStringAsFixed(2),
                style: theme.textTheme.displayMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: UtenColors.primary,
                  height: 1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s16),
          const Divider(),
          const SizedBox(height: UtenSpacing.s16),
          // 应发 / 扣除
          Row(
            children: [
              Expanded(
                child: _SummaryItem(
                  label: '应发',
                  value: slip.grossIncome,
                  color: UtenColors.success,
                ),
              ),
              Container(
                width: 1,
                height: 40,
                color: theme.colorScheme.outlineVariant,
              ),
              Expanded(
                child: _SummaryItem(
                  label: '扣除',
                  value: -slip.totalDeduction,
                  color: UtenColors.error,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '—';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime? date) {
    if (date == null) return '—';
    return '${_formatDate(date)} ${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }
}

/// 顶部摘要小项（应发 / 扣除）
class _SummaryItem extends StatelessWidget {
  const _SummaryItem({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final double value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '${value >= 0 ? '' : '-'}¥ ${value.abs().toStringAsFixed(2)}',
          style: theme.textTheme.titleLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
