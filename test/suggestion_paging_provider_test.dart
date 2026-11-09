import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/suggestion/models/suggestion.dart';
import 'package:uten_imp/features/suggestion/providers/suggestion_providers.dart';
import 'package:uten_imp/features/suggestion/repositories/suggestion_repository.dart';
import 'package:uten_imp/shared/models/paged_result.dart';

import 'support/complete_read_plan_batches.dart';

/// More rows than one first batch: the complete scope spans several server
/// batches of the shared plan and its tail row comes from the last batch.
const _total = 145;

void main() {
  test(
    'repository sends 1-based page, scope and category to the server',
    () async {
      late RequestOptions captured;
      final repository = DioSuggestionRepository(
        _api((request) {
          captured = request;
          return {
            'items': [_suggestionJson(id: 'suggestion-41', replyCount: 4)],
            'page': 3,
            'size': 25,
            'total': 41,
            'totalPages': 3,
          };
        }),
      );

      final result = await repository.list(
        mine: true,
        category: SuggestionCategory.process,
        page: 3,
        size: 25,
      );

      expect(captured.method, 'GET');
      expect(captured.path, '/suggestions');
      expect(captured.queryParameters, {
        'scope': 'mine',
        'category': 'process',
        'page': 3,
        'size': 25,
      });
      expect(result.page, 3);
      expect(result.total, 41);
      expect(result.totalPages, 3);
      expect(result.items.single.replyCount, 4);
      expect(result.items.single.replies, isEmpty);
      expect(
        result.items.single.displayName,
        '张三',
        reason: 'the server already applied viewer-specific anonymization',
      );
    },
  );

  test(
    'provider refreshes a complete scope and patches a tail-row like in place',
    () async {
      final repository = _FakeSuggestionRepository();
      final container = ProviderContainer(
        overrides: [suggestionRepositoryProvider.overrideWithValue(repository)],
      );
      addTearDown(container.dispose);
      final subscription = container.listen(
        suggestionListProvider,
        (_, _) {},
        fireImmediately: true,
      );
      addTearDown(subscription.close);

      final first = await container.read(suggestionListProvider.future);
      expect(first.page, 1);
      expect(first.items, hasLength(_total));
      expect(first.total, _total);
      expect(first.totalPages, 1);
      expect(first.items.map((item) => item.id), [
        for (var i = 1; i <= _total; i++) 'suggestion-$i',
      ]);
      final completeRead = [
        for (final batch in completeReadPlanBatches(_total))
          (mine: false, page: batch.page, size: batch.size),
      ];
      expect(completeRead, hasLength(greaterThan(1)));
      expect(repository.calls, completeRead);

      await container.read(suggestionListProvider.notifier).nextPage();
      expect(container.read(suggestionListProvider).requireValue.page, 1);
      expect(
        repository.calls,
        completeRead,
        reason: 'The local complete result needs no paging read',
      );

      await container.read(suggestionListProvider.notifier).refresh();
      expect(container.read(suggestionListProvider).requireValue.page, 1);
      expect(
        container.read(suggestionListProvider).requireValue.items,
        hasLength(_total),
      );
      expect(repository.calls, [...completeRead, ...completeRead]);

      final id = container
          .read(suggestionListProvider)
          .requireValue
          .items
          .last
          .id;
      await container.read(suggestionListProvider.notifier).toggleLike(id);
      final updated = container
          .read(suggestionListProvider)
          .requireValue
          .items
          .last;
      expect(updated.likedByMe, isTrue);
      expect(updated.likes, 1);
      expect(container.read(suggestionListProvider).requireValue.page, 1);
      expect(
        container.read(suggestionListProvider).requireValue.items,
        hasLength(_total),
      );
      expect(repository.calls, [...completeRead, ...completeRead]);

      container
          .read(suggestionListProvider.notifier)
          .replaceIfPresent(
            updated.copyWith(
              replyCount: 3,
              replies: [
                SuggestionReply(
                  id: 'reply-1',
                  replier: '管理员',
                  replierRole: '人事部',
                  content: '已处理',
                  repliedAt: DateTime.utc(2026, 7, 30),
                ),
              ],
            ),
          );
      final replied = container
          .read(suggestionListProvider)
          .requireValue
          .items
          .last;
      expect(replied.replyCount, 3);
      expect(replied.replies, isEmpty);
      expect(container.read(suggestionListProvider).requireValue.page, 1);
      expect(
        container.read(suggestionListProvider).requireValue.items,
        hasLength(_total),
      );

      container.read(suggestionScopeProvider.notifier).state =
          SuggestionScope.mine;
      final mine = await container.read(suggestionListProvider.future);
      expect(mine.page, 1);
      expect(mine.items, hasLength(_total));
      expect(repository.calls.skip(2 * completeRead.length), [
        for (final batch in completeReadPlanBatches(_total))
          (mine: true, page: batch.page, size: batch.size),
      ]);
    },
  );
}

