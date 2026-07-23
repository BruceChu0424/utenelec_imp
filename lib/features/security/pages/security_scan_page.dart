// 保安扫码核验页：mobile_scanner 扫码 + 手动输入兜底（Web/无摄像头场景）。
import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import 'visitor_check_result_page.dart';

class SecurityScanPage extends ConsumerStatefulWidget {
  const SecurityScanPage({super.key});

  @override
  ConsumerState<SecurityScanPage> createState() => _SecurityScanPageState();
}

class _SecurityScanPageState extends ConsumerState<SecurityScanPage> {
  MobileScannerController? _controller;
  final _manualCtl = TextEditingController();
  bool _navigating = false;

  @override
  void initState() {
    super.initState();
    // Web/桌面无摄像头 → 不创建 controller（手动输入兜底）
    if (!kIsWeb) {
      _controller = MobileScannerController();
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    _manualCtl.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_navigating) return;
    final code = capture.barcodes.firstOrNull?.rawValue;
    if (code == null || code.isEmpty) return;
    _navigating = true;
    _controller?.stop();
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => VisitorCheckResultPage(qrToken: code)))
        .then((_) {
      if (!mounted) return;
      _navigating = false;
      _controller?.start();
    });
  }

  void _manualGo() {
    final t = _manualCtl.text.trim();
    if (t.isEmpty) return;
    Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => VisitorCheckResultPage(passcode: t)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    return Scaffold(
      appBar: UtenAppBar(title: l10n.securityTitle, showBackButton: true),
      body: Stack(
        children: [
          if (!kIsWeb && _controller != null)
            MobileScanner(controller: _controller!, onDetect: _onDetect)
          else
            Center(child: Text(l10n.securityScanManual, style: theme.textTheme.bodyLarge)),
          Center(
            child: Container(
              width: 240,
              height: 240,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white70, width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
            ),
          ),
          Align(
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.only(top: 24),
              child: Text(l10n.securityScanHint,
                  style: theme.textTheme.bodySmall?.copyWith(color: Colors.white)),
            ),
          ),
          Align(
            alignment: Alignment.bottomCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: SafeArea(
                top: false,
                child: UtenCard(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Expanded(
                        child: UtenInput(
                          controller: _manualCtl,
                          label: l10n.securityPasscodeHint,
                          keyboardType: TextInputType.number,
                          prefixIcon: Icons.password_rounded,
                        ),
                      ),
                      const SizedBox(width: 8),
                      UtenButton(onPressed: _manualGo, child: Text(l10n.commonConfirm)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
