import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../components/buttons/uten_button.dart';
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
  bool _loading = false;
  bool _performing = false;

  String get _identity =>
      '${widget.family}:${widget.documentId}:${identityHashCode(widget.revision)}';

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
      _capability = null;
      _error = null;
      _load();
    }
  }

  @override
  void nativeReadOwnerChanged() {
    ++_generation;
    setState(() {
      _capability = null;
      _error = null;
      _loading = false;
      _performing = false;
    });
  }

  @override
  void nativeReadPermissionChanged() {
    if (mounted) setState(() {});
  }

  @override
  Future<void> nativeReadReload() => _load();

  Future<void> _load() async {
    final generation = ++_generation;
    final identity = _identity;
    final accepts = captureNativeRead(identity, () => _identity);
    final family = widget.family;
    final id = widget.documentId;
    setState(() {
      _loading = true;
      _capability = null;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      final scope = await api.captureRequestScope(
        isCurrent: () => mounted && generation == _generation && accepts(),
      );
      final capability = await scope.run(
        () => fetchDocumentUnapprovalCapability(api, family, id),
      );
      if (!mounted || generation != _generation || !accepts()) return;
      acceptNativeRead();
      setState(() {
        _capability = capability;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation || !accepts()) return;
      setState(() {
        _loading = false;
        _error = error is ApiException ? error.message : '无法核对反审条件，请重新核对。';
      });
    }
  }

  Future<void> _perform() async {
    if (_performing || widget.onPressed == null || !nativeReadCanWrite) return;
    final owns = captureNativeOwnership();
    final identity = _identity;
    setState(() => _performing = true);
    try {
      await _load();
      if (!mounted || !owns() || identity != _identity || !nativeReadCanWrite) {
        return;
      }
      final capability = _capability;
      if (capability?.eligible != true) {
        context.appWarning(capability?.blockReason ?? _error ?? '反审条件尚未核实');
        return;
      }
      await withDocumentUnapprovalSnapshot(
        widget.family,
        widget.documentId,
        capability!.factsSnapshot,
        widget.onPressed!,
      );
    } finally {
      if (mounted && owns() && identity == _identity) {
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
      _load();
      return;
    }
    if (!nativeReadAccessConfirmed) return;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => trackNativeReadDialog(
        dialogContext,
        UtenAlertDialog(
          title: const Text('暂不能反审'),
          content: Text(_capability!.blockReason),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(dialogContext);
                _load();
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