ApiClient _api(Object? Function(RequestOptions request) responder) {
  final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (request, handler) => handler.resolve(
        Response<dynamic>(
          requestOptions: request,
          statusCode: 200,
          data: responder(request),
        ),
      ),
    ),
  );
  return ApiClient(dio);
}

Map<String, dynamic> _suggestionJson({
  required String id,
  int replyCount = 0,
}) => {
  'id': id,
  'submitterId': 'user-1',
  'submitterName': '张三',
  'category': 'process',
  'title': '改善流程',
  'content': '建议减少重复录入并保留完整审批记录。',
  'status': 'submitted',
  'submittedAt': '2026-07-30T08:00:00Z',
  'isAnonymous': true,
  'likes': 0,
  'likedByMe': false,
  'replyCount': replyCount,
  'replies': const <Map<String, dynamic>>[],
};

typedef _ListCall = ({bool mine, int page, int size});

class _FakeSuggestionRepository implements SuggestionRepository {
  final calls = <_ListCall>[];
  final suggestions = <String, Suggestion>{};

  @override
  Future<PagedResult<Suggestion>> list({
    bool mine = false,
    SuggestionCategory? category,
    SuggestionStatus? status,
    int page = 1,
    int size = 20,
    Map<String, String?> columns = const {},
    String? sort,
    bool ascending = true,
  }) async {
    calls.add((mine: mine, page: page, size: size));
    final rows = [
      for (
        var index = (page - 1) * size;
        index < _total && index < page * size;
        index++
      )
        Suggestion(
          id: 'suggestion-${index + 1}',
          submitterId: 'user-1',
          submitterName: '张三',
          category: SuggestionCategory.process,
          title: '建议 ${index + 1}',
          content: '完整范围由服务端有界分批返回，保留各行原身份与精确状态。',
          status: SuggestionStatus.submitted,
          submittedAt: DateTime.utc(2026, 7, 30),
        ),
    ];
    for (final suggestion in rows) {
      suggestions[suggestion.id] = suggestion;
    }
    return PagedResult(
      items: rows,
      page: page,
      size: size,
      total: _total,
      totalPages: (_total / size).ceil(),
    );
  }

  @override
  Future<Suggestion> toggleLike(String id) async {
    final current = suggestions[id]!;
    final updated = current.copyWith(likes: 1, likedByMe: true);
    suggestions[id] = updated;
    return updated;
  }

  @override
  Future<Suggestion?> getById(String id) async => suggestions[id];

  @override
  Future<Suggestion> reply({
    required String id,
    required String content,
    SuggestionStatus? newStatus,
  }) async {
    return suggestions[id]!;
  }

  @override
  Future<Suggestion> submit({
    required SuggestionCategory category,
    required String title,
    required String content,
    bool isAnonymous = false,
  }) async {
    throw UnimplementedError();
  }
}
