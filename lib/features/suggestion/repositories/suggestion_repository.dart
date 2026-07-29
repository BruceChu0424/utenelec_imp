// 建议箱仓库（真实后端）
// 后端：server .../features/suggestion/SuggestionController（/api/suggestions）

import '../../../core/network/api_client.dart';
import '../../../core/network/api_endpoints.dart';
import '../models/suggestion.dart';

abstract interface class SuggestionRepository {
  /// 建议广场（全员，时间倒序），category 可空
  Future<List<Suggestion>> list({SuggestionCategory? category});

  /// 我提交的
  Future<List<Suggestion>> mine();

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
}

class DioSuggestionRepository implements SuggestionRepository {
  DioSuggestionRepository(this._api);

  final ApiClient _api;

  @override
  Future<List<Suggestion>> list({SuggestionCategory? category}) async {
    final json = await _api.get(
      ApiEndpoints.suggestions,
      query: category != null ? {'category': category.name} : null,
    );
    return _items(json);
  }

  @override
  Future<List<Suggestion>> mine() async {
    final json = await _api.get(ApiEndpoints.suggestions, query: {'scope': 'mine'});
    return _items(json);
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
    final json = await _api.post(ApiEndpoints.suggestions, body: {
      'category': category.name,
      'title': title,
      'content': content,
      'isAnonymous': isAnonymous,
    });
    return _fromJson(json);
  }

  @override
  Future<Suggestion> toggleLike(String id) async {
    final json = await _api.post(ApiEndpoints.suggestionLike(id));
    return _fromJson(json);
  }

  List<Suggestion> _items(Map<String, dynamic> json) {
    final items = (json['items'] as List<dynamic>? ?? const [])
        .cast<Map<String, dynamic>>();
    return [for (final m in items) _fromJson(m)];
  }

  Suggestion _fromJson(Map<String, dynamic> json) {
    return Suggestion(
      id: json['id'] as String,
      submitterId: json['submitterId'] as String? ?? '',
      submitterName: json['submitterName'] as String? ?? '',
      category: _categoryFrom(json['category'] as String?),
      title: json['title'] as String? ?? '',
      content: json['content'] as String? ?? '',
      status: _statusFrom(json['status'] as String?),
      submittedAt:
          DateTime.tryParse(json['submittedAt'] as String? ?? '')?.toLocal() ??
              DateTime.now(),
      isAnonymous: json['isAnonymous'] as bool? ?? false,
      likes: (json['likes'] as num?)?.toInt() ?? 0,
      likedByMe: json['likedByMe'] as bool? ?? false,
      replies: [
        for (final r
            in (json['replies'] as List<dynamic>? ?? const [])
                .cast<Map<String, dynamic>>())
          SuggestionReply(
            id: r['id'] as String,
            replier: r['replier'] as String? ?? '',
            replierRole: r['replierRole'] as String? ?? '',
            content: r['content'] as String? ?? '',
            repliedAt:
                DateTime.tryParse(r['repliedAt'] as String? ?? '')?.toLocal() ??
                    DateTime.now(),
          ),
      ],
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
