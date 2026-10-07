import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/api_client.dart';
import '../ai_job_models.dart';
import 'ai_chat_models.dart';

abstract interface class AiChatRepository {
  Future<AiChatCapabilities> capabilities();
  Future<AiChatPageSuggestions> pageSuggestions(String pageRoute);

  /// [snapshot] is the bounded page snapshot (ADR-150), sent only together
  /// with a valid [currentRoute] while page reading is on. [conversationId]
  /// ties the question to the current conversation (ADR-152): the server
  /// reads the earlier turns itself; the client never sends history.
  /// [locale] is the interface language a reply follows by default.
  Future<AiJobSnapshot> send({
    required String message,
    required String conversationId,
    String? currentRoute,
    String? intentHint,
    Map<String, Object?>? snapshot,
    String? locale,
  });

  /// Changes one or more chat settings (whitelisted on the server).
  Future<({AiChatSettings settings, bool reasoningEffortSupported})>
  updateSettings(Map<String, Object> change);

  /// The caller's conversation to restore: [conversationId], or the latest.
  Future<AiChatConversationView> conversation({String? conversationId});

  /// Clears the caller's own chat history on the server.
  Future<void> clearConversations();

  /// The caller's own remembered operations (ADR-163), for the welcome area.
  Future<List<AiChatMemorySuggestion>> memorySuggestions();

  /// Clears the caller's own operation memory on the server (ADR-163).
  Future<void> clearOperationMemory();

  /// Current state of a confirmation card; use it when a result is unknown
  /// instead of confirming again.
  Future<AiChatAction> actionStatus(String proposalId);

  /// One-time consumption of a client card; returns the authoritative
  /// arguments the page handler must use.
  Future<({AiChatAction card, Map<String, Object?> args})> confirmAction(
    String proposalId,
  );
  Future<AiChatAction> cancelAction(String proposalId);
  Future<AiChatAction> actionReceipt(
    String proposalId, {
    required bool succeeded,
    String? message,
  });

  /// Server-executed super-admin grant; the network layer adds step-up.
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
  Future<AiChatPageSuggestions> pageSuggestions(String pageRoute) async {
    final path = safeAiChatRoute(pageRoute);
    if (path == null || path.length > 240) {
      throw const FormatException('Invalid AI page suggestion path');
    }
    final result = AiChatPageSuggestions.fromJson(
      await api.get('/ai/chat/page-suggestions', query: {'pageRoute': path}),
    );
    if (result.pageRoute != path) {
      throw const FormatException('AI page suggestions belong to another page');
    }
    return result;
  }

  String _proposalPath(String proposalId) {
    if (!aiChatProposalId.hasMatch(proposalId)) {
      throw const FormatException('Invalid AI action proposal ID');
    }
    return '/ai/chat/actions/${proposalId.toLowerCase()}';
  }

  AiChatAction _card(Map<String, dynamic> json, String proposalId) {
    final card = AiChatAction.tryParse(json);
    if (card == null || card.proposalId != proposalId.toLowerCase()) {
      throw const FormatException('AI action card belongs to another proposal');
    }
    return card;
  }

  @override
  Future<AiChatAction> actionStatus(String proposalId) async =>
      _card(await api.get(_proposalPath(proposalId)), proposalId);

  @override
  Future<({AiChatAction card, Map<String, Object?> args})> confirmAction(
    String proposalId,
  ) async {
    final json = await api.post('${_proposalPath(proposalId)}/confirm');
    final card = _card(json, proposalId);
    if (card.status != AiChatActionStatus.confirmed ||
        json['args'] is! Map<String, dynamic>) {
      throw const FormatException('AI action confirmation has no arguments');
    }
    return (
      card: card,
      args: Map<String, Object?>.of(json['args'] as Map<String, dynamic>),
    );
  }

  @override
  Future<AiChatAction> cancelAction(String proposalId) async =>
      _card(await api.post('${_proposalPath(proposalId)}/cancel'), proposalId);

  @override
  Future<AiChatAction> actionReceipt(
    String proposalId, {
    required bool succeeded,
    String? message,
  }) async {
    final note = message?.trim();
    return _card(
      await api.post(
        '${_proposalPath(proposalId)}/receipt',
        body: {
          'outcome': succeeded ? 'SUCCEEDED' : 'FAILED',
          if (note != null && note.isNotEmpty)
            'message': note.length > 500 ? note.substring(0, 500) : note,
        },
      ),
      proposalId,
    );
  }

  @override
  Future<String> confirmPermissionGrant(String proposalId) async {
    if (!aiChatProposalId.hasMatch(proposalId)) {
      throw const FormatException('Invalid AI action proposal ID');
    }
    final json = await api.post(
      '/ai/chat/permission-grants/confirm',
      body: {'proposalId': proposalId.toLowerCase()},
    );
    if (json['status'] != 'GRANTED' && json['status'] != 'ALREADY_GRANTED') {
      throw const FormatException('Unknown AI permission confirmation outcome');
    }
    return json['reply'] is String ? json['reply'] as String : '';
  }

  @override
  Future<({AiChatSettings settings, bool reasoningEffortSupported})>
  updateSettings(Map<String, Object> change) async {
    if (change.isEmpty) throw const FormatException('Empty settings change');
    final json = await api.patch('/ai/chat/settings', body: change);
    return (
      settings: AiChatSettings.fromJson(json['settings']),
      reasoningEffortSupported: json['reasoningEffortSupported'] == true,
    );
  }

  @override
  Future<AiChatConversationView> conversation({String? conversationId}) async {
    if (conversationId != null && !aiChatUuid.hasMatch(conversationId)) {
      throw const FormatException('Invalid AI conversation ID');
    }
    return AiChatConversationView.fromJson(
      await api.get(
        '/ai/chat/conversations/current',
        query: {
          if (conversationId != null)
            'conversationId': conversationId.toLowerCase(),
        },
      ),
    );
  }

  @override
  Future<void> clearConversations() => api.delete('/ai/chat/conversations');

  @override
  Future<List<AiChatMemorySuggestion>> memorySuggestions() async =>
      AiChatMemorySuggestion.listFrom(
        await api.get('/ai/chat/memory/suggestions'),
      );

  @override
  Future<void> clearOperationMemory() => api.delete('/ai/chat/memory');

  @override
  Future<AiJobSnapshot> send({
    required String message,
    required String conversationId,
    String? currentRoute,
    String? intentHint,
    Map<String, Object?>? snapshot,
    String? locale,
  }) async {
    if (!aiChatUuid.hasMatch(conversationId)) {
      throw const FormatException('Invalid AI conversation ID');
    }
    final route = safeAiChatRoute(currentRoute);
    if (intentHint != null && (intentHint != 'PAGE_HELP' || route == null)) {
      throw const FormatException(
        'Invalid AI chat intent hint or page context',
      );
    }
    final job = AiJobSnapshot.fromJson(
      await api.post(
        '/ai/chat/messages',
        body: {
          'message': message,
          'conversationId': conversationId.toLowerCase(),
          'intentHint': ?intentHint,
          if (const {'zh', 'en', 'ko'}.contains(locale)) 'locale': locale,
          if (route != null)
            'pageContext': {'route': route, 'snapshot': ?snapshot},
        },
      ),
    );
    if (checkedAiChatId(job.id) == null) {
      throw const FormatException('AI chat response has no valid job ID');
    }
    return job;
  }
}

/// Proposal ids are server UUIDs; anything else never reaches a URL path.
final aiChatProposalId = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// The page path never carries a query or fragment. The bounded snapshot of
/// what is visible on the page travels separately (ADR-150).
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
