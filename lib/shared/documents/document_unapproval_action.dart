import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
import '../../components/feedback/uten_busy_overlay.dart';
import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/ui/app_notification.dart';
import '../auth/native_read_view_scope_mixin.dart';
import 'document_unapproval.dart';

/// The action uses the same source/cash/cost predicates as the actual reversal.
class DocumentUnapprovalAction extends ConsumerStatefulWidget {
  const DocumentUnapprovalAction({
    super.key,
    required this.family,
    required this.documentId,
    required this.revision,
    required this.onPressed,
    this.size = UtenButtonSize.large,
  });

  final String family;
  final String documentId;
  final Object revision;
  final FutureOr<void> Function()? onPressed;
  final UtenButtonSize size;

  @override
  ConsumerState<DocumentUnapprovalAction> createState() =>
      _DocumentUnapprovalActionState();
}

class _DocumentUnapprovalActionState
    extends ConsumerState<DocumentUnapprovalAction>
    with NativeReadViewScopeMixin<DocumentUnapprovalAction> {
  DocumentUnapprovalCapability? _capability;
  String? _error;
  int _generation = 0;
  int _performGeneration = 0;
  VoidCallback? _cancelRead;
  bool _loading = false;
  bool _performing = false;

  Object get _identity => (widget.family, widget.documentId, widget.revision);

  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    _load();
  }

  @override
  void didUpdateWidget(covariant DocumentUnapprovalAction oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.family != widget.family ||
        oldWidget.documentId != widget.documentId ||
        oldWidget.revision != widget.revision) {
      ++_generation;
      ++_performGeneration;
      _cancelRead?.call();
      _performing = false;
      _capability = null;
      _error = null;
      _load();
    }
  }

  @override
  void nativeReadOwnerChanged() {
    ++_generation;
    ++_performGeneration;
    _cancelRead?.call();
    setState(() {
      _capability = null;
      _error = null;
      _loading = false;
      _performing = false;
    });
  }

  @override
  void nativeReadPermissionChanged() {
    ++_generation;
    ++_performGeneration;
    _cancelRead?.call();
    if (mounted) {
      setState(() {
        _capability = null;
        _loading = false;
        _performing = false;
      });
    }
  }

  @override
  Future<void> nativeReadReload() => _load().then((_) {});

  Future<bool> _load({bool userTriggered = false, int? performingToken}) async {
    _cancelRead?.call();
    final generation = ++_generation;
    final identity = _identity;
    final accepts = captureNativeRead(identity, () => _identity);
    final family = widget.family;
    final id = widget.documentId;
    final api = ref.read(apiClientProvider);
    final route = userTriggered ? ModalRoute.of(context) : null;
    var stopped = false;
    bool current() =>
        mounted &&
        !stopped &&
        generation == _generation &&
        identity == _identity &&
        accepts() &&
        identical(api, ref.read(apiClientProvider)) &&
        (!userTriggered || route?.isCurrent != false);
    if (!current()) return false;
    final cancelled = Completer<bool>();
    OverlayEntry? mask;
    var maskRemoved = false;
    void closeMask() {
      if (maskRemoved) return;
      maskRemoved = true;
      mask?.remove();
      mask?.dispose();
    }

    void cancelRead() {
      if (stopped) return;
      stopped = true;
      closeMask();
      if (!cancelled.isCompleted) cancelled.complete(false);
      if (!mounted || generation != _generation) return;
      ++_generation;
      if (performingToken != null && performingToken == _performGeneration) {
        ++_performGeneration;
        _performing = false;
      }
      failNativeRead(
        StateError('Capability read cancelled'),
        message: '本次核对已取消',
      );
      setState(() {
        _loading = false;
        _capability = null;
        _error = '本次核对已取消，请重新核对。';
      });
    }

    _cancelRead = cancelRead;
    setState(() {
      _loading = true;
      _capability = null;
      _error = null;
    });
    if (userTriggered) {
      mask = OverlayEntry(
        builder: (_) => UtenBusyOverlay(
          title: '正在核对反审条件',
          showDoNotLeaveHint: false,
          onCancel: cancelRead,
        ),
      );
      Overlay.of(context, rootOverlay: true).insert(mask);
    }
    Future<bool> read() async {
      try {
        final scope = await api.captureRequestScope(isCurrent: current);
        final capability = await scope.run(
          () => fetchDocumentUnapprovalCapability(api, family, id),
        );
        if (!current()) return false;
        acceptNativeRead();
        setState(() {
          _capability = capability;
          _loading = false;
        });
        return true;
      } catch (error) {
        if (!current()) return false;
        final message = error is ApiException
            ? error.message
            : '无法核对反审条件，请重新核对。';
        failNativeRead(error, message: message);
        setState(() {
          _loading = false;
          _error = message;
        });
        return false;
      }
    }

    try {
      return await Future.any([read(), cancelled.future]);
    } finally {
      stopped = true;
      closeMask();
      if (identical(_cancelRead, cancelRead)) _cancelRead = null;
      if (mounted && generation == _generation && _loading) {
        setState(() => _loading = false);
      }
      if (userTriggered && mask != null && mounted) {
        // The busy widget owns its own root entry. Let its removal finish
        // before the caller can present a confirmation or result dialog.
        await WidgetsBinding.instance.endOfFrame;
      }
    }
  }

  Future<void> _perform() async {
    if (_performing || widget.onPressed == null || !nativeReadCanWrite) return;
    final owns = captureNativeOwnership();
    final identity = _identity;
    final performingToken = ++_performGeneration;
    final action = widget.onPressed!;
    final family = widget.family, documentId = widget.documentId;
    setState(() => _performing = true);
    try {
      final accepted = await _load(
        userTriggered: true,
        performingToken: performingToken,
      );
      if (!accepted ||
          !mounted ||
          performingToken != _performGeneration ||
          !owns() ||
          identity != _identity ||
          !nativeReadCanWrite ||
          widget.onPressed == null ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      final capability = _capability;
      if (capability?.eligible != true) {
        context.appWarning(capability?.blockReason ?? _error ?? '反审条件尚未核实');
        return;
      }
      await withDocumentUnapprovalSnapshot(
        family,
        documentId,
        capability!.factsSnapshot,
        action,
      );
    } finally {
      if (mounted &&
          performingToken == _performGeneration &&
          owns() &&
          identity == _identity) {
        setState(() => _performing = false);
      }
    }
  }

  void _explain() {
    if (_loading) return;
    if (widget.onPressed == null) {
      context.appInfo('当前还有操作正在处理，请稍候再反审');
      return;
    }
    if (_capability == null) {
      unawaited(_load(userTriggered: true));
      return;
    }
    if (!nativeReadAccessConfirmed) return;
    var retryRequested = false;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => trackNativeReadDialog(
        dialogContext,
        UtenAlertDialog(
          title: const Text('暂不能反审'),
          showCloseButton: true,
          onClose: () => Navigator.pop(dialogContext),
          content: Text(_capability!.blockReason),
          actions: [
            TextButton(
              onPressed: () {
                if (retryRequested) return;
                retryRequested = true;
                Navigator.pop(dialogContext);
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) unawaited(_load(userTriggered: true));
                });
              },
              child: const Text('重新核对'),
            ),
          ],
        ),
        readOnly: true,
      ),
    );
  }

  @override
  void dispose() {
    ++_generation;
    ++_performGeneration;
    _cancelRead?.call();
    _cancelRead = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ready = nativeReadCanWrite && _capability?.eligible == true;
    final hint = !nativeReadAccessConfirmed
        ? '正在核对反审条件'
        : _capability?.blockReason ?? _error ?? '正在核对反审条件';
    return Tooltip(
      message: ready ? '撤回本次审核并进入可编辑草稿' : hint,
      child: UtenButton(
        type: UtenButtonType.danger,
        size: widget.size,
        icon: Icons.undo_outlined,
        onPressed:
            ready && !_loading && !_performing && widget.onPressed != null
            ? _perform
            : null,
        onDisabledTap: _performing ? null : _explain,
        child: Text(
          _loading
              ? '核对反审条件'
              : _error != null
              ? '重新核对反审'
              : '反审',
        ),
      ),
    );
  }
}
