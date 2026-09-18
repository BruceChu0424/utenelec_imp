// 保安扫码核验结果页：verify 二维码 → 绿（放行，可签到）/ 红（拒绝）+ 访客信息。
//
// 视觉：全屏路由（不经外壳），语义色柔和底全幅铺背景；内容用
// UtenContentContainer.narrow 收敛，宽屏居中不拉宽；错误态统一 UtenEmpty。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_reviewer_responsibility_notice.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/auth/permissions.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';
import '../../visitor/widgets/visitor_status_ui.dart';

class VisitorCheckResultPage extends ConsumerStatefulWidget {
  const VisitorCheckResultPage({super.key, this.qrToken, this.passcode});
  final String? qrToken;
  final String? passcode;

  @override
  ConsumerState<VisitorCheckResultPage> createState() =>
      _VisitorCheckResultPageState();
}

class _VisitorCheckResultPageState
    extends ConsumerState<VisitorCheckResultPage> {
  SecurityVerifyResult? _result;
  bool _loading = true;
  bool _checking = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    Future.microtask(_verify);
  }

  Future<void> _verify() async {
    final l10n = AppLocalizations.of(context);
    try {
      final r = await ref
          .read(visitorStaffRepositoryProvider)
          .verify(qrToken: widget.qrToken, passcode: widget.passcode);
      if (!mounted) return;
      setState(() {
        _result = r;
        _loading = false;
      });
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = l10n.commonError;
          _loading = false;
        });
      }
    }
  }

  Future<void> _checkIn() async {
    final id = _result?.applicationId;
    if (id == null) return;
    setState(() => _checking = true);
    try {
      final r = await ref.read(visitorStaffRepositoryProvider).checkIn(id);
      if (!mounted) return;
      setState(() => _result = r);
      context.appSuccess(AppLocalizations.of(context).securityCheckInDone);
    } on ApiException catch (e) {
      // 签到被拒（并发已签/状态变化/网络失败）保持当前核验结果可读，仅提示。
      if (mounted) {
        context.appApiError(
          e,
          fallback: AppLocalizations.of(context).commonError,
        );
      }
    } catch (_) {
      if (mounted) {
        context.appError(AppLocalizations.of(context).commonError);
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  String _reasonLabel(String reason, AppLocalizations l10n) => switch (reason) {
    'ok' => l10n.securityReasonOk,
    'invalid' => l10n.securityReasonInvalid,
    'expired' => l10n.securityReasonExpired,
    'used' => l10n.securityReasonUsed,
    'rejected' => l10n.securityReasonRejected,
    'blocked' => l10n.securityReasonBlocked,
    _ => reason,
  };

  /// 拉黑该访客：红结果且能定位到访客账号时出现（visitor:blacklist）。
  /// 原因必填；拉黑后账号 blocked → 其 JWT 即时失效、凭证全部失效。
  Future<void> _blacklist() async {
    final l10n = AppLocalizations.of(context);
    final visitorId = _result?.visitorId;
    if (visitorId == null) return;
    final ctl = TextEditingController();
    final confirmed = await UtenDialog.show(
      context,
      title: l10n.securityBlacklistAction,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          UtenReviewerResponsibilityNotice(
            actionLabel: l10n.securityBlacklistNoticeLabel,
            description: l10n.securityBlacklistNoticeDesc,
          ),
          const SizedBox(height: UtenSpacing.s12),
          UtenInput(
            controller: ctl,
            label: l10n.securityBlacklistReasonLabel,
            hint: l10n.securityBlacklistReasonHint,
            maxLines: 2,
          ),
        ],
      ),
      confirmLabel: l10n.securityBlacklistAction,
      cancelLabel: l10n.commonCancel,
      danger: true,
    );
    final reason = ctl.text.trim();
    ctl.dispose();
    if (confirmed != true || reason.isEmpty || !mounted) return;
    try {
      await ref
          .read(visitorStaffRepositoryProvider)
          .blacklist(visitorId, reason: reason);
      if (!mounted) return;
      context.appSuccess(l10n.securityBlacklistDone);
      // 重新核验：同码再验显示红「已拉黑」，按钮随之消失。
      setState(() {
        _loading = true;
        _error = null;
      });
      await _verify();
    } on ApiException catch (e) {
      if (mounted) {
        context.appApiError(e, fallback: l10n.commonError);
      }
    } catch (_) {
      if (mounted) context.appError(l10n.commonError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final valid = _result?.valid ?? false;
    final mainColor = valid ? UtenColors.success : UtenColors.error;
    final permissions = ref.watch(currentPermissionsProvider);
    final canCheckIn = permissions.contains(Perm.visitorCheckIn);
    // 拉黑入口：红结果 + 能定位访客账号 + 持权限 + 未在黑名单（blocked 已是终态）。
    final canBlacklist =
        !valid &&
        _result?.visitorId != null &&
        _result?.reason != 'blocked' &&
        permissions.contains(Perm.visitorBlacklist);

    return Scaffold(
      appBar: UtenAppBar(title: l10n.securityTitle, showBackButton: true),
      // 语义色柔和底全幅铺背景（本页为全屏路由，不进外壳）
      backgroundColor: mainColor.withValues(alpha: 0.08),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? UtenEmpty.error(
              message: _error!,
              actionLabel: l10n.commonRetry,
              onAction: () {
                setState(() {
                  _loading = true;
                  _error = null;
                });
                _verify();
              },
            )
          : Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    // 内容窄收敛：宽屏居中，手机端保持原有节奏；
                    // 底部留出右下悬浮操作组的高度。
                    child: UtenContentContainer.narrow(
                      padding: const EdgeInsets.fromLTRB(
                        0,
                        UtenSpacing.s16,
                        0,
                        UtenFloatingActionGroup.scrollClearance,
                      ),
                      child: Column(
                        children: [
                          const SizedBox(height: UtenSpacing.s24),
                          Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              color: mainColor.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              valid
                                  ? Icons.check_circle_rounded
                                  : Icons.cancel_rounded,
                              size: 64,
                              color: mainColor,
                            ),
                          ),
                          const SizedBox(height: UtenSpacing.s16),
                          Text(
                            valid ? l10n.securityPass : l10n.securityReject,
                            style: Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: mainColor,
                                ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _reasonLabel(_result?.reason ?? 'invalid', l10n),
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                          const SizedBox(height: UtenSpacing.s24),
                          if (_result?.visitorName != null)
                            UtenCard(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                                vertical: 4,
                              ),
                              child: Column(
                                children: [
                                  UtenInfoRow(
                                    label: l10n.securityVisitor,
                                    value: _result!.visitorName,
                                    isImportant: true,
                                  ),
                                  if (_result!.visitPurpose != null)
                                    UtenInfoRow(
                                      label: l10n.securityPurpose,
                                      value: _result!.visitPurpose,
                                    ),
                                  if (_result!.hostName != null)
                                    UtenInfoRow(
                                      label: l10n.securityHost,
                                      value: _result!.hostName,
                                    ),
                                  if (_result!.plateNo != null)
                                    UtenInfoRow(
                                      label: l10n.securityPlate,
                                      value: _result!.plateNo,
                                    ),
                                  if (_result!.plannedVisitAt != null)
                                    UtenInfoRow(
                                      label: l10n.securityVisitTime,
                                      value: fmtDateTime(
                                        _result!.plannedVisitAt!,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          const SizedBox(height: UtenSpacing.s24),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
      // 2026-09-14 UI 统一口径：吸底操作按钮改右下悬浮组（按钮已是 large）。
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
      floatingActionButton:
          (valid && canCheckIn && _result?.checkInAt == null) || canBlacklist
          ? UtenFloatingActionGroup(
              children: [
                if (canBlacklist)
                  UtenButton(
                    type: UtenButtonType.danger,
                    size: UtenButtonSize.large,
                    icon: Icons.block_rounded,
                    onPressed: _checking ? null : _blacklist,
                    child: Text(l10n.securityBlacklistAction),
                  ),
                if (valid && canCheckIn && _result?.checkInAt == null)
                  UtenButton(
                    onPressed: _checking ? null : _checkIn,
                    isLoading: _checking,
                    size: UtenButtonSize.large,
                    child: Text(l10n.securityCheckIn),
                  ),
              ],
            )
          : null,
    );
  }
}
