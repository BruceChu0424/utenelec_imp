// 保安扫码核验结果页：verify 二维码 → 绿（放行，可签到）/ 红（拒绝）+ 访客信息。
//
// 视觉：全屏路由（不经外壳），语义色柔和底全幅铺背景；内容用
// UtenContentContainer.narrow 收敛，宽屏居中不拉宽；错误态统一 UtenEmpty。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/data_display/uten_info_row.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_bottom_action_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../visitor/repositories/visitor_staff_repository.dart';

class VisitorCheckResultPage extends ConsumerStatefulWidget {
  const VisitorCheckResultPage({super.key, this.qrToken, this.passcode});
  final String? qrToken;
  final String? passcode;

  @override
  ConsumerState<VisitorCheckResultPage> createState() => _VisitorCheckResultPageState();
}

class _VisitorCheckResultPageState extends ConsumerState<VisitorCheckResultPage> {
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
        _ => reason,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final valid = _result?.valid ?? false;
    final mainColor = valid ? UtenColors.success : UtenColors.error;

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
                        // 内容窄收敛：宽屏居中，手机端保持原有节奏
                        child: UtenContentContainer.narrow(
                          padding: const EdgeInsets.symmetric(
                              vertical: UtenSpacing.s16),
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
                                  valid ? Icons.check_circle_rounded : Icons.cancel_rounded,
                                  size: 64,
                                  color: mainColor,
                                ),
                              ),
                              const SizedBox(height: UtenSpacing.s16),
                              Text(
                                valid ? l10n.securityPass : l10n.securityReject,
                                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                                    fontWeight: FontWeight.w800, color: mainColor),
                              ),
                              const SizedBox(height: 6),
                              Text(_reasonLabel(_result?.reason ?? 'invalid', l10n),
                                  style: Theme.of(context).textTheme.bodyMedium),
                              const SizedBox(height: UtenSpacing.s24),
                              if (_result?.visitorName != null)
                                UtenCard(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 4),
                                  child: Column(
                                    children: [
                                      UtenInfoRow(
                                          label: l10n.securityVisitor,
                                          value: _result!.visitorName,
                                          isImportant: true),
                                      if (_result!.visitPurpose != null)
                                        UtenInfoRow(
                                            label: l10n.securityPurpose,
                                            value: _result!.visitPurpose),
                                      if (_result!.hostName != null)
                                        UtenInfoRow(
                                            label: l10n.securityHost,
                                            value: _result!.hostName),
                                      if (_result!.plateNo != null)
                                        UtenInfoRow(
                                            label: l10n.securityPlate,
                                            value: _result!.plateNo),
                                      if (_result!.plannedVisitAt != null)
                                        UtenInfoRow(
                                            label: l10n.securityVisitTime,
                                            value:
                                                '${_result!.plannedVisitAt!.year}-${_result!.plannedVisitAt!.month.toString().padLeft(2, '0')}-${_result!.plannedVisitAt!.day.toString().padLeft(2, '0')}'),
                                    ],
                                  ),
                                ),
                              const SizedBox(height: UtenSpacing.s24),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (valid && _result?.checkInAt == null)
                      UtenBottomActionBar(
                        child: UtenButton(
                          onPressed: _checking ? null : _checkIn,
                          isLoading: _checking,
                          isExpanded: true,
                          size: UtenButtonSize.large,
                          child: Text(l10n.securityCheckIn),
                        ),
                      ),
                  ],
                ),
    );
  }
}
