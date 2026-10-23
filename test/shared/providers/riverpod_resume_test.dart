import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class _Seed extends Notifier<int> {
  @override
  int build() => 0;

  void bump() => state++;
}

void main() {
  test(
    'resume delivers the last missed value once and keeps later updates',
    () async {
      final container = ProviderContainer.test();
      final seed = NotifierProvider<_Seed, int>(_Seed.new);
      final value = Provider<int>((ref) => ref.watch(seed));
      final events = <int>[];
      final subscription = container.listen(
        value,
        (_, next) => events.add(next),
        fireImmediately: true,
      );
      subscription.pause();
      container.read(seed.notifier)
        ..bump()
        ..bump();
      expect(events, [0]);
      subscription.resume();
      expect(events, [0, 2]);
      container.read(seed.notifier).bump();
      await container.pump();
      expect(events, [0, 2, 3]);
      subscription.close();
    },
  );

  test('idle pause and resume preserve the same ref lifecycle', () {
    final container = ProviderContainer.test();
    var cancelled = 0;
    var resumed = 0;
    final value = Provider<int>((ref) {
      ref.onCancel(() => cancelled++);
      ref.onResume(() => resumed++);
      return 1;
    });
    final subscription = container.listen(value, (_, _) {});
    subscription.pause();
    expect(cancelled, 1);
    expect(resumed, 0);
    subscription.resume();
    expect(cancelled, 1);
    expect(resumed, 1);
    expect(subscription.read(), 1);
    subscription.close();
    expect(cancelled, 2);
  });

  test('resume delivers a missed error and accepts later data', () async {
    final container = ProviderContainer.test();
    final seed = NotifierProvider<_Seed, int>(_Seed.new);
    final value = Provider<int>((ref) {
      final current = ref.watch(seed);
      if (current == 1) throw StateError('paused failure');
      return current;
    });
    final events = <int>[];
    final errors = <Object>[];
    final subscription = container.listen(
      value,
      (_, next) => events.add(next),
      onError: (error, stack) => errors.add(error),
      fireImmediately: true,
    );
    subscription.pause();
    container.read(seed.notifier).bump();
    subscription.resume();
    expect(errors, hasLength(1));
    expect(errors.single.toString(), contains('paused failure'));
    container.read(seed.notifier).bump();
    await container.pump();
    expect(events, [0, 2]);
    expect(errors, hasLength(1));
    subscription.close();
  });

  for (final rightFirst in [false, true]) {
    testWidgets('paused diamond resumes and keeps updating ($rightFirst)', (
      tester,
    ) async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final seed = NotifierProvider<_Seed, int>(_Seed.new);
      final shared = Provider<int>((ref) => ref.watch(seed));
      final left = Provider<int>((ref) => ref.watch(shared) + 1);
      final rightLeaf = Provider<int>((ref) => ref.watch(shared) * 2);
      final right = Provider<int>((ref) => ref.watch(rightLeaf));
      final total = Provider<int>((ref) {
        if (rightFirst) {
          final rightValue = ref.watch(right);
          return rightValue + ref.watch(left);
        }
        final leftValue = ref.watch(left);
        return leftValue + ref.watch(right);
      });
      Widget app(bool enabled) => UncontrolledProviderScope(
        container: container,
        child: TickerMode(
          enabled: enabled,
          child: Consumer(
            builder: (context, ref, child) =>
                Text('${ref.watch(total)}', textDirection: TextDirection.ltr),
          ),
        ),
      );

      await tester.pumpWidget(app(true));
      expect(find.text('1'), findsOneWidget);
      await tester.pumpWidget(app(false));
      container.read(seed.notifier).bump();
      await tester.pumpWidget(app(true));
      expect(tester.takeException(), isNull);
      expect(find.text('4'), findsOneWidget);

      container.read(seed.notifier).bump();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('7'), findsOneWidget);
    });
  }
}
