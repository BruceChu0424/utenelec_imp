// 访客登录页（手机号 + 短信验证码；验证码统一 123456 / 开发期后端日志返回）。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../providers/visitor_session_provider.dart';

class VisitorLoginPage extends ConsumerStatefulWidget {
  const VisitorLoginPage({super.key});

  @override
  ConsumerState<VisitorLoginPage> createState() => _VisitorLoginPageState();
}

class _VisitorLoginPageState extends ConsumerState<VisitorLoginPage> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();
  bool _isLoading = false;
  bool _sendingCode = false;
  int _countdown = 0;
  Timer? _timer;
  String? _devCode;
  String? _errorMessage;

  @override
  void dispose() {
    _timer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  bool _validPhone(String p) => RegExp(r'^1\d{10}$').hasMatch(p);

  Future<void> _sendCode() async {
    final phone = _phoneController.text.trim();
    final l10n = AppLocalizations.of(context);
    if (!_validPhone(phone)) {
      setState(() => _errorMessage = l10n.visitorPhoneInvalid);
      return;
    }
    setState(() {
      _sendingCode = true;
      _errorMessage = null;
    });
    try {
      final dev = await ref.read(visitorSessionProvider.notifier).sendCode(phone);
      if (!mounted) return;
      setState(() {
        _devCode = dev;
        _countdown = 60;
      });
      _startCountdown();
    } on ApiException catch (e) {
      if (mounted) setState(() => _errorMessage = e.message);
    } catch (_) {
      if (mounted) setState(() => _errorMessage = l10n.commonError);
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  void _startCountdown() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 1), (t) {
      setState(() => _countdown--);
      if (_countdown <= 0) t.cancel();
    });
  }

  Future<void> _login() async {
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();
    final l10n = AppLocalizations.of(context);
    if (!_validPhone(phone)) {
      setState(() => _errorMessage = l10n.visitorPhoneInvalid);
      return;
    }
    if (code.isEmpty) {
      setState(() => _errorMessage = l10n.visitorCodeRequired);
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      await ref.read(visitorSessionProvider.notifier).login(phone, code);
      if (!mounted) return;
      context.go(RouteName.visitorHome);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _errorMessage =
            e.code == 'IS_EMPLOYEE' ? l10n.visitorIsEmployee : e.message);
      }
    } catch (_) {
      if (mounted) setState(() => _errorMessage = l10n.commonError);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: DecoratedBox(
        decoration: BoxDecoration(color: theme.scaffoldBackgroundColor),
        child: SafeArea(
          child: LayoutBuilder(builder: (context, c) {
            return SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: c.maxHeight),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: UtenCard(
                        padding: const EdgeInsets.all(28),
                        borderRadius: 20,
                        elevation: UtenCardElevation.high,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(children: [
                              IconButton(
                                icon: const Icon(Icons.arrow_back_rounded),
                                onPressed: () => context.go(RouteName.entry),
                              ),
                              Text(l10n.visitorLoginTitle,
                                  style: theme.textTheme.titleLarge
                                      ?.copyWith(fontWeight: FontWeight.w700)),
                            ]),
                            const SizedBox(height: 8),
                            Text(l10n.visitorLoginSubtitle,
                                style: theme.textTheme.bodyMedium
                                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                            const SizedBox(height: 24),
                            UtenInput(
                              controller: _phoneController,
                              label: l10n.visitorPhoneLabel,
                              hint: l10n.visitorPhoneHint,
                              keyboardType: TextInputType.phone,
                              prefixIcon: Icons.phone_iphone_rounded,
                              textInputAction: TextInputAction.next,
                            ),
                            const SizedBox(height: 16),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Expanded(
                                  child: UtenInput(
                                    controller: _codeController,
                                    label: l10n.visitorCodeLabel,
                                    hint: l10n.visitorCodeHint,
                                    keyboardType: TextInputType.number,
                                    prefixIcon: Icons.password_outlined,
                                    textInputAction: TextInputAction.go,
                                    onFieldSubmitted: (_) => _login(),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                SizedBox(
                                  height: 48,
                                  child: UtenButton(
                                    onPressed:
                                        (_countdown > 0 || _sendingCode) ? null : _sendCode,
                                    isLoading: _sendingCode,
                                    type: UtenButtonType.secondary,
                                    child: Text(_countdown > 0
                                        ? l10n.visitorCodeCountdown(_countdown)
                                        : l10n.visitorGetCode),
                                  ),
                                ),
                              ],
                            ),
                            if (_devCode != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: UtenColors.teal500.withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(l10n.visitorCodeSentDev(_devCode!),
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(color: UtenColors.teal800)),
                              ),
                            ],
                            if (_errorMessage != null) ...[
                              const SizedBox(height: 12),
                              Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: UtenColors.error.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(children: [
                                  const Icon(Icons.error_outline,
                                      color: UtenColors.error, size: 18),
                                  const SizedBox(width: 8),
                                  Expanded(
                                      child: Text(_errorMessage!,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(color: UtenColors.error))),
                                ]),
                              ),
                            ],
                            const SizedBox(height: 20),
                            UtenButton(
                              onPressed: _isLoading ? null : _login,
                              isLoading: _isLoading,
                              isExpanded: true,
                              size: UtenButtonSize.large,
                              child: Text(
                                  _isLoading ? l10n.visitorLoggingIn : l10n.visitorLoginButton),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
