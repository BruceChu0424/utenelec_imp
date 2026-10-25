// 工资条详情页
// 文档：docs/03-页面/工资条详情页.md（待写）
//
// 响应式：全断点套默认 UtenContentContainer，正文随父容器扩宽，保留响应式 gutter。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/utils/china_datetime.dart';
import '../../../components/buttons/click_guard.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_detail_summary_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/io/file_saver.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/human_error_message.dart';
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
  bool _markViewedRequested = false;

  Future<void> _markViewed() async {
    try {
      await markPayrollViewed(ref, widget.slipId);
    } catch (error) {
      if (mounted) {
        context.appError(humanErrorMessage(error) ?? '「已查看」没有记录成功，请稍后重试');
      }
    }
  }

  /// 工资条下载（悬浮按钮动作）：独立 State 方法，async 后的 context 用
  /// mounted 守卫（State.context 与 mounted 同源）。
  Future<void> _download(PayrollSlip slip) async {
    try {
      final bytes = await downloadPayrollSlip(ref, slip.id);
      if (!hasPdfSignature(bytes)) {
        throw const FormatException('下载到的文件不是有效的 PDF，请稍后重试');
      }
      final savedPath = await saveBytes(
        bytes,
        payrollPdfFilename(
          period: slip.periodLabel,
          employeeCode: slip.employeeCode,
        ),
      );
      if (!mounted) return;
      context.appSuccess('工资条已保存：$savedPath');
    } catch (error) {
      if (!mounted) return;
      // 下载链路可能是网络(服务端给因)、也可能是本机保存问题：能给人看的都如实报。
      context.appError(humanErrorMessage(error) ?? '工资条没有下载成功，请稍后重试');
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
          message: humanErrorMessage(e) ?? '工资条没有加载出来，请稍后重试',
          actionLabel: '重试',
          onAction: () => ref.invalidate(payrollDetailProvider(widget.slipId)),
        ),
        data: (slip) {
          if (!_markViewedRequested) {
            _markViewedRequested = true;
            WidgetsBinding.instance.addPostFrameCallback((_) => _markViewed());
          }
          return _DetailContent(slip: slip);
        },
      ),
      // 2026-09-14 UI 统一口径：吸底下载按钮改右下悬浮组，按钮统一 large。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton: detail.maybeWhen(
        data: (slip) => UtenFloatingActionGroup(
          children: [
            UtenActionButton(
              size: UtenActionButtonSize.large,
              icon: Icons.download_outlined,
              label: const Text('下载工资条'),
              loadingLabel: const Text('生成中…'),
              onAction: () => _download(slip),
            ),
          ],
        ),
        orElse: () => null,
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
            // 正文不设固定最大宽度，导航收起后跟随可用区域扩宽。
            child: UtenContentContainer(
              child: ListView(
                // 底部留出右下悬浮操作组的高度，末段内容可滚出按钮区。
                padding: const EdgeInsets.fromLTRB(
                  0,
                  UtenSpacing.s16,
                  0,
                  UtenFloatingActionGroup.scrollClearance,
                ),
                children: [
                  // 金额与状态信息合为顶部摘要；工资构成仍在下方逐项显示。
                  _buildSummary(),
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
      ],
    );
  }

  Widget _buildSummary() {
    return UtenDetailSummaryCard(
      key: ValueKey('payroll-slip-summary-${slip.id}'),
      heading: Text(slip.periodLabelZh),
      // 状态徽章与列表状态列同源（ADR-169：PayrollSlipStatus.badgeType）。
      status: UtenStatusBadge(
        label: slip.status.label,
        type: slip.status.badgeType,
        icon: slip.status == PayrollSlipStatus.downloaded
            ? Icons.check_circle_rounded
            : null,
      ),
      primary: [
        UtenSummaryField(
          label: '实发金额',
          value: '${slip.netIncome.toStringAsFixed(2)} 元',
          emphasis: true,
          danger: true,
        ),
        UtenSummaryField(
          label: '应发',
          value: '${slip.grossIncome.toStringAsFixed(2)} 元',
        ),
        UtenSummaryField(
          label: '扣除',
          value:
              '${slip.totalDeduction > 0 ? '-' : ''}${slip.totalDeduction.abs().toStringAsFixed(2)} 元',
        ),
      ],
      facts: [UtenSummaryField(label: '员工工号', value: slip.employeeCode)],
      details: [
        UtenSummaryFacts(
          children: [
            UtenSummaryField(
              label: '发布日期',
              value: _formatDate(slip.publishedAt),
            ),
            UtenSummaryField(
              label: '查看时间',
              value: _formatDateTime(slip.viewedAt),
            ),
          ],
        ),
      ],
    );
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '—';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _formatDateTime(DateTime? date) {
    if (date == null) return '—';
    return ChinaDateTime.formatDateTime(date);
  }
}
