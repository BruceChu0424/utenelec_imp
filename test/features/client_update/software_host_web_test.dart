import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/client_update/software_host_info.dart';
import 'package:uten_imp/features/client_update/software_windows_host.dart';

void main() {
  testWidgets(
    'Web conditional bridge reads browser hints without native channel',
    (tester) async {
      final host = await tester.runAsync(readSoftwareHostInfo);
      expect(host, isA<SoftwareHostInfo>());
      expect(host!.source, anyOf('userAgent', 'userAgentClientHints'));
      expect(
        host.architecture,
        anyOf(isNull, 'x86', 'x64', 'arm64', 'armeabi-v7a'),
      );
      expect(
        host.osCertainty,
        isNot(SoftwareDetectionCertainty.nativeConfirmed),
      );
    },
    skip: !kIsWeb,
  );
}
