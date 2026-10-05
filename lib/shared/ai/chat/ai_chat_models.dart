/// Chat results are data, never routes, executable code, or authorization.
library;

/// How much an answer unfolds by default (ADR-152). Words in one question
/// ("简单点" / "详细点") override it on the server for that question only.
enum AiChatDetail {
  comprehensive('COMPREHENSIVE'),
  standard('STANDARD'),
  concise('CONCISE');

  const AiChatDetail(this.wire);
  final String wire;
  static AiChatDetail? parse(Object? raw) =>
      values.where((value) => value.wire == raw).firstOrNull;
}

/// Thinking depth; mapped by the server to the provider's own parameter.
enum AiChatReasoning {
  fast('FAST'),
  standard('STANDARD'),
  deep('DEEP');

  const AiChatReasoning(this.wire);
  final String wire;
  static AiChatReasoning? parse(Object? raw) =>
      values.where((value) => value.wire == raw).firstOrNull;
}

/// Answer language; [auto] follows the interface language.
enum AiChatReplyLanguage {
  auto('AUTO'),
  zh('ZH'),
  en('EN'),
  ko('KO');

  const AiChatReplyLanguage(this.wire);
  final String wire;
  static AiChatReplyLanguage? parse(Object? raw) =>
      values.where((value) => value.wire == raw).firstOrNull;
}

/// Composer key that sends a message.
enum AiChatSendKey {
  enter('ENTER'),
  ctrlEnter('CTRL_ENTER');

  const AiChatSendKey(this.wire);
  final String wire;
  static AiChatSendKey? parse(Object? raw) =>
      values.where((value) => value.wire == raw).firstOrNull;
}

/// Plain words that explain terms, or concise business terminology.
enum AiChatExplanationStyle {
  plain('PLAIN'),
  professional('PROFESSIONAL');

  const AiChatExplanationStyle(this.wire);
  final String wire;
  static AiChatExplanationStyle? parse(Object? raw) =>
      values.where((value) => value.wire == raw).firstOrNull;
}

/// Per-account chat settings (ADR-152), stored on the server with the account
/// so they follow the person to every device. Unknown or invalid stored values
/// fall back field by field to the defaults; none of them can widen what is
/// read or sent (page reading can only be switched off; actions are always
/// confirmed and are not a setting).
class AiChatSettings {
  const AiChatSettings({
    this.detail = AiChatDetail.standard,
    this.reasoning = AiChatReasoning.fast,
    this.pageAware = true,
    this.showSources = true,
    this.memoryTurns = 6,
    this.replyLanguage = AiChatReplyLanguage.auto,
    this.sendKey = AiChatSendKey.enter,
    this.explanationStyle = AiChatExplanationStyle.plain,
    this.showSuggestions = true,
  });

  static const defaults = AiChatSettings();
  static const memoryChoices = [0, 3, 6, 10];

  factory AiChatSettings.fromJson(Object? raw) {
    if (raw is! Map) return defaults;
    bool flag(Object? value, bool fallback) => value is bool ? value : fallback;
    final memory = raw['memoryTurns'];
    return AiChatSettings(
      detail: AiChatDetail.parse(raw['detail']) ?? defaults.detail,
      reasoning: AiChatReasoning.parse(raw['reasoning']) ?? defaults.reasoning,
      pageAware: flag(raw['pageAware'], defaults.pageAware),
      showSources: flag(raw['showSources'], defaults.showSources),
      memoryTurns: memory is int && memoryChoices.contains(memory)
          ? memory
          : defaults.memoryTurns,
      replyLanguage:
          AiChatReplyLanguage.parse(raw['replyLanguage']) ??
          defaults.replyLanguage,
      sendKey: AiChatSendKey.parse(raw['sendKey']) ?? defaults.sendKey,
      explanationStyle:
          AiChatExplanationStyle.parse(raw['explanationStyle']) ??
          defaults.explanationStyle,
      showSuggestions: flag(raw['showSuggestions'], defaults.showSuggestions),
    );
  }

  final AiChatDetail detail;
  final AiChatReasoning reasoning;
  final bool pageAware;
  final bool showSources;
  final int memoryTurns;
  final AiChatReplyLanguage replyLanguage;
  final AiChatSendKey sendKey;
  final AiChatExplanationStyle explanationStyle;
  final bool showSuggestions;

  Map<String, Object> toJson() => {
    'detail': detail.wire,
    'reasoning': reasoning.wire,
    'pageAware': pageAware,
    'showSources': showSources,
    'memoryTurns': memoryTurns,
    'replyLanguage': replyLanguage.wire,
    'sendKey': sendKey.wire,
    'explanationStyle': explanationStyle.wire,
    'showSuggestions': showSuggestions,
  };

  /// These settings with one field changed (the wire name and wire value the
  /// server accepts); unknown fields or values leave the settings unchanged.
  AiChatSettings withField(String field, Object value) =>
      AiChatSettings.fromJson({...toJson(), field: value});

