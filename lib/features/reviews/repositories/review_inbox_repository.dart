// V459 我的待审收件台：后端 summary 聚合的轻量仓库与 Provider。
// section 可见性由后端按「部门（主/兼职）× 职责权限码」资格过滤；
// 计数 = 当前用户名下未办结待审通知数（办结撤回自动联动）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';

/// 收件台一个职责域的分片。
class ReviewInboxSection {
  const ReviewInboxSection({
    required this.key,
    required this.title,
    required this.pendingCount,
    required this.route,
  });

  factory ReviewInboxSection.fromJson(Map<String, dynamic> json) {
    return ReviewInboxSection(
      key: json['key'] as String,
      title: json['title'] as String? ?? '',
      pendingCount: (json['pendingCount'] as num?)?.toInt() ?? 0,
      route: json['route'] as String? ?? '',
    );
  }

  /// 域标识（= 通知 source_event）。
  final String key;
  final String title;
  final int pendingCount;
  final String route;

  /// 各域展示图标（与通知类型语义对齐）。
  IconData get icon => switch (key) {
    'SALES_ORDER_PENDING_FINANCE_CONFIRM' => Icons.request_quote_outlined,
    'PROCUREMENT_FINANCE_SUBMITTED' => Icons.approval_outlined,
    'PROCUREMENT_IQC_PENDING' => Icons.science_outlined,
    'SALES_ORDER_FULLY_PRODUCED_READY_TO_SHIP' => Icons.local_shipping_outlined,
    _ => Icons.fact_check_outlined,
  };
}

abstract interface class ReviewInboxRepository {
  Future<List<ReviewInboxSection>> summary();
}

class DioReviewInboxRepository implements ReviewInboxRepository {
  DioReviewInboxRepository(this._api);
  final ApiClient _api;

  @override
  Future<List<ReviewInboxSection>> summary() async {
    final json = await _api.get(ApiEndpoints.reviewsInboxSummary);
    final rows = json['sections'];
    if (rows is! List) return const [];
    return rows
        .whereType<Map<String, dynamic>>()
        .map(ReviewInboxSection.fromJson)
        .toList();
  }
}

final reviewInboxRepositoryProvider = Provider<ReviewInboxRepository>((ref) {
  return DioReviewInboxRepository(ref.watch(apiClientProvider));
});

/// 收件台 summary：进入页面时拉取 + 下拉刷新（invalidate）。
final reviewInboxSummaryProvider =
    FutureProvider.autoDispose<List<ReviewInboxSection>>((ref) {
      return ref.watch(reviewInboxRepositoryProvider).summary();
    });
