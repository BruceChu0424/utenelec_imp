/// Chat results are data, never routes, executable code, or authorization.
library;

class AiChatCapabilities {
  const AiChatCapabilities({
    required this.canChat,
    required this.available,
    this.canUploadSalesOrder = false,
    this.canUploadDocument = false,
    this.workflows = const [],
    this.canManagePermissions = false,
    this.scopeSummary = '',
    this.suggestions = const [],
  });

  factory AiChatCapabilities.fromJson(Map<String, dynamic> json) =>
      AiChatCapabilities(
        canChat: json['canChat'] == true,
        available: json['available'] == true,
        canUploadSalesOrder: json['canUploadSalesOrder'] == true,
        canUploadDocument: json['canUploadDocument'] == true,
        workflows: json['workflows'] is List
            ? (json['workflows'] as List<dynamic>).whereType<String>().toList()
            : const [],
        canManagePermissions: json['canManagePermissions'] == true,
        scopeSummary: _text(json['scopeSummary']),
        suggestions:
            (json['suggestions'] is List
                    ? json['suggestions'] as List<dynamic>
                    : const <dynamic>[])
                .whereType<String>()
                .take(4)
                .toList(growable: false),
      );

  final bool canChat;
  final bool available;
  final bool canUploadSalesOrder;
  final bool canUploadDocument;
  final List<String> workflows;
  final bool canManagePermissions;
  final String scopeSummary;
  final List<String> suggestions;
  bool get usable => canChat;
}

class AiChatPageSuggestions {
  const AiChatPageSuggestions({
    required this.pageRoute,
    this.pageTitle = '',
    this.suggestions = const [],
  });
  factory AiChatPageSuggestions.fromJson(Map<String, dynamic> json) =>
      AiChatPageSuggestions(
        pageRoute: _text(json['pageRoute']),
        pageTitle: _text(json['pageTitle']),
        suggestions: {
          if (json['suggestions'] is List)
            for (final value in json['suggestions'] as List)
              if (value is String &&
                  value.trim().isNotEmpty &&
                  value.length <= 240)
                value.trim(),
        }.take(3).toList(growable: false),
      );
  final String pageRoute;
  final String pageTitle;
  final List<String> suggestions;
}

class AiChatReply {
  const AiChatReply({required this.reply, this.actions = const []});

  factory AiChatReply.fromJson(Map<String, dynamic> json) => AiChatReply(
    reply: _text(json['reply']),
    actions:
        (json['actions'] is List
                ? json['actions'] as List<dynamic>
                : const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .take(8)
            .map(AiChatAction.fromJson)
            .toList(growable: false),
  );

  final String reply;
  final List<AiChatAction> actions;
}

class AiChatAction {
  const AiChatAction({
    required this.type,
    required this.title,
    required this.summary,
    this.jobId,
    this.proposalId,
    this.targetName = '',
    this.permissionCode = '',
    this.permissionName = '',
    this.scopeSummary = '',
    this.expiresAt,
  });

  factory AiChatAction.fromJson(Map<String, dynamic> json) => AiChatAction(
    type: _text(json['type']),
    title: _text(json['title']),
    summary: _text(json['summary']),
    jobId: checkedAiChatId(json['jobId']),
    proposalId:
        json['proposalId'] is String &&
            (json['proposalId'] as String).length <= 16384
        ? json['proposalId'] as String
        : null,
    targetName: _text(json['targetName']),
    permissionCode: _text(json['permissionCode']),
    permissionName: _text(json['permissionName']),
    scopeSummary: _text(json['scopeSummary']),
    expiresAt: DateTime.tryParse(_text(json['expiresAt'])),
  );

  final String type;
  final String title;
  final String summary;
  final String? jobId;
  final String? proposalId;
  final String targetName;
  final String permissionCode;
  final String permissionName;
  final String scopeSummary;
  final DateTime? expiresAt;

  bool get hasReviewableGrant =>
      proposalId != null &&
      proposalId!.isNotEmpty &&
      targetName.isNotEmpty &&
      permissionCode.isNotEmpty &&
      permissionName.isNotEmpty &&
      scopeSummary.isNotEmpty &&
      expiresAt != null;
}

/// Reject all route/query characters even when an AI result supplies an ID.
String? checkedAiChatId(Object? raw) =>
    raw is String && RegExp(r'^[0-9A-Za-z-]{1,64}$').hasMatch(raw) ? raw : null;

String _text(Object? value) => value is String ? value : '';
