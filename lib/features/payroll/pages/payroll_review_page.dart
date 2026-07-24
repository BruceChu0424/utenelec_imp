// 工资条审核页（Phase 3）
// 文档：docs/03-页面/工资条审核页.md
//
// 响应式：compact 由页面自套 UtenContentContainer（gutter 16）；
// medium+ 外壳（MainShellPage）已收敛内容区，页面不再重复套容器

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../employee/models/employee.dart';
import '../../employee/providers/employee_providers.dart';

class _Batch {
  const _Batch(this.month, this.department, this.status, this.headcount);
  final String month;
  final String department;
  final String status; // 待审核 / 已通过
  final int headcount;
}

class PayrollReviewPage extends ConsumerStatefulWidget {
  const PayrollReviewPage({super.key});

  @override
  ConsumerState<PayrollReviewPage> createState() => _PayrollReviewPageState();
}

class _PayrollReviewPageState extends ConsumerState<PayrollReviewPage> {
  final _batches = const [
    _Batch('2026-07', '生产部', '待审核', 6),
    _Batch('2026-07', '质量部', '待审核', 2),
    _Batch('2026-06', '全员', '已通过', 11),
  ];
  int _selected = 0;
  bool _acting = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final batch = _batches[_selected];
    final isPending = batch.status == '待审核';

    // compact 自套容器补 gutter；medium+ 外壳已收敛，避免双层 gutter
    Widget body = Column(
        children: [
          // 批次选择
          SizedBox(
            height: 56,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(
                vertical: UtenSpacing.s8,
              ),
              children: [
                for (var i = 0; i < _batches.length; i++) ...[
                  if (i > 0) const SizedBox(width: UtenSpacing.s8),
                  _BatchChip(
                    batch: _batches[i],
                    selected: i == _selected,
                    onTap: () => setState(() => _selected = i),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 1),
          // 明细
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(
                vertical: UtenSpacing.s16,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UtenCard(
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${batch.month} · ${batch.department}',
                                  style: theme.textTheme.titleMedium
                                      ?.copyWith(fontWeight: FontWeight.w700)),
                              const SizedBox(height: UtenSpacing.s4),
                              Text('${batch.headcount} 人',
                                  style: theme.textTheme.bodySmall),
                            ],
                          ),
                        ),
                        UtenStatusBadge(
                          label: batch.status,
                          type: isPending
                              ? UtenStatusBadgeType.warning
                              : UtenStatusBadgeType.success,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  const UtenSectionHeader(title: '员工明细预览'),
                  const SizedBox(height: UtenSpacing.s8),
                  _BatchDetail(department: batch.department),
                ],
              ),
            ),
          ),
        ],
      );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: const UtenAppBar(title: '工资条审核', showBackButton: true),
      bottomNavigationBar: isPending
          ? UtenBottomActionBar(
              child: Row(
                children: [
                  UtenButton(
                    type: UtenButtonType.ghost,
                    isLoading: _acting,
                    icon: Icons.close_rounded,
                    onPressed: () => _act(false),
                    child: const Text('驳回'),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: UtenButton(
                      isLoading: _acting,
                      isExpanded: true,
                      icon: Icons.check_rounded,
                      onPressed: () => _act(true),
                      child: const Text('审核通过'),
                    ),
                  ),
                ],
              ),
            )
          : null,
      body: body,
    );
  }

  Future<void> _act(bool approve) async {
    setState(() => _acting = true);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (mounted) {
      setState(() => _acting = false);
      context.appInfo(approve ? '已审核通过，交人事发布（Mock）' : '已驳回（Mock）');
    }
  }
}

class _BatchChip extends StatelessWidget {
  const _BatchChip(
      {required this.batch, required this.selected, required this.onTap});
  final _Batch batch;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: selected
          ? theme.colorScheme.primary.withValues(alpha: 0.1)
          : theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary
                  : theme.colorScheme.outline,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('${batch.month} · ${batch.department}',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  )),
              Text('${batch.status} · ${batch.headcount}人',
                  style: TextStyle(
                      fontSize: 11, color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ),
    );
  }
}

class _BatchDetail extends ConsumerWidget {
  const _BatchDetail({required this.department});
  final String department;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<List<Employee>>(
      future: ref.read(employeeRepositoryProvider).list(department: department),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final emps = snap.data ?? const [];
        if (emps.isEmpty) {
          return const Padding(
            padding: EdgeInsets.all(24),
            child: Center(child: Text('该批次无员工数据')),
          );
        }
        num total = 0;
        final theme = Theme.of(context);
        return UtenCard(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            children: [
              for (final e in emps) ...[
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 16,
                    backgroundColor: UtenColors.teal500,
                    child: Text(e.fullName.characters.first,
                        style: const TextStyle(color: Colors.white)),
                  ),
                  title: Text('${e.fullName}（${e.code}）',
                      style: theme.textTheme.bodyMedium),
                  subtitle: Text(e.position, style: theme.textTheme.bodySmall),
                  trailing: Builder(builder: (_) {
                    final base = e.baseSalary ?? 6000;
                    final net = base + base * 0.15 - base * 0.105 - base * 0.05;
                    total += net;
                    return Text('¥ ${net.toStringAsFixed(0)}',
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()]));
                  }),
                ),
                if (e != emps.last)
                  Divider(height: 1, color: theme.colorScheme.outlineVariant),
              ],
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Text('合计 ',
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w700)),
                    Text('¥ ${total.toStringAsFixed(0)}',
                        style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                            color: theme.colorScheme.primary,
                            fontFeatures: const [
                              FontFeature.tabularFigures()
                            ])),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
