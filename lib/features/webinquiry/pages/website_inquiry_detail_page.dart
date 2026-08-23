// 官网询盘详情页：完整留言 + 跟进动作（开始跟进 / 关闭 / 一键转客户）

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_section_header.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../shared/auth/permissions.dart';
import '../models/website_inquiry.dart';
import '../providers/website_inquiry_providers.dart';

class WebsiteInquiryDetailPage extends ConsumerWidget {
  const WebsiteInquiryDetailPage({super.key, required this.inquiryId});

  final String inquiryId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detail = ref.watch(websiteInquiryDetailProvider(inquiryId));
    final permissions = ref.watch(currentPermissionsProvider);
    final canClaim = permissions.contains(Perm.webinquiryClaim);
    final canClose = permissions.contains(Perm.webinquiryClose);
    final canConvert = permissions.contains(Perm.webinquiryConvertClient);

    Widget body = detail.when(
      loading: () => const UtenSkeletonList(itemCount: 4),
      error: (e, _) => UtenEmpty.error(
        message: '加载失败：$e',
        onAction: () => ref.invalidate(websiteInquiryDetailProvider(inquiryId)),
      ),
      data: (inquiry) {
        if (inquiry == null) {
          return const UtenEmpty(
            icon: Icons.mail_outline_rounded,
            message: '询盘不存在或已被移除',
          );
        }
        return RefreshIndicator(
          onRefresh: () async =>
              ref.invalidate(websiteInquiryDetailProvider(inquiryId)),
          child: SingleChildScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: UtenSpacing.s8, bottom: 80),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HeaderCard(inquiry: inquiry),
                const SizedBox(height: UtenSpacing.s16),
                _MessageCard(inquiry: inquiry),
                const SizedBox(height: UtenSpacing.s16),
                _RequirementCard(inquiry: inquiry),
                if ((canClaim || canClose || canConvert) &&
                    inquiry.status != WebsiteInquiryStatus.converted) ...[
                  const SizedBox(height: UtenSpacing.s24),
                  _ActionPanel(
                    inquiry: inquiry,
                    canClaim: canClaim,
                    canClose: canClose,
                    canConvert: canConvert,
                  ),
                ],
                if (inquiry.status == WebsiteInquiryStatus.converted) ...[
                  const SizedBox(height: UtenSpacing.s16),
                  _ConvertedCard(inquiry: inquiry),
                ],
              ],
            ),
          ),
        );
      },
    );
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: const UtenAppBar(title: '询盘详情', showBackButton: true),
      body: body,
    );
  }
}

class _HeaderCard extends StatelessWidget {
  const _HeaderCard({required this.inquiry});

