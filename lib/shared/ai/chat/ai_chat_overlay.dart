import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/capsule_nav_metrics.dart';
import '../../../features/sales/intake/sales_intake_launcher.dart';
import '../../../features/sales/intake/sales_intake_models.dart';
import '../../../features/sales/models/sales_doc.dart';
import '../../auth/permissions.dart';
import '../../providers/authenticated_scope_provider.dart';
import '../ai_job_models.dart';
import '../ai_job_runner.dart';
import 'ai_chat_l10n.dart';
import 'ai_chat_models.dart';
import 'ai_chat_repository.dart';

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
    this.attempt,
  });
  final String text;
  final bool user;
  final String? fileName;
  final List<AiChatAction> actions;
  final _ChatAttempt? attempt;
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
    this.file,
    this.previousJobId,
    this.currentRoute,
    this.intentHint,
  });
  final int id;
  final String text;
  final PlatformFile? file;
  final String? previousJobId;
  final String? currentRoute;
  final String? intentHint;
  String? attachmentJobId;
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
  final _sourceFiles = <String, PlatformFile>{};
  final _completedActions = <AiChatAction>{};
  final _dialogs = <DialogRoute<bool>>{};
  AiChatCapabilities? _capabilities;
  AiJobCancelToken? _cancel;
  PlatformFile? _attachment;
  String? _previousJobId;
  String? _error;
  String? _progressKey;
  double? _launcherBottom;
  bool _open = false;
  bool _loadingCapabilities = true;
  bool _busy = false;
  bool _picking = false;
  bool _pageAware = true;
  int _generation = 0;
  int _nextMessageId = 0;
  _ChatMessage? _activeMessage;

  String _t(String key) => aiChatText(context, key);
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
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _generation++;
    _cancel?.cancel();
    _input.dispose();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    _scroll.dispose();
    _sourceFiles.clear();
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

  Future<void> _loadCapabilities() async {
    final repository = ref.read(aiChatRepositoryProvider);
    try {
      final result = await repository.capabilities();
      if (!_current) return;
      setState(() {
        _capabilities = result;
        _loadingCapabilities = false;
        _error = null;
      });
    } catch (_) {
      if (!_current) return;
      setState(() {
        _loadingCapabilities = false;
        _error = _t('loadFailed');
      });
    }
  }

  Future<void> _pickFile() async {
    if (!_current ||
        _busy ||
        _picking ||
        widget.identity.scope.readOnly ||
        _capabilities?.canUploadSalesOrder != true) {
      return;
    }
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['xlsx', 'xls', 'csv'],
        withData: true,
        allowCompression: false,
      );
      if (!_current || result == null || result.files.isEmpty) return;
      final file = result.files.single;
      final bytes = file.bytes;
      final extension = file.extension?.toLowerCase();
      if (!const ['xlsx', 'xls', 'csv'].contains(extension) ||
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
        ..._sourceFiles.values,
        for (final message in _messages) ?message.attempt?.file,
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
    if (_messages.length >= 40) {
      setState(() => _error = _t('limit'));
      return;
    }
    final message = typed.isEmpty ? _t('attachmentQuestion') : typed;
    if (message.length > 2000) return;
    final currentRoute = _pageAware
        ? safeAiChatRoute(widget.currentRoute)
        : null;
    final outgoing = _ChatMessage(
      text: message,
      user: true,
      fileName: file?.name,
      attempt: _ChatAttempt(
        id: ++_nextMessageId,
        text: message,
        file: file,
        previousJobId: _previousJobId,
        currentRoute: currentRoute,
        intentHint: currentRoute == null ? null : intentHint,
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
      attempt.progressKey = file != null && attempt.attachmentJobId == null
          ? 'uploading'
          : 'sending';
      if (!resume) {
        attempt.submittedJobId = null;
        attempt.chatSubmissionStarted = false;
      }
    });
    _scrollToEnd();
    try {
      final AiJobSnapshot snapshot;
      if (resume && attempt.submittedJobId != null) {
        snapshot = await runner.resume(
          attempt.submittedJobId!,
          cancelToken: cancel,
        );
      } else {
        if (file != null && attempt.attachmentJobId == null) {
          final uploaded = await runner.run(
            AiJobRequest(
              kind: kSalesIntakeJobKind,
              params: const {'docType': 'order'},
              bytes: file.bytes!,
              fileName: file.name,
              contentType:
                  kSalesIntakeContentTypes[file.extension!.toLowerCase()]!,
            ),
            cancelToken: cancel,
          );
          if (!_active(generation) || cancel.isCancelled) return;
          attempt.attachmentJobId = uploaded.id;
          _sourceFiles[uploaded.id] = file;
        }
        if (!_active(generation) || cancel.isCancelled) return;
        setState(() => attempt.progressKey = 'sending');
        attempt.chatSubmissionStarted = true;
        final submitted = await repository.send(
          message: attempt.text,
          previousJobId: attempt.previousJobId,
          attachmentJobId: attempt.attachmentJobId,
          currentRoute: attempt.currentRoute,
          intentHint: attempt.intentHint,
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
        // Retrying an older bubble must not rewind a newer conversation branch.
        if (!_messages.skip(index + 1).any((item) => item.user)) {
          _previousJobId = snapshot.id;
        }
        attempt.delivery = _ChatDelivery.answered;
        _messages.insert(
          index + 1,
          _ChatMessage(
            text: reply.reply.isEmpty ? _t('emptyReply') : reply.reply,
            actions: reply.actions,
          ),
        );
      });
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
    _cancel?.cancel();
    _cancel = null;
    _messages.clear();
    _sourceFiles.clear();
    _completedActions.clear();
    _attachment = null;
    _previousJobId = null;
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
  }

  void _scrollToEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  Future<void> _openDraft(AiChatAction action) async {
    if (!_current ||
        _busy ||
        _completedActions.contains(action) ||
        action.jobId == null ||
        _capabilities?.canUploadSalesOrder != true ||
        widget.identity.scope.readOnly ||
        !ref.read(currentPermissionsProvider).contains(Perm.salesOrderCreate)) {
      return;
    }
    final file = _sourceFiles[action.jobId];
    if (file == null) {
      setState(() => _error = _t('fileMissing'));
      return;
    }
    // Only this hard-coded, permission-guarded route can leave the chat. Any
    // path/url included in a model response is ignored by the model parser.
    final uri = Uri(
      path: RoutePath.salesDocNew(SalesDocType.order.pathSegment),
      queryParameters: {'aiJobId': action.jobId!},
    );
    setState(() {
      _open = false;
      _completedActions.add(action);
    });
    _focus.unfocus();
    await context.push(uri.toString(), extra: file);
  }

  Future<void> _confirmGrant(AiChatAction action) async {
    if (!_current || _busy || !_canConfirmGrant(action)) return;
    if (!action.expiresAt!.isAfter(DateTime.now())) {
      setState(() => _error = _t('grantExpired'));
      return;
    }
    final approved = await _confirmForIdentity(
      title: _t('confirmPermission'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_t('grantDetails')),
          const SizedBox(height: UtenSpacing.s16),
          _grantDetails(action),
        ],
      ),
    );
    if (!_current || approved != true || !_canConfirmGrant(action)) return;
    final repository = ref.read(aiChatRepositoryProvider);
    final generation = ++_generation;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      // The shared network interceptor performs the required step-up. No
      // password, permission code, target, or scope is invented by this client.
      final reply = await repository.confirmPermissionGrant(action.proposalId!);
      if (!_active(generation)) return;
      setState(() {
        _completedActions.add(action);
        _messages.add(
          _ChatMessage(text: reply.isEmpty ? _t('permissionDone') : reply),
        );
      });
    } catch (error) {
      if (!_active(generation)) return;
      setState(
        () => _error =
            error is NetworkException || error is NetworkTimeoutException
            ? _t('grantUnknown')
            : _errorText(error),
      );
    } finally {
      if (_active(generation)) {
        setState(() => _busy = false);
        _scrollToEnd();
      }
    }
  }

  bool _canConfirmGrant(AiChatAction action) =>
      _capabilities?.canManagePermissions == true &&
      widget.identity.superAdmin &&
      widget.identity.scope.actorId == null &&
      !widget.identity.scope.readOnly &&
      action.hasReviewableGrant &&
      !_completedActions.contains(action);

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

  Widget _grantDetails(AiChatAction action) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('${_t('permissionTarget')}：${action.targetName}'),
      const SizedBox(height: UtenSpacing.s8),
      Text(
        '${_t('permissionItem')}：${action.permissionName} (${action.permissionCode})',
      ),
      const SizedBox(height: UtenSpacing.s8),
      Text('${_t('permissionScope')}：${action.scopeSummary}'),
      if (action.expiresAt != null) ...[
        const SizedBox(height: UtenSpacing.s8),
        Text(
          '${_t('permissionExpiry')}：${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(action.expiresAt!.toLocal()))}',
        ),
      ],
    ],
  );

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
        final bottom = (_launcherBottom ?? minimumBottom + 72)
            .clamp(minimumBottom, maximumBottom)
            .toDouble();
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
        void move(double delta) => setState(
          () => _launcherBottom = (bottom + delta)
              .clamp(minimumBottom, maximumBottom)
              .toDouble(),
        );
        return Stack(
          children: [
            if (!_open)
              Positioned(
                right: UtenSpacing.s16,
                bottom: bottom,
                child: Semantics(
                  label: _t('open'),
                  customSemanticsActions: {
                    CustomSemanticsAction(label: _t('moveUp')): () => move(72),
                    CustomSemanticsAction(label: _t('moveDown')): () =>
                        move(-72),
                  },
                  child: GestureDetector(
                    onVerticalDragUpdate: (details) => move(-details.delta.dy),
                    child: FloatingActionButton.small(
                      key: const ValueKey('ai-chat-launcher'),
                      heroTag: null,
                      tooltip: _t('open'),
                      backgroundColor: colors.primaryContainer,
                      foregroundColor: colors.onPrimaryContainer,
                      onPressed: () {
                        setState(() => _open = true);
                        _scrollToEnd();
                      },
                      child: const Icon(Icons.auto_awesome_outlined),
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
                    const SingleActivator(
                      LogicalKeyboardKey.enter,
                      control: true,
                    ): _send,
                    const SingleActivator(LogicalKeyboardKey.enter, meta: true):
                        _send,
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
              Icon(
                Icons.auto_awesome_outlined,
                size: 20,
                color: colors.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  _t('title'),
                  style: Theme.of(context).textTheme.titleMedium,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                key: const ValueKey('ai-chat-info'),
                tooltip: _t('info'),
                onPressed: _showHelp,
                icon: const Icon(Icons.info_outline, size: 20),
              ),
              IconButton(
                tooltip: _t('reset'),
                onPressed: _busy || _picking ? null : _newChat,
                icon: const Icon(Icons.add_comment_outlined, size: 20),
              ),
              IconButton(
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
        if (!tight)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: UtenSpacing.s12),
            child: Row(
              children: [
                const Icon(Icons.description_outlined, size: 16),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    _t(_pageAware ? 'pageAware' : 'pageOff'),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Tooltip(
                  message: _t('pageHint'),
                  child: Switch.adaptive(
                    value: _pageAware,
                    onChanged: (value) => setState(() => _pageAware = value),
                  ),
                ),
              ],
            ),
          ),
        messagesViewport(
          child: ListView(
            key: const ValueKey('ai-chat-messages'),
            controller: scrollAll ? null : _scroll,
            shrinkWrap: scrollAll,
            physics: scrollAll ? const NeverScrollableScrollPhysics() : null,
            padding: const EdgeInsets.all(UtenSpacing.s16),
            children: [
              if (_messages.isEmpty) _welcome(),
              for (final message in _messages) _message(message),
              if (_busy && _activeMessage == null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s8),
                  child: Row(
                    children: [
                      const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: UtenSpacing.s12),
                      Expanded(child: Text(_t(_progressKey ?? 'pendingGrant'))),
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
        _composer(tight),
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
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            key: const ValueKey('ai-chat-composer'),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLowest,
              borderRadius: UtenRadius.xlAll,
              border: Border.all(
                color: _focus.hasFocus ? colors.primary : colors.outlineVariant,
                width: _focus.hasFocus ? 1.5 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_attachment != null)
                  Padding(
                    padding: const EdgeInsets.only(
                      left: UtenSpacing.s12,
                      right: UtenSpacing.s4,
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.description_outlined,
                          size: 18,
                          color: colors.primary,
                        ),
                        const SizedBox(width: UtenSpacing.s8),
                        Expanded(
                          child: Text(
                            _attachment!.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        IconButton(
                          tooltip: _t('removeFile'),
                          onPressed: () => setState(() => _attachment = null),
                          icon: const Icon(Icons.close, size: 16),
                        ),
                      ],
                    ),
                  ),
                Semantics(
                  label: _t('label'),
                  child: TextField(
                    key: const ValueKey('ai-chat-input'),
                    controller: _input,
                    focusNode: _focus,
                    minLines: tight ? 1 : 2,
                    maxLines: tight ? 2 : 4,
                    inputFormatters: [LengthLimitingTextInputFormatter(2000)],
                    enabled: _capabilities?.usable == true,
                    textInputAction: TextInputAction.newline,
                    style: Theme.of(context).textTheme.bodyMedium,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      hintText: _t(
                        _capabilities?.canUploadSalesOrder == true
                            ? 'hint'
                            : 'hintNoUpload',
                      ),
                      hintStyle: TextStyle(color: colors.onSurfaceVariant),
                      contentPadding: const EdgeInsets.fromLTRB(
                        UtenSpacing.s12,
                        UtenSpacing.s12,
                        UtenSpacing.s12,
                        UtenSpacing.s4,
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
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    UtenSpacing.s4,
                    0,
                    UtenSpacing.s4,
                    UtenSpacing.s4,
                  ),
                  child: Row(
                    children: [
                      if (_capabilities?.canUploadSalesOrder == true &&
                          !widget.identity.scope.readOnly)
                        IconButton(
                          key: const ValueKey('ai-chat-attach'),
                          tooltip: _t('attach'),
                          onPressed: _busy || _picking ? null : _pickFile,
                          icon: Icon(
                            Icons.attach_file,
                            size: 20,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      const Spacer(),
                      IconButton.filled(
                        key: const ValueKey('ai-chat-send'),
                        tooltip: _t(_cancel != null ? 'stop' : 'send'),
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
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
                          size: 20,
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
          ),
        ],
      ),
    );
  }

  Widget _welcome() {
    final colors = Theme.of(context).colorScheme;
    final suggestions = <String, bool>{
      if (_pageAware) _t('pageQuestion'): true,
    };
    for (final text in _capabilities?.suggestions ?? const <String>[]) {
      suggestions.putIfAbsent(text, () => false);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_t('welcome'), style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          _capabilities?.scopeSummary.isNotEmpty == true
              ? _capabilities!.scopeSummary
              : _t('boundary'),
          style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
        ),
        if (_capabilities?.available == false) ...[
          const SizedBox(height: UtenSpacing.s12),
          Text(_t('unavailable'), style: Theme.of(context).textTheme.bodySmall),
        ],
        const SizedBox(height: UtenSpacing.s20),
        for (final suggestion in suggestions.entries)
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
            if (message.attempt != null) _messageDelivery(message),
            for (final action in message.actions) _action(action),
          ],
        ),
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

  Widget _action(AiChatAction action) {
    final colors = Theme.of(context).colorScheme;
    final isOrder =
        action.type == 'OPEN_SALES_ORDER_DRAFT' && action.jobId != null;
    final isGrant =
        action.type == 'CONFIRM_PERMISSION_GRANT' && action.hasReviewableGrant;
    final completed = _completedActions.contains(action);
    return Container(
      margin: const EdgeInsets.only(top: UtenSpacing.s8),
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: UtenRadius.lgAll,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isGrant
                    ? Icons.admin_panel_settings_outlined
                    : Icons.description_outlined,
                size: 20,
                color: colors.primary,
              ),
              const SizedBox(width: UtenSpacing.s8),
              Expanded(
                child: Text(
                  action.title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
            ],
          ),
          if (action.summary.isNotEmpty) ...[
            const SizedBox(height: UtenSpacing.s8),
            Text(action.summary),
          ],
          const SizedBox(height: UtenSpacing.s12),
          if (isOrder) ...[
            Text(_t('draftHint'), style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: UtenSpacing.s12),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed:
                  !_busy &&
                      !completed &&
                      _capabilities?.canUploadSalesOrder == true &&
                      !widget.identity.scope.readOnly
                  ? () => _openDraft(action)
                  : null,
              child: Flexible(
                child: Text(_t(completed ? 'draftOpened' : 'openDraft')),
              ),
            ),
          ] else if (isGrant) ...[
            _grantDetails(action),
            const SizedBox(height: UtenSpacing.s12),
            UtenButton(
              type: UtenButtonType.secondary,
              onPressed: !_busy && _canConfirmGrant(action)
                  ? () => _confirmGrant(action)
                  : null,
              child: Flexible(
                child: Text(
                  _t(completed ? 'permissionDone' : 'confirmPermission'),
                ),
              ),
            ),
          ] else
            Text(
              _t('unsupported'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
    );
  }
}
