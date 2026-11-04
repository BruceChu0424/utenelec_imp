import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/business_precision.dart';

void main() {
  test(
    'known no-write preview preserves current choices for a changed request body',
    () async {
      final transport = BusinessPrecisionTransport();
      transport.choices['allocation'] = const BusinessPrecisionChoice(
        24,
        'DOWN',
      );
      transport.beginRun(unknown: false);
      await transport.dispatch(
        'old',
        mutating: true,
        semanticFingerprint: 'old',
      );
      await transport.rejected('old');
      transport.prepareRelatedPreview();
      transport.beginRun(unknown: false);
      await transport.dispatch(
        'new',
        mutating: true,
        semanticFingerprint: 'new',
      );
      expect(transport.choices['allocation']?.scale, 24);
    },
  );
  test(
    'an unknown original command cannot be cleared by preview or fake continuation',
    () async {
      final transport = BusinessPrecisionTransport();
      transport.choices['allocation'] = const BusinessPrecisionChoice(
        2,
        'DOWN',
      );
      await transport.dispatch(
        'original',
        mutating: true,
        semanticFingerprint: 'original',
      );
      transport.prepareRelatedPreview();
      expect(transport.advanceConfirmedRequest, throwsStateError);
      transport.beginRun(unknown: true);
      await expectLater(
        transport.dispatch(
          'changed',
          mutating: true,
          semanticFingerprint: 'changed',
        ),
        throwsException,
      );
      expect(transport.choices['allocation']?.scale, 2);
      await transport.completed('original', mutating: true);
      transport.advanceConfirmedRequest();
      transport.beginRun(unknown: false);
      await transport.dispatch(
        'next-window',
        mutating: true,
        semanticFingerprint: 'next-window',
      );
      expect(transport.choices['allocation']?.scale, 2);
    },
  );
}
