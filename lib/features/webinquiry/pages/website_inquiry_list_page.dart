// 官网询盘列表页（综合营销统一收件箱）
// 响应式：compact 下内容套 UtenContentContainer（medium+ 由 MainShell 统一收敛）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_paged_grid.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../components/layout/uten_segmented_filter.dart';
import '../../../core/responsive/breakpoint.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../models/website_inquiry.dart';
import '../providers/website_inquiry_providers.dart';

class WebsiteInquiryListPage extends ConsumerWidget {
  const WebsiteInquiryListPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = ref.watch(websiteInquiryListProvider);
    final status = ref.watch(websiteInquiryStatusFilterProvider);

    Widget body = Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            onRefresh: () =>
                ref.read(websiteInquiryListProvider.notifier).refresh(),
            child: list.when(
              loading: () => const UtenSkeletonList(itemCount: 6),
              error: (e, _) => UtenEmpty.error(
                message: '加载失败：$e',
                onAction: () => ref.invalidate(websiteInquiryListProvider),
              ),
              data: (page) {
                final inquiries = page.items;
                if (inquiries.isEmpty) {
                  return UtenEmpty(
                    icon: Icons.mail_outline_rounded,
                    message: status == null ? '暂无官网询盘' : '该状态下暂无询盘',
                    description: '客户在官网提交的留言会实时汇入这里',
                  );
                }
                return SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.only(
                    top: UtenSpacing.s8,
                    bottom: 80, // 底部悬浮胶囊导航留白
                  ),
                  child: Column(
                    children: [
                      UtenResponsiveGrid(
                        itemCount: inquiries.length,
                        itemBuilder: (context, i, _) => _InquiryCard(
                          inquiry: inquiries[i],
                          onTap: () => context.push(
                            RoutePath.websiteInquiryDetail(inquiries[i].id),
                          ),
                        ),
                      ),
                      if (page.totalPages > 1)
                        UtenGridPager(
                          currentPage: page.page,
                          totalPages: page.totalPages,
                          totalItems: page.total,
                          onPrev: !list.isLoading && page.page > 1
                              ? () => ref
                                    .read(websiteInquiryListProvider.notifier)
                                    .previousPage()
                              : null,
                          onNext: !list.isLoading && page.page < page.totalPages
                              ? () => ref
                                    .read(websiteInquiryListProvider.notifier)
                                    .nextPage()
                              : null,
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
    // compact 下页面自带宽度收敛；medium+ 由 MainShell 的容器统一处理
    if (context.breakpoint.isCompact) {
      body = UtenContentContainer(child: body);
    }

    return Scaffold(
      appBar: UtenAppBar(
        title: '官网询盘',
        showBackButton: true,
        centerWidget: UtenSegmentedFilter<WebsiteInquiryStatus?>(
          selected: status,
          onChanged: (v) =>
              ref.read(websiteInquiryStatusFilterProvider.notifier).state = v,
          segments: const [
            UtenSegment(value: WebsiteInquiryStatus.newOne, label: '未处理'),
            UtenSegment(value: WebsiteInquiryStatus.following, label: '跟进中'),
            UtenSegment(value: WebsiteInquiryStatus.converted, label: '已转客户'),
            UtenSegment(value: WebsiteInquiryStatus.closed, label: '已关闭'),
            UtenSegment(value: null, label: '全部'),
          ],
        ),
      ),
      body: body,
    );
  }
}

class _InquiryCard extends StatelessWidget {
  const _InquiryCard({required this.inquiry, required this.onTap});

  final WebsiteInquiry inquiry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return UtenCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头部：来源 + 状态
          Row(
            children: [
              Icon(
                Icons.language_rounded,
                size: 14,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: UtenSpacing.s4),
              Text(
                inquiry.locale.toUpperCase(),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              UtenStatusBadge(
                label: inquiry.status.label,
                type: _statusBadgeType(inquiry.status),
                size: UtenStatusBadgeSize.small,
              ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s12),
          // 联系人 + 公司
          Text(
            inquiry.name,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (inquiry.subtitle.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s4),
            Text(
              inquiry.subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: UtenSpacing.s8),
          // 留言摘要
          Text(
            inquiry.message,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: UtenSpacing.s12),
          const Divider(),
          const SizedBox(height: UtenSpacing.s12),
          // 底部：意向产品 + 时间 + 跟进人
          Row(
            children: [
              if (inquiry.productInterest != null &&
                  inquiry.productInterest!.isNotEmpty)
                Flexible(
                  child: Text(
                    inquiry.productInterest!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              const Spacer(),
              if (inquiry.assigneeName != null) ...[
                Icon(
                  Icons.account_circle_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: UtenSpacing.s4),
                Text(
                  inquiry.assigneeName!,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
              ],
              Text(
                _fmt(inquiry.receivedAt),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

UtenStatusBadgeType _statusBadgeType(WebsiteInquiryStatus status) =>
    switch (status) {
      WebsiteInquiryStatus.newOne => UtenStatusBadgeType.info,
      WebsiteInquiryStatus.following => UtenStatusBadgeType.warning,
      WebsiteInquiryStatus.converted => UtenStatusBadgeType.success,
      WebsiteInquiryStatus.closed => UtenStatusBadgeType.neutral,
    };

String _fmt(DateTime value) =>
    '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
