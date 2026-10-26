import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/network/interceptors/auth_interceptor.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/sensitive_write.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

final _identity = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'A'),
);
final _permissions = StateProvider<Set<String>>((ref) => {Perm.goodsEdit});

class _Session extends SessionNotifier {
  int intent = 0;
  @override
  int get requestIntentEpoch => intent;
  @override
  SessionState build() => const SessionState();
}

class _Storage extends SecureStorage {
  _Storage() : super(const FlutterSecureStorage());
  AuthTokenSnapshot snapshot = const AuthTokenSnapshot(
    accessToken: 'test-A-token',
    refreshToken: null,
    generation: 1,
    intentGeneration: 1,
    sessionLineage: 'A-first-login',
  );
  Completer<void>? snapshotReadStarted;
  Completer<void>? snapshotGate;
  @override
  Future<AuthTokenSnapshot> getAuthTokenSnapshot() async {
    final gate = snapshotGate;
    if (gate != null) {
      final started = snapshotReadStarted;
      if (started != null && !started.isCompleted) started.complete();
      await gate.future;
    }
    return snapshot;
  }

  @override
  Future<ImpersonationRecord?> getImpersonationRecord() async => null;
}

void main() {
  testWidgets(
    'synchronous session intent fences capture before the visible boundary changes',
    (tester) async {
      final started = Completer<void>();
      final gate = Completer<void>();
      final storage = _Storage()
        ..snapshotReadStarted = started
        ..snapshotGate = gate;
      final sent = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.test/api'));
      dio.interceptors.add(
        AuthInterceptor(storage: storage, baseUrl: 'https://erp.test/api'),
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            sent.add(request);
            handler.resolve(
              Response<Object?>(
                requestOptions: request,
                statusCode: 200,
                data: <String, dynamic>{},
              ),
            );
          },
        ),
      );
      final api = ApiClient(dio);
      Object? failure;
      var writes = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWith(_Session.new),
            apiClientProvider.overrideWithValue(api),
            authenticatedScopeProvider.overrideWith(
              (ref) => ref.watch(_identity),
            ),
            currentPermissionsProvider.overrideWith(
              (ref) => ref.watch(_permissions),
            ),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) => TextButton(
                onPressed: () async {
                  try {
                    await runSensitiveWrite(
                      ref,
                      isCurrent: () => context.mounted,
                      write: () {
                        writes++;
                        return api.patch(
                          '/master/inline-edit/goods/goods-A',
                          body: {
                            'expected': {'version': 7},
                            'changes': {'stockPlace': 'A-01'},
                          },
                        );
                      },
                    );
                  } catch (error) {
                    failure = error;
                  }
                },
                child: const Text('save'),
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TextButton)),
      );
      await tester.tap(find.text('save'));
      for (var frame = 0; frame < 30 && !started.isCompleted; frame++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(started.isCompleted, isTrue);
      expect(writes, 0);
      // Switching impersonation/password intent is synchronous. The visible
      // identity can remain A until a new credential record has already committed.
      final session = container.read(sessionProvider.notifier) as _Session;
      session.intent++;
      storage.snapshot = const AuthTokenSnapshot(
        accessToken: 'new-B-token',
        refreshToken: null,
        generation: 2,
        intentGeneration: 2,
        sessionLineage: 'new-B-session',
      );
      expect(container.read(_identity), const AuthenticatedScope(userId: 'A'));
      gate.complete();
      await tester.pumpAndSettle();
      expect(
        writes,
        0,
        reason:
            'an old patch cannot acquire the new credential identity during capture',
      );
      expect(sent, isEmpty);
      expect(
        failure,
        isA<ApiException>().having(
          (error) => error.code,
          'code',
          'SESSION_CHANGED',
        ),
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final change in [
    'other-user',
    'A-B-A',
    'permission',
    'read-only',
    'read-scope',
    'read-scope-A-B-A',
    'unchanged',
  ]) {
    testWidgets('real auth queue retains original patch authority: $change', (
      tester,
    ) async {
      final storage = _Storage();
      final queued = Completer<void>();
      final gate = Completer<void>();
      final sent = <RequestOptions>[];
      final dio = Dio(BaseOptions(baseUrl: 'https://erp.test/api'));
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) async {
            // Device audit/local storage can wait before AuthInterceptor first runs.
            queued.complete();
            await gate.future;
            handler.next(request);
          },
        ),
      );
      dio.interceptors.add(
        AuthInterceptor(storage: storage, baseUrl: 'https://erp.test/api'),
      );
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (request, handler) {
            sent.add(request);
            handler.resolve(
              Response<Object?>(
                requestOptions: request,
                statusCode: 200,
                data: <String, dynamic>{},
              ),
            );
          },
        ),
      );
      final api = ApiClient(dio);
      Object? failure;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sessionProvider.overrideWith(_Session.new),
            apiClientProvider.overrideWithValue(api),
            authenticatedScopeProvider.overrideWith(
              (ref) => ref.watch(_identity),
            ),
            currentPermissionsProvider.overrideWith(
              (ref) => ref.watch(_permissions),
            ),
            isSuperAdminProvider.overrideWithValue(false),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) => TextButton(
                onPressed: () async {
                  try {
                    await runSensitiveWrite(
                      ref,
                      isCurrent: () => context.mounted,
                      write: () => api.patch(
                        '/master/inline-edit/goods/goods-A',
                        body: {
                          'expected': {'version': 7},
                          'changes': {'stockPlace': 'A-01'},
                        },
                      ),
                    );
                  } catch (error) {
                    failure = error;
                  }
                },
                child: const Text('save'),
              ),
            ),
          ),
        ),
      );
      final container = ProviderScope.containerOf(
        tester.element(find.byType(TextButton)),
      );
      await tester.tap(find.text('save'));
      for (var frame = 0; frame < 30 && !queued.isCompleted; frame++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(queued.isCompleted, isTrue);
      if (change == 'other-user' || change == 'A-B-A') {
        container.read(_identity.notifier).state = const AuthenticatedScope(
          userId: 'B',
        );
        await tester.pump();
        if (change == 'A-B-A') {
          container.read(_identity.notifier).state = const AuthenticatedScope(
            userId: 'A',
          );
          await tester.pump();
        }
        storage.snapshot = AuthTokenSnapshot(
          accessToken: 'new-token',
          refreshToken: null,
          generation: 2,
          intentGeneration: 2,
          sessionLineage: change,
        );
      } else if (change == 'permission') {
        container.read(_permissions.notifier).state = {};
        await tester.pump();
      } else if (change == 'read-only') {
        container.read(_identity.notifier).state = const AuthenticatedScope(
          userId: 'A',
          readOnly: true,
        );
        await tester.pump();
      } else if (change == 'read-scope' || change == 'read-scope-A-B-A') {
        container.read(readScopeRevisionProvider.notifier).state = 1;
        await tester.pump();
        if (change == 'read-scope-A-B-A') {
          container.read(readScopeRevisionProvider.notifier).state = 0;
          await tester.pump();
        }
      }
      gate.complete();
      await tester.pumpAndSettle();
      if (change == 'unchanged') {
        expect(failure, isNull);
        expect(sent.single.headers['Authorization'], 'Bearer test-A-token');
        expect(sent.single.data, {
          'expected': {'version': 7},
          'changes': {'stockPlace': 'A-01'},
        });
      } else {
        expect(
          sent,
          isEmpty,
          reason: 'old patch must stop before adopting current credentials',
        );
        expect(failure, isA<ApiException>());
      }
      expect(tester.takeException(), isNull);
    });
  }
}
