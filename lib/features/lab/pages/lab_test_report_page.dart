// 检测报告页（Phase 4）
// 文档：docs/03-页面/检测报告页.md

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/ui/app_notification.dart';
import '../../../components/buttons/click_guard.dart';
import '../providers/lab_providers.dart';

class LabTestReportPage extends ConsumerWidget {
  const LabTestReportPage({super.key, required this.testId});
  final String testId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(labDetailProvider(testId));
    return Scaffold(
      appBar: UtenAppBar(
        title: '检测报告',
        showBackButton: true,
        actions: [
          UtenActionButton(
            type: UtenActionButtonType.ghost,
            size: UtenActionButtonSize.small,
            icon: Icons.picture_as_pdf_outlined,
            label: const Text('导出'),
            loadingLabel: const Text('生成中…'),
            onAction: () async {
              await Future<void>.delayed(const Duration(milliseconds: 600));
              if (context.mounted) context.appInfo('导出 PDF（Mock）');
            },
          ),
        ],
      ),
      body: detail.when(
        loading: () => const UtenSkeletonList(itemCount: 3),
        error: (e, _) => UtenEmpty.error(
          message: '加载失败：$e',
          onAction: () => ref.invalidate(labDetailProvider(testId)),
        ),
        data: (t) {
          if (t == null) return const UtenEmpty(message: '检测记录不存在');
          return Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Hero
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            t.qualified
                                ? UtenColors.teal600
                                : UtenColors.error,
                            t.qualified
                                ? UtenColors.teal500
                                : const Color(0xFFB91C1C),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          UtenStatusBadge(
                            label: t.qualified ? '✓ 合格' : '✗ 不合格',
                            type: t.qualified
                                ? UtenStatusBadgeType.success
                                : UtenStatusBadgeType.danger,
                          ),
                          const SizedBox(height: 12),
                          Text(t.project,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13)),
                          const SizedBox(height: 4),
                          Text(t.sampleName,
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 24,
                                  fontWeight: FontWeight.w700)),
                          const SizedBox(height: 8),
                          Text('${t.sampleCode}  ·  ${_fmt(t.testDate)}',
                              style: const TextStyle(color: Colors.white70, fontSize: 12)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    const UtenSectionHeader(title: '样品信息'),
                    const SizedBox(height: 8),
                    UtenCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Column(
                        children: [
                          UtenInfoRow(label: '样品编号', value: t.sampleCode),
                          UtenInfoRow(label: '样品名称', value: t.sampleName),
                          UtenInfoRow(label: '来源/批次', value: t.source),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    const UtenSectionHeader(title: '检测数据'),
                    const SizedBox(height: 8),
                    UtenCard(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 4),
                      child: Column(
                        children: [
                          UtenInfoRow(label: '检测项目', value: t.project, isImportant: true),
                          UtenInfoRow(label: '检测结果', value: t.result, isImportant: true),
                          UtenInfoRow(label: '标准值', value: t.standard),
                          UtenInfoRow(label: '检测设备', value: t.equipment),
                          UtenInfoRow(label: '检测员', value: t.testerName),
                          UtenInfoRow(label: '检测日期', value: _fmt(t.testDate)),
                        ],
                      ),
                    ),
                    if (t.remark != null) ...[
                      const SizedBox(height: 20),
                      UtenCard(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            const Icon(Icons.info_outline_rounded,
                                color: UtenColors.warning, size: 18),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(t.remark!,
                                  style: Theme.of(context).textTheme.bodySmall),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

String _fmt(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
