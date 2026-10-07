import 'dart:async';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../features/sales/intake/sales_intake_launcher.dart';
import '../../../features/sales/models/sales_doc.dart';
import '../../auth/permissions.dart';
import '../../providers/authenticated_scope_provider.dart';
import '../ai_job_models.dart';
import '../ai_job_runner.dart';
import '../guided/ai_guided_file_plan.dart';
import '../page_context/ai_page_context.dart';
import 'ai_chat_action_card.dart';
import 'ai_chat_l10n.dart';
import 'ai_chat_models.dart';
import 'ai_chat_repository.dart';
import 'ai_chat_settings_panel.dart';

typedef AiChatIdentity = ({
  AuthenticatedScope scope,
  String server,
  String permissions,
  bool superAdmin,
});

/// Replacing any security boundary destroys the entire local chat, including
/// file bytes, input, pending proposals, previous-job pointers and late replies.
final aiChatIdentityProvider = Provider<AiChatIdentity?>((ref) {
  final scope = ref.watch(authenticatedScopeProvider);
  if (scope == null) return null;
  final permissions = ref.watch(currentPermissionsProvider).toList()..sort();
  final superAdmin = ref.watch(isSuperAdminProvider);
  if (!permissions.contains('ai:use') && !superAdmin) return null;
  return (
    scope: scope,
    server: ref.watch(apiBaseUrlProvider),
    permissions: permissions.join('\n'),
    superAdmin: superAdmin,
  );
});

/// Lives outside the compact/rail branches so window resizing and business
/// navigation preserve the conversation; identity changes never do.
class AiChatOverlay extends ConsumerWidget {
  const AiChatOverlay({
    super.key,
    required this.child,
    required this.currentRoute,
  });

  final Widget child;
  final String currentRoute;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final identity = ref.watch(aiChatIdentityProvider);
    return Stack(
      fit: StackFit.expand,
      children: [
        child,
        if (identity != null)
          Positioned.fill(
            child: _ChatSession(
              key: ValueKey(identity),
              identity: identity,
              currentRoute: currentRoute,
            ),
          ),
      ],
    );
  }
}

class _ChatMessage {
  _ChatMessage({
    required this.text,
    this.user = false,
    this.fileName,
    this.actions = const [],
    this.sources = const [],
    this.fallback = false,
    this.attempt,
    this.documentResult,
    this.documentJobId,
    this.documentPageRoute,
    this.documentRequest,
    this.sourceFile,
  });
  final String text;
  final bool user;
  final String? fileName;

  /// Server-issued one-time confirmation cards (ADR-150).
  final List<AiChatAction> actions;
  final List<({String id, String label})> sources;

  /// Deterministic page summary (model unavailable or rejected by the guard).
  final bool fallback;
  final _ChatAttempt? attempt;
  final AiGuidedFileResult? documentResult;
  final String? documentJobId;
  final String? documentPageRoute;

  /// The user's own words sent with the file; a purpose chosen afterwards is
  /// sent together with them for the same file.
  final String? documentRequest;
  final PlatformFile? sourceFile;

  /// The purpose picked from this reply's choices; one pick per reply.
  AiGuidedWorkflow? chosenWorkflow;
}

enum _ChatDelivery {
  sending,
  processing,
  answered,
  rejected,
  unknown,
  processingFailed,
  interrupted,
  stopped,
}

/// A retry belongs to the original message, never to whatever is now in the
/// editor. Known accepted jobs can be read again without submitting a duplicate.
class _ChatAttempt {
  _ChatAttempt({
    required this.id,
    required this.text,
    required this.conversationId,
    this.file,
    this.locale,
    this.currentRoute,
    this.intentHint,
    this.snapshot,
    this.binding = AiCaptureBinding.none,
    this.workflow,
  });
  final int id;
  final String text;
  final PlatformFile? file;

  /// The purpose the user picked for [file]; a retry keeps it.
  final AiGuidedWorkflow? workflow;

  /// The conversation the message was written in; a retry stays in it.
  final String conversationId;

  /// Interface language when the message was written (zh/en/ko).
  final String? locale;
  String? currentRoute;
  String? intentHint;

  /// Page snapshot captured when the message was written; a retry resends it
  /// only while page awareness is still on.
  Map<String, Object?>? snapshot;

  /// What cards proposed from this message are bound to (page instance, rows).
  AiCaptureBinding binding;

  /// Page reading was switched off: a retry sends only the question.
  void dropPageContext() {
    currentRoute = null;
    intentHint = null;
    snapshot = null;
    binding = AiCaptureBinding.none;
  }

  String? submittedJobId;
  String? failure;
  bool chatSubmissionStarted = false;
  String progressKey = 'sending';
  _ChatDelivery delivery = _ChatDelivery.sending;
}

class _ChatSession extends ConsumerStatefulWidget {
  const _ChatSession({
    super.key,
    required this.identity,
    required this.currentRoute,
  });
  final AiChatIdentity identity;
  final String currentRoute;

  @override
  ConsumerState<_ChatSession> createState() => _ChatSessionState();
}

class _ChatSessionState extends ConsumerState<_ChatSession> {
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _messages = <_ChatMessage>[];

  /// Latest state of every confirmation card, by proposal id.
  final _cards = <String, AiChatCardUi>{};

  /// Page instance and rows each page card was proposed for, by proposal id.
  final _cardBindings = <String, AiCaptureBinding>{};
  final _dialogs = <DialogRoute<bool>>{};

  /// What the next message would attach (computed while the panel is open).
  AiPageCapture? _attachPreview;
  bool _attachPreviewScheduled = false;
  AiChatCapabilities? _capabilities;
  AiChatPageSuggestions? _pageSuggestions;
  AiJobCancelToken? _cancel;
  PlatformFile? _attachment;

  /// ADR-152: the current conversation. "New chat" starts a new id; after a
  /// page refresh the latest conversation is restored from the server, which
  /// reads earlier turns itself (the client never sends history).
  String _conversationId = _newConversationId();
  AiChatSettings _settings = AiChatSettings.defaults;
  bool _reasoningSupported = false;
  bool _settingsOpen = false;

  /// Wire name of the setting being saved.
  String? _settingsSaving;
  String? _settingsError;
  bool _clearingHistory = false;
  bool _restoreStarted = false;
  bool _restored = false;
  int _hiddenTurns = 0;
  String? _error;
  String? _progressKey;

  /// Launcher circle center in overlay coordinates; null = never moved (default
  /// anchored bottom-right). Persisted only for this session, like the previous
  /// vertical-only offset.
  Offset? _launcherCenter;

  /// Edge the launcher is stuck to: 0 none, -1 left, 1 right. While docked the
  /// circle sits half outside the border at reduced opacity (2026-10-06 user
  /// ask: draggable round AI button that can be pushed off the edge and stays
  /// as a translucent half circle).
  int _launcherDockEdge = 0;

  /// Suppresses the snap animation while the pointer is down.
  bool _launcherDragging = false;
  bool _open = false;
  bool _loadingCapabilities = true;
  bool _busy = false;
  bool _picking = false;
  int _generation = 0;
  int _pageSuggestionGeneration = 0;
  int _nextMessageId = 0;
  _ChatMessage? _activeMessage;

  String _t(String key) => aiChatText(context, key);
  bool get _pageAware => _settings.pageAware;
  static String _newConversationId() => const Uuid().v4();

  /// Interface language sent with each question (the default reply language).
  String? get _locale {
    final code = Localizations.maybeLocaleOf(context)?.languageCode;
    return const {'zh', 'en', 'ko'}.contains(code) ? code : null;
  }

