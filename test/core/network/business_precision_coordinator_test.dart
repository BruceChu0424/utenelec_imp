import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/business_precision.dart';
import 'package:uten_imp/core/network/business_precision_coordinator.dart';

const requirement = BusinessPrecisionRequirement(
  key: 'test.current',
  groupKey: 'test.current',
  label: '本次核对',
  maxScale: 24,
  reason: 'NON_TERMINATING',
);
void main() {
  test(
    'a retired owner throwing completes its caller and does not poison the queue',
    () async {
      final coordinator = BusinessPrecisionCoordinator();
      coordinator.register(
        (_) async => const BusinessPrecisionChoice(4, 'DOWN'),
      );
      await expectLater(
        coordinator
            .ask(
              requirement,
              isCurrent: () => throw StateError('owner disposed'),
            )
            .timeout(const Duration(milliseconds: 200)),
        throwsStateError,
      );
      expect(
        (await coordinator
                .ask(requirement, isCurrent: () => true)
                .timeout(const Duration(milliseconds: 200)))
            ?.scale,
        4,
      );
    },
  );

  test(
    'retiring an active dialog completes its queued reads and does not block a new identity',
    () async {
      final coordinator = BusinessPrecisionCoordinator();
      final old = Completer<BusinessPrecisionChoice?>();
      coordinator.register((_) => old.future);
      final active = coordinator.ask(requirement, isCurrent: () => true);
      final queued = coordinator.ask(requirement, isCurrent: () => true);
      await Future<void>.delayed(Duration.zero);
      coordinator.register(
        (_) async => const BusinessPrecisionChoice(7, 'DOWN'),
      );
      expect(await active, isNull);
      expect(await queued, isNull);
      expect(
        (await coordinator.ask(requirement, isCurrent: () => true))?.scale,
        7,
      );
      old.complete(const BusinessPrecisionChoice(1, 'HALF_UP'));
      await Future<void>.delayed(Duration.zero);
      expect(
        (await coordinator.ask(requirement, isCurrent: () => true))?.rounding,
        'DOWN',
      );
    },
  );
}
