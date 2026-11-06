import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/api_provider_retry.dart';
import 'package:uten_imp/core/performance/ui_work_budget.dart';

void main() {
  testWidgets('nested production-style scopes show one terminal API error', (
    tester,
  ) async {
    var attempts = 0;
    final failure = ApiException(
      'INTERNAL',
      'owned gateway failure',
      httpStatus: 503,
    );
    final value = FutureProvider<int>((ref) async {
      attempts++;
      throw failure;
    });
    await tester.pumpWidget(
      ProviderScope(
        retry: apiProviderRetry,
        child: ProviderScope(
          child: Directionality(
            textDirection: TextDirection.ltr,
            child: Consumer(
              builder: (context, ref, child) => ref
                  .watch(value)
                  .when(
                    data: (v) => Text('value=$v'),
                    error: (error, stack) => const Text('terminal failure'),
                    loading: () => const Text('loading'),
                  ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('terminal failure'), findsOneWidget);
    expect(attempts, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('terminal failure'), findsOneWidget);
    expect(
      attempts,
      1,
      reason: 'No hidden SDK backoff may restart a full API snapshot.',
    );
  });

  test(
    'explicit provider recovery remains an opt-in over the root policy',
    () async {
      var attempts = 0;
      final failure = NetworkException();
      final value = FutureProvider<int>((ref) async {
        attempts++;
        throw failure;
      }, retry: (count, error) => count == 0 ? Duration.zero : null);
      final container = ProviderContainer(retry: apiProviderRetry);
      addTearDown(container.dispose);
      final subscription = container.listen(value, (_, _) {});
      addTearDown(subscription.close);
      await expectLater(container.read(value.future), throwsA(same(failure)));
      expect(attempts, 2);
    },
  );

  test(
    'an unknown dispatched outcome retains the original body and is not replayed',
    () async {
      var attempts = 0;
      final body = <String, Object>{
        'requestId': 'original-owned-request',
        'amount': '999999999999.1234567890123456789',
        'state': 'DISPATCHED_UNKNOWN',
      };
      final before = Map<String, Object>.from(body);
      final failure = NetworkTimeoutException();
      final operation = FutureProvider<int>((ref) async {
        attempts++;
        throw failure;
      });
      final container = ProviderContainer(retry: apiProviderRetry);
      addTearDown(container.dispose);
      final subscription = container.listen(operation, (_, _) {});
      addTearDown(subscription.close);
      await expectLater(
        container.read(operation.future),
        throwsA(same(failure)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(attempts, 1);
      expect(body, before);
    },
  );

  test('non API sources retain the exact SDK default retry calculation', () {
    final error = Exception('non API source');
    for (var count = 0; count <= 11; count++) {
      expect(
        apiProviderRetry(count, error),
        ProviderContainer.defaultRetry(count, error),
      );
    }
  });

  test('retired or malformed reads never reacquire an inactive bootstrap', () {
    expect(apiProviderRetry(0, const UiWorkCancelled()), isNull);
    expect(
      apiProviderRetry(0, const FormatException('malformed snapshot')),
      isNull,
    );
  });
}
