import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/route_names.dart';
import '../../../shared/auth/native_read_view_scope_mixin.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/drafts/form_draft.dart';
import '../../../shared/drafts/form_draft_store.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../models/production_daily_report_create_request.dart';
import '../models/daily_report_attachment_recovery.dart';
import '../repositories/production_repository.dart';

class DailyReportCreateRecoveryResult {
  const DailyReportCreateRecoveryResult(this.resolution, this.checkpoint);
  final DailyReportCreateResolution resolution;
  final FormDraft checkpoint;
}

/// View-only receipt entry, including after create/edit permissions are revoked.
/// It never creates a report, retries CREATE, or uploads a pending attachment.
class ProductionDailyReportCreateRecoveryPage extends ConsumerStatefulWidget {
  const ProductionDailyReportCreateRecoveryPage({
    super.key,
    required this.draftId,
    this.returnToEditor = false,
  });
  final String draftId;
  final bool returnToEditor;
  @override
  ConsumerState<ProductionDailyReportCreateRecoveryPage> createState() =>
      _ProductionDailyReportCreateRecoveryPageState();
}

class _ProductionDailyReportCreateRecoveryPageState
    extends ConsumerState<ProductionDailyReportCreateRecoveryPage>
    with NativeReadViewScopeMixin<ProductionDailyReportCreateRecoveryPage> {
  bool _loading = false;
  String? _error;
  FormDraft? _checkpoint;
  DailyReportCreateResolution? _resolution;
  bool _missingOriginal = false;
  String? _attachmentNotice;
  bool _attachmentDeleted = false;

  @override
  void initState() {
    super.initState();
    initializeNativeReadScope();
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void didUpdateWidget(
    covariant ProductionDailyReportCreateRecoveryPage oldWidget,
  ) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.draftId != widget.draftId) {
      _checkpoint = null;
      _resolution = null;
      _error = null;
      _attachmentNotice = null;
      _attachmentDeleted = false;
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }
  }

  @override
  void nativeReadOwnerChanged() => setState(() {
    _checkpoint = null;
    _resolution = null;
    _attachmentNotice = null;
    _attachmentDeleted = false;
    _loading = false;
    _error = '登录身份或服务器已变化，原提交信息已隐藏';
  });
  @override
  void nativeReadPermissionChanged() => setState(() => _loading = false);
  @override
  Future<void> nativeReadReload() => _load();

  Future<void> _load() async {
    final accepts = captureNativeRead(
      'create/${widget.draftId}',
      () => 'create/${widget.draftId}',
    );
    if (!accepts()) {
      return;
    }
    if (!ref
        .read(currentPermissionsProvider)
        .contains(Perm.productionDailyReportView)) {
      setState(() {
        _error = '当前无生产日报查看权限，原提交仍保留';
        _loading = false;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _resolution = null;
      _checkpoint = null;
      _attachmentNotice = null;
      _attachmentDeleted = false;
    });
    try {
      final store = ref.read(formDraftsProvider.notifier);
      await store.ready;
      if (!accepts()) {
        return;
      }
      final ownerKey = store.ownerKey;
      final draft = await store.readDailyReportCreateRecovery(widget.draftId);
      if (!accepts()) {
        return;
      }
      if (draft == null || !isDailyReportCreateRecoveryDraft(draft)) {
        throw const FormatException('原提交不存在或当前身份无权核对');
      }
      final raw = draft.data[dailyReportCreateCommandKey];
      if (raw is! Map) {
        acceptNativeRead();
        setState(() {
          _missingOriginal = true;
          _loading = false;
        });
        return;
      }
      final command = FrozenDailyReportCreate.restore(
        Map<String, dynamic>.from(raw),
      );
      final scope = ref.read(authenticatedScopeProvider);
      if (scope == null ||
          !command.belongsTo(
            server: ref.read(apiBaseUrlProvider),
            userId: scope.userId,
            actorId: scope.actorId,
          )) {
        throw const FormatException('原提交不属于当前账号、操作身份或服务器');
      }
      final result = await ref
          .read(productionDailyReportRepositoryProvider)
          .createReceipt(command);
      if (!accepts() || store.ownerKey != ownerKey) {
        return;
      }
      result.verify(command);
      FormDraft? checkpoint;
      String? attachmentNotice;
      var attachmentDeleted = false;
      if (result.committed) {
        final existing = draft.data[dailyReportCreateReceiptKey];
        final alreadyConfirmed =
            draft.data['createdReportId'] == result.reportId &&
            draft.data[dailyReportCreateStateKey] == 'CONFIRMED' &&
            existing is Map &&
            existing['status'] == 'COMMITTED' &&
            existing['fullPayloadVersion'] == 1 &&
            existing['idempotencyKey'] == command.idempotencyKey &&
            existing['fullPayloadHash'] == command.fullPayloadHash &&
            existing['requestHash'] == command.requestHash;
        checkpoint = alreadyConfirmed
            ? draft
            : await store.confirmDailyReportCreateRecovery(
                draft.id,
                expectedRevision: draft.revision,
                receipt: result.toCheckpoint(),
              );
      }
      if (checkpoint != null && checkpoint.data['attachments'] is Map) {
        try {
          final attachments = await recoverDailyReportAttachments(
            ref,
            checkpoint,
            accepts,
          );
          checkpoint = attachments.draft;
          attachmentDeleted = attachments.deleted > 0;
          attachmentNotice = attachments.unknown > 0
              ? '已核对 ${attachments.confirmed} 份原附件；${attachments.unknown} 份仍待核对，原文件保留，不会重新上传'
              : attachments.confirmed > 0
              ? '原附件上传已按唯一标识和文件指纹核对，没有重新上传'
              : null;
          if (attachmentDeleted) {
            attachmentNotice = '原附件已确认曾上传并已删除，保留历史，不会重新上传';
          }
        } catch (_) {
          attachmentNotice = '原附件尚未在当前查看范围内完整核对，原文件继续保留，不会重新上传';
        }
      }
      if (!accepts() || store.ownerKey != ownerKey) {
        return;
      }
      acceptNativeRead();
      setState(() {
        _checkpoint = checkpoint;
        _resolution = result;
        _attachmentNotice = attachmentNotice;
        _attachmentDeleted = attachmentDeleted;
        _missingOriginal = false;
        _loading = false;
      });
    } on ApiException catch (error) {
      if (accepts()) {
        setState(() {
          _loading = false;
          _error = error.message;
        });
      }
    } on FormatException catch (error) {
      if (accepts()) {
        setState(() {
          _loading = false;
          _error = error.message;
        });
      }
    } catch (_) {
      if (accepts()) {
        setState(() {
          _loading = false;
          _error = '核对或本机检查点保存尚未完成，原提交与附件继续保留，请重试';
        });
      }
    }
  }

  void _returnConfirmed() {
    final result = _resolution;
    final checkpoint = _checkpoint;
    if (!nativeReadAccessConfirmed ||
        result?.committed != true ||
        checkpoint == null ||
        !ref
            .read(currentPermissionsProvider)
            .contains(Perm.productionDailyReportView)) {
      return;
    }
    context.pop(DailyReportCreateRecoveryResult(result!, checkpoint));
  }

  Future<void> _continueAttachments() async {
    final checkpoint = _checkpoint;
    final result = _resolution;
    final permissions = ref.read(currentPermissionsProvider);
    if (!nativeReadCanWrite ||
        checkpoint == null ||
        result?.committed != true ||
        result!.deleted ||
        !permissions.contains(Perm.productionDailyReportCreate) ||
        !permissions.contains(Perm.productionDailyReportEdit) ||
        !permissions.contains(Perm.attachmentUpload)) {
      return;
    }
    final owns = captureNativeOwnership();
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fresh = await ref
          .read(productionDailyReportRepositoryProvider)
          .detail(result.reportId!);
      if (!mounted || !owns() || !nativeReadCanWrite) return;
      if (fresh.id != result.reportId ||
          fresh.status != 0 ||
          fresh.closed ||
          fresh.canceled ||
          !await loadDocumentOwnerCanWrite(
            ref,
            DocumentDataScope.productionPlan,
            fresh.makerId,
          )) {
        throw const FormatException('当前日报只可查看，未完成附件继续保留在本机');
      }
      final current = ref.read(currentPermissionsProvider);
      if (!mounted ||
          !owns() ||
          !nativeReadCanWrite ||
          !current.contains(Perm.productionDailyReportCreate) ||
          !current.contains(Perm.productionDailyReportEdit) ||
          !current.contains(Perm.attachmentUpload)) {
        return;
      }
      final original = Uri.parse(checkpoint.route);
      final query = {...original.queryParameters, 'draftId': checkpoint.id}
        ..remove('executionSegmentId')
        ..remove('executionSegmentIds');
      // This only opens the existing accepted-document attachment workflow.
      // No CREATE or attachment write occurs in this recovery page.
      context.go(original.replace(queryParameters: query).toString());
    } catch (_) {
      if (mounted && owns()) {
        setState(() {
          _error = '当前单据状态或写入范围尚未核对，未完成附件继续保留在本机';
        });
      }
    } finally {
      if (mounted && owns()) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final permissions = ref.watch(currentPermissionsProvider);
    final result = _resolution;
    return Scaffold(
      appBar: const UtenAppBar(title: '核对生产日报原提交', showBackButton: true),
      body: SafeArea(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
            ? UtenEmpty(
                message: _error!,
                isError: true,
                actionLabel: '重新核对',
                onAction: _load,
              )
            : !nativeReadAccessConfirmed
            ? nativeReadAccessNotice()
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    _missingOriginal
                        ? '原创建请求未完整保留，暂不能自动核对'
                        : result?.committed == true
                        ? '已确认原提交创建了生产日报'
                        : result?.status == 'LEGACY_UNCONFIRMED'
                        ? '旧版记录缺少完整字段证明，仍待核对'
                        : '创建结果仍未确认',
                    key: const Key('daily-create-recovery-outcome'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    result?.committed == true
                        ? '不会再次创建。未完成附件仍留在原草稿，核对不会上传文件。'
                        : '原输入和提交标识继续保留。此页只读取回执，不会重新创建，也不会用相似内容猜测已成功。',
                  ),
                  if (result?.committed == true) ...[
                    const SizedBox(height: 12),
                    Text('单据号：${result!.detail!.billNo ?? result.reportId}'),
                    if (result.deleted) const Text('已删除（原提交记录永久保留）'),
                    Text(
                      '当前业务状态：${switch (result.detail!.status) {
                        0 => '草稿',
                        1 => '已审',
                        -1 => '红冲',
                        _ => '尚未提供',
                      }}',
                    ),
                  ],
                  if (_attachmentNotice != null) ...[
                    const SizedBox(height: 12),
                    Text(_attachmentNotice!),
                  ],
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      FilledButton(
                        onPressed: _load,
                        child: const Text('再次核对原提交'),
                      ),
                      if (widget.returnToEditor &&
                          _checkpoint != null &&
                          permissions.contains(Perm.productionDailyReportView))
                        OutlinedButton(
                          onPressed: _returnConfirmed,
                          child: const Text('返回原页面，保留已确认检查点'),
                        ),
                      if (!widget.returnToEditor &&
                          _checkpoint != null &&
                          result?.deleted != true &&
                          !_attachmentDeleted &&
                          permissions.contains(
                            Perm.productionDailyReportCreate,
                          ) &&
                          permissions.contains(
                            Perm.productionDailyReportEdit,
                          ) &&
                          permissions.contains(Perm.attachmentUpload))
                        OutlinedButton(
                          onPressed: _continueAttachments,
                          child: const Text('继续处理待上传附件'),
                        ),
                      OutlinedButton(
                        onPressed: () =>
                            context.go(RouteName.productionDailyReportList),
                        child: const Text('返回日报列表'),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}
