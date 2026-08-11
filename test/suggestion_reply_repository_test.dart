import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/suggestion/models/suggestion.dart';
import 'package:uten_imp/features/suggestion/repositories/suggestion_repository.dart';

void main() {
  test(
    'official reply sends content and optional status to the real endpoint',
    () async {
      late RequestOptions captured;
      final repository = DioSuggestionRepository(
        _api((request) {
          captured = request;
          return _suggestionJson();
        }),
      );

      final result = await repository.reply(
        id: 'suggestion-1',
        content: '  已安排设备组处理。  ',
        newStatus: SuggestionStatus.reviewing,
      );

      expect(captured.method, 'POST');
      expect(captured.path, '/suggestions/suggestion-1/replies');
      expect(captured.data, {'content': '已安排设备组处理。', 'newStatus': 'reviewing'});
      expect(result.status, SuggestionStatus.reviewing);
      expect(result.replies.single.content, '已安排设备组处理。');
    },
  );

  test(
    'official reply omits newStatus when status must stay unchanged',
    () async {
      late RequestOptions captured;
      final repository = DioSuggestionRepository(
        _api((request) {
          captured = request;
          return _suggestionJson();
        }),
      );

      await repository.reply(id: 'suggestion-1', content: '补充处理进度');

      expect(captured.data, {'content': '补充处理进度'});
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

Map<String, dynamic> _suggestionJson() => {
  'id': 'suggestion-1',
  'submitterId': 'user-1',
  'submitterName': '张三',
  'category': 'equipment',
  'title': '改善设备点检',
  'content': '建议为关键设备增加每日点检提醒。',
  'status': 'reviewing',
  'submittedAt': '2026-07-30T08:00:00Z',
  'isAnonymous': false,
  'likes': 3,
  'likedByMe': false,
  'replies': [
    {
      'id': 'reply-1',
      'replier': '李经理',
      'replierRole': '设备部',
      'content': '已安排设备组处理。',
      'repliedAt': '2026-07-30T09:00:00Z',
    },
  ],
};
