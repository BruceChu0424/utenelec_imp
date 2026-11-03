import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart' as testing;

/// Owns manually supplied containers through widget teardown, before Flutter
/// verifies pending timers. A retained read is allowed to survive a route;
/// it must still be disposed with its actual container owner.
class OwnedProviderWidgetTests {
  final _containers = <ProviderContainer>[];

  void own(ProviderContainer container) => _containers.add(container);

  void disposeContainer(ProviderContainer container) {
    if (!_containers.remove(container)) {
      throw StateError('Provider container is not owned by this fixture');
    }
    container.dispose();
  }

  void testWidgets(
    String description,
    Future<void> Function(testing.WidgetTester) callback,
  ) {
    testing.testWidgets(description, (tester) async {
      assert(_containers.isEmpty);
      try {
        await callback(tester);
      } finally {
        try {
          await tester.pumpWidget(const SizedBox.shrink());
        } finally {
          for (final container in _containers.reversed) {
            container.dispose();
          }
          _containers.clear();
        }
        await tester.pump();
      }
    });
  }
}