  @override
  bool operator ==(Object other) =>
      other is AiChatSettings &&
      other.toJson().toString() == toJson().toString();

  @override
  int get hashCode => toJson().toString().hashCode;
}

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
    this.settings = AiChatSettings.defaults,
    this.reasoningEffortSupported = false,
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
        settings: AiChatSettings.fromJson(json['settings']),
        reasoningEffortSupported: json['reasoningEffortSupported'] == true,
      );

  final bool canChat;
  final bool available;
  final bool canUploadSalesOrder;
  final bool canUploadDocument;
  final List<String> workflows;
  final bool canManagePermissions;
  final String scopeSummary;
  final List<String> suggestions;

  /// The account's chat settings (ADR-152).
  final AiChatSettings settings;

  /// Whether the current AI service can adjust thinking depth.
  final bool reasoningEffortSupported;
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

/// One assistant answer (ADR-150): plain text, its sources, whether it is the
/// deterministic page summary (model unavailable or rejected by the fact
/// guard) and server-issued confirmation cards.
class AiChatReply {
  const AiChatReply({
    required this.reply,
    this.actions = const [],
    this.sources = const [],
    this.fallback = false,
    this.intent = '',
    this.question = '',
    this.conversationId,
    this.pageTitle = '',
    this.dataChanged = false,
  });

  factory AiChatReply.fromJson(Map<String, dynamic> json) => AiChatReply(
    reply: _text(json['reply']),
    actions: AiChatAction.listFrom(json['actions']),
    sources: [
      if (json['sources'] is List)
        for (final source in (json['sources'] as List).take(8))
          if (source is Map<String, dynamic> &&
              source['id'] is String &&
              source['label'] is String &&
              (source['label'] as String).trim().isNotEmpty &&
              (source['label'] as String).length <= 80)
            (
              id: source['id'] as String,
              label: (source['label'] as String).trim(),
            ),
    ],
    fallback: json['fallback'] == true,
    intent: _text(json['intent']),
    question: _text(json['question']),
    conversationId: aiChatUuid.hasMatch(_text(json['conversationId']))
        ? _text(json['conversationId']).toLowerCase()
        : null,
    pageTitle: _text(json['pageTitle']).length <= 80
        ? _text(json['pageTitle'])
        : '',
    dataChanged: json['dataChanged'] == true,
  );

  final String reply;
  final List<AiChatAction> actions;
  final List<({String id, String label})> sources;
  final bool fallback;
  final String intent;

  /// The question this reply answers (as stored by the server).
  final String question;

  /// The conversation the turn belongs to (ADR-152).
  final String? conversationId;

  /// Title of the page the question was asked on, when known.
  final String pageTitle;

  /// A restored turn whose answer quoted business data that has changed
  /// since (ADR-152): the server returns only the question, never the old
  /// answer.
  final bool dataChanged;
}

/// One stored turn of the caller's own conversation, re-read and re-checked
/// by the server when the chat is restored.
class AiChatTurn {
  const AiChatTurn({required this.jobId, required this.reply});
  final String jobId;
  final AiChatReply reply;
}

/// The caller's conversation to show after a page refresh (ADR-152). Turns
/// that no longer pass the server's identity and access checks are only
/// counted; a turn whose quoted data changed comes back as its question.
class AiChatConversationView {
  const AiChatConversationView({
    this.conversationId,
    this.turns = const [],
    this.hiddenTurns = 0,
  });

  factory AiChatConversationView.fromJson(Map<String, dynamic> json) {
    final id = _text(json['conversationId']);
    return AiChatConversationView(
      conversationId: aiChatUuid.hasMatch(id) ? id.toLowerCase() : null,
      turns: [
        if (json['turns'] is List)
          for (final turn in (json['turns'] as List).take(40))
            if (turn is Map<String, dynamic> &&
                checkedAiChatId(turn['jobId']) != null &&
                turn['result'] is Map<String, dynamic>)
              AiChatTurn(
                jobId: turn['jobId'] as String,
                reply: AiChatReply.fromJson(
                  turn['result'] as Map<String, dynamic>,
                ),
              ),
      ],
      hiddenTurns: json['hiddenTurns'] is int
          ? (json['hiddenTurns'] as int).clamp(0, 1000)
          : 0,
    );
  }

  final String? conversationId;
  final List<AiChatTurn> turns;
  final int hiddenTurns;
}

