// 官网询盘 Provider

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/providers/master_name_provider.dart'
    show masterDataSessionKeyProvider;
import '../models/website_inquiry.dart';
import '../repositories/website_inquiry_repository.dart';

final websiteInquiryRepositoryProvider = Provider<WebsiteInquiryRepository>((
  ref,
) {
  return DioWebsiteInquiryRepository(ref.watch(apiClientProvider));
});

/// Null clears only the status within the current active/history scope.
final websiteInquiryStatusFilterProvider = StateProvider<WebsiteInquiryStatus?>(
  (ref) => null,
);
final websiteInquiryHistoryProvider = StateProvider<bool>((ref) => false);

final websiteInquiryListProvider =
    AsyncNotifierProvider.autoDispose<
      WebsiteInquiryListNotifier,
      PagedResult<WebsiteInquiry>
    >(WebsiteInquiryListNotifier.new);

class WebsiteInquiryListNotifier
    extends AutoDisposeAsyncNotifier<PagedResult<WebsiteInquiry>> {
  int _page = 1;
  Object? _lastScope;
  @override
  Future<PagedResult<WebsiteInquiry>> build() {
    final status = ref.watch(websiteInquiryStatusFilterProvider);
    final history = ref.watch(websiteInquiryHistoryProvider);
    final scope = (status, history, ref.watch(masterDataSessionKeyProvider));
    if (_lastScope != scope) _page = 1;
    _lastScope = scope;
    return ref
        .watch(websiteInquiryRepositoryProvider)
        .list(
          status: status?.wireName ?? (history ? 'HISTORY' : 'ACTIVE'),
          page: _page,
        );
  }

  Future<void> refresh() async {
    await _goTo(state.valueOrNull?.page ?? 1, keepPrevious: false);
  }

  Future<void> previousPage() async {
    final current = state.valueOrNull;
    if (current == null || current.page <= 1) return;
    await _goTo(current.page - 1);
  }

  Future<void> nextPage() async {
    final current = state.valueOrNull;
    if (current == null || current.page >= current.totalPages) return;
    await _goTo(current.page + 1);
  }

  /// 详情页写操作完成后，把服务端回执同步到当前页并保留页码。
  ///
  /// 2026-09-24 修补：写完的行如果已不在当前筛选口径里（如「新询盘」列表里
  /// 点了开始跟进/转客户），要从当前页移除——原来一律原位替换，过滤后的列表
  /// 一直挂着已离开该状态的旧行，返回列表要手动刷新才消失。
  void replaceIfPresent(WebsiteInquiry updated) {
    final current = state.valueOrNull;
    if (current == null) return;
    final filter = ref.read(websiteInquiryStatusFilterProvider);
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
      final total = current.total > 0 ? current.total - 1 : 0;
      final size = current.size > 0 ? current.size : 1;
      final totalPages = (total + size - 1) ~/ size;
      final lastPage = totalPages > 0 ? totalPages : 1;
      final targetPage = current.page > lastPage
          ? lastPage
          : items.isEmpty && current.page > 1
          ? current.page - 1
          : current.page;
      if (targetPage != current.page) {
        // A server mutation can remove the last row of the last page. Reload
        // a valid page through build so filters and stale-response guards stay
        // identical to ordinary navigation and later refreshes.
        _page = targetPage;
        state = const AsyncLoading();
        ref.invalidateSelf();
        return;
      }
      state = AsyncData(
        PagedResult(
          items: items,
          page: current.page,
          size: current.size,
          total: total,
          totalPages: totalPages,
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

  Future<void> _goTo(int page, {bool keepPrevious = true}) async {
    if (state.isLoading) return;
    state = keepPrevious
        ? const AsyncLoading<PagedResult<WebsiteInquiry>>().copyWithPrevious(
            state,
          )
        : const AsyncLoading<PagedResult<WebsiteInquiry>>();
    _page = page;
    ref.invalidateSelf();
    try {
      await future;
    } catch (_) {
      /* Provider state retains the error. */
    }
  }
}

final websiteInquiryDetailProvider = FutureProvider.autoDispose
    .family<WebsiteInquiry?, String>((ref, id) async {
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
  final updated = await ref
      .read(websiteInquiryRepositoryProvider)
      .updateStatus(id: id, status: status, note: note, assignToMe: assignToMe);
  ref.read(websiteInquiryListProvider.notifier).replaceIfPresent(updated);
  ref.invalidate(websiteInquiryDetailProvider(id));
  return updated;
}

/// 一键转客户；成功后同步列表页与详情缓存。
Future<WebsiteInquiry> convertWebsiteInquiry(WidgetRef ref, String id) async {
  final updated = await ref.read(websiteInquiryRepositoryProvider).convert(id);
  ref.read(websiteInquiryListProvider.notifier).replaceIfPresent(updated);
  ref.invalidate(websiteInquiryDetailProvider(id));
  return updated;
}
