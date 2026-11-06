import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../core/network/api_client.dart';
import '../../../core/performance/json_value_snapshot.dart';
import '../../../core/router/route_names.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/drafts/form_draft.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../config/finance_doc_config.dart';
import '../models/finance_doc.dart';
import '../repositories/finance_repository.dart';

class FinanceBatchRecoveryPage extends StatelessWidget {
  const FinanceBatchRecoveryPage({
    super.key,
    required this.docType,
    required this.draftId,
  });
  final FinanceDocType docType;
  final String draftId;
  @override
  Widget build(BuildContext context) => Scaffold(
    body: UtenEmbeddedDialogScope(
      child: _FinanceBatchRecovery(
        draftId: draftId,
        expectedSegment: docType.pathSegment,
        onFinish: (location) {
          if (location != null) {
            context.go(location);
          } else {
            popOrBackTo(
              context,
              defaultPath: FinanceDocConfig.by(docType).listLocation,
            );
          }
        },
      ),
    ),
  );
}

/// This view-only entry never creates a document, changes financial input or
/// uploads a file. Its only local write adopts the matched original outcome.
class _FinanceBatchRecovery extends ConsumerStatefulWidget {
  const _FinanceBatchRecovery({
    required this.draftId,
    required this.expectedSegment,
    required this.onFinish,
  });
  final String draftId;
  final String expectedSegment;
  final ValueChanged<String?> onFinish;
  @override
  ConsumerState<_FinanceBatchRecovery> createState() =>
      _FinanceBatchRecoveryState();
}

