// 生产日报详情页（全页路由 · production_daily_report:view）：主表头卡 + 只读明细子表 +
// 状态门控操作（审核/红冲/编辑/删除）。结构与生产计划单详情页同构。
//
// 状态机：草稿(0)→可编辑/删除/审核；已审(1)→仅红冲；红冲(-1)→只读。操作按 production_daily_report:edit。
// 本期空结构（0 行），UI 完整保未来启用零成本。
//
// 2026-09-11 折叠头+表内滚改版（对齐采购/货品资料页）：整页 ListView 改
// UtenCollapsingHeaderScrollView——上滑先折叠头部（提示条/表头卡/附件），
// 「明细 (N)」标题顶到页面顶部后再滚明细表内部。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/forms/maker_audit_fields.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_collapsing_header_scroll_view.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/authenticated_request_scope.dart';
import '../../../core/network/server_config.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/page_resume_provider.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/document_permission_set.dart';
import '../../../shared/auth/document_scope_capability.dart';
import '../../../shared/auth/document_scope_write_notice.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/formatters/quantity_display.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../../../shared/providers/list_refresh_provider.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../models/production_daily_report.dart';
import '../models/daily_report_approval_intent.dart';
import '../providers/production_execution_refresh.dart';
import '../repositories/production_repository.dart';
import '../repositories/daily_report_approval_intent_store.dart';
import '../widgets/production_status_badge.dart';
import '../../../shared/auth/session_snapshot_provider.dart';

class ProductionDailyReportDetailPage extends ConsumerStatefulWidget {
  const ProductionDailyReportDetailPage({
    super.key,
    required this.id,
    this.returnToWorkshopTasks = false,
  });
  static Widget route(BuildContext context, GoRouterState state) {
    final id = state.pathParameters['id']!;
    final fromWorkshop = state.uri.queryParameters['from'] == 'workshop-tasks';
    return ProductionDailyReportDetailPage(
      key: ValueKey((id, fromWorkshop)),
      id: id,
      returnToWorkshopTasks: fromWorkshop,
    );
  }

  final String id;
  final bool returnToWorkshopTasks;

  @override
  ConsumerState<ProductionDailyReportDetailPage> createState() =>
      _ProductionDailyReportDetailPageState();
}

