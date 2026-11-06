import 'package:flutter/services.dart';

/// Native widget tests install their real bundled-asset channel handler.
Future<ByteData> loadAuditFontAsset(String key) => rootBundle.load(key);

/// Native font loading already honors the explicitly requested family.
void enableAuditFontMetrics() {}
