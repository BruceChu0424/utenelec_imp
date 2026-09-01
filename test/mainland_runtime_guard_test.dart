import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  group('mainland runtime dependency guard', () {
    test('application runtime does not hard-code blocked public CDNs', () {
      final forbiddenHosts = RegExp(
        r'(?:fonts\.googleapis\.com|fonts\.gstatic\.com|www\.gstatic\.com|'
        r'unpkg\.com|cdn\.jsdelivr\.net|cdnjs\.cloudflare\.com|'
        r'googletagmanager\.com|google-analytics\.com|firebaseio\.com|'
        r'githubusercontent\.com|sentry\.io)',
        caseSensitive: false,
      );
      final violations = <String>[];

      for (final root in [Directory('lib'), Directory('web')]) {
        for (final entity in root.listSync(recursive: true)) {
          if (entity is! File || !_isRuntimeTextFile(entity.path)) continue;
          if (_isSupplyChainMetadata(entity.path)) continue;
          if (forbiddenHosts.hasMatch(entity.readAsStringSync())) {
            violations.add(entity.path);
          }
        }
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Mainland production runtime must use same-origin or an explicitly '
            'approved mainland service. Supply-chain provenance metadata is '
            'excluded because it is never fetched by the application.',
      );
    });

    test('printing Web implementation cannot reintroduce remote pdf.js', () {
      final violations = <String>[];
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final normalized = entity.path.replaceAll(r'\', '/');
        final source = entity.readAsStringSync();
        if (source.contains('package:printing/printing.dart') &&
            !normalized.endsWith('/core/print/pdf_printer_io.dart')) {
          violations.add(normalized);
        }
        if (source.contains('PdfPreview(')) violations.add(normalized);
      }

      expect(
        violations,
        isEmpty,
        reason:
            'Web printing must stay behind pdf_printer_web.dart so it does not '
            'load the printing package default unpkg.com PDF.js runtime.',
      );
    });

    test('China Web release contract stays enabled', () {
      final workflow = File('.github/workflows/quality.yml').readAsStringSync();
      final index = File('web/index.html').readAsStringSync();
      final bootstrap = File('web/flutter_bootstrap.js').readAsStringSync();
      final nginx = File(
        'deploy/nginx/uten-imp.conf.example',
      ).readAsStringSync();
      final macosDebug = File(
        'macos/Runner/DebugProfile.entitlements',
      ).readAsStringSync();
      final macosRelease = File(
        'macos/Runner/Release.entitlements',
      ).readAsStringSync();

      expect(workflow, contains('--no-web-resources-cdn'));
      expect(index, contains('<html lang="zh-CN">'));
      expect(
        bootstrap,
        contains("canvasKitVariant: 'full'"),
        reason:
            'Keep the universal CanvasKit build pinned until the reproduced '
            'Chromium-variant synchronous hang has an independently verified '
            'engine fix.',
      );
      expect(nginx, contains("connect-src 'self'"));
      expect(nginx, contains("font-src 'self'"));
      expect(nginx, contains("frame-src 'self' blob:"));
      expect(nginx, contains('gzip on;'));
      expect(nginx, isNot(contains('rate=5r/m')));
      expect(macosDebug, contains('com.apple.security.network.client'));
      expect(macosRelease, contains('com.apple.security.network.client'));
    });
  });
}

bool _isRuntimeTextFile(String path) {
  final extension = path.toLowerCase().split('.').last;
  return const {'dart', 'html', 'js', 'css', 'json'}.contains(extension);
}

bool _isSupplyChainMetadata(String path) {
  final normalized = path.replaceAll(r'\', '/');
  return normalized.endsWith('/fallback_fonts/SHA256SUMS.json');
}
