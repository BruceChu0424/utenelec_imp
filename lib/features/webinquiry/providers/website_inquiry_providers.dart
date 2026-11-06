import 'package:uten_imp/shared/paging/read_view_activity.dart';
import '../../../shared/paging/complete_paged_snapshot.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
// 官网询盘 Provider

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../models/website_inquiry.dart';
import '../repositories/website_inquiry_repository.dart';

// Riverpod 3 将 copyWithPrevious 标记为 @internal；跨 family 实例手动保页/保旧值是既有架构，等上游公开等价 API 后再迁移。
// ignore_for_file: invalid_use_of_internal_member

final websiteInquiryRepositoryProvider = Provider<WebsiteInquiryRepository>((
  ref,
) {
  return DioWebsiteInquiryRepository(ref.watch(apiClientProvider));
});

/// Null restores the default unread category or all historical inquiries.
final websiteInquiryStatusFilterProvider = StateProvider<WebsiteInquiryStatus?>(
  (ref) => null,
);
final websiteInquiryHistoryProvider = StateProvider<bool>((ref) => false);

final websiteInquiryReadActivityProvider =
    Provider.autoDispose<ReadViewActivity>((ref) {
      final activity = ReadViewActivity(onResume: ref.notifyListeners);
      ref.onDispose(activity.dispose);
      return activity;
    });

final websiteInquiryListProvider =
    AsyncNotifierProvider.autoDispose<
      WebsiteInquiryListNotifier,
      PagedResult<WebsiteInquiry>
    >(
      WebsiteInquiryListNotifier.new,
      dependencies: [
        exportContextEpochProvider,
        websiteInquiryReadActivityProvider,
      ],
    );

class WebsiteInquiryListNotifier
    extends AsyncNotifier<PagedResult<WebsiteInquiry>> {
  @override
  Future<PagedResult<WebsiteInquiry>> build() {
    final status = ref.watch(websiteInquiryStatusFilterProvider);
    final history = ref.watch(websiteInquiryHistoryProvider);
    ref.watch(masterDataSessionKeyProvider);
    ref.watch(exportContextEpochProvider);
    final repository = ref.watch(websiteInquiryRepositoryProvider);
    final activity = ref.watch(websiteInquiryReadActivityProvider);
    var current = true;
    ref.onDispose(() => current = false);
    return activity.runRead(
      () => current,
      () => loadCompletePagedResult<WebsiteInquiry>(
        isCurrent: () => current,
        idOf: (inquiry) => inquiry.id,
        loadPage: (page, size) => repository.list(
          status: status?.wireName ?? (history ? 'HISTORY' : 'new'),
          page: page,
          size: size,
        ),
      ),
    );
  }

  Future<void> refresh() async {
    if (state.isLoading) return;
    state = const AsyncLoading<PagedResult<WebsiteInquiry>>();
    ref.invalidateSelf();
    try {
      await future;
    } catch (_) {
      /* Provider exposes the read error. */
    }
  }

  /// 详情页写操作完成后，把服务端回执同步到当前页并保留页码。
  ///
  /// 2026-09-24 修补：写完的行如果已不在当前筛选口径里（如「新询盘」列表里
  /// 点了开始跟进/转客户），要从当前页移除——原来一律原位替换，过滤后的列表
  /// 一直挂着已离开该状态的旧行，返回列表要手动刷新才消失。
  void replaceIfPresent(WebsiteInquiry updated) {
    final current = state.value;
    if (current == null) return;
    final history = ref.read(websiteInquiryHistoryProvider);
    final filter =
        ref.read(websiteInquiryStatusFilterProvider) ??
        (history ? null : WebsiteInquiryStatus.newOne);
    final index = current.items.indexWhere((item) => item.id == updated.id);
    if (index < 0) return; // 不在当前页：翻页/刷新自然带上，不动。
    final terminal =
        updated.status == WebsiteInquiryStatus.converted ||
        updated.status == WebsiteInquiryStatus.closed;
    final stillInFilter =
        terminal == ref.read(websiteInquiryHistoryProvider) &&
        (filter == null || updated.status == filter);
    if (!stillInFilter) {
      final items = [...current.items]..removeAt(index);
      state = AsyncData(
        PagedResult(
          items: items,
          page: 1,
          size: items.length,
          total: items.length,
          totalPages: items.isEmpty ? 0 : 1,
        ),
      );
      return;
    }
    state = AsyncData(
      PagedResult(
        items: [
          for (final item in current.items)
            if (item.id == updated.id) updated else item,
        ],
        page: current.page,
        size: current.size,
        total: current.total,
        totalPages: current.totalPages,
      ),
    );
  }
}

final websiteInquiryDetailProvider = FutureProvider.autoDispose
    .family<WebsiteInquiry?, String>((ref, id) async {
      ref.watch(masterDataSessionKeyProvider);
      ref.watch(authenticatedScopeProvider);
      return ref.watch(websiteInquiryRepositoryProvider).getById(id);
    });

/// 跟进状态推进；成功后同步列表页与详情缓存。
Future<WebsiteInquiry> updateWebsiteInquiryStatus(
  WidgetRef ref, {
  required String id,
  required WebsiteInquiryStatus status,
  String? note,
  bool assignToMe = false,
}) async {
  return _mutateInquiry(
    ref,
    id,
    status == WebsiteInquiryStatus.closed
        ? Perm.webinquiryClose
        : Perm.webinquiryClaim,
    () => ref
        .read(websiteInquiryRepositoryProvider)
        .updateStatus(
          id: id,
          status: status,
          note: note,
          assignToMe: assignToMe,
        ),
  );
}

/// 一键转客户；成功后同步列表页与详情缓存。
Future<WebsiteInquiry> convertWebsiteInquiry(WidgetRef ref, String id) async {
  return _mutateInquiry(
    ref,
    id,
    Perm.webinquiryConvertClient,
    () => ref.read(websiteInquiryRepositoryProvider).convert(id),
  );
}

Future<WebsiteInquiry> followUpWebsiteInquiry(
  WidgetRef ref,
  String id,
  String note,
) => _mutateInquiry(
  ref,
  id,
  Perm.webinquiryClaim,
  () => ref.read(websiteInquiryRepositoryProvider).followUp(id, note),
);

Future<WebsiteInquiry> _mutateInquiry(
  WidgetRef ref,
  String id,
  String permission,
  Future<WebsiteInquiry> Function() action,
) async {
  final owner = ref.read(authenticatedScopeProvider);
  final sessionKey = ref.read(masterDataSessionKeyProvider);
  final scope = await ref
      .read(apiClientProvider)
      .captureRequestScope(
        isCurrent: () =>
            ref.context.mounted &&
            owner != null &&
            !owner.readOnly &&
            ref.read(authenticatedScopeProvider) == owner &&
            ref.read(masterDataSessionKeyProvider) == sessionKey &&
            ref.read(currentPermissionsProvider).contains(permission),
      );
  final updated = await scope.run(action);
  await scope.verify();
  ref.read(websiteInquiryListProvider.notifier).replaceIfPresent(updated);
  ref.invalidate(websiteInquiryDetailProvider(id));
  return updated;
}
