// 建议 Provider

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../models/suggestion.dart';
import '../repositories/suggestion_repository.dart';

final suggestionRepositoryProvider = Provider<SuggestionRepository>((ref) {
  return DioSuggestionRepository(ref.watch(apiClientProvider));
});

/// 列表筛选：我的 / 全部
enum SuggestionScope { square, mine }

extension SuggestionScopeValue on SuggestionScope {
  String get label => switch (this) {
    SuggestionScope.square => '建议广场',
    SuggestionScope.mine => '我的建议',
  };
}

final suggestionScopeProvider = StateProvider<SuggestionScope>((ref) {
  return SuggestionScope.square;
});

/// 列表「状态」表头筛选（2026-09-10）：下推后端 status 参数（非页内裁剪），
/// null = 不筛。与分段（广场/我的）正交；换筛选由 provider 重建回第 1 页。
final suggestionStatusFilterProvider = StateProvider<SuggestionStatus?>(
  (ref) => null,
);

final suggestionListProvider =
    AsyncNotifierProvider.autoDispose<
      SuggestionListNotifier,
      PagedResult<Suggestion>
    >(SuggestionListNotifier.new);

class SuggestionListNotifier
    extends AutoDisposeAsyncNotifier<PagedResult<Suggestion>> {
  final Set<String> _likeRequests = {};

  @override
  Future<PagedResult<Suggestion>> build() {
    // 换分段 / 换表头状态筛选 → 重建即回第 1 页。
    ref.watch(suggestionScopeProvider);
    ref.watch(suggestionStatusFilterProvider);
    return _fetch(1);
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

  /// 直接拉目标页（2026-09-09 建议箱列表表格化：表格内置翻页条含跳页输入）。
  Future<void> goToPage(int page) async {
    final current = state.valueOrNull;
    if (current == null) return;
    if (page < 1 || page == current.page || page > current.totalPages) return;
    await _goTo(page);
  }

  /// 点赞期间按建议 id 防重入；成功后只替换当前页对应行，不跳回第 1 页。
  Future<void> toggleLike(String id) async {
    if (!_likeRequests.add(id)) return;
    try {
      final updated = await ref
          .read(suggestionRepositoryProvider)
          .toggleLike(id);
      replaceIfPresent(updated);
      ref.invalidate(suggestionDetailProvider(id));
    } finally {
      _likeRequests.remove(id);
    }
  }

  /// 回复等详情页写操作完成后，把服务端回执同步到当前页并保留页码。
  void replaceIfPresent(Suggestion updated) {
    final current = state.valueOrNull;
    if (current == null ||
        !current.items.any((item) => item.id == updated.id)) {
      return;
    }
    final summary = updated.copyWith(replies: const []);
    state = AsyncData(
      PagedResult(
        items: [
          for (final item in current.items)
            if (item.id == updated.id) summary else item,
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
        ? const AsyncLoading<PagedResult<Suggestion>>().copyWithPrevious(state)
        : const AsyncLoading<PagedResult<Suggestion>>();
    state = await AsyncValue.guard(() => _fetch(page));
  }

  Future<PagedResult<Suggestion>> _fetch(int page) {
    final scope = ref.read(suggestionScopeProvider);
    return ref
        .read(suggestionRepositoryProvider)
        .list(
          mine: scope == SuggestionScope.mine,
          status: ref.read(suggestionStatusFilterProvider),
          page: page,
        );
  }
}

final suggestionDetailProvider = FutureProvider.autoDispose
    .family<Suggestion?, String>((ref, id) async {
      return ref.watch(suggestionRepositoryProvider).getById(id);
    });

Future<void> toggleSuggestionLike(WidgetRef ref, String id) async {
  await ref.read(suggestionListProvider.notifier).toggleLike(id);
}

Future<Suggestion> submitSuggestion(
  WidgetRef ref, {
  required SuggestionCategory category,
  required String title,
  required String content,
  bool isAnonymous = false,
}) async {
  final s = await ref
      .read(suggestionRepositoryProvider)
      .submit(
        category: category,
        title: title,
        content: content,
        isAnonymous: isAnonymous,
      );
  ref.invalidate(suggestionListProvider);
  return s;
}

Future<Suggestion> replyToSuggestion(
  WidgetRef ref, {
  required String id,
  required String content,
  SuggestionStatus? newStatus,
}) async {
  final suggestion = await ref
      .read(suggestionRepositoryProvider)
      .reply(id: id, content: content, newStatus: newStatus);
  ref.read(suggestionListProvider.notifier).replaceIfPresent(suggestion);
  ref.invalidate(suggestionDetailProvider(id));
  return suggestion;
}