  final WebsiteInquiry inquiry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final contacts = [
      if (inquiry.phone != null && inquiry.phone!.isNotEmpty) inquiry.phone!,
      if (inquiry.email != null && inquiry.email!.isNotEmpty) inquiry.email!,
    ];

    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  inquiry.name,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              UtenStatusBadge(
                label: inquiry.status.label,
                type: switch (inquiry.status) {
                  WebsiteInquiryStatus.newOne => UtenStatusBadgeType.info,
                  WebsiteInquiryStatus.following => UtenStatusBadgeType.warning,
                  WebsiteInquiryStatus.converted => UtenStatusBadgeType.success,
                  WebsiteInquiryStatus.closed => UtenStatusBadgeType.neutral,
                },
              ),
            ],
          ),
          if (inquiry.subtitle.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              inquiry.subtitle,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
          if (contacts.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s12),
            SelectableText(
              contacts.join('  ·  '),
              style: theme.textTheme.bodyMedium,
            ),
          ],
          const SizedBox(height: UtenSpacing.s12),
          Text(
            '提交于 ${_fmtFull(inquiry.receivedAt)}'
            '${inquiry.assigneeName != null ? ' · 跟进人：${inquiry.assigneeName}' : ''}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard({required this.inquiry});

  final WebsiteInquiry inquiry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const UtenSectionHeader(title: '客户留言'),
          const SizedBox(height: UtenSpacing.s8),
          SelectableText(
            inquiry.message,
            style: theme.textTheme.bodyLarge?.copyWith(height: 1.7),
          ),
          if (inquiry.note != null && inquiry.note!.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s16),
            const Divider(),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              '跟进备注：${inquiry.note}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _RequirementCard extends StatelessWidget {
  const _RequirementCard({required this.inquiry});

  final WebsiteInquiry inquiry;

  @override
  Widget build(BuildContext context) {
    final entries = <MapEntry<String, String?>>[
      MapEntry('目标市场', inquiry.market),
      MapEntry('客户类型', inquiry.customerType),
      MapEntry('标准要求', inquiry.requiredStandard),
      MapEntry('意向产品', inquiry.productInterest),
      MapEntry('需求类型', inquiry.requestType),
      MapEntry('预估数量', inquiry.estimatedQuantity),
      MapEntry('目标交期', inquiry.targetSchedule),
      MapEntry('偏好联系方式', inquiry.preferredContact),
      MapEntry('来源页面', inquiry.source),
    ].where((e) => e.value != null && e.value!.isNotEmpty).toList();
    if (entries.isEmpty) return const SizedBox.shrink();

    final theme = Theme.of(context);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const UtenSectionHeader(title: '需求信息'),
          const SizedBox(height: UtenSpacing.s8),
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 96,
                    child: Text(
                      entry.key,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: SelectableText(
                      entry.value!,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 跟进动作面板：开始跟进（记为我的）/ 关闭 / 一键转客户。
class _ActionPanel extends ConsumerWidget {
  const _ActionPanel({
    required this.inquiry,
    required this.canClaim,
    required this.canClose,
    required this.canConvert,
  });

  final WebsiteInquiry inquiry;
  final bool canClaim;
  final bool canClose;
  final bool canConvert;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const UtenSectionHeader(title: '处理'),
        const SizedBox(height: UtenSpacing.s8),
        Wrap(
          spacing: UtenSpacing.s12,
          runSpacing: UtenSpacing.s12,
          children: [
            if (canClaim && inquiry.status == WebsiteInquiryStatus.newOne)
              UtenActionButton(
                key: const ValueKey('webinquiry-follow'),
                icon: Icons.play_arrow_rounded,
                label: const Text('开始跟进（记为我的）'),
                loadingLabel: const Text('处理中…'),
                onAction: () => _run(
                  context,
                  ref,
                  () => updateWebsiteInquiryStatus(
                    ref,
                    id: inquiry.id,
                    status: WebsiteInquiryStatus.following,
                    assignToMe: true,
                  ),
                  '已转为跟进中',
                ),
              ),
            if (canConvert)
              UtenActionButton(
                key: const ValueKey('webinquiry-convert'),
                icon: Icons.person_add_alt_rounded,
                label: const Text('一键转客户'),
                loadingLabel: const Text('转换中…'),
                onAction: () => _run(
                  context,
                  ref,
                  () => convertWebsiteInquiry(ref, inquiry.id),
                  '已创建客户并关联',
                ),
              ),
            if (canClose && inquiry.status != WebsiteInquiryStatus.closed)
              UtenActionButton(
                key: const ValueKey('webinquiry-close'),
                icon: Icons.close_rounded,
                label: const Text('关闭询盘'),
                loadingLabel: const Text('关闭中…'),
                onAction: () => _run(
                  context,
                  ref,
                  () => updateWebsiteInquiryStatus(
                    ref,
                    id: inquiry.id,
                    status: WebsiteInquiryStatus.closed,
                  ),
                  '已关闭',
                ),
              ),
          ],
        ),
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '转客户会按询盘信息创建最小客户主档（归属当前账号），此后可在客户资料中补全。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    Future<WebsiteInquiry> Function() action,
    String successMessage,
  ) async {
    try {
      await action();
      if (context.mounted) UtenNotify.success(context, successMessage);
    } catch (error) {
      if (context.mounted) {
        UtenNotify.apiError(context, error, fallback: '操作失败，请重试');
      }
    }
  }
}

class _ConvertedCard extends StatelessWidget {
  const _ConvertedCard({required this.inquiry});

  final WebsiteInquiry inquiry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return UtenCard(
      child: Row(
        children: [
          Icon(
            Icons.check_circle_rounded,
            color: theme.colorScheme.primary,
            size: 20,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '已转客户${inquiry.clientName != null ? '：${inquiry.clientName}' : ''}，可在客户资料中继续维护。',
              style: theme.textTheme.bodyMedium,
            ),
          ),
        ],
      ),
    );
  }
}

String _fmtFull(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} '
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