/// Conversation and proposal ids are server-style UUIDs.
final aiChatUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Effective card status returned by the server (an expired or identity-voided
/// open card is already reported as EXPIRED / CANCELLED).
enum AiChatActionStatus {
  proposed('PROPOSED'),
  confirmed('CONFIRMED'),
  cancelled('CANCELLED'),
  expired('EXPIRED'),
  failed('FAILED');

  const AiChatActionStatus(this.wire);
  final String wire;
  static AiChatActionStatus? parse(Object? raw) =>
      values.where((value) => value.wire == raw).firstOrNull;
}

/// A server-issued one-time confirmation card (`CONFIRM_ACTION`). Its summary
/// lines are rendered by the server; the model's text never becomes a line.
/// Arguments shown here are display-only: execution uses the arguments the
/// confirm endpoint returns.
class AiChatAction {
  const AiChatAction({
    required this.proposalId,
    required this.actionType,
    required this.handler,
    required this.execution,
    required this.title,
    required this.summaryLines,
    required this.risk,
    required this.status,
    required this.expiresAt,
    this.riskNote,
    this.requiresStepUp = false,
    this.route,
    this.args = const {},
    this.outcome,
    this.outcomeMessage,
  });

  static const pageAction = 'PAGE_ACTION';
  static const openGuidedForm = 'OPEN_GUIDED_FORM';
  static const permissionGrant = 'PERMISSION_GRANT';
  static final _uuid = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    caseSensitive: false,
  );
  static final _handler = RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,47}$');

  /// Unknown types, malformed ids, handlers or routes are dropped, never shown.
  static AiChatAction? tryParse(Object? raw) {
    if (raw is! Map<String, dynamic> || raw['type'] != 'CONFIRM_ACTION') {
      return null;
    }
    final id = raw['proposalId'];
    final type = raw['actionType'];
    final handler = raw['handler'];
    final execution = raw['execution'];
    final status = AiChatActionStatus.parse(raw['status']);
    final expires = DateTime.tryParse(_text(raw['expiresAt']));
    final route = raw['route'];
    if (id is! String ||
        !_uuid.hasMatch(id) ||
        !const {pageAction, openGuidedForm, permissionGrant}.contains(type) ||
        handler is! String ||
        !_handler.hasMatch(handler) ||
        !const {'CLIENT', 'SERVER'}.contains(execution) ||
        status == null ||
        expires == null ||
        (route != null &&
            (route is! String || safeAiChatPath(route) != route))) {
      return null;
    }
    final lines = [
      if (raw['summaryLines'] is List)
        for (final line in (raw['summaryLines'] as List).take(16))
          if (line is String && line.trim().isNotEmpty && line.length <= 240)
            line,
    ];
    final title = _text(raw['title']).trim();
    if (lines.isEmpty || title.isEmpty || title.length > 80) return null;
    final args = <String, Object?>{};
    if (raw['args'] is Map<String, dynamic>) {
      for (final entry in (raw['args'] as Map<String, dynamic>).entries) {
        final value = entry.value;
        if (value is String || value is num || value is bool) {
          args[entry.key] = value;
        }
      }
    }
    return AiChatAction(
      proposalId: id.toLowerCase(),
      actionType: type as String,
      handler: handler,
      execution: execution as String,
      title: title,
      summaryLines: lines,
      risk: const {'LOW', 'MEDIUM', 'HIGH'}.contains(raw['risk'])
          ? raw['risk'] as String
          : 'HIGH',
      riskNote: raw['riskNote'] is String ? raw['riskNote'] as String : null,
      requiresStepUp: raw['requiresStepUp'] == true,
      route: route as String?,
      args: Map.unmodifiable(args),
      status: status,
      expiresAt: expires,
      outcome:
          const {'SUCCEEDED', 'FAILED', 'AUTH_CHANGED'}.contains(raw['outcome'])
          ? raw['outcome'] as String
          : null,
      outcomeMessage: raw['outcomeMessage'] is String
          ? raw['outcomeMessage'] as String
          : null,
    );
  }

  static List<AiChatAction> listFrom(Object? raw) => [
    if (raw is List)
      for (final item in raw.take(8)) ?tryParse(item),
  ];

  final String proposalId;
  final String actionType;
  final String handler;
  final String execution;
  final String title;
  final List<String> summaryLines;
  final String risk;
  final String? riskNote;
  final bool requiresStepUp;
  final String? route;
  final Map<String, Object?> args;
  final AiChatActionStatus status;
  final DateTime expiresAt;
  final String? outcome;
  final String? outcomeMessage;

  bool get isClient => execution == 'CLIENT';
  bool openAt(DateTime now) =>
      status == AiChatActionStatus.proposed && expiresAt.isAfter(now);
}

/// Reject all route/query characters even when an AI result supplies an ID.
String? checkedAiChatId(Object? raw) =>
    raw is String && RegExp(r'^[0-9A-Za-z-]{1,64}$').hasMatch(raw) ? raw : null;

String _text(Object? value) => value is String ? value : '';

/// Same rule as safeAiChatRoute: a local path without query or fragment.
String? safeAiChatPath(String raw) =>
    raw.length <= 240 &&
        RegExp(r'^/[a-zA-Z0-9/_-]*$').hasMatch(raw) &&
        !raw.contains('//')
    ? raw
    : null;
