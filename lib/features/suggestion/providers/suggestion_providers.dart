// 建议 Provider

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
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

final suggestionListProvider =
    AsyncNotifierProvider.autoDispose<SuggestionListNotifier, List<Suggestion>>(
  SuggestionListNotifier.new,
);

class SuggestionListNotifier
    extends AutoDisposeAsyncNotifier<List<Suggestion>> {
  @override
  Future<List<Suggestion>> build() async {
    final scope = ref.watch(suggestionScopeProvider);
    final repo = ref.watch(suggestionRepositoryProvider);
    return scope == SuggestionScope.mine ? repo.mine() : repo.list();
  }

  Future<void> refresh() async {
    state = const AsyncLoading();
    state = await AsyncValue.guard(() {
      final scope = ref.read(suggestionScopeProvider);
      final repo = ref.read(suggestionRepositoryProvider);
      return scope == SuggestionScope.mine ? repo.mine() : repo.list();
    });
  }
}

final suggestionDetailProvider =
    FutureProvider.autoDispose.family<Suggestion?, String>((ref, id) async {
  return ref.watch(suggestionRepositoryProvider).getById(id);
});

Future<void> toggleSuggestionLike(WidgetRef ref, String id) async {
  await ref.read(suggestionRepositoryProvider).toggleLike(id);
  ref.invalidate(suggestionListProvider);
  ref.invalidate(suggestionDetailProvider(id));
}

Future<Suggestion> submitSuggestion(
  WidgetRef ref, {
  required SuggestionCategory category,
  required String title,
  required String content,
  bool isAnonymous = false,
}) async {
  final s = await ref.read(suggestionRepositoryProvider).submit(
        category: category,
        title: title,
        content: content,
        isAnonymous: isAnonymous,
      );
  ref.invalidate(suggestionListProvider);
  return s;
}
