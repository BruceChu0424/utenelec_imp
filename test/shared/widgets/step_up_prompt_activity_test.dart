import 'dart:async';

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

class _DelayedRepository implements StepUpRepository {
  final response = Completer<String>();
  int verifications = 0;

  @override
  Future<String> verify(String password) {
    verifications++;
    return response.future;
  }
}

void main() {
  for (final scope in <AuthenticatedScope?>[
    null,
    const AuthenticatedScope(userId: 'offline-user'),
  ]) {
    testWidgets('idle host does not initialize unavailable API ($scope)', (
      tester,
    ) async {
      var apiReads = 0;
      var repositoryReads = 0;
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(scope),
          apiClientProvider.overrideWith((ref) {
            apiReads++;
            throw StateError('Business API unavailable');
          }),
          stepUpRepositoryProvider.overrideWith((ref) {
            repositoryReads++;
            throw StateError('No business authentication repository');
          }),
        ],
      );
      addTearDown(container.dispose);
      await _mountHost(tester, container);
      await tester.pump(const Duration(seconds: 31));
      UserActivity.record();
      await tester.pump(const Duration(seconds: 16));
      expect(apiReads, 0);
      expect(repositoryReads, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('cancelling the only prompt releases the API replacement watch', (
    tester,
  ) async {
    final unavailable = StateProvider((ref) => false);
    var apiReads = 0;
    final container = ProviderContainer(
      overrides: [
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'u-1'),
        ),
        apiClientProvider.overrideWith((ref) {
          apiReads++;
          if (ref.watch(unavailable)) {
            throw StateError('Business API unavailable');
          }
          return ApiClient(Dio());
        }),
        stepUpRepositoryProvider.overrideWithValue(_Repository()),
      ],
    );
    addTearDown(container.dispose);
    await _mountHost(tester, container);
    final proof = StepUpCoordinator.instance.obtain();
    await tester.pumpAndSettle();
    expect(apiReads, 1);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await proof, isNull);
    container.read(unavailable.notifier).state = true;
    await tester.pump(const Duration(seconds: 31));
    expect(apiReads, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('API switch rejects a late verification without replaying it', (
    tester,
  ) async {
    final repository = _DelayedRepository();
    final endpoint = StateProvider((ref) => ApiClient(Dio()));
    final container = ProviderContainer(
      overrides: [
        authenticatedScopeProvider.overrideWithValue(
          const AuthenticatedScope(userId: 'u-1'),
        ),
        apiClientProvider.overrideWith((ref) => ref.watch(endpoint)),
        stepUpRepositoryProvider.overrideWithValue(repository),
      ],
    );
    addTearDown(container.dispose);
    await _mountHost(tester, container);
    final proof = StepUpCoordinator.instance.obtain();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'my-password');
    await tester.tap(find.byKey(const Key('reauth-confirm')));
    await tester.pump();
    container.read(endpoint.notifier).state = ApiClient(Dio());
    await tester.pump();
    repository.response.complete('late-proof');
    await tester.pumpAndSettle();
    expect(find.text('登录身份或服务器已变化，请重新确认'), findsOneWidget);
    expect(StepUpCoordinator.instance.cachedToken, isNull);
    expect(repository.verifications, 1);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(await proof, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

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
    await _mountHost(tester, container);
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

    container.read(endpoint.notifier).state = ApiClient(
      Dio(BaseOptions(baseUrl: 'https://server-b.test/api')),
    );
    await tester.pump();
    expect(StepUpCoordinator.instance.cachedToken, isNull);
    final replacementProof = StepUpCoordinator.instance.obtain();
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), 'my-password');
    await tester.tap(find.byKey(const Key('reauth-confirm')));
    await tester.pumpAndSettle();
    expect(await replacementProof, 'proof-2');
    container.read(scope.notifier).state = const AuthenticatedScope(
      userId: 'u-2',
    );
    await tester.pump();
    expect(StepUpCoordinator.instance.cachedToken, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

Future<void> _mountHost(
  WidgetTester tester,
  ProviderContainer container,
) async {
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
}