  bool get _current =>
      mounted && ref.read(aiChatIdentityProvider) == widget.identity;
  bool _active(int generation) => _current && _generation == generation;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
    _loadCapabilities();
  }

  void _focusChanged() {
    if (!mounted) return;
    setState(() {});
    if (_focus.hasFocus) _scheduleAttachPreview();
  }

  AiPageContextController? get _pageContext =>
      AiPageContextScope.maybeOf(context);

  /// Snapshot of the top page right now (send time). Empty when page
  /// awareness is off or the path cannot be sent.
  AiPageCapture _capturePage() {
    final route = safeAiChatRoute(widget.currentRoute);
    if (!_pageAware || route == null) return AiPageCapture.empty;
    // System administration pages (ADR-153): nothing is read, no action runs.
    if (aiPageProtected(route)) return AiPageCapture.systemPage;
    // Payroll, HR and personal pages: only the question is sent.
    if (aiPageContentWithheld(route)) return AiPageCapture.contentWithheld;
    return _pageContext?.capture(aiPageL10n(context)) ?? AiPageCapture.empty;
  }

  /// Recomputes the "will attach ..." line after the current frame, so a page
  /// that just opened is laid out first. Only while the panel is open.
  void _scheduleAttachPreview() {
    if (_attachPreviewScheduled || !_open) return;
    _attachPreviewScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _attachPreviewScheduled = false;
      if (!_current || !_open) return;
      setState(() => _attachPreview = _capturePage());
    });
  }

  @override
  void dispose() {
    _pageSuggestionGeneration++;
    _generation++;
    _cancel?.cancel();
    _input.dispose();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _scroll.dispose();
    _cards.clear();
    _cardBindings.clear();
    _messages.clear();
    _attachment = null;
    // A root-navigator confirmation must not outlive the identity that opened
    // it. Its Consumer also hides content immediately on a boundary change.
    for (final route in _dialogs.toList()) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route.isActive) route.navigator?.removeRoute(route);
      });
    }
    _dialogs.clear();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ChatSession oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (safeAiGuidedPageRoute(oldWidget.currentRoute) !=
        safeAiGuidedPageRoute(widget.currentRoute)) {
      _loadPageSuggestions();
      _scheduleAttachPreview();
    }
  }

  Future<void> _loadPageSuggestions() async {
    final generation = ++_pageSuggestionGeneration;
    setState(() => _pageSuggestions = null);
    final route = safeAiGuidedPageRoute(widget.currentRoute);
    if (!_current ||
        !_open ||
        !_pageAware ||
        route == null ||
        _capabilities?.usable != true) {
      return;
    }
    try {
      final result = await ref
          .read(aiChatRepositoryProvider)
          .pageSuggestions(route);
      if (!_current ||
          !_open ||
          !_pageAware ||
          generation != _pageSuggestionGeneration ||
          safeAiGuidedPageRoute(widget.currentRoute) != route ||
          result.pageRoute != route) {
        return;
      }
      setState(() => _pageSuggestions = result);
    } catch (_) {
      // Optional guidance failures do not interrupt the conversation.
    }
  }

  Future<void> _loadCapabilities() async {
    final repository = ref.read(aiChatRepositoryProvider);
    try {
      final result = await repository.capabilities();
      if (!_current) return;
      setState(() {
        _capabilities = result;
        if (_settingsSaving == null) _settings = result.settings;
        _reasoningSupported = result.reasoningEffortSupported;
        _loadingCapabilities = false;
        _error = null;
      });
      _loadPageSuggestions();
      // The conversation is restored when the panel is first opened, not on
      // every page load: the overlay is always mounted and most page loads
      // never open the chat.
      if (result.usable && _open) unawaited(_restoreConversation());
    } catch (_) {
      if (!_current) return;
      setState(() {
        _loadingCapabilities = false;
        _error = _t('loadFailed');
      });
    }
  }

  /// ADR-152: after a page refresh the latest conversation is shown again the
  /// first time the panel opens, re-read and re-checked by the server.
  /// Restoring is optional: it never replaces messages the user already
  /// started, and failures stay silent. A turn whose quoted data changed shows
  /// its question and a note instead of the old answer; restored page cards
  /// can no longer run (their page was reloaded) and only offer cancel.
  Future<void> _restoreConversation() async {
    if (_restoreStarted || !_current) return;
    _restoreStarted = true;
    final generation = _generation;
    try {
      final view = await ref.read(aiChatRepositoryProvider).conversation();
      if (!mounted ||
          !_current ||
          generation != _generation ||
          _messages.isNotEmpty) {
        return;
      }
      final id = view.conversationId;
      if (id == null || view.turns.isEmpty) {
        if (view.hiddenTurns > 0) {
          setState(() => _hiddenTurns = view.hiddenTurns);
        }
        return;
      }
      final dataChanged = aiPageL10n(context).aiChatRestoredDataChanged;
      setState(() {
        _conversationId = id;
        _hiddenTurns = view.hiddenTurns;
        _restored = true;
        for (final turn in view.turns) {
          final reply = turn.reply;
          if (reply.question.isNotEmpty) {
            _messages.add(_ChatMessage(text: reply.question, user: true));
          }
          if (reply.dataChanged) {
            _messages.add(_ChatMessage(text: dataChanged));
            continue;
          }
          _rememberCards(reply.actions, detached: true);
          _messages.add(
            _ChatMessage(
              text: reply.reply.isEmpty ? _t('emptyReply') : reply.reply,
              actions: reply.actions,
              sources: reply.sources,
              fallback: reply.fallback,
            ),
          );
        }
      });
      _scrollToEnd();
    } catch (_) {
      // Restoring is a convenience; the chat works without it.
    }
  }

  // ------------------------------------------------------------ settings

  /// Saves one setting at once: optimistic, busy row, rolled back on failure.
  Future<void> _updateSetting(String field, Object value) async {
    if (!_current || _settingsSaving != null) return;
    final previous = _settings;
    final next = previous.withField(field, value);
    if (next == previous) return;
    final l10n = aiPageL10n(context);
    setState(() {
      _settings = next;
      _settingsSaving = field;
      _settingsError = null;
      _applyPageAwareness();
    });
    try {
      final saved = await ref.read(aiChatRepositoryProvider).updateSettings({
        field: value,
      });
      if (!_current) return;
      setState(() {
        _settings = saved.settings;
        _reasoningSupported = saved.reasoningEffortSupported;
        _applyPageAwareness();
      });
    } catch (error) {
      if (!_current) return;
      setState(() {
        _settings = previous;
        _settingsError = l10n.aiChatSettingsSaveFailed;
        _applyPageAwareness();
      });
      if (mounted) context.appError(l10n.aiChatSettingsSaveFailed);
    } finally {
      if (_current) setState(() => _settingsSaving = null);
    }
    if (field == 'pageAware' && _current) {
      _loadPageSuggestions();
      _scheduleAttachPreview();
    }
  }

  /// Reading the page off means off for retries too: drop what earlier
  /// messages captured from the page.
  void _applyPageAwareness() {
    _attachPreview = null;
    if (_settings.pageAware) return;
    for (final message in _messages) {
      message.attempt?.dropPageContext();
    }
  }

  Future<void> _clearHistory() async {
    if (!_current || _busy || _picking || _clearingHistory) return;
    final l10n = aiPageL10n(context);
    final accepted = await _confirmForIdentity(
      title: l10n.aiChatSettingsClearTitle,
      content: Text(l10n.aiChatSettingsClearBody),
    );
    if (!_current || accepted != true || _busy) return;
    setState(() {
      _clearingHistory = true;
      _settingsError = null;
    });
    try {
      await ref.read(aiChatRepositoryProvider).clearConversations();
      if (!_current) return;
      setState(_clear);
      if (mounted) context.appSuccess(l10n.aiChatSettingsClearDone);
    } catch (_) {
      if (!_current) return;
      setState(() => _settingsError = l10n.aiChatSettingsClearFailed);
      if (mounted) context.appError(l10n.aiChatSettingsClearFailed);
    } finally {
      if (_current) setState(() => _clearingHistory = false);
    }
  }

  void _toggleSettings() {
    if (!_current) return;
    setState(() {
      _settingsOpen = !_settingsOpen;
      _settingsError = null;
    });
    if (!_settingsOpen) {
      _scheduleAttachPreview();
      _scrollToEnd();
    }
  }

  /// Any chat user may upload a file to have it recognized (the server says so
  /// per account); what may be done with it afterwards is gated separately.
  bool get _canUpload =>
      _capabilities?.canUploadDocument == true &&
      !widget.identity.scope.readOnly;

  Future<void> _pickFile() async {
    if (!_current || _busy || _picking || !_canUpload) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: aiGuidedContentTypes.keys.toList(),
        withData: true,
        allowCompression: false,
      );
      if (!_current || result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes;
      final extension = file.extension?.toLowerCase();
      if (!aiGuidedContentTypes.containsKey(extension) ||
          bytes == null ||
          bytes.isEmpty) {
        setState(() => _error = _t('fileFailed'));
        return;
      }
      if (bytes.length > kSalesIntakeMaxFileBytes) {
        setState(() => _error = _t('fileLarge'));
        return;
      }
      final retained = <PlatformFile>{
        for (final message in _messages) ...[
          ?message.sourceFile,
          ?message.attempt?.file,
        ],
      }.fold<int>(0, (sum, source) => sum + (source.bytes?.length ?? 0));
      if (retained + bytes.length > 30 * 1024 * 1024) {
        setState(() => _error = _t('fileMemory'));
        return;
      }
      setState(() {
        _attachment = file;
        _error = null;
      });
      _focus.requestFocus();
    } catch (_) {
      if (_current) setState(() => _error = _t('fileFailed'));
    } finally {
      if (_current) setState(() => _picking = false);
    }
  }

  Future<void> _send({String? suggestion, String? intentHint}) async {
    if (!_current || _busy || _picking || _capabilities?.usable != true) return;
    final typed = (suggestion ?? _input.text).trim();
    final file = _attachment;
    if (typed.isEmpty && file == null) return;
    if (_messages.length >= 80) {
      setState(() => _error = _t('limit'));
      return;
    }
    final message = typed.isEmpty ? _t('attachmentQuestion') : typed;
    if (message.length > 2000) return;
    final currentRoute = _pageAware
        ? safeAiChatRoute(widget.currentRoute)
        : null;
    // ADR-150: what is visible on the top page, computed once, now.
    final capture = currentRoute == null || file != null
        ? AiPageCapture.empty
        : _capturePage();
    final outgoing = _ChatMessage(
      text: message,
      user: true,
      fileName: file?.name,
      attempt: _ChatAttempt(
        id: ++_nextMessageId,
        text: message,
        file: file,
        conversationId: _conversationId,
        locale: _locale,
        currentRoute: currentRoute,
        intentHint: currentRoute == null ? null : intentHint,
        snapshot: capture.snapshot,
        binding: capture.binding,
      ),
    );
    setState(() {
      _error = null;
      _messages.add(outgoing);
      _input.clear();
      _attachment = null;
    });
    await _performMessage(outgoing);
  }

  Future<void> _retryMessage(_ChatMessage message) async {
    if (!_current || _busy || !_messages.contains(message)) return;
    final attempt = message.attempt;
    if (attempt == null || attempt.delivery == _ChatDelivery.answered) return;
    await _performMessage(
      message,
      resume: attempt.delivery == _ChatDelivery.interrupted,
    );
  }

  Future<void> _performMessage(
    _ChatMessage message, {
    bool resume = false,
  }) async {
    if (!_current || _busy || _capabilities?.usable != true) return;
    final attempt = message.attempt!;
    // A retry after page awareness was switched off sends only the question.
    if (!_pageAware) attempt.dropPageContext();
    final file = attempt.file;
    final repository = ref.read(aiChatRepositoryProvider);
    final runner = ref.read(aiJobRunnerProvider);
    final generation = ++_generation;
    final cancel = AiJobCancelToken();
    setState(() {
      _busy = true;
      _cancel = cancel;
      _activeMessage = message;
      attempt.failure = null;
      attempt.delivery = resume
          ? _ChatDelivery.processing
          : _ChatDelivery.sending;
      attempt.progressKey = file != null ? 'uploading' : 'sending';
      if (!resume) {
        attempt.submittedJobId = null;
        attempt.chatSubmissionStarted = false;
      }
    });
    _scrollToEnd();
    try {
      if (file != null) {
        await _performDocumentMessage(
          message,
          generation,
          cancel,
          runner,
          resume: resume,
        );
        return;
      }
      final AiJobSnapshot snapshot;
      if (resume && attempt.submittedJobId != null) {
        snapshot = await runner.resume(
          attempt.submittedJobId!,
          cancelToken: cancel,
        );
      } else {
        if (!_active(generation) || cancel.isCancelled) return;
        setState(() => attempt.progressKey = 'sending');
        attempt.chatSubmissionStarted = true;
        final submitted = await repository.send(
          message: attempt.text,
          conversationId: attempt.conversationId,
          currentRoute: attempt.currentRoute,
          intentHint: attempt.intentHint,
          snapshot: attempt.snapshot,
          locale: attempt.locale,
        );
        if (!_active(generation) || cancel.isCancelled) {
          if (_current && cancel.isCancelled) {
            try {
              await runner.repository.cancel(submitted.id);
            } catch (_) {
              // Cancellation is best effort, like the shared job runner.
            }
          }
          return;
        }
        setState(() {
          attempt.submittedJobId = submitted.id;
          attempt.delivery = _ChatDelivery.processing;
        });
        snapshot =
            submitted.status == AiJobStatus.succeeded &&
                submitted.result != null
            ? submitted
            : await runner.resume(submitted.id, cancelToken: cancel);
      }
      if (!_active(generation) || cancel.isCancelled) return;
      final reply = AiChatReply.fromJson(snapshot.result ?? const {});
      setState(() {
        final index = _messages.indexOf(message);
        attempt.delivery = _ChatDelivery.answered;
        _rememberCards(reply.actions, binding: attempt.binding);
        _messages.insert(
          index + 1,
          _ChatMessage(
            text: reply.reply.isEmpty ? _t('emptyReply') : reply.reply,
            actions: reply.actions,
            sources: reply.sources,
            fallback: reply.fallback,
          ),
        );
      });
      _scheduleAttachPreview();
    } catch (error) {
      if (!_active(generation)) return;
      if ((error is ApiException &&
              (error.httpStatus == 401 || error.httpStatus == 403)) ||
          (error is AiJobFailure &&
              const {'PRINCIPAL_CHANGED', 'FORBIDDEN'}.contains(error.code))) {
        _clear();
        setState(() => _error = _t('permissionChanged'));
        _loadCapabilities();
      } else {
        setState(() {
          attempt.failure = _errorText(error);
          attempt.delivery = _failedDelivery(attempt, error);
        });
      }
    } finally {
      if (_active(generation)) {
        setState(() {
          _busy = false;
          _cancel = null;
          _activeMessage = null;
          _progressKey = null;
        });
        _scrollToEnd();
      }
    }
  }

  Future<void> _performDocumentMessage(
    _ChatMessage outgoing,
    int generation,
    AiJobCancelToken cancel,
    AiJobRunner runner, {
    required bool resume,
  }) async {
    final attempt = outgoing.attempt!;
    final file = attempt.file!;
    final AiJobSnapshot snapshot;
    void progress(AiJobSnapshot value) {
      if (!_active(generation)) return;
      setState(() {
        if (value.id.isNotEmpty) attempt.submittedJobId = value.id;
        attempt.progressKey = switch (value.stage) {
          'READING' => 'documentReading',
          'PARSING' => 'documentParsing',
          'CLASSIFYING' => 'documentClassifying',
          'READY_TO_FILL' => 'documentReady',
          _ => 'uploading',
        };
      });
    }

    if (resume && attempt.submittedJobId != null) {
      snapshot = await runner.resume(
        attempt.submittedJobId!,
        cancelToken: cancel,
        onProgress: progress,
      );
    } else {
      snapshot = await runner.run(
        AiJobRequest(
          kind: aiGuidedRouteKind,
          params: {
            'message': aiGuidedRequestMessage(attempt.text),
            'pageRoute': ?safeAiGuidedPageRoute(attempt.currentRoute),
            'workflow': ?attempt.workflow?.code,
          },
          bytes: file.bytes!,
          fileName: file.name,
          contentType: aiGuidedContentTypes[file.extension!.toLowerCase()]!,
        ),
        cancelToken: cancel,
        onProgress: progress,
      );
    }
    if (!_active(generation) || cancel.isCancelled) return;
    final result = AiGuidedFileResult.fromJson(snapshot.result ?? const {});
    if (!result.matchesSource(file)) {
      throw AiJobFailure(
        code: 'DOCUMENT_SOURCE_MISMATCH',
        message: _t('documentSourceMismatch'),
      );
    }
    final partialRequest = aiGuidedRequestIsTruncated(attempt.text);
    // ADR-150: a recognized file never opens a page by itself. The server
    // issues at most one confirmation card per file, always a guided form
    // that opens on confirm; any other card type is not part of a file
    // answer and is dropped.
    final cards = AiChatAction.listFrom(snapshot.result?['actions'])
        .where((card) => card.actionType == AiChatAction.openGuidedForm)
        .take(1)
        .toList(growable: false);
    final response = _ChatMessage(
      text:
          '${result.summary.isEmpty ? result.title : result.summary}${partialRequest ? '\n\n${_t('documentLongRequest')}' : ''}',
      actions: cards,
      documentResult: result,
      documentJobId: snapshot.id,
      documentPageRoute: safeAiGuidedPageRoute(attempt.currentRoute),
      documentRequest: attempt.text,
      sourceFile: file,
    );
    setState(() {
      attempt.delivery = _ChatDelivery.answered;
      _rememberCards(cards);
      _messages.insert(_messages.indexOf(outgoing) + 1, response);
    });
  }

  // ------------------------------------------------------------ cards

  /// [detached]: restored cards whose page instance is gone. Cards that run
  /// on the page (page actions, opening a form with this chat's file) can then
  /// only be cancelled; server-executed cards stay confirmable.
  void _rememberCards(
    List<AiChatAction> cards, {
    AiCaptureBinding binding = AiCaptureBinding.none,
    bool detached = false,
  }) {
    for (final card in cards) {
      final ui = _cards.putIfAbsent(card.proposalId, () => AiChatCardUi(card))
        ..card = card;
      if (detached && card.execution != 'SERVER') ui.detached = true;
      _cardBindings.putIfAbsent(card.proposalId, () => binding);
    }
  }

  AiChatCardUi _cardUi(AiChatAction card) =>
      _cards.putIfAbsent(card.proposalId, () => AiChatCardUi(card));

  bool get _cardRunning => _cards.values.any((ui) => ui.running);

  /// Network/gateway failures leave the outcome unknown: check, never replay.
  static bool _unknownOutcome(Object error) =>
      error is NetworkException ||
      error is NetworkTimeoutException ||
      (error is ApiException &&
          (error.httpStatus == null ||
              error.httpStatus == 408 ||
              error.httpStatus! >= 500));

  String _cardError(Object error) {
    final l10n = aiPageL10n(context);
    if (error is AiActionFailure) {
      return error.message.isEmpty ? l10n.aiChatCardInvalidArgs : error.message;
    }
    if (error is ApiException) {
      final code = error.fieldErrors
          ?.where((field) => field.field == 'errorCode')
          .firstOrNull
          ?.message;
      return switch (code) {
        'AI_ACTION_EXPIRED' => l10n.aiChatCardExpired,
        'AI_ACTION_AUTH_CHANGED' => l10n.aiChatCardAuthChanged,
        _ => error.message,
      };
    }
    return _t('failed');
  }

  void _cardNote(AiChatCardUi ui, String? note, {bool error = true}) {
    if (!_current) return;
    setState(() {
      ui
        ..running = false
        ..note = note
        ..noteIsError = error;
    });
  }

  /// Re-reads a card (unknown result, or after a refused request).
  Future<void> _refreshCard(AiChatCardUi ui) async {
    try {
      final card = await ref
          .read(aiChatRepositoryProvider)
          .actionStatus(ui.card.proposalId);
      if (!_current) return;
      setState(() {
        ui
          ..card = card
          ..unknown = false;
      });
    } catch (error) {
      if (_current && !_unknownOutcome(error)) {
        _cardNote(ui, _cardError(error));
      }
    }
  }

  Future<void> _cancelCard(AiChatCardUi ui) async {
    if (!_current || ui.running) return;
    try {
      final card = await ref
          .read(aiChatRepositoryProvider)
          .cancelAction(ui.card.proposalId);
      if (!_current) return;
      setState(() {
        ui
          ..card = card
          ..note = null
          ..unknown = false;
      });
    } catch (error) {
      _cardNote(ui, _cardError(error));
    }
  }

  Future<void> _confirmCard(_ChatMessage message, AiChatCardUi ui) async {
    if (!_current || ui.running || _cardRunning) return;
    if (ui.detached) {
      _cardNote(ui, aiPageL10n(context).aiChatCardDetached, error: false);
      return;
    }
    if (!ui.card.openAt(DateTime.now())) {
      setState(() {});
      return;
    }
    switch (ui.card.actionType) {
      case AiChatAction.permissionGrant:
        await _executeGrantCard(ui);
      case AiChatAction.openGuidedForm:
        await _executeGuidedCard(message, ui);
      default:
        await _executePageCard(ui);
    }
  }

  /// One-time consumption; null when the card could not be confirmed (the
  /// reason is already shown on the card).
  Future<Map<String, Object?>?> _consumeCard(AiChatCardUi ui) async {
    setState(() {
      ui
        ..running = true
        ..note = null
        ..unknown = false
        ..localSucceeded = null;
    });
    try {
      final confirmed = await ref
          .read(aiChatRepositoryProvider)
          .confirmAction(ui.card.proposalId);
      if (!_current) return null;
      ui.card = confirmed.card;
      return confirmed.args;
    } catch (error) {
      if (!_current) return null;
      if (_unknownOutcome(error)) {
        setState(() {
          ui
            ..running = false
            ..unknown = true
            ..note = aiPageL10n(context).aiChatCardUnknown
            ..noteIsError = false;
        });
        return null;
      }
      _cardNote(ui, _cardError(error));
      await _refreshCard(ui);
      return null;
    }
  }

  /// The execution receipt is recorded once; a lost receipt is never replayed
  /// as a second confirmation.
  Future<void> _receipt(
    AiChatCardUi ui, {
    required bool succeeded,
    String? message,
  }) async {
    try {
      final card = await ref
          .read(aiChatRepositoryProvider)
          .actionReceipt(
            ui.card.proposalId,
            succeeded: succeeded,
            message: message,
          );
      if (!_current) return;
      setState(() {
        ui
          ..card = card
          ..running = false
          ..unknown = false
          ..localSucceeded = null
          ..note = succeeded ? message : null
          ..noteIsError = false;
      });
    } catch (_) {
      if (!_current) return;
      setState(() {
        ui
          ..running = false
          ..localSucceeded = succeeded
          ..note = succeeded ? message : message ?? _t('failed')
          ..noteIsError = !succeeded;
      });
    }
  }

  /// CLIENT page action: route + handler check, confirm (authoritative args),
  /// run the page's own handler against the page instance and rows the card
  /// was proposed for (fail-closed otherwise), receipt.
  Future<void> _executePageCard(AiChatCardUi ui) async {
    final l10n = aiPageL10n(context);
    final card = ui.card;
    final binding = _cardBindings[card.proposalId] ?? AiCaptureBinding.none;
    // ADR-153: nothing on a system administration page runs through the
    // assistant, whatever card arrives.
    if (aiPageProtected(card.route) ||
        aiPageProtected(safeAiChatRoute(widget.currentRoute))) {
      _cardNote(ui, l10n.aiChatCardProtectedPage);
      return;
    }
    // Not bound to a page instance (restored after a refresh, or page reading
    // was off): the handler could never run, so the one-time proposal is not
    // used up for nothing.
    if (binding.isNone) {
      _cardNote(ui, l10n.aiChatCardDetached, error: false);
      return;
    }
    if (safeAiChatRoute(widget.currentRoute) != card.route) {
      _cardNote(ui, l10n.aiChatCardWrongPage);
      return;
    }
    if (_pageContext?.actions(l10n)[card.handler] == null) {
      _cardNote(ui, l10n.aiChatCardHandlerMissing);
      return;
    }
    final args = await _consumeCard(ui);
    if (args == null || !_current) return;
    var succeeded = false;
    String? outcome;
    try {
      final page = _pageContext;
      if (page == null || safeAiChatRoute(widget.currentRoute) != card.route) {
        throw AiActionFailure(l10n.aiChatCardHandlerMissing);
      }
      outcome = await page.run(l10n, binding, card.handler, args);
      succeeded = true;
    } catch (error) {
      outcome = _cardError(error);
    }
    if (!_current) return;
    await _receipt(ui, succeeded: succeeded, message: outcome);
  }

  /// Filling a form from the file (purpose chips and guided cards); uploading
  /// itself does not depend on it.
  bool _workflowAllowed(AiGuidedWorkflow workflow) =>
      workflow != AiGuidedWorkflow.none &&
      _capabilities?.workflows.contains(workflow.code) == true &&
      !widget.identity.scope.readOnly &&
      ref.read(currentPermissionsProvider).containsAll(workflow.permissions);

  /// OPEN_GUIDED_FORM: opens the new form with this chat's verified file only
  /// after the user confirmed. Saving stays with the page's own button.
  Future<void> _executeGuidedCard(_ChatMessage message, AiChatCardUi ui) async {
    final l10n = aiPageL10n(context);
    final jobId = message.documentJobId;
    final result = message.documentResult;
    final file = message.sourceFile;
    final identity = ref.read(aiGuidedFileIdentityProvider);
    final workflow = AiGuidedWorkflow.parse(ui.card.args['workflow']);
    if (jobId == null ||
        result == null ||
        file == null ||
        identity == null ||
        !result.matchesSource(file)) {
      _cardNote(ui, l10n.aiChatCardSourceMissing);
      return;
    }
    if (!_workflowAllowed(workflow)) {
      _cardNote(ui, _t('permissionChanged'));
      return;
    }
    final args = await _consumeCard(ui);
    if (args == null || !_current) return;
    // The destination is selected from this enum; server/model route strings
    // are never evaluated, and no save/submit/approve endpoint is called here.
    final route = switch (AiGuidedWorkflow.parse(args['workflow'])) {
      AiGuidedWorkflow.salesOrder => RoutePath.salesDocNew(
        SalesDocType.order.pathSegment,
      ),
      AiGuidedWorkflow.salesQuote => RoutePath.salesDocNew(
        SalesDocType.quote.pathSegment,
      ),
      AiGuidedWorkflow.expenseClaim => RouteName.expenseNew,
      AiGuidedWorkflow.none => null,
    };
    if (route == null ||
        args['sourceJobId'] != jobId ||
        AiGuidedWorkflow.parse(args['workflow']) != workflow) {
      await _receipt(ui, succeeded: false, message: l10n.aiChatCardInvalidArgs);
      return;
    }
    final AiGuidedFilePlan verified;
    try {
      final plan = AiGuidedFilePlan(
        jobId: jobId,
        file: file,
        result: result,
        workflow: workflow,
        identity: identity,
        pageRoute: message.documentPageRoute,
      );
      if (!plan.matches(ref)) {
        throw ApiException('FORBIDDEN', _t('permissionChanged'));
      }
      verified = await validateAiGuidedFilePlan(ref, plan);
      if (!_current || !_workflowAllowed(workflow) || !verified.matches(ref)) {
        throw ApiException('FORBIDDEN', _t('permissionChanged'));
      }
    } catch (error) {
      if (!_current) return;
      await _receipt(
        ui,
        succeeded: false,
        message: error is ApiException
            ? error.message
            : _t('documentOpenFailed'),
      );
      return;
    }
    // Navigate first and check that the form really is the top page; only
    // then close the panel and report success. Otherwise the panel stays open
    // with the reason on the card.
    final landed = await _pushAndLand(route, verified);
    if (!_current) return;
    if (landed != route) {
      await _receipt(
        ui,
        succeeded: false,
        message: landed == RouteName.accessDenied
            ? l10n.aiChatCardFormNoAccess
            : l10n.aiChatCardFormNotOpened,
      );
      return;
    }
    _focus.unfocus();
    setState(() => _open = false);
    await _receipt(ui, succeeded: true);
  }

  /// Pushes [route] and returns the top route one frame later (null without
  /// a router or when the push throws). A redirect, e.g. for missing access,
  /// lands elsewhere. The push future completes only when the page closes,
  /// so it is not awaited.
  Future<String?> _pushAndLand(String route, Object extra) async {
    final router = GoRouter.maybeOf(context);
    if (router == null) return null;
    try {
      router.push<Object?>(route, extra: extra).ignore();
    } catch (_) {
      return null;
    }
    await WidgetsBinding.instance.endOfFrame;
    return mounted ? topMatchedLocationOf(router) : null;
  }

  // ------------------------------------------------------------ file answers

  /// Purposes offered for a file whose use was not clear: only when the
  /// server asked for a choice, only those this account may fill in, and
  /// only while the reply still holds the file (checked against the result
  /// when the reply arrived; the resent job is checked again).
  List<AiGuidedChoice> _documentChoices(_ChatMessage reply) {
    final result = reply.documentResult;
    if (result == null ||
        !result.needsChoice ||
        reply.sourceFile == null ||
        !_canUpload) {
      return const [];
    }
    final seen = <AiGuidedWorkflow>{};
    return [
      for (final choice in result.choices)
        if (_workflowAllowed(choice.workflow) && seen.add(choice.workflow))
          choice,
    ];
  }

  /// Pages offered for the file, re-checked against the same route guard the
  /// router applies (the server already filtered them by permission).
  List<AiDocumentPage> _documentPages(_ChatMessage reply) => [
    for (final page in reply.documentResult?.pages ?? const <AiDocumentPage>[])
      if (_pageAllowed(page.route)) page,
  ];

  bool _pageAllowed(String route) =>
      safeAiChatPath(route) == route &&
      locationAllowedFor(
        ref.read(currentPermissionsProvider),
        widget.identity.superAdmin,
        route,
      );

  /// One pick per reply: the same file is sent again with the chosen purpose,
  /// and the answer to that carries at most one confirmation card.
  Future<void> _chooseWorkflow(
    _ChatMessage reply,
    AiGuidedChoice choice,
  ) async {
    final file = reply.sourceFile;
    if (!_current ||
        _busy ||
        _picking ||
        reply.chosenWorkflow != null ||
        file == null ||
        !_documentChoices(reply).contains(choice)) {
      return;
    }
    if (_messages.length >= 80) {
      setState(() => _error = _t('limit'));
      return;
    }
    final outgoing = _ChatMessage(
      text: aiPageL10n(context).aiChatDocumentChosen(choice.title),
      user: true,
      fileName: file.name,
      attempt: _ChatAttempt(
        id: ++_nextMessageId,
        text: reply.documentRequest ?? _t('attachmentQuestion'),
        file: file,
        conversationId: _conversationId,
        locale: _locale,
        currentRoute: reply.documentPageRoute,
        workflow: choice.workflow,
      ),
    );
    setState(() {
      reply.chosenWorkflow = choice.workflow;
      _error = null;
      _messages.add(outgoing);
    });
    await _performMessage(outgoing);
  }

  /// Goes to a page offered for the file (never a form fill, never a write).
  void _openDocumentPage(AiDocumentPage page) {
    if (!_current || !_pageAllowed(page.route)) return;
    final router = GoRouter.maybeOf(context);
    if (router == null) return;
    _focus.unfocus();
    router.go(page.route);
    setState(() => _open = false);
  }

  bool get _canConfirmGrant =>
      _capabilities?.canManagePermissions == true &&
      widget.identity.superAdmin &&
      widget.identity.scope.actorId == null &&
      !widget.identity.scope.readOnly;

  /// SERVER grant card: the dedicated endpoint consumes the proposal in the
  /// grant transaction; the shared network layer asks for the password.
  /// Closing the password prompt leaves the card open.
  Future<void> _executeGrantCard(AiChatCardUi ui) async {
    if (!_canConfirmGrant) {
      _cardNote(ui, _t('permissionChanged'));
      return;
    }
    setState(() {
      ui
        ..running = true
        ..note = null
        ..unknown = false;
    });
    try {
      final reply = await ref
          .read(aiChatRepositoryProvider)
          .confirmPermissionGrant(ui.card.proposalId);
      if (!_current) return;
      _cardNote(ui, reply.isEmpty ? null : reply, error: false);
    } catch (error) {
      if (!_current) return;
      if (_unknownOutcome(error)) {
        setState(() {
          ui
            ..running = false
            ..unknown = true
            ..note = aiPageL10n(context).aiChatCardUnknown
            ..noteIsError = false;
        });
        return;
      }
      _cardNote(ui, _cardError(error));
    }
    await _refreshCard(ui);
  }

  _ChatDelivery _failedDelivery(_ChatAttempt attempt, Object error) {
    if (error is AiJobFailure && error.isCancelled) {
      return _ChatDelivery.stopped;
    }
    if (attempt.submittedJobId != null) {
      return error is AiJobFailure &&
              error.code != AiJobFailure.codeClientTimeout
          ? _ChatDelivery.processingFailed
          : _ChatDelivery.interrupted;
    }
    if (!attempt.chatSubmissionStarted) return _ChatDelivery.rejected;
    if (error is ApiException &&
        error.httpStatus != null &&
        error.httpStatus! >= 400 &&
        error.httpStatus! < 500 &&
        error.httpStatus != 408) {
      return _ChatDelivery.rejected;
    }
    return _ChatDelivery.unknown;
  }

  String _errorText(Object error) {
    if (error is AiJobFailure) {
      if (error.isCancelled) return _t('stopped');
      if (error.code == AiJobFailure.codeClientTimeout) return _t('timeout');
      if (error.code == AiJobFailure.codeJobGone) return _t('gone');
      return error.clientMessage ? _t('failed') : error.message;
    }
    return error is ApiException ? error.message : _t('failed');
  }

  void _stop() {
    _cancel?.cancel();
    // A send request may be between submit and poll. Fence its result too.
    _generation++;
    setState(() {
      final attempt = _activeMessage?.attempt;
      if (attempt != null) {
        attempt.delivery = _ChatDelivery.stopped;
        attempt.failure = null;
      }
      _busy = false;
      _cancel = null;
      _progressKey = null;
      _activeMessage = null;
    });
  }

  void _clear() {
    _generation++;
    _pageSuggestionGeneration++;
    _pageSuggestions = null;
    _cancel?.cancel();
    _cancel = null;
    _messages.clear();
    _cards.clear();
    _cardBindings.clear();
    _attachment = null;
    _conversationId = _newConversationId();
    _hiddenTurns = 0;
    _restored = false;
    _error = null;
    _progressKey = null;
    _busy = false;
    _activeMessage = null;
    _input.clear();
  }

  Future<void> _newChat() async {
    if (_busy || _picking) return;
    if (_messages.isNotEmpty || _attachment != null || _input.text.isNotEmpty) {
      final accepted = await _confirmForIdentity(
        title: _t('resetTitle'),
        content: Text(_t('resetHint')),
      );
      if (!_current || accepted != true) return;
    }
    setState(_clear);
    _focus.requestFocus();
    _loadPageSuggestions();
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<bool?> _confirmForIdentity({
    required String title,
    required Widget content,
    bool informationOnly = false,
  }) async {
    final identity = widget.identity;
    final confirmLabel = _t(informationOnly ? 'infoDone' : 'confirm');
    final cancelLabel = _t('cancel');
    late final DialogRoute<bool> route;
    route = DialogRoute<bool>(
      context: context,
      builder: (dialogContext) => Consumer(
        builder: (context, ref, _) {
          if (ref.watch(aiChatIdentityProvider) != identity) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (route.isActive) route.navigator?.removeRoute(route);
            });
            return const SizedBox.shrink();
          }
          return AlertDialog(
            title: Text(title),
            content: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: 460,
                maxHeight: MediaQuery.sizeOf(context).height * 0.6,
              ),
              child: SingleChildScrollView(child: content),
            ),
            actionsAlignment: MainAxisAlignment.center,
            actions: [
              if (!informationOnly)
                UtenButton(
                  type: UtenButtonType.ghost,
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                  child: Text(cancelLabel),
                ),
              UtenButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(confirmLabel),
              ),
            ],
          );
        },
      ),
    );
    _dialogs.add(route);
    try {
      return await Navigator.of(context, rootNavigator: true).push(route);
    } finally {
      _dialogs.remove(route);
    }
  }

  Future<void> _showHelp() async {
    await _confirmForIdentity(
      title: _t('info'),
      informationOnly: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_t('privacy')),
          const SizedBox(height: UtenSpacing.s16),
          Text(_t('boundary')),
          const SizedBox(height: UtenSpacing.s16),
          Text(_t('pageHint')),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loadingCapabilities || _capabilities?.canChat == false) {
      return const SizedBox.shrink();
    }
    final media = MediaQuery.of(context);
    final colors = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 600;
        final inset = math.max(media.viewInsets.bottom, media.padding.bottom);
        final minimumBottom =
            (compact
                ? UtenCapsuleNavScope.computeOcclusion(context)
                : media.padding.bottom) +
            UtenSpacing.s16;
        final maximumBottom = math.max(
          minimumBottom,
          constraints.maxHeight - media.padding.top - 72,
        );
        final panelBottom = inset + UtenSpacing.s16;
        final panelHeight = math.min(
          660.0,
          math.max(
            120.0,
            constraints.maxHeight -
                media.padding.top -
                panelBottom -
                UtenSpacing.s16,
          ),
        );
        final panelWidth = math.min(
          440.0,
          math.max(0.0, constraints.maxWidth - UtenSpacing.s32),
        );

        // Launcher geometry: a draggable circle; pushed onto a side edge it
        // docks half-out at reduced opacity. The visual circle is 48 and, being
        // already at the minimum tap-target size, its hit box is 48 too —
        // position math uses that box.
        const launcherSize = 48.0;
        const launcherHalf = launcherSize / 2;
        const launcherMargin = 16.0;
        // Release this close to a side edge (center within 20px of it) docks;
        // the resting margin keeps the center 36px away, so plain vertical
        // drags never dock by accident.
        const launcherDockRange = 20.0;
        final launcherTopLimit =
            constraints.maxHeight - maximumBottom - launcherHalf;
        final launcherBottomLimit =
            constraints.maxHeight - minimumBottom - launcherHalf;
        final defaultLauncherCenter = Offset(
          constraints.maxWidth - launcherMargin - launcherHalf,
          (constraints.maxHeight - minimumBottom - 72 - launcherHalf).clamp(
            launcherTopLimit,
            launcherBottomLimit,
          ),
        );
        Offset clampLauncherCenter(Offset center) => Offset(
          center.dx.clamp(0.0, constraints.maxWidth),
          center.dy.clamp(launcherTopLimit, launcherBottomLimit),
        );

        // Derived every build so window resizing re-clamps and a docked circle
        // follows its edge without mutating the stored offset.
        final storedCenter = _launcherCenter ?? defaultLauncherCenter;
        final docked = _launcherDockEdge != 0;
        Offset settleLauncherCenter(Offset center) => Offset(
          center.dx.clamp(launcherHalf, constraints.maxWidth - launcherHalf),
          center.dy.clamp(launcherTopLimit, launcherBottomLimit),
        );
        final launcherCenter = docked
            ? Offset(
                _launcherDockEdge > 0 ? constraints.maxWidth : 0.0,
                storedCenter.dy.clamp(launcherTopLimit, launcherBottomLimit),
              )
            : settleLauncherCenter(storedCenter);

        void move(double delta) => setState(() {
          _launcherDockEdge = 0;
          _launcherCenter = settleLauncherCenter(
            (_launcherCenter ?? defaultLauncherCenter) + Offset(0, delta),
          );
        });
        return Stack(
          children: [
            if (!_open)
              AnimatedPositioned(
                duration: _launcherDragging
                    ? Duration.zero
                    : const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                left: launcherCenter.dx - launcherHalf,
                top: launcherCenter.dy - launcherHalf,
                child: Semantics(
                  label: _t('open'),
                  customSemanticsActions: {
                    CustomSemanticsAction(label: _t('moveUp')): () => move(72),
                    CustomSemanticsAction(label: _t('moveDown')): () =>
                        move(-72),
                  },
                  child: GestureDetector(
                    onPanStart: (details) => setState(() {
                      _launcherDragging = true;
                      _launcherCenter ??= defaultLauncherCenter;
                    }),
                    onPanUpdate: (details) => setState(() {
                      _launcherDockEdge = 0;
                      _launcherCenter = clampLauncherCenter(
                        (_launcherCenter ?? defaultLauncherCenter) +
                            details.delta,
                      );
                    }),
                    onPanEnd: (_) => setState(() {
                      _launcherDragging = false;
                      final center = _launcherCenter ?? defaultLauncherCenter;
                      final nearRight =
                          constraints.maxWidth - center.dx <= launcherDockRange;
                      final nearLeft = center.dx <= launcherDockRange;
                      if (nearRight || nearLeft) {
                        _launcherDockEdge = nearRight ? 1 : -1;
                      } else {
                        _launcherCenter = clampLauncherCenter(
                          Offset(
                            center.dx.clamp(
                              launcherHalf,
                              constraints.maxWidth - launcherHalf,
                            ),
                            center.dy,
                          ),
                        );
                      }
                    }),
                    onPanCancel: () =>
                        setState(() => _launcherDragging = false),
                    child: AnimatedOpacity(
                      duration: const Duration(milliseconds: 150),
                      opacity: docked ? 0.55 : 1.0,
                      child: SizedBox.square(
                        dimension: launcherSize,
                        child: FloatingActionButton(
                          key: const ValueKey('ai-chat-launcher'),
                          heroTag: null,
                          tooltip: _t('open'),
                          shape: const CircleBorder(),
                          // Deep teal with a white icon in light mode; the
                          // former primaryContainer teal100 circle was too
                          // faint.
                          backgroundColor: colors.primary,
                          foregroundColor: colors.onPrimary,
                          onPressed: () {
                            if (_launcherDockEdge != 0) {
                              // Docked: tap pulls the circle back inside first,
                              // then the chat opens as usual.
                              final edge = _launcherDockEdge;
                              setState(() {
                                _launcherDockEdge = 0;
                                _launcherCenter = settleLauncherCenter(
                                  Offset(
                                    edge > 0
                                        ? constraints.maxWidth -
                                              launcherMargin -
                                              launcherHalf
                                        : launcherMargin + launcherHalf,
                                    (_launcherCenter ?? defaultLauncherCenter)
                                        .dy,
                                  ),
                                );
                              });
                            }
                            setState(() => _open = true);
                            if (_capabilities?.usable == true) {
                              unawaited(_restoreConversation());
                            }
                            _loadPageSuggestions();
                            _scheduleAttachPreview();
                            _scrollToEnd();
                          },
                          child: const Icon(Icons.auto_awesome_outlined),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            if (_open)
              Positioned(
                right: UtenSpacing.s16,
                bottom: panelBottom,
                width: panelWidth,
                height: panelHeight,
                child: CallbackShortcuts(
                  bindings: {
                    const SingleActivator(LogicalKeyboardKey.escape): () =>
                        setState(() => _open = false),
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: UtenRadius.xlAll,
                      boxShadow: UtenElevation.high(
                        isDark: Theme.of(context).brightness == Brightness.dark,
                      ),
                    ),
                    child: Material(
                      key: const ValueKey('ai-chat-panel'),
                      color: colors.surface,
                      shape: RoundedRectangleBorder(
                        borderRadius: UtenRadius.xlAll,
                        side: BorderSide(color: colors.outlineVariant),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _panel(panelHeight),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _panel(double height) {
    final colors = Theme.of(context).colorScheme;
    final tight = height < 400;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    // At large accessibility sizes the messages and editor may exceed
    // the space above the keyboard. Keep every word and control reachable in
    // one scroll surface instead of clipping content or shrinking the font.
    final scrollAll =
        height < 240 || (textScale > 1.2 && height < 400 * textScale);
    Widget messagesViewport({required Widget child}) =>
        scrollAll ? child : Expanded(child: child);
    final content = Column(
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: UtenSpacing.s16,
            right: UtenSpacing.s4,
          ),
          child: Row(
            children: [
              if (_settingsOpen)
                IconButton(
                  key: const ValueKey('ai-settings-back'),
                  tooltip: aiPageL10n(context).aiChatSettingsBack,
                  onPressed: _toggleSettings,
                  icon: const Icon(Icons.arrow_back, size: 20),
                )
              else
                Icon(
                  Icons.auto_awesome_outlined,
                  size: 20,
                  color: colors.primary,
                ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  _settingsOpen
                      ? aiPageL10n(context).aiChatSettings
                      : _t('title'),
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (!_settingsOpen) ...[
                IconButton(
                  key: const ValueKey('ai-chat-settings'),
                  tooltip: aiPageL10n(context).aiChatSettings,
                  onPressed: _toggleSettings,
                  icon: const Icon(Icons.tune, size: 20),
                ),
                IconButton(
                  key: const ValueKey('ai-chat-info'),
                  tooltip: _t('info'),
                  onPressed: _showHelp,
                  icon: const Icon(Icons.info_outline, size: 20),
                ),
                IconButton(
                  key: const ValueKey('ai-chat-new'),
                  tooltip: _t('reset'),
                  onPressed: _busy || _picking ? null : _newChat,
                  icon: const Icon(Icons.add_comment_outlined, size: 20),
                ),
              ],
              IconButton(
                key: const ValueKey('ai-chat-close'),
                tooltip: _t('close'),
                onPressed: () {
                  _focus.unfocus();
                  setState(() => _open = false);
                },
                icon: const Icon(Icons.close, size: 20),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        if (_settingsOpen)
          messagesViewport(
            child: AiChatSettingsPanel(
              settings: _settings,
              reasoningSupported: _reasoningSupported,
              savingField: _settingsSaving,
              error: _settingsError,
              clearing: _clearingHistory,
              canClear: !_busy && !_picking,
              onChange: _updateSetting,
              onClearHistory: _clearHistory,
            ),
          ),
        if (!tight && !_settingsOpen)
          Padding(
            key: const ValueKey('ai-chat-page-line'),
            padding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s12,
              vertical: UtenSpacing.s6,
            ),
            child: Row(
              children: [
                const Icon(Icons.description_outlined, size: 16),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Tooltip(
                    message: _t('pageHint'),
                    child: Text(
                      !_pageAware
                          ? _t('pageOff')
                          : _pageSuggestions?.pageTitle.isNotEmpty == true
                          ? _pageSuggestions!.pageTitle
                          : _t('pageAware'),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (!_settingsOpen &&
            _messages.isNotEmpty &&
            _pageAware &&
            _settings.showSuggestions &&
            _pageSuggestions?.suggestions.isNotEmpty == true)
          Padding(
            key: const ValueKey('ai-chat-page-suggestions'),
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s12,
              0,
              UtenSpacing.s12,
              UtenSpacing.s8,
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s4,
                children: [
                  for (final suggestion in _pageSuggestions!.suggestions.take(
                    2,
                  ))
                    ActionChip(
                      label: Text(suggestion),
                      onPressed: _busy || _picking
                          ? null
                          : () => _sendPageSuggestion(suggestion),
                    ),
                ],
              ),
            ),
          ),
        if (!_settingsOpen)
          messagesViewport(
            child: ListView(
              key: const ValueKey('ai-chat-messages'),
              controller: scrollAll ? null : _scroll,
              shrinkWrap: scrollAll,
              physics: scrollAll ? const NeverScrollableScrollPhysics() : null,
              padding: const EdgeInsets.all(UtenSpacing.s16),
              children: [
                if (_hiddenTurns > 0)
                  _historyNote(
                    aiPageL10n(context).aiChatHiddenTurns(_hiddenTurns),
                    key: const ValueKey('ai-chat-hidden-turns'),
                  ),
                if (_restored && _messages.isNotEmpty)
                  _historyNote(
                    aiPageL10n(context).aiChatRestored,
                    key: const ValueKey('ai-chat-restored'),
                  ),
                if (_messages.isEmpty) _welcome(),
                for (final message in _messages) _message(message),
                if (_busy && _activeMessage == null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: UtenSpacing.s8,
                    ),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        const SizedBox(width: UtenSpacing.s12),
                        Expanded(child: Text(_t(_progressKey ?? 'sending'))),
                        if (_cancel != null)
                          TextButton(onPressed: _stop, child: Text(_t('stop'))),
                      ],
                    ),
                  ),
                if (_error != null)
                  Semantics(
                    liveRegion: true,
                    child: Container(
                      margin: const EdgeInsets.only(top: UtenSpacing.s8),
                      padding: const EdgeInsets.all(UtenSpacing.s12),
                      decoration: BoxDecoration(
                        color: colors.errorContainer,
                        borderRadius: UtenRadius.controlAll,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _error!,
                            style: TextStyle(color: colors.onErrorContainer),
                          ),
                          if (_capabilities == null)
                            TextButton(
                              onPressed: _loadCapabilities,
                              child: Text(_t('retry')),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        if (!_settingsOpen) _composer(tight),
      ],
    );
    return scrollAll
        ? SingleChildScrollView(
            key: const ValueKey('ai-chat-accessible-scroll'),
            controller: _scroll,
            child: content,
          )
        : content;
  }

  Widget _composer(bool tight) {
    final colors = Theme.of(context).colorScheme;
    final canSend =
        !_busy &&
        !_picking &&
        _capabilities?.usable == true &&
        (_input.text.trim().isNotEmpty || _attachment != null);
    // WeChat-style split composer (2026-10-06): round attach button on the
    // left, a freestanding rounded input field, round send button on the
    // right; the pending file sits in a chip above the row. The 2/4px inner
    // insets keep the buttons off the composer bounds the tests assert on.
    final file = _attachment;
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        key: const ValueKey('ai-chat-composer'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_attachPreviewText() case final preview?)
            Padding(
              key: const ValueKey('ai-chat-attach-preview'),
              padding: const EdgeInsets.only(
                left: UtenSpacing.s4,
                right: UtenSpacing.s4,
                bottom: UtenSpacing.s8,
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.table_view_outlined,
                    size: 14,
                    color: colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: UtenSpacing.s6),
                  Expanded(
                    child: Text(
                      preview,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          if (file != null)
            Padding(
              padding: const EdgeInsets.only(
                left: UtenSpacing.s4,
                right: UtenSpacing.s4,
                bottom: UtenSpacing.s8,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s12,
                  UtenSpacing.s6,
                  UtenSpacing.s6,
                  UtenSpacing.s6,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHigh,
                  borderRadius: UtenRadius.controlAll,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.description_outlined,
                      size: 16,
                      color: colors.primary,
                    ),
                    const SizedBox(width: UtenSpacing.s8),
                    Flexible(
                      child: Text(
                        file.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                    const SizedBox(width: UtenSpacing.s4),
                    IconButton(
                      tooltip: _t('removeFile'),
                      onPressed: () => setState(() => _attachment = null),
                      constraints: const BoxConstraints.tightFor(
                        width: 28,
                        height: 28,
                      ),
                      padding: EdgeInsets.zero,
                      style: const ButtonStyle(
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      icon: Icon(
                        Icons.close,
                        size: 14,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s4,
              0,
              UtenSpacing.s4,
              UtenSpacing.s4,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (_canUpload) ...[
                  IconButton(
                    key: const ValueKey('ai-chat-attach'),
                    tooltip: _t('attach'),
                    onPressed: _busy || _picking ? null : _pickFile,
                    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                    style: IconButton.styleFrom(
                      backgroundColor: colors.surfaceContainerHigh,
                      foregroundColor: colors.onSurfaceVariant,
                      shape: const CircleBorder(),
                    ),
                    icon: const Icon(Icons.attach_file, size: 18),
                  ),
                  const SizedBox(width: UtenSpacing.s8),
                ],
                Expanded(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.surfaceContainerLowest,
                      borderRadius: UtenRadius.controlAll,
                      border: Border.all(
                        color: _focus.hasFocus
                            ? colors.primary
                            : colors.outlineVariant,
                        width: _focus.hasFocus ? 1.5 : 1,
                      ),
                    ),
                    child: Semantics(
                      label: _t('label'),
                      child: Focus(
                        canRequestFocus: false,
                        skipTraversal: true,
                        onKeyEvent: _composerKey,
                        child: TextField(
                          key: const ValueKey('ai-chat-input'),
                          controller: _input,
                          focusNode: _focus,
                          minLines: 1,
                          maxLines: tight ? 2 : 4,
                          inputFormatters: [
                            LengthLimitingTextInputFormatter(2000),
                          ],
                          enabled: _capabilities?.usable == true,
                          textInputAction: TextInputAction.newline,
                          style: Theme.of(context).textTheme.bodyMedium,
                          onChanged: (_) => setState(() {}),
                          decoration: InputDecoration(
                            hintText: _t(_canUpload ? 'hint' : 'hintNoUpload'),
                            hintStyle: TextStyle(
                              color: colors.onSurfaceVariant,
                            ),
                            contentPadding: const EdgeInsets.fromLTRB(
                              UtenSpacing.s12,
                              UtenSpacing.s8,
                              UtenSpacing.s12,
                              UtenSpacing.s8,
                            ),
                            isDense: true,
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            disabledBorder: InputBorder.none,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: UtenSpacing.s8),
                IconButton.filled(
                  key: const ValueKey('ai-chat-send'),
                  tooltip: _t(_cancel != null ? 'stop' : 'send'),
                  constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                  style: IconButton.styleFrom(
                    shape: const CircleBorder(),
                    backgroundColor: colors.primary,
                    foregroundColor: colors.onPrimary,
                  ),
                  onPressed: _cancel != null
                      ? _stop
                      : canSend
                      ? _send
                      : null,
                  icon: Icon(
                    _cancel != null
                        ? Icons.stop_rounded
                        : Icons.arrow_upward_rounded,
                    size: 18,
                    color: _cancel != null || canSend
                        ? colors.onPrimary
                        : colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// ADR-152 send key: Enter sends (Shift+Enter = new line), or Ctrl/Cmd+Enter
  /// sends (Enter = new line). A key that confirms an input-method
  /// composition never sends.
  KeyEventResult _composerKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent ||
        (event.logicalKey != LogicalKeyboardKey.enter &&
            event.logicalKey != LogicalKeyboardKey.numpadEnter)) {
      return KeyEventResult.ignored;
    }
    final composing = _input.value.composing;
    if (composing.isValid && !composing.isCollapsed) {
      return KeyEventResult.ignored;
    }
    final keys = HardwareKeyboard.instance;
    if (keys.isShiftPressed || keys.isAltPressed) return KeyEventResult.ignored;
    final modified = keys.isControlPressed || keys.isMetaPressed;
    final sends = _settings.sendKey == AiChatSendKey.enter || modified;
    if (!sends) return KeyEventResult.ignored;
    if (_cancel == null) _send();
    return KeyEventResult.handled;
  }

  /// "This page will be attached: N rows / M fields / K to review" (ADR-150).
  String? _attachPreviewText() {
    final preview = _attachPreview;
    if (!_pageAware ||
        preview == null ||
        _attachment != null ||
        safeAiChatRoute(widget.currentRoute) == null) {
      return null;
    }
    final l10n = aiPageL10n(context);
    if (preview.protectedPage) return l10n.aiChatAttachProtected;
    if (preview.withheld) return l10n.aiChatAttachWithheld;
    return preview.snapshot == null
        ? l10n.aiChatAttachRouteOnly
        : l10n.aiChatAttachSummary(
            preview.rows,
            preview.fields,
            preview.flagged,
          );
  }

  Widget _historyNote(String text, {Key? key}) => Padding(
    key: key,
    padding: const EdgeInsets.only(bottom: UtenSpacing.s12),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.labelSmall?.copyWith(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    ),
  );

  Widget _welcome() {
    final suggestions = <String, bool>{
      if (_pageAware && _settings.showSuggestions)
        for (final text in _pageSuggestions?.suggestions ?? const <String>[])
          text: text == _t('pageQuestion'),
    };
    if (_settings.showSuggestions) {
      for (final text in _capabilities?.suggestions ?? const <String>[]) {
        if (text == _t('pageQuestion')) continue;
        suggestions.putIfAbsent(text, () => false);
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_t('welcome'), style: Theme.of(context).textTheme.titleLarge),
        if (_capabilities?.available == false) ...[
          const SizedBox(height: UtenSpacing.s12),
          Text(_t('unavailable')),
        ],
        const SizedBox(height: UtenSpacing.s16),
        for (final suggestion in suggestions.entries.take(2))
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: UtenButton(
              type: UtenButtonType.secondary,
              onPressed: _capabilities?.usable == true
                  ? () => _send(
                      suggestion: suggestion.key,
                      intentHint: suggestion.value && _pageAware
                          ? 'PAGE_HELP'
                          : null,
                    )
                  : null,
              child: Flexible(child: Text(suggestion.key)),
            ),
          ),
      ],
    );
  }

  void _sendPageSuggestion(String suggestion) {
    if (!_pageAware ||
        _pageSuggestions?.pageRoute !=
            safeAiGuidedPageRoute(widget.currentRoute) ||
        _pageSuggestions?.suggestions.contains(suggestion) != true) {
      return;
    }
    _send(
      suggestion: suggestion,
      intentHint: suggestion == _t('pageQuestion') ? 'PAGE_HELP' : null,
    );
  }

  Widget _message(_ChatMessage message) {
    final colors = Theme.of(context).colorScheme;
    final largeText = MediaQuery.textScalerOf(context).scale(14) > 21;
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        key: message.attempt == null
            ? null
            : ValueKey('ai-chat-message-${message.attempt!.id}'),
        padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: message.user
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            if (!message.user) ...[
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.auto_awesome_outlined,
                    size: 14,
                    color: colors.primary,
                  ),
                  const SizedBox(width: UtenSpacing.s6),
                  Text(
                    _t('assistant'),
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: UtenSpacing.s6),
            ],
            Align(
              alignment: message.user
                  ? Alignment.centerRight
                  : Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth:
                      constraints.maxWidth *
                      (largeText
                          ? 0.94
                          : message.user
                          ? 0.62
                          : 0.92),
                ),
                child: IntrinsicWidth(
                  child: Container(
                    key: message.attempt == null
                        ? const ValueKey('ai-chat-assistant-bubble')
                        : ValueKey(
                            'ai-chat-user-bubble-${message.attempt!.id}',
                          ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: UtenSpacing.s12,
                      vertical: UtenSpacing.s8,
                    ),
                    decoration: BoxDecoration(
                      color: message.user
                          ? colors.primaryContainer
                          : colors.surfaceContainerLow,
                      borderRadius: UtenRadius.lgAll,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Plain text cannot execute model-supplied links or HTML.
                        SelectableText(
                          message.text,
                          style: TextStyle(
                            height: 1.5,
                            color: message.user
                                ? colors.onPrimaryContainer
                                : colors.onSurface,
                          ),
                        ),
                        if (message.fileName != null) ...[
                          const SizedBox(height: UtenSpacing.s8),
                          Text(
                            message.fileName!,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
            if (!message.user &&
                (message.fallback ||
                    (_settings.showSources && message.sources.isNotEmpty)))
              _replyBasis(message),
            if (message.attempt != null) _messageDelivery(message),
            if (!message.user && message.documentResult != null)
              _documentFollowUps(message),
            for (final action in message.actions) _actionCard(message, action),
          ],
        ),
      ),
    );
  }

  /// Under a file answer: how the purpose was judged (when AI helped), the
  /// purposes to pick, the pages to go to, and what this account cannot do.
  Widget _documentFollowUps(_ChatMessage reply) {
    final result = reply.documentResult!;
    final choices = _documentChoices(reply);
    final pages = _documentPages(reply);
    final aiJudged = result.typeSource == 'AI';
    if (!aiJudged &&
        choices.isEmpty &&
        pages.isEmpty &&
        result.blocked.isEmpty) {
      return const SizedBox.shrink();
    }
    final l10n = aiPageL10n(context);
    final colors = Theme.of(context).colorScheme;
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant);
    final job = reply.documentJobId ?? '';
    final canPick = reply.chosenWorkflow == null && !_busy && !_picking;
    return Padding(
      key: ValueKey('ai-doc-followups-$job'),
      padding: const EdgeInsets.only(top: UtenSpacing.s8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (aiJudged)
            Padding(
              padding: const EdgeInsets.only(bottom: UtenSpacing.s6),
              child: Text(l10n.aiChatDocumentAiJudged, style: muted),
            ),
          if (choices.isNotEmpty)
            Wrap(
              spacing: UtenSpacing.s8,
              runSpacing: UtenSpacing.s4,
              children: [
                for (final choice in choices)
                  ChoiceChip(
                    key: ValueKey('ai-doc-choice-$job-${choice.workflow.code}'),
                    label: Text(choice.title),
                    selected: reply.chosenWorkflow == choice.workflow,
                    onSelected: canPick
                        ? (_) => _chooseWorkflow(reply, choice)
                        : null,
                  ),
              ],
            ),
          if (pages.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(
                top: choices.isEmpty ? 0 : UtenSpacing.s4,
              ),
              child: Wrap(
                spacing: UtenSpacing.s8,
                runSpacing: UtenSpacing.s4,
                children: [
                  for (final page in pages)
                    ActionChip(
                      key: ValueKey('ai-doc-page-$job-${page.key}'),
                      avatar: const Icon(Icons.open_in_new, size: 16),
                      label: Text(l10n.aiChatDocumentOpenPage(page.title)),
                      onPressed: () => _openDocumentPage(page),
                    ),
                ],
              ),
            ),
          for (final (index, item) in result.blocked.indexed)
            Padding(
              key: ValueKey('ai-doc-blocked-$job-$index'),
              padding: const EdgeInsets.only(top: UtenSpacing.s6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: UtenSpacing.s2),
                    child: Icon(
                      Icons.lock_outline,
                      size: 14,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s6),
                  Expanded(
                    child: Text(
                      l10n.aiChatDocumentBlockedLine(item.title, item.reason),
                      style: muted,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// "Based on: ..." and the deterministic-summary note under a reply.
  Widget _replyBasis(_ChatMessage message) {
    final l10n = aiPageL10n(context);
    final style = Theme.of(context).textTheme.labelSmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
    );
    final labels = message.sources.map((source) => source.label).toSet();
    final page = message.sources.any((source) => source.id.startsWith('page.'));
    return Padding(
      key: const ValueKey('ai-chat-reply-basis'),
      padding: const EdgeInsets.only(top: UtenSpacing.s4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.fallback) Text(l10n.aiChatFallback, style: style),
          // ADR-152: "show answer sources" off hides only this line; the
          // server still checks every answer against its sources.
          if (labels.isNotEmpty && _settings.showSources)
            Text(
              page || message.fallback
                  ? '${l10n.aiChatSources(labels.join('、'))} · ${l10n.aiChatVerifyOnPage}'
                  : l10n.aiChatSources(labels.join('、')),
              style: style,
            ),
        ],
      ),
    );
  }

  Widget _messageDelivery(_ChatMessage message) {
    final attempt = message.attempt!;
    if (attempt.delivery == _ChatDelivery.answered) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final pending =
        attempt.delivery == _ChatDelivery.sending ||
        attempt.delivery == _ChatDelivery.processing;
    final status = switch (attempt.delivery) {
      _ChatDelivery.sending => attempt.progressKey,
      _ChatDelivery.processing => 'received',
      _ChatDelivery.rejected => 'requestRejected',
      _ChatDelivery.unknown => 'deliveryUnknown',
      _ChatDelivery.processingFailed => 'replyFailed',
      _ChatDelivery.interrupted => 'replyInterrupted',
      _ChatDelivery.stopped => 'waitingStopped',
      _ChatDelivery.answered => 'received',
    };
    return Padding(
      key: ValueKey('ai-chat-delivery-${attempt.id}'),
      padding: const EdgeInsets.only(top: UtenSpacing.s6),
      child: Semantics(
        liveRegion: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (pending)
                  const Padding(
                    padding: EdgeInsets.only(top: UtenSpacing.s2),
                    child: SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.5),
                    ),
                  )
                else
                  Icon(Icons.error_outline, size: 16, color: colors.error),
                const SizedBox(width: UtenSpacing.s6),
                Flexible(
                  child: Text(
                    _t(status),
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: pending ? colors.onSurfaceVariant : colors.error,
                      height: 1.4,
                    ),
                  ),
                ),
              ],
            ),
            if (!pending && attempt.failure?.isNotEmpty == true) ...[
              const SizedBox(height: UtenSpacing.s4),
              Text(
                attempt.failure!,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
            if (!pending)
              TextButton(
                key: ValueKey('ai-chat-retry-${attempt.id}'),
                onPressed: _busy ? null : () => _retryMessage(message),
                child: Text(
                  _t(
                    attempt.delivery == _ChatDelivery.interrupted
                        ? 'checkReply'
                        : attempt.delivery == _ChatDelivery.unknown
                        ? 'sendAgain'
                        : 'retryMessage',
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _actionCard(_ChatMessage message, AiChatAction action) {
    final ui = _cardUi(action);
    return AiChatActionCard(
      key: ValueKey('ai-action-${action.proposalId}'),
      ui: ui,
      enabled: !_cardRunning || ui.running,
      onConfirm: () => _confirmCard(message, ui),
      onCancel: () => _cancelCard(ui),
      onCheck: () => _refreshCard(ui),
    );
  }
}