class _FinanceBatchRecoveryState extends ConsumerState<_FinanceBatchRecovery>
    with NativeReadViewScopeMixin<_FinanceBatchRecovery> {
  bool _busy = false;
  String? _error;
  FormDraft? _draft, _checkpoint;
  Map<String, dynamic>? _command, _receipt;
  FinanceDocConfig? _config;
  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void nativeReadOwnerChanged() => setState(() {
    _draft = null;
    _checkpoint = null;
    _command = null;
    _receipt = null;
    _config = null;
    _busy = false;
    _error = '原账号或服务器已变化，原批次仍保留';
  });
  @override
  void nativeReadPermissionChanged() => setState(() {
    _busy = false;
    _draft = null;
    _checkpoint = null;
    _command = null;
    _receipt = null;
    _config = null;
  });
  @override
  Future<void> nativeReadReload() => _load();
  bool get _mayCancel {
    final owner = ref.read(authenticatedScopeProvider);
    return nativeReadAccessConfirmed &&
        owner != null &&
        !owner.readOnly &&
        owner.actorId == null &&
        _config != null &&
        ref.read(currentPermissionsProvider).contains(_config!.listPerm);
  }

  Future<void> _load() async {
    if (_busy) return;
    final accepts = captureNativeRead(
      'batch/${widget.draftId}',
      () => 'batch/${widget.draftId}',
    );
    if (!accepts()) return;
    setState(() {
      _busy = true;
      _error = null;
      _receipt = null;
      _checkpoint = null;
    });
    try {
      final store = ref.read(formDraftsProvider.notifier);
      await store.ready;
      if (!mounted || !accepts()) return;
      final ownerKey = store.ownerKey;
      final draft = await store.readFinanceBatchRecovery(widget.draftId);
      if (!mounted || !accepts() || store.ownerKey != ownerKey) return;
      final family = draft == null ? null : financeBatchRecoveryFamily(draft);
      if (draft == null ||
          family == null ||
          family.segment != widget.expectedSegment ||
          !ref
              .read(currentPermissionsProvider)
              .contains(family.permissions.view)) {
        throw StateError('原批次不存在或当前无权核对');
      }
      final active = draft.data['batchCommand'],
          retired = draft.data['batchRetiredReceipt'];
      final body = active is Map
          ? active
          : retired is Map
          ? retired['requestBody']
          : null;
      if (body is! Map) throw StateError('原批次正文不完整，原草稿继续保留');
      final command =
          await snapshotJsonValueResponsive(
                Map<String, dynamic>.from(body),
                isCurrent: () => accepts() && store.ownerKey == ownerKey,
              )
              as Map<String, dynamic>;
      final owner = ref.read(authenticatedScopeProvider);
      if (!mounted || !accepts() || owner == null) return;
      final type = FinanceDocType.byPath(family.segment),
          config = FinanceDocConfig.by(FinanceDocType.byPath(family.segment));
      final api = ref.read(apiClientProvider);
      final scope = await api.captureRequestScope(
        isCurrent: () => mounted && accepts() && store.ownerKey == ownerKey,
      );
      final receipt = await scope.run(
        () => ref
            .read(financeRepositoryProvider(type))
            .batchReceipt(
              command,
              owner.userId,
              isCurrent: () => mounted && scope.isCurrent,
            ),
      );
      if (!mounted || !scope.isCurrent || !accepts()) return;
      FormDraft? checkpoint;
      if (receipt['found'] == true) {
        checkpoint = await store.confirmFinanceBatchRecovery(
          draft.id,
          expectedRevision: draft.revision,
          receipt: receipt,
        );
      }
      if (!mounted || !scope.isCurrent || !accepts()) return;
      acceptNativeRead();
      setState(() {
        _draft = draft;
        _command = command;
        _config = config;
        _receipt = receipt;
        _checkpoint = checkpoint;
        _busy = false;
      });
    } catch (_) {
      if (mounted && accepts()) {
        setState(() => _error = '原批次尚未核对完成，请重新读取。原行、原编号与凭证继续保留');
      }
    } finally {
      if (mounted && accepts()) setState(() => _busy = false);
    }
  }

  Future<void> _cancel() async {
    final draft = _draft, command = _command, config = _config;
    if (_busy ||
        !_mayCancel ||
        draft == null ||
        command == null ||
        config == null ||
        _receipt?['outcome'] == 'SUCCEEDED' ||
        _receipt?['outcome'] == 'CANCELLED_UNWRITTEN') {
      return;
    }
    final owns = captureNativeOwnership();
    final store = ref.read(formDraftsProvider.notifier),
        ownerKey = ref.read(formDraftsProvider.notifier).ownerKey;
    final owner = ref.read(authenticatedScopeProvider);
    if (owner == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final scope = await ref
          .read(apiClientProvider)
          .captureRequestScope(
            isCurrent: () => mounted && owns() && store.ownerKey == ownerKey,
          );
      final receipt = await scope.run(
        () => ref
            .read(financeRepositoryProvider(config.type))
            .cancelBatchUnwritten(
              command,
              owner.userId,
              isCurrent: () => mounted && scope.isCurrent,
            ),
      );
      if (!mounted || !scope.isCurrent || !owns()) return;
      final checkpoint = await store.confirmFinanceBatchRecovery(
        draft.id,
        expectedRevision: draft.revision,
        receipt: receipt,
      );
      if (!mounted || !scope.isCurrent || !owns()) return;
      setState(() {
        _receipt = receipt;
        _checkpoint = checkpoint;
      });
    } catch (_) {
      if (mounted && owns()) {
        setState(() => _error = '停止结果仍待核对，请读取同一原批次回执。原请求继续保留');
      }
    } finally {
      if (mounted && owns()) setState(() => _busy = false);
    }
  }

  void _continue() {
    final draft = _checkpoint, config = _config;
    if (_busy ||
        !nativeReadCanWrite ||
        draft == null ||
        config == null ||
        !ref.read(currentPermissionsProvider).contains(config.createPerm)) {
      return;
    }
    final uri = Uri.parse(draft.route);
    widget.onFinish(
      uri
          .replace(
            queryParameters: {...uri.queryParameters, 'draftId': draft.id},
          )
          .toString(),
    );
  }

  void _openDocument(String id) {
    final config = _config;
    if (_busy ||
        !nativeReadAccessConfirmed ||
        config == null ||
        !ref.read(currentPermissionsProvider).contains(config.listPerm)) {
      return;
    }
    widget.onFinish(RoutePath.financeDocDetail(config.type.pathSegment, id));
  }

  @override
  Widget build(BuildContext context) {
    final config = _config;
    final permitted =
        nativeReadAccessConfirmed &&
        config != null &&
        ref.watch(currentPermissionsProvider).contains(config.listPerm);
    final outcome = _receipt?['outcome'];
    final result = _receipt?['result'];
    final documents =
        permitted &&
            outcome == 'SUCCEEDED' &&
            result is Map &&
            result['items'] is List
        ? result['items'] as List
        : const <Object?>[];
    final count = _command?['documents'] is List
        ? (_command!['documents'] as List).length
        : null;
    return PopScope(
      canPop: !_busy,
      child: UtenDialogFrame(
        fillHeight: true,
        maxWidth: 1000,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                UtenDialogHeader(
                  title: UtenDialogTitleWithHint(
                    title: Text(
                      config == null ? '原财务批次核对' : '${config.label} · 原批次核对',
                    ),
                    info:
                        '只核对本人原提交。不会自动创建新单或办理凭证；未写入须服务器永久停止原请求后，才可回原编辑页核对新批次。',
                  ),
                  showCloseButton: true,
                  onClose: _busy ? null : () => widget.onFinish(null),
                ),
                Expanded(
                  child: !permitted
                      ? Center(child: Text(_error ?? '正在核对读取范围'))
                      : ListView(
                          padding: const EdgeInsets.symmetric(horizontal: 24),
                          children: [
                            Text(
                              outcome == 'SUCCEEDED'
                                  ? '已确认生成 ${documents.length} 张单据'
                                  : outcome == 'CANCELLED_UNWRITTEN'
                                  ? '原批次已确认未写入'
                                  : '原提交结果待核对',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            if (count != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text('原批次明细：$count 条'),
                              ),
                            if (_error != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: Text(
                                  _error!,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.error,
                                  ),
                                ),
                              ),
                            for (final document in documents)
                              if (document is Map && document['id'] is String)
                                ListTile(
                                  title: Text(
                                    document['billNo']?.toString() ?? '原创建单据',
                                  ),
                                  trailing: UtenButton(
                                    type: UtenButtonType.secondary,
                                    onPressed: _busy
                                        ? null
                                        : () => _openDocument(
                                            document['id'] as String,
                                          ),
                                    child: const Text('查看当前单据'),
                                  ),
                                ),
                          ],
                        ),
                ),
                UtenDialogActions(
                  children: [
                    UtenButton(
                      type: UtenButtonType.secondary,
                      onPressed: _busy ? null : _load,
                      child: const Text('读取原批次回执'),
                    ),
                    if (permitted && outcome == null)
                      UtenButton(
                        type: UtenButtonType.secondary,
                        onPressed: _busy || !_mayCancel ? null : _cancel,
                        child: const Text('核实未写并保留输入'),
                      ),

                    if (permitted &&
                        _checkpoint != null &&
                        ref
                            .read(currentPermissionsProvider)
                            .contains(config.createPerm))
                      UtenButton(
                        onPressed: _busy ? null : _continue,
                        child: Text(
                          outcome == 'SUCCEEDED' ? '继续办理凭证' : '返回原输入核对新批次',
                        ),
                      ),
                  ],
                ),
              ],
            ),
            if (_busy)
              const Positioned.fill(
                child: UtenBusyOverlay(
                  title: '正在核对原批次',
                  showDoNotLeaveHint: false,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
