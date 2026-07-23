// 访客入厂凭证二维码（qr_flutter 渲染后端签发的 qrToken）。
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

class VisitorQrWidget extends StatelessWidget {
  const VisitorQrWidget({super.key, required this.token});

  final String token;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: QrImageView(
        data: token,
        version: QrVersions.auto,
        size: 220,
        gapless: true,
        backgroundColor: Colors.white,
      ),
    );
  }
}
