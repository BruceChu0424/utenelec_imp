// 建议 Provider

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../../core/network/api_client.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read_provider.dart';
import '../../../shared/providers/export_context_epoch_provider.dart';
import '../models/suggestion.dart';
import '../repositories/suggestion_repository.dart';

// Riverpod 3 将 copyWithPrevious 标记为 @internal；跨 family 实例手动保页/保旧值是既有架构，等上游公开等价 API 后再迁移。
// ignore_for_file: invalid_use_of_internal_member

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

/// 列表「类别」表头筛选（2026-09-16）：下推后端 category 参数（固定枚举六类）。
final suggestionCategoryFilterProvider = StateProvider<SuggestionCategory?>(
  (ref) => null,
);

final suggestionListProvider =
    AsyncNotifierProvider.autoDispose<
      SuggestionListNotifier,
      PagedResult<Suggestion>
    >(
      SuggestionListNotifier.new,
      retry: pagedReadProviderRetry,
      dependencies: [
        _suggestionReads,
        suggestionRepositoryProvider,
        suggestionScopeProvider,
        suggestionCategoryFilterProvider,
        suggestionStatusFilterProvider,
      ],
    );

final _suggestionReads = Provider.autoDispose
    .family<ScopedPagedReadProviderLease<Suggestion>, Object>(
      (ref, query) {
        ref.watch(suggestionRepositoryProvider);
        return ScopedPagedReadProviderLease(ref, query: query);
      },
      dependencies: [exportContextEpochProvider, suggestionRepositoryProvider],
    );

class SuggestionListNotifier extends AsyncNotifier<PagedResult<Suggestion>> {
  final Set<String> _likeRequests = {};
  int _readGeneration = 0;
  int _page = 1;
  Object? _lastReadQuery;
  int? Function()? _visiblePage;

  Object get _readQuery => (
    ref.read(suggestionScopeProvider),
    ref.read(suggestionCategoryFilterProvider),
    ref.read(suggestionStatusFilterProvider),
  );
  ScopedPagedReadProviderLease<Suggestion> get _reader =>
      ref.read(_suggestionReads(_readQuery));
  void bindReadView(BuildContext context, {int? Function()? visiblePage}) {
    _visiblePage = visiblePage;
    _reader.bindView(context, currentQuery: () => _readQuery);
  }

  @override
  Future<PagedResult<Suggestion>> build() {
    ++_readGeneration;
    ref.onDispose(() => ++_readGeneration);
    // 换分段 / 换表头状态或类别筛选 → 重建即回第 1 页。
    ref.watch(suggestionScopeProvider);
    ref.watch(suggestionStatusFilterProvider);
    ref.watch(suggestionCategoryFilterProvider);
    ref.watch(_suggestionReads(_readQuery));
    final query = _readQuery;
    _page = _lastReadQuery == query ? (_visiblePage?.call() ?? _page) : 1;
    _lastReadQuery = query;
    return _fetch(_page);
  }

  Future<void> refresh() async {
    _reader.invalidate();
    await _goTo(_visiblePage?.call() ?? state.value?.page ?? _page, keepPrevious: false);
  }

  Future<void> previousPage() async {
    final current = state.value;
    final page = _visiblePage?.call() ?? current?.page ?? 1;
    if (current == null || page <= 1) return;
    await _goTo(page - 1);
  }

  Future<void> nextPage() async {
    final current = state.value;
    final page = _visiblePage?.call() ?? current?.page ?? 1;
    if (current == null || page >= current.totalPages) return;
    await _goTo(page + 1);
  }

  /// 直接拉目标页（2026-09-09 建议箱列表表格化：表格内置翻页条含跳页输入）。
  Future<void> goToPage(int page) async {
    final current = state.value;
    if (current == null) return;
    if (page < 1 || page == (_visiblePage?.call() ?? current.page) || page > current.totalPages) return;
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
    _reader.invalidate();
    final current = state.value;
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
    final generation = _readGeneration;
    state = keepPrevious
        ? const AsyncLoading<PagedResult<Suggestion>>().copyWithPrevious(state)
        : const AsyncLoading<PagedResult<Suggestion>>();
    final next = keepPrevious
        ? await _reader.paginate(
            page,
            () => AsyncValue.guard(() => _fetch(page)),
          )
        : await AsyncValue.guard(() => _fetch(page));
    if (generation == _readGeneration) {
      if (next.hasValue) _page = next.requireValue.page;
      state = next;
    }
  }

  Future<PagedResult<Suggestion>> _fetch(int page) {
    final scope = ref.read(suggestionScopeProvider);
    final repository = ref.read(suggestionRepositoryProvider);
    final category = ref.read(suggestionCategoryFilterProvider);
    final status = ref.read(suggestionStatusFilterProvider);
    return _reader.read(
      page,
      fetchPage: (page) => repository.list(
        mine: scope == SuggestionScope.mine,
        category: category,
        status: status,
        page: page,
      ),
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
