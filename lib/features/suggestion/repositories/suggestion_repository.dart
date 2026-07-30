// 建议箱仓库（真实后端）
// 后端：server .../features/suggestion/SuggestionController（/api/suggestions）

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/models/paged_result.dart';
import '../models/suggestion.dart';

abstract interface class SuggestionRepository {
  /// 建议广场 / 我的建议（真实服务端分页），category 可空。
  Future<PagedResult<Suggestion>> list({
    bool mine = false,
    SuggestionCategory? category,
    int page = 1,
    int size = 20,
  });

  Future<Suggestion?> getById(String id);

  /// 提交建议
  Future<Suggestion> submit({
    required SuggestionCategory category,
    required String title,
    required String content,
    bool isAnonymous = false,
  });

  /// 点赞切换（有则取消、无则点赞）
  Future<Suggestion> toggleLike(String id);

  /// 官方回复；[newStatus] 为空时仅追加回复，不改变处理状态。
  Future<Suggestion> reply({
    required String id,
    required String content,
    SuggestionStatus? newStatus,
  });
}

class DioSuggestionRepository implements SuggestionRepository {
  DioSuggestionRepository(this._api);

  final ApiClient _api;

  @override
  Future<PagedResult<Suggestion>> list({
    bool mine = false,
    SuggestionCategory? category,
    int page = 1,
    int size = 20,
  }) async {
    final json = await _api.get(
      ApiEndpoints.suggestions,
      query: {
        if (mine) 'scope': 'mine',
        if (category != null) 'category': category.name,
        'page': page,
        'size': size,
      },
    );
    return PagedResult.fromJson(json, _fromJson);
  }

  @override
  Future<Suggestion?> getById(String id) async {
    final json = await _api.get(ApiEndpoints.suggestion(id));
    if (json.isEmpty) return null;
    return _fromJson(json);
  }

  @override
  Future<Suggestion> submit({
    required SuggestionCategory category,
    required String title,
    required String content,
    bool isAnonymous = false,
  }) async {
    final json = await _api.post(
      ApiEndpoints.suggestions,
      body: {
        'category': category.name,
        'title': title,
        'content': content,
        'isAnonymous': isAnonymous,
      },
    );
    return _fromJson(json);
  }

  @override
  Future<Suggestion> toggleLike(String id) async {
    final json = await _api.post(ApiEndpoints.suggestionLike(id));
    return _fromJson(json);
  }

  @override
  Future<Suggestion> reply({
    required String id,
    required String content,
    SuggestionStatus? newStatus,
  }) async {
    final json = await _api.post(
      ApiEndpoints.suggestionReplies(id),
      body: {
        'content': content.trim(),
        if (newStatus != null) 'newStatus': newStatus.name,
      },
    );
    return _fromJson(json);
  }

  Suggestion _fromJson(Map<String, dynamic> json) {
    final replies = [
      for (final r
          in (json['replies'] as List<dynamic>? ?? const [])
              .cast<Map<String, dynamic>>())
        SuggestionReply(
          id: r['id'] as String,
          replier: r['replier'] as String? ?? '',
          replierRole: r['replierRole'] as String? ?? '',
          content: r['content'] as String? ?? '',
          repliedAt:
              ChinaDateTime.tryParse(r['repliedAt'] as String?) ??
              ChinaDateTime.now(),
        ),
    ];
    return Suggestion(
      id: json['id'] as String,
      submitterId: json['submitterId'] as String? ?? '',
      submitterName: json['submitterName'] as String? ?? '',
      category: _categoryFrom(json['category'] as String?),
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      status: _statusFrom(json['status'] as String?),
      submittedAt:
          ChinaDateTime.tryParse(json['submittedAt'] as String?) ??
          ChinaDateTime.now(),
      isAnonymous: json['isAnonymous'] as bool? ?? false,
      likes: (json['likes'] as num?)?.toInt() ?? 0,
      likedByMe: json['likedByMe'] as bool? ?? false,
      replyCount: (json['replyCount'] as num?)?.toInt() ?? replies.length,
      replies: replies,
    );
  }

  static SuggestionCategory _categoryFrom(String? name) => switch (name) {
    'process' => SuggestionCategory.process,
    'welfare' => SuggestionCategory.welfare,
    'environment' => SuggestionCategory.environment,
    'equipment' => SuggestionCategory.equipment,
    'other' => SuggestionCategory.other,
    _ => SuggestionCategory.product,
  };

  static SuggestionStatus _statusFrom(String? name) => switch (name) {
    'reviewing' => SuggestionStatus.reviewing,
    'resolved' => SuggestionStatus.resolved,
    'rejected' => SuggestionStatus.rejected,
    _ => SuggestionStatus.submitted,
  };
}
