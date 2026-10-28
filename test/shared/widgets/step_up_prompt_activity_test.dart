import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/step_up_coordinator.dart';
import 'package:uten_imp/core/network/user_activity.dart';
import 'package:uten_imp/features/auth/repositories/step_up_repository.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/widgets/reauth_dialog.dart';

class _Repository implements StepUpRepository, StepUpActivityRepository {
  int verifications = 0;
  final List<String> activities = [];
  @override
  Future<String> verify(String password) async => 'proof-${++verifications}';
  @override
  Future<void> recordActivity(String token) async => activities.add(token);
}

void main() {
  testWidgets('宿主复用全局输入保活，后台计时不续期，身份和服务器切换清除凭证', (tester) async {
    var now = DateTime.utc(2026, 10, 28);
    UserActivity.clock = () => now;
    addTearDown(UserActivity.reset);
    final repository = _Repository();
    final scope = StateProvider<AuthenticatedScope?>(
      (ref) => const AuthenticatedScope(userId: 'u-1'),
    );
    final endpoint = StateProvider<ApiClient>(
      (ref) =>
          ApiClient(Dio(BaseOptions(baseUrl: 'https://server-a.test/api'))),
    );
    final container = ProviderContainer(
      overrides: [
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(scope)),
        apiClientProvider.overrideWith((ref) => ref.watch(endpoint)),
        stepUpRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: StepUpPromptHost(
              navigatorContext: () => navigator.currentContext,
            ),
          ),
        ),
      ),
    );
    final proof = StepUpCoordinator.instance.obtain();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'my-password');
    await tester.tap(find.byKey(const Key('reauth-confirm')));
    await tester.pumpAndSettle();
    expect(await proof, 'proof-1');
    expect(await StepUpCoordinator.instance.obtain(), 'proof-1');
    expect(repository.verifications, 1);

    now = now.add(const Duration(seconds: 20));
    UserActivity.record();
    await tester.pump(const Duration(seconds: 30));
    expect(repository.activities, ['proof-1']);
    now = now.add(const Duration(seconds: 30));
    await tester.pump(const Duration(seconds: 30));
    expect(repository.activities, ['proof-1'], reason: '没有新增输入，计时器不能自己续期');

    container.read(scope.notifier).state = const AuthenticatedScope(
      userId: 'u-2',
    );
    await tester.pump();
    expect(StepUpCoordinator.instance.cachedToken, isNull);
    container.read(endpoint.notifier).state = ApiClient(
      Dio(BaseOptions(baseUrl: 'https://server-b.test/api')),
    );
    await tester.pump();
    expect(StepUpCoordinator.instance.cachedToken, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