class _ProductionDailyReportDetailPageState
    extends ConsumerState<ProductionDailyReportDetailPage> {
  ProductionDailyReportDetail? _detail;
  bool _loading = false;
  bool _busy = false;

  /// 审核/红冲/删除网络段的加载遮罩标题（null=无遮罩）。
  String? _busyTitle;
  String? _error;
  StoredDailyReportApproval? _pendingApproval;
  bool _approvalRecoveryReady = false;
  bool _approvalConfirming = false;
  bool _approvalLocallySettled = false;
  bool _busyReadOnly = false;
  String? _approvalRecoveryMessage;
  int _approvalViewGeneration = 0;

  /// 「返回即刷新」登记用的本页路径（build 首次捕获，不随后续导航现取）。
  String? _myLocation;

  AppLocalizations get _l10n => AppLocalizations.of(context);

  @override
  void initState() {
    super.initState();
    ref.listenManual(authenticatedScopeProvider, (before, after) {
      if (before != after) _invalidateApprovalView();
    });
    ref.listenManual(apiBaseUrlProvider, (before, after) {
      if (before != after) _invalidateApprovalView();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _invalidateApprovalView() {
    if (!mounted) return;
    setState(() {
      _approvalViewGeneration++;
      _detail = null;
      _pendingApproval = null;
      _approvalRecoveryReady = false;
      _approvalLocallySettled = false;
      _approvalConfirming = false;
      _busy = false;
      _loading = false;
      _error = '登录身份或服务器已变化，请重新读取这张日报。';
    });
  }

  bool Function() _approvalViewFence({
    bool requireCurrentRoute = true,
    bool requireCurrentIntent = true,
  }) {
    final scope = ref.read(authenticatedScopeProvider);
    final server = ref.read(apiBaseUrlProvider);
    final id = widget.id;
    final generation = _approvalViewGeneration;
    final route = ModalRoute.of(context);
    final session = ref.read(sessionProvider.notifier);
    final intentEpoch = session.requestIntentEpoch;
    return () =>
        mounted &&
        identical(ref.read(sessionProvider.notifier), session) &&
        (!requireCurrentIntent || session.requestIntentEpoch == intentEpoch) &&
        _approvalViewGeneration == generation &&
        widget.id == id &&
        ref.read(authenticatedScopeProvider) == scope &&
        ref.read(apiBaseUrlProvider) == server &&
        (!requireCurrentRoute || route == null || route.isCurrent);
  }

  bool _allows(DocumentPermissionAction action) => DocumentPermissionCatalog
      .productionDailyReport
      .allows(ref.read(currentPermissionsProvider), action);

  bool get _ordinaryWritable => documentOwnerCanWrite(
    ref.read(documentScopeCapabilityProvider(DocumentDataScope.productionPlan)),
    _detail?.makerId,
  );

  bool get _canEdit =>
      _pendingApproval == null &&
      _approvalRecoveryReady &&
      _ordinaryWritable &&
      _allows(DocumentPermissionAction.edit);
  bool get _canDelete =>
      _pendingApproval == null &&
      _approvalRecoveryReady &&
      _ordinaryWritable &&
      _allows(DocumentPermissionAction.delete);
  // 审核按钮只看服务端下发的 allowedActions(含车间直送审核权与对象范围，permissions-15)，
  // 避免没有直送审核权的人点了才被拒。
  bool get _canApprove =>
      _approvalRecoveryReady &&
      !_approvalConfirming &&
      _pendingApproval == null &&
      (_detail?.canApprove ?? false) &&
      ((_detail?.supportsLegacyApproval ?? false) ||
          (_detail?.canFreezeReviewedApproval ?? false));
  bool get _canReverse =>
      _pendingApproval == null &&
      _approvalRecoveryReady &&
      _allows(DocumentPermissionAction.reverse);

  Future<void> _load() async {
    if (!mounted || _loading || _busy) return;
    final isCurrent = _approvalViewFence(requireCurrentRoute: false);
    setState(() {
      _loading = true;
      _error = null;
      _approvalRecoveryReady = false;
    });
    try {
      final d = await ref
          .read(productionDailyReportRepositoryProvider)
          .detail(widget.id);
      if (!mounted || !isCurrent()) return;
      if (d.id != widget.id) throw StateError('日报响应身份不一致');
      _applyDetail(d);
      try {
        final saved = await ref
            .read(dailyReportApprovalIntentStoreProvider)
            .read(widget.id);
        if (!mounted || !isCurrent()) return;
        setState(() {
          _approvalLocallySettled =
              _approvalLocallySettled && saved?.raw == _pendingApproval?.raw;
          _pendingApproval = saved;
          _approvalRecoveryReady = true;
          _approvalRecoveryMessage = null;
        });
      } catch (_) {
        if (!mounted || !isCurrent()) return;
        setState(
          () => _approvalRecoveryMessage = '本机原审核记录尚未读取，暂不能提交新审核。请保留本机记录并重试。',
        );
      }
    } on ApiException catch (e) {
      if (!mounted || !isCurrent()) return;
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || !isCurrent()) return;
      setState(() {
        _error = _l10n.productionDailyReportLoadFailed;
        _loading = false;
      });
    }
  }

  /// 落一份详情到页面。
  ///
  /// 本页显示的每个名字都由服务端随单解析下发(货品名称/编号/颜色/单位/车间/参与人员),
  /// 所以这里没有任何名称预热，状态翻转不再被字典往返挡住——审核/红冲接口本身就返回
  /// 最新详情，走这里直接用，也不再多发一次详情请求(2026-09-20 用户反馈审核后等太久)。
  void _applyDetail(ProductionDailyReportDetail d) {
    setState(() {
      _detail = d;
      _loading = false;
      _error = null;
    });
  }

  /// 审核/红冲/删除改变了车间任务的已报数量与分类归属(2026-09-24 用户口径「报工成功
  /// 回到生产中，分类或整个页面应该刷新」)：发生产执行刷新信号——徽章汇总立刻重拉，
  /// 车间任务页与调度台返回时整页重拉。
  void _signalExecutionChanged() =>
      bumpListRefresh(ref, productionExecutionRefreshKey);

  Future<void> _approve({AuthenticatedRequestScope? retainedScope}) async {
    if (_busy || _approvalConfirming || !_canApprove) return;
    final reviewed = _detail;
    if (reviewed == null || reviewed.id != widget.id) return;
    final isCurrent = _approvalViewFence();
    final sameOwner = _approvalViewFence(
      requireCurrentRoute: false,
      requireCurrentIntent: false,
    );
    late final DailyReportApprovalIntent intent;
    try {
      // All confirmation semantics come from this one detail, before opening the dialog.
      intent = DailyReportApprovalIntent.review(
        reviewed,
        '请核对本次实际产量与产出去向：\n${_routeLines(reviewed)}'
        '转给上层工单的部分交下工序；送入仓库的部分生成仓库到货登记任务，'
        '仓库登记成品仓与库位并送品质部检查。'
        '只有品质合格且仓库实际接收的数量才增加可用库存。确认审核？'
        '${reviewed.supportsLegacyApproval ? '\n此服务器使用旧版审核，暂不核对所见版本。' : ''}',
      );
    } catch (_) {
      context.appError('当前审核资料不完整，请刷新后重新核对，暂不能提交审核。');
      return;
    }
    setState(() => _approvalConfirming = true);
    bool confirmed;
    late final AuthenticatedRequestScope requestScope;
    try {
      requestScope =
          retainedScope ??
          await ref
              .read(apiClientProvider)
              .captureRequestScope(isCurrent: isCurrent);
      await requestScope.verify();
      if (!mounted || !isCurrent()) return;
      confirmed = await showUtenReviewerConfirmDialog(
        context,
        message: intent.confirmation,
      );
      if (confirmed) await requestScope.verify();
    } on ApiException catch (error) {
      if (mounted) context.appWarning(error.message);
      return;
    } finally {
      if (sameOwner()) setState(() => _approvalConfirming = false);
    }
    if (!mounted || !isCurrent()) return;
    if (confirmed != true) return;
    try {
      await requestScope.run(
        () => _sendApproval(intent, requestScope: requestScope),
      );
    } on ApiException catch (error) {
      if (mounted) context.appWarning(error.message);
    }
  }

  Future<bool> _clearApprovalRecord(StoredDailyReportApproval record) async {
    final sameOwner = _approvalViewFence(requireCurrentRoute: false);
    try {
      await ref.read(dailyReportApprovalIntentStoreProvider).complete(record);
      if (sameOwner()) {
        setState(() {
          _pendingApproval = null;
          _approvalLocallySettled = false;
          _approvalRecoveryMessage = null;
        });
      }
      return true;
    } catch (_) {
      if (sameOwner()) {
        setState(() {
          _approvalLocallySettled = true;
          _approvalRecoveryMessage = '原审核结果已核对，本机记录尚未清理；请保留页面后重试清理，不会重发审核。';
        });
      }
      return false;
    }
  }

  Future<void> _publishApproval(
    StoredDailyReportApproval record,
    ProductionDailyReportDetail updated, {
    bool replay = false,
    bool legacyMismatch = false,
  }) async {
    final isCurrent = _approvalViewFence();
    if (updated.id != record.intent.reportId || !isCurrent()) return;
    // The response is confirmed before any local cleanup or navigation.
    _approvalLocallySettled = true;
    _applyDetail(updated);
    _signalExecutionChanged();
    await _clearApprovalRecord(record);
    if (!mounted || !isCurrent()) return;
    if (legacyMismatch) {
      setState(() => _approvalRecoveryMessage = '原审核记录已找到，但所见版本未被验证，请核对当前日报。');
      context.appWarning('原审核按旧版规则登记，未验证所见版本；请以当前记录为准。');
      return;
    } else if (updated.status != kProductionStatusApproved) {
      context.appWarning(_l10n.productionDailyReportStateChangedReview);
    } else {
      context.appSuccess(replay ? '原审核已登记' : '已审核');
    }
    await _returnAfterApproval(updated, responseIsCurrent: isCurrent);
  }

  Future<void> _sendApproval(
    DailyReportApprovalIntent intent, {
    required AuthenticatedRequestScope requestScope,
    StoredDailyReportApproval? original,
  }) async {
    if (_busy) return;
    final isCurrent = _approvalViewFence();
    final sameOwner = _approvalViewFence(
      requireCurrentRoute: false,
      requireCurrentIntent: false,
    );
    final repository = ref.read(productionDailyReportRepositoryProvider);
    final store = ref.read(dailyReportApprovalIntentStoreProvider);
    StoredDailyReportApproval? record = original;
    StoredDailyReportApproval? beforeClaim;
    var sent = false;
    var acknowledged = false;
    setState(() {
      _busy = true;
      _busyReadOnly = false;
      _busyTitle = '正在审核生产日报';
    });
    try {
      record ??= await store.begin(intent);
      if (!mounted || !isCurrent()) return;
      final prepared = record;
      final claimed = await store.claim(prepared);
      beforeClaim = prepared;
      record = claimed;
      await requestScope.verify();
      if (!mounted || !isCurrent()) return;
      setState(() {
        _pendingApproval = record;
        _approvalLocallySettled = false;
        _approvalRecoveryMessage = null;
      });
      // The complete original command is durable before the repository sends bytes.
      sent = true;
      final updated = await repository.approve(
        intent.reportId,
        idempotencyKey: intent.idempotencyKey,
        commandVersion: intent.legacy ? null : 2,
        expectedVersion: intent.expectedVersion,
      );
      await requestScope.verify();
      if (!mounted || !isCurrent()) return;
      final receipt = updated.approvalReceipt;
      final verified = receipt != null && intent.verifiedReceipt(receipt);
      final legacyAcceptedWithoutReceipt =
          intent.legacy &&
          receipt == null &&
          updated.status != null &&
          updated.status != kProductionStatusDraft;
      if (updated.id != intent.reportId ||
          (!verified && !legacyAcceptedWithoutReceipt)) {
        await _settleApprovalUnknown('收到的审核回执不完整，原提交已保留，请核对原审核记录。', record);
        return;
      }
      acknowledged = true;
      await _publishApproval(record, updated, replay: receipt?.replay ?? false);
    } catch (error) {
      if (!mounted || !isCurrent()) return;
      if (acknowledged) {
        setState(() {
          _approvalLocallySettled = true;
          _approvalRecoveryMessage = '审核已确认，页面或本机收尾未完成，请以当前记录为准。';
        });
        context.appWarning(_approvalRecoveryMessage!);
        return;
      }
      if (!sent) {
        try {
          final saved = await store.read(intent.reportId);
          if (isCurrent()) {
            _pendingApproval = saved;
            _approvalLocallySettled = false;
          }
        } catch (_) {}
        if (!mounted || !isCurrent()) return;
        setState(
          () => _approvalRecoveryMessage = '本机审核保护尚未保存，本次未发送审核。请保留页面并重新读取本机记录。',
        );
        context.appError(_approvalRecoveryMessage!);
        return;
      }
      if (isSessionBoundaryError(error)) {
        setState(
          () => _approvalRecoveryMessage = '登录状态已变化，原审核标识与待核对记录继续保留，请重新进入后核对。',
        );
        context.appWarning(_approvalRecoveryMessage!);
        return;
      }
      final staleV2 =
          !intent.legacy &&
          error is ApiException &&
          error.code == 'DAILY_REPORT_REVIEW_VERSION_CONFLICT';
      final rejectedFirstAttempt =
          original == null &&
          error is ApiException &&
          const {
            'BUSINESS',
            'VALIDATION_FAILED',
            'MALFORMED_REQUEST',
            'CONFLICT',
          }.contains(error.code);
      if (staleV2 || rejectedFirstAttempt) {
        await _clearApprovalRecord(record!);
        if (!mounted || !isCurrent()) return;
        await _settleFailedAction(
          error.message,
          targetStatus: kProductionStatusApproved,
          returnAfterApproval: true,
          responseIsCurrent: isCurrent,
        );
      } else {
        await _settleApprovalUnknown(
          error is ApiException ? error.message : '未收到审核结果，原提交已保留。',
          record!,
        );
      }
    } finally {
      if (!sent &&
          record != null &&
          sameOwner() &&
          !(beforeClaim?.hasBeenDispatched ?? record.hasBeenDispatched)) {
        try {
          if (beforeClaim == null) {
            await store.cancelPrepared(record);
          } else {
            await store.cancelUnsentClaim(record, beforeClaim);
          }
          final current = await store.read(intent.reportId);
          if (sameOwner()) {
            setState(() {
              _pendingApproval = current;
              _approvalLocallySettled = false;
              _approvalRecoveryMessage = current == null
                  ? '本次审核尚未发送，可以重新核对后继续。'
                  : '原记录已由另一页面领取，请先核对原审核。';
            });
          }
        } catch (_) {
          // Failure to release never erases evidence or authorizes a new write.
        }
      }
      if (sameOwner()) {
        setState(() {
          _busy = false;
          _busyTitle = null;
          _busyReadOnly = false;
        });
      }
    }
  }

  Future<bool> _tryResolveApproval(StoredDailyReportApproval record) async {
    final isCurrent = _approvalViewFence();
    final repository = ref.read(productionDailyReportRepositoryProvider);
    var confirmed = false;
    try {
      if (!(_detail?.supportsReviewedApproval ?? false)) return false;
      final observed = await repository.approvalReceipt(
        record.intent.reportId,
        idempotencyKey: record.intent.idempotencyKey,
      );
      if (!mounted || !isCurrent()) return true;
      final detail = observed.detail;
      if (detail != null && detail.id == widget.id) _applyDetail(detail);
      final receipt = observed.receipt;
      if (observed.status == 'CONFIRMED' &&
          receipt != null &&
          record.intent.ownsReceipt(receipt) &&
          detail?.id == widget.id) {
        if (record.intent.verifiedReceipt(receipt) || receipt.legacy) {
          confirmed = true;
          await _publishApproval(
            record,
            detail!,
            replay: true,
            legacyMismatch: !record.intent.legacy && receipt.legacy,
          );
        } else {
          setState(
            () => _approvalRecoveryMessage = '原记录与本机保存的审核版本不一致，内容已保留，请联系管理员核对。',
          );
          context.appError(_approvalRecoveryMessage!);
        }
        return true;
      }
      setState(
        () => _approvalRecoveryMessage = observed.status == 'PENDING'
            ? '原审核仍在处理中，请稍后核对。原内容已保留。'
            : '暂未找到可确认的原审核记录；原请求仍可能完成，原内容已保留。',
      );
    } catch (_) {
      if (mounted && isCurrent()) {
        setState(() {
          if (confirmed) _approvalLocallySettled = true;
          _approvalRecoveryMessage = confirmed
              ? '原审核已确认，页面或本机收尾未完成，请以当前记录为准。'
              : '原审核记录暂时无法读取，原内容已保留，请稍后核对。';
        });
      }
      if (confirmed) return true;
    }
    return false;
  }

  Future<void> _settleApprovalUnknown(
    String message,
    StoredDailyReportApproval record,
  ) async {
    final isCurrent = _approvalViewFence();
    if (isCurrent()) {
      setState(() {
        _busyReadOnly = true;
        _busyTitle = '正在核对原审核';
      });
    }
    if (await _tryResolveApproval(record) || !mounted || !isCurrent()) return;
    try {
      final current = await ref
          .read(productionDailyReportRepositoryProvider)
          .detail(record.intent.reportId);
      if (!mounted || !isCurrent()) return;
      if (current.id == record.intent.reportId) {
        final changed = _detail?.status != current.status;
        _applyDetail(current);
        if (changed) _signalExecutionChanged();
      }
    } catch (_) {
      /* Keep the original command when even the state read fails. */
    }
    if (!mounted || !isCurrent()) return;
    setState(
      () => _approvalRecoveryMessage =
          _detail?.status == kProductionStatusApproved
          ? '当前显示已审核，但原提交尚未获得可核对回执。请保留原内容，继续核对原审核。'
          : _detail?.status == kProductionStatusReversed
          ? '当前显示已红冲，但原提交结果仍待核对。原内容已保留。'
          : '$message 原提交结果仍待核对，原内容已保留。',
    );
    context.appWarning(_approvalRecoveryMessage!);
  }

  Future<void> _resumePreparedApproval() async {
    final record = _pendingApproval;
    if (_busy || record == null || record.hasBeenDispatched) return;
    final isCurrent = _approvalViewFence();
    final store = ref.read(dailyReportApprovalIntentStoreProvider);
    try {
      final requestScope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: isCurrent);
      await requestScope.run(() async {
        if (!await store.cancelPrepared(record)) {
          final latest = await store.read(record.intent.reportId);
          if (isCurrent()) {
            setState(() {
              _pendingApproval = latest;
              _approvalLocallySettled = false;
              _approvalRecoveryMessage = '原记录已由另一页面领取，请先核对原审核。';
            });
          }
          return;
        }
        if (!isCurrent()) return;
        setState(() {
          _pendingApproval = null;
          _approvalRecoveryMessage = null;
        });
        await _load();
        await requestScope.verify();
        if (isCurrent() && _canApprove) {
          await _approve(retainedScope: requestScope);
        }
      });
    } catch (_) {
      if (mounted && isCurrent()) context.appWarning('本机待审核记录暂未完成核对，本次未发送审核。');
    }
  }

  Future<void> _resolveApproval() async {
    final record = _pendingApproval;
    if (_busy || record == null) return;
    final isCurrent = _approvalViewFence();
    final sameOwner = _approvalViewFence(
      requireCurrentRoute: false,
      requireCurrentIntent: false,
    );
    setState(() {
      _busy = true;
      _busyReadOnly = true;
      _busyTitle = '正在核对原审核';
    });
    try {
      if (_approvalLocallySettled) {
        await _clearApprovalRecord(record);
        return;
      }
      if (!(_detail?.supportsReviewedApproval ?? false)) {
        final current = await ref
            .read(productionDailyReportRepositoryProvider)
            .detail(widget.id);
        if (!mounted || !isCurrent()) return;
        _applyDetail(current);
      }
      if (await _tryResolveApproval(record) || !mounted || !isCurrent()) return;
      context.appWarning(
        _approvalRecoveryMessage ?? '当前服务器暂不能提供原审核回执；原记录已保留，不会重复发送旧版审核。',
      );
    } catch (_) {
      if (mounted && isCurrent()) context.appWarning('原审核暂未核对，原记录已保留。');
    } finally {
      if (sameOwner()) {
        setState(() {
          _busy = false;
          _busyTitle = null;
          _busyReadOnly = false;
        });
      }
    }
  }

  Future<void> _retryOriginalApproval() async {
    final record = _pendingApproval;
    if (_busy ||
        record == null ||
        record.intent.legacy ||
        _approvalLocallySettled ||
        !(_detail?.canFreezeReviewedApproval ?? false)) {
      return;
    }
    final isCurrent = _approvalViewFence();
    late final AuthenticatedRequestScope requestScope;
    try {
      requestScope = await ref
          .read(apiClientProvider)
          .captureRequestScope(isCurrent: isCurrent);
    } on ApiException catch (error) {
      if (mounted) context.appWarning(error.message);
      return;
    }
    if (!mounted || !isCurrent()) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('按原内容重试审核'),
        content: Text(
          '${record.intent.confirmation}\n\n将重试保存的原审核；日报已经变化时会拒绝，请重新核对。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('重试原审核'),
          ),
        ],
      ),
    );
    if (confirmed == true && isCurrent()) {
      try {
        await requestScope.run(
          () => _sendApproval(
            record.intent,
            original: record,
            requestScope: requestScope,
          ),
        );
      } on ApiException catch (error) {
        if (mounted) context.appWarning(error.message);
      }
    }
  }

  /// 审核确认里逐批列出去向(直送给哪个工单多少；送入仓库多少及其中实际超产)，最多列 6 批。
  /// 摘要由服务端按实物交接批拼好(ADR-148)，页面直接显示。
  String _routeLines(ProductionDailyReportDetail reviewed) {
    final batches = reviewed.outputBatches;
    const limit = 6;
    final lines = [
      for (final batch in batches.take(limit)) '· ${batch.summary}',
      if (batches.length > limit) '· 等共 ${batches.length} 批，详见明细表',
    ];
    return lines.isEmpty ? '' : '${lines.join('\n')}\n';
  }

  Future<void> _reverse() => _doAction(
    _l10n.productionDailyReportReverseConfirmation,
    (repo) => repo.reverse(widget.id),
    '已红冲',
    targetStatus: kProductionStatusReversed,
  );

  Future<void> _doAction(
    String confirm,
    Future<ProductionDailyReportDetail> Function(
      ProductionDailyReportRepository,
    )
    fn,
    String ok, {
    required int targetStatus,
    bool reviewerResponsibility = false,
  }) async {
    if (_busy) return;
    final c = reviewerResponsibility
        ? await showUtenReviewerConfirmDialog(context, message: confirm)
        : await UtenDialog.show(
            context,
            title: _l10n.commonConfirm,
            content: Text(confirm),
            confirmLabel: _l10n.commonConfirm,
            cancelLabel: _l10n.commonCancel,
            danger: true,
          );
    if (c != true || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _busyTitle = '正在${reviewerResponsibility ? '审核' : '红冲'}生产日报';
    });
    try {
      final updated = await fn(
        ref.read(productionDailyReportRepositoryProvider),
      );
      if (!mounted) return;
      // 服务端已返回审核/红冲后的完整详情：直接落页面，省掉一次详情往返。
      _applyDetail(updated);
      _signalExecutionChanged();
      if (updated.status != targetStatus) {
        context.appWarning(_l10n.productionDailyReportStateChangedReview);
        return;
      }
      context.appSuccess(ok);
      if (reviewerResponsibility) await _returnAfterApproval(updated);
    } on ApiException catch (e) {
      await _settleFailedAction(
        e.message,
        targetStatus: targetStatus,
        returnAfterApproval: reviewerResponsibility,
      );
    } catch (_) {
      await _settleFailedAction(
        '操作失败，请稍后重试',
        targetStatus: targetStatus,
        returnAfterApproval: reviewerResponsibility,
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyTitle = null;
        });
      }
    }
  }

  /// 写请求没拿到结果时的收尾：先按服务端权威状态刷新本页，再决定说什么。
  ///
  /// 超时或断连不代表服务端没做——审核事务可能已经提交(2026-09-21 实测：服务端 15.094 秒
  /// 返回 200，浏览器 15 秒就掐了连接)。这时继续拿旧详情画「审核」按钮，用户必然再点一次，
  /// 第二次必然撞上「仅草稿单据可审核」。服务端明确拒绝时同理：本地状态多半已经陈旧。
  /// 核对只证明当前状态：达到本次目标才提示当前已审核/红冲，不能把其它人的状态变化归因于本次命令。
  Future<void> _settleFailedAction(
    String failureMessage, {
    required int targetStatus,
    bool returnAfterApproval = false,
    bool Function()? responseIsCurrent,
  }) async {
    final before = _detail?.status;
    ProductionDailyReportDetail? fresh;
    try {
      fresh = await ref
          .read(productionDailyReportRepositoryProvider)
          .detail(widget.id);
    } catch (_) {
      fresh = null; // 连重读都失败：只能报原始错误，页面保持原样。
    }
    if (!mounted || !(responseIsCurrent?.call() ?? true)) return;
    if (fresh != null) {
      _applyDetail(fresh);
      if (fresh.status != before) {
        _signalExecutionChanged();
      }
      if (fresh.status == targetStatus) {
        context.appSuccess(
          targetStatus == kProductionStatusApproved
              ? _l10n.productionDailyReportApprovedStateVerified
              : _l10n.productionDailyReportReversedStateVerified,
        );
        if (returnAfterApproval) {
          await _returnAfterApproval(
            fresh,
            responseIsCurrent: responseIsCurrent,
          );
        }
        return;
      }
      if (fresh.status != before) {
        context.appWarning(_l10n.productionDailyReportStateChangedReview);
        return;
      }
    }
    context.appError(failureMessage);
  }

  Future<void> _returnAfterApproval(
    ProductionDailyReportDetail detail, {
    bool Function()? responseIsCurrent,
  }) async {
    if (!widget.returnToWorkshopTasks ||
        detail.status != kProductionStatusApproved) {
      return;
    }
    await _leaveAfterCompletedAction(() {
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(RouteName.productionWorkshopTasks);
      }
    }, responseIsCurrent: responseIsCurrent);
  }

  /// A confirmed result releases the busy route guard before its own navigation.
  Future<void> _leaveAfterCompletedAction(
    VoidCallback navigate, {
    bool Function()? responseIsCurrent,
  }) async {
    final route = ModalRoute.of(context);
    setState(() {
      _busy = false;
      _busyTitle = null;
    });
    await WidgetsBinding.instance.endOfFrame;
    if (mounted &&
        (responseIsCurrent?.call() ?? true) &&
        route?.isCurrent == true &&
        identical(ModalRoute.of(context), route)) {
      navigate();
    }
  }

  /// 车间链路的编辑往返中。不进 [_busy]：忙碌遮罩只盖纯网络段（UtenBusyOverlay
  /// 契约，挂着跳页会把目标页盖住、widget 测试也 settle 不了），跳页期间不需要
  /// 任何遮罩。本标记只挡编辑重入，并让「返回即刷新」让位——回来后由 [_edit]
  /// 自己按保存结果重拉一次，避免一次返回拉两遍详情。
  bool _editing = false;

  /// 审核链路（returnToWorkshopTasks）的编辑入口：带上 from=workshop-tasks，
  /// 编辑页保存后 pop 回日报 ID，这里重拉详情保住「审核后回车间任务」的落点；
  /// 普通入口照旧 push，返回刷新交给「返回即刷新」。
  Future<void> _edit() async {
    if (_busy || _editing) return;
    final path = '/production/daily-reports/${widget.id}/edit';
    if (!widget.returnToWorkshopTasks) {
      await context.push(path);
      return;
    }
    _editing = true;
    try {
      final savedId = await context.push<String>('$path?from=workshop-tasks');
      if (!mounted || savedId == null || savedId.isEmpty) return;
      await _load();
      if (mounted) _signalExecutionChanged();
    } finally {
      _editing = false;
    }
  }

  Future<void> _delete() async {
    if (_busy) return;
    final c = await UtenDialog.show(
      context,
      title: _l10n.productionDailyReportDeleteTitle,
      content: Text(_l10n.productionDailyReportDeleteConfirmation),
      confirmLabel: _l10n.productionDailyReportDeleteAction,
      cancelLabel: _l10n.commonCancel,
      danger: true,
    );
    if (c != true || !mounted || _busy) return;
    setState(() {
      _busy = true;
      _busyTitle = '正在删除日报';
    });
    try {
      await ref.read(productionDailyReportRepositoryProvider).delete(widget.id);
      if (!mounted) return;
      _signalExecutionChanged();
      context.appSuccess('已删除');
      // 返回键契约（路由设计 §十一）：pop 回来源（列表/车间任务），栈空回 hub。
      await _leaveAfterCompletedAction(
        () => popOrBackTo(context, defaultPath: RouteName.production),
      );
    } on ApiException catch (e) {
      if (mounted) context.appError(e.message);
    } catch (_) {
      if (mounted) context.appError('删除失败，请稍后重试');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyTitle = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 返回即刷新（对齐计划详情页同款修复）：本页 push 编辑页，编辑保存后
    // context.replace 成「新详情页」——旧的本页实例被压在栈下，replace 丢掉了
    // push 的 Future，返回到它时停在保存前的旧状态。注册后：期间写过数据
    // （保存/审核都在子页办完）就重拉本页详情。
    _myLocation ??= currentLocationOr(context, RouteName.production);
    ref.onPageResume(_myLocation!, () {
      if (!_busy && !_editing) _load();
    });
    final scopeCapability = ref.watch(
      documentScopeCapabilityProvider(DocumentDataScope.productionPlan),
    );
    final theme = Theme.of(context);
    final page = Scaffold(
      appBar: const UtenAppBar(title: '生产日报详情', showBackButton: true),
      body: Stack(
        children: [
          SafeArea(
            child: UtenContentContainer(
              child: _loading
                  ? Semantics(
                      label: _l10n.commonLoading,
                      liveRegion: true,
                      child: const UtenSkeletonList(),
                    )
                  : _error != null
                  ? UtenEmpty.error(
                      message: _error,
                      actionLabel: _l10n.commonRetry,
                      onAction: _load,
                    )
                  : _detail == null
                  ? const SizedBox.shrink()
                  // 2026-09-11 折叠头+表内滚：头部（提示条/表头卡/附件）随上滚收起，
                  // 明细标题吸顶后表格内部继续滚。
                  : UtenCollapsingHeaderScrollView(
                      collapsingHeader: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          0,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            DocumentScopeWriteNotice(
                              capability: scopeCapability,
                              ownerEmployeeId: _detail!.makerId,
                              onRetry: () => ref
                                  .read(sessionSnapshotProvider.notifier)
                                  .refresh(),
                            ),
                            if (_approvalNotice() case final notice?) ...[
                              notice,
                              const SizedBox(height: UtenSpacing.s12),
                            ],
                            _headerCard(theme),
                            // 日报附件（报工照片/检验记录）：草稿可管理，审核后只读。
                            // 属「备注类小卡」，并入折叠头尾部随头部一起收起。
                            const SizedBox(height: UtenSpacing.s12),
                            BusinessAttachmentSection(
                              ownerType: 'PRODUCTION_DAILY_REPORT',
                              ownerId: _detail!.id,
                              canView: ref
                                  .watch(currentPermissionsProvider)
                                  .contains(Perm.productionDailyReportView),
                              // 详情=审核页：文件只读（增删回编辑页）。
                              canManage: false,
                              readOnlyNote: BusinessAttachmentSection
                                  .kReviewReadOnlyAttachmentNote,
                              title: '附件（报工照片/检验记录）',
                              categories: const ['报工照片', '检验记录', '签认单', '其他'],
                            ),
                          ],
                        ),
                      ),
                      // body：明细标题（钉住）+ 表格占满内滚（primary 拾取联动控制器）。
                      body: Padding(
                        // 底部让位右下悬浮操作组：末行可滚出按钮区。
                        padding: const EdgeInsets.fromLTRB(
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenSpacing.s12,
                          UtenFloatingActionGroup.controlHeight +
                              UtenSpacing.s32,
                        ),
                        child: _itemsCard(theme),
                      ),
                    ),
            ),
          ),
          // 审核/红冲/删除网络段的全屏加载遮罩；确认弹窗期间不挂（_busy 在弹窗后才置位）。
          if (_busy)
            UtenBusyOverlay(
              title: _busyTitle ?? '正在处理',
              description: _busyReadOnly
                  ? '正在读取原审核记录，不会再次提交审核。'
                  : '正在保存日报并生成后续任务，请勿重复提交或离开本页。',
            ),
        ],
      ),
      // 2026-09-14 UI 统一口径：吸底操作条改右下悬浮组，大小/高度/禁用态全站统一。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton:
          _detail == null || _busy || _loading || _error != null
          ? null
          : _actions(theme),
    );
    return PopScope<Object?>(canPop: !_busy, child: page);
  }

  Widget _headerCard(ThemeData theme) {
    final d = _detail!;
    final rows = <_KV>[
      _KV('单据号', d.billNo),
      _KV('日期', d.billDate),
      _KV('制单员', d.makerName),
      _KV('制单时间', utenFmtIsoTime(d.createdAt)),
      // 车间与参与人员都用服务端随单解析的名字：客户端字典缓存会随连接恢复或权限快照
      // 变化整体清空，那时这两行会变「—」且不自愈; 员工档案接口还要 employee:view。
      if ((d.departmentName ?? d.workshopName ?? '').isNotEmpty)
        _KV('车间', d.departmentName ?? d.workshopName),
      if (d.workerNames.isNotEmpty)
        _KV('生产参与人员', d.workerNames.where((n) => n.isNotEmpty).join('、')),
      if ((d.sourceDocNo ?? '').isNotEmpty) _KV('来源单号', d.sourceDocNo),
      if ((d.remark ?? '').isNotEmpty) _KV('备注', d.remark),
      _KV(
        '状态',
        null,
        badge: ProductionStatusBadge(status: d.status, closed: d.closed),
      ),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final r in rows) _kvRow(theme, r)],
        ),
      ),
    );
  }

  Widget _kvRow(ThemeData theme, _KV r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              r.label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: r.badge ?? Text(r.value ?? '—')),
        ],
      ),
    );
  }

  /// 明细区：统一表格样式（MasterDataTableView，与全站报表/主档同款），
  /// 不再是卡片式拼凑行；单位内联在数量后（2026-10-10 数量内联口径）。
  /// 2026-09-11 起是折叠容器的 body：表格 primary:true 参与联动内滚；
  /// 2026-09-25 纯计数标题「明细 (N)」随全站退役。
  Widget _itemsCard(ThemeData theme) {
    final items = _detail!.items;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: MasterDataTableView<ProductionDailyReportItem>(
            tableKey: 'production.daily.items',
            primary: true,
            columns: [
              // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。
              // 同名不同编号的货品（自制/委外两条同名成品）在日报里必须分得开，
              // 否则审核时会认错货。2026-10-10 数量内联口径：独立「单位」列撤销，
              // 单位跟在完工申报量/不良数的数字后。
              MasterColumnDef(
                key: 'goods',
                label: '货品名称',
                width: 200,
                value: (it) => _dictText(it.goodsName) ?? '—',
                cellBuilderHandlesSemantics: true,
                cellBuilder: (_, it) =>
                    UtenGoodsIdentityCell(name: _dictText(it.goodsName)),
              ),
              MasterColumnDef(
                key: 'goodsCode',
                label: '编号',
                width: 130,
                value: (it) => UtenGoodsAttributeCell.text(it.goodsCode),
                cellBuilder: (_, it) => UtenGoodsAttributeCell(it.goodsCode),
              ),
              MasterColumnDef(
                key: 'colorName',
                label: '颜色',
                width: 96,
                value: (it) =>
                    UtenGoodsAttributeCell.text(_dictText(it.colorName)),
                cellBuilder: (_, it) =>
                    UtenGoodsAttributeCell(_dictText(it.colorName)),
              ),
              MasterColumnDef(
                key: 'qty',
                label: '完工申报量',
                width: 146,
                type: 'number',
                value: (it) => it.qty == null
                    ? null
                    : formatQtyWithUnit(it.qty!, _dictText(it.unitName)),
              ),
              // ADR-129：一次报工拆成多条明细时不良数只记在第一条，其余留空。
              MasterColumnDef(
                key: 'defectQty',
                label: '不良数',
                width: 130,
                type: 'number',
                info: productionDailyReportDefectInfo,
                value: (it) => it.defectQty > 0
                    ? formatQtyWithUnit(it.defectQty, _dictText(it.unitName))
                    : null,
              ),
              MasterColumnDef(
                key: 'outputKind',
                label: '产出归属',
                width: 180,
                value: (it) => it.outputKindLabel,
                cellBuilder: (context, it) => it.dispositionId == null
                    ? Text(it.outputKindLabel)
                    : TextButton(
                        onPressed: () => context.push(
                          RoutePath.productionOverLimitDisposition(
                            it.dispositionId!,
                          ),
                        ),
                        child: Text('${it.outputKindLabel} · 查看处置'),
                      ),
              ),
              MasterColumnDef(
                key: 'overLimitReason',
                label: '超限原因',
                width: 220,
                value: (it) => it.overLimitReason,
              ),
              MasterColumnDef(
                key: 'weight',
                label: '实际重量',
                width: 100,
                type: 'number',
                value: (it) => it.weight?.toStringAsFixed(4),
              ),
              MasterColumnDef(
                // 2026-09-25 单号列统一：明细全量加载，就地排序+按值筛选。
                key: 'planNo',
                sortable: true,
                filterFromRows: true,
                label: '计划号',
                width: 140,
                value: (it) => it.planNo,
              ),
              // V584/V595/V736：产出去向与说明——一行报工分给几个上层工单就有几条转送明细，
              // 送入仓库的明细写明为什么没转(服务端给的原因)。
              MasterColumnDef(
                key: 'destination',
                label: '产出去向',
                width: 120,
                value: (it) => it.isDirectTransfer ? '转下一道工序' : '送入仓库',
              ),
              MasterColumnDef(
                key: 'routeNote',
                label: '去向说明',
                width: 300,
                value: (it) => it.isDirectTransfer
                    ? '转给 ${it.directTransferTargetLabel ?? '上层工单'}'
                    : (it.outputRouteReasonText ?? '—'),
              ),
            ],
            items: items,
            facets: const {},
            nullCounts: const {},
            filters: const {},
            onFilterChanged: (_, _) {},
            // 右下悬浮操作组让位：末行可滚出按钮区。
            bottomContentPadding: UtenFloatingActionGroup.scrollClearance,
            emptyMessage: '暂无明细',
          ),
        ),
      ],
    );
  }

  Widget _actions(ThemeData theme) {
    final detail = _detail!;
    final children = <Widget>[];
    // 「返回列表」只对能进 /production/daily-reports 的人渲染（车间任务等入口
    // push 进来的人可能只有报工权限；2026-09-10 审计）；走返回键契约 pop 回来源。
    final canOpenList = locationAllowedFor(
      ref.watch(currentPermissionsProvider),
      ref.watch(isSuperAdminProvider),
      RouteName.productionDailyReportList,
    );

    void addAction(Widget action) {
      if (children.isNotEmpty) {
        children.add(const SizedBox(width: UtenSpacing.s8));
      }
      children.add(action);
    }

    void addBack() {
      if (!canOpenList) return;
      addAction(
        UtenButton(
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: () => popOrBackTo(
            context,
            defaultPath: RouteName.productionDailyReportList,
          ),
          child: const Text('返回列表'),
        ),
      );
    }

    if (_pendingApproval != null) {
      addAction(
        UtenButton(
          key: const Key('daily-report-resolve-approval'),
          size: UtenButtonSize.large,
          onPressed: !_pendingApproval!.hasBeenDispatched
              ? _resumePreparedApproval
              : _resolveApproval,
          child: Text(
            !_pendingApproval!.hasBeenDispatched
                ? '重新核对审核'
                : _approvalLocallySettled
                ? '清理已核对记录'
                : '核对原审核',
          ),
        ),
      );
      if (_pendingApproval!.hasBeenDispatched &&
          !_approvalLocallySettled &&
          !_pendingApproval!.intent.legacy &&
          detail.canFreezeReviewedApproval &&
          detail.status == kProductionStatusDraft &&
          detail.canApprove) {
        addAction(
          UtenButton(
            key: const Key('daily-report-retry-original-approval'),
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            onPressed: _retryOriginalApproval,
            child: const Text('按原内容重试'),
          ),
        );
      }
    } else if (!_approvalRecoveryReady ||
        (detail.canApprove &&
            !detail.supportsLegacyApproval &&
            !detail.canFreezeReviewedApproval)) {
      addAction(
        UtenButton(
          key: const Key('daily-report-review-reload'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: _load,
          child: Text(_l10n.commonRetry),
        ),
      );
    }

    if (detail.status == kProductionStatusDraft) {
      if (_canDelete) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.delete_outline,
            onPressed: _delete,
            child: const Text('删除'),
          ),
        );
      }
      if (_canEdit) {
        addAction(
          UtenButton(
            type: UtenButtonType.secondary,
            size: UtenButtonSize.large,
            icon: Icons.edit_outlined,
            onPressed: _edit,
            child: const Text('编辑'),
          ),
        );
      }
      if (_canApprove) {
        addAction(
          UtenButton(
            size: UtenButtonSize.large,
            icon: Icons.check_circle_outline,
            onPressed: _approve,
            child: const Text('审核'),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else if (detail.status == kProductionStatusApproved) {
      if (_canReverse) {
        addAction(
          UtenButton(
            type: UtenButtonType.danger,
            size: UtenButtonSize.large,
            icon: Icons.undo_outlined,
            onPressed: _reverse,
            child: const Text('红冲'),
          ),
        );
      }
      if (children.isEmpty) addBack();
    } else {
      addBack();
    }
    if (children.isEmpty) return const SizedBox.shrink();
    // 2026-09-14 UI 统一口径：吸底操作条改右下悬浮组；SizedBox 占位过滤
    //（组自带 8px 间距），按钮统一 large。
    return UtenFloatingActionGroup(
      children: children.where((child) => child is! SizedBox).toList(),
    );
  }

  Widget? _approvalNotice() {
    final pending = _pendingApproval;
    if (pending != null) {
      return UtenInlineNotice(
        key: const Key('daily-report-approval-recovery'),
        level: _approvalLocallySettled
            ? UtenInlineNoticeLevel.info
            : UtenInlineNoticeLevel.warning,
        title: !pending.hasBeenDispatched
            ? '审核尚未发送'
            : _approvalLocallySettled
            ? '原审核结果已核对'
            : '原审核结果待核对',
        message:
            _approvalRecoveryMessage ??
            (!pending.hasBeenDispatched
                ? '本机保留了尚未发送的确认内容；重新核对当前日报后可继续。'
                : pending.intent.legacy
                ? '原提交内容已保留。旧版审核只查询原记录，不会用当前资料重新发送审核。'
                : '原提交内容已保留。先核对原审核；需要重试时仍使用原内容，日报已变化会拒绝。'),
      );
    }
    if (_approvalRecoveryMessage != null) {
      return UtenInlineNotice(
        key: const Key('daily-report-approval-recovery'),
        level: UtenInlineNoticeLevel.warning,
        title: '审核保护需要核对',
        message: _approvalRecoveryMessage!,
      );
    }
    final detail = _detail;
    if (detail != null &&
        detail.canApprove &&
        !detail.supportsLegacyApproval &&
        !detail.canFreezeReviewedApproval) {
      return const UtenInlineNotice(
        key: Key('daily-report-approval-capability-unavailable'),
        level: UtenInlineNoticeLevel.error,
        title: '审核资料需要重新读取',
        message: '当前资料不能用于核对审核版本，请刷新后重试；暂不能提交审核。',
      );
    }
    return null;
  }
}

/// 身份格入参归一：服务端可能给空串或历史占位「—」，
/// 身份格约定「没有就不显示」，占位符要还原成 null。
String? _dictText(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty || trimmed == '—' ? null : trimmed;
}

class _KV {
  const _KV(this.label, this.value, {this.badge});
  final String label;
  final String? value;
  final Widget? badge;
}
