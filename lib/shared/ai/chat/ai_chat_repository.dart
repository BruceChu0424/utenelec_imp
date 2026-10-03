import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../ai_job_models.dart';
import 'ai_chat_models.dart';

abstract interface class AiChatRepository {
  Future<AiChatCapabilities> capabilities();
  Future<AiJobSnapshot> send({
    required String message,
    String? previousJobId,
    String? attachmentJobId,
    String? currentRoute,
  });
  Future<String> confirmPermissionGrant(String proposalId);
}

final aiChatRepositoryProvider = Provider<AiChatRepository>(
  (ref) => DioAiChatRepository(ref.watch(apiClientProvider)),
);

class DioAiChatRepository implements AiChatRepository {
  const DioAiChatRepository(this.api);
  final ApiClient api;

  @override
  Future<AiChatCapabilities> capabilities() async =>
      AiChatCapabilities.fromJson(await api.get('/ai/chat/capabilities'));

  @override
  Future<String> confirmPermissionGrant(String proposalId) async {
    final json = await api.post(
      '/ai/chat/permission-grants/confirm',
      body: {'proposalId': proposalId},
    );
    if (json['status'] != 'GRANTED' && json['status'] != 'ALREADY_GRANTED') {
      throw const FormatException('Unknown AI permission confirmation outcome');
    }
    return json['reply'] is String ? json['reply'] as String : '';
  }

  @override
  Future<AiJobSnapshot> send({
    required String message,
    String? previousJobId,
    String? attachmentJobId,
    String? currentRoute,
  }) async {
    for (final id in [previousJobId, attachmentJobId]) {
      if (id != null && checkedAiChatId(id) == null) {
        throw const FormatException('Invalid AI chat job ID');
      }
    }
    final snapshot = AiJobSnapshot.fromJson(
      await api.post(
        '/ai/chat/messages',
        body: {
          'message': message,
          'previousJobId': ?previousJobId,
          'attachmentJobId': ?attachmentJobId,
          if (safeAiChatRoute(currentRoute) case final route?)
            'pageContext': {'route': route},
        },
      ),
    );
    if (checkedAiChatId(snapshot.id) == null) {
      throw const FormatException('AI chat response has no valid job ID');
    }
    return snapshot;
  }
}

/// Page awareness sends only a local path: never a query, URL, or form value.
String? safeAiChatRoute(String? raw) {
  if (raw == null || raw.length > 512) return null;
  final rawPath = raw.split(RegExp(r'[?#]')).first;
  if (rawPath.contains('..') || rawPath.contains('%')) return null;
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.hasScheme || uri.hasAuthority) return null;
  final path = uri.path;
  if (!RegExp(r'^/[a-zA-Z0-9/_-]*$').hasMatch(path) ||
      path.contains('//') ||
      path.contains('..')) {
    return null;
  }
  return path;
}
