import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/visitor_session_event_bus.dart';
import 'package:uten_imp/core/security/secure_storage.dart';
import 'package:uten_imp/features/visitor/models/visitor.dart';
import 'package:uten_imp/features/visitor/providers/visitor_session_provider.dart';
import 'package:uten_imp/features/visitor/repositories/visitor_repository.dart';

const _visitor = Visitor(id: 'v1', visitorNo: 'V001', name: 'Visitor');

class _Storage extends SecureStorage {
  _Storage() : super(const FlutterSecureStorage());

  int reads = 0;
  Completer<String?>? gate;
  Object? readError;

  @override
  Future<String?> getVisitorAccessToken() {
    reads++;
    if (readError case final error?) return Future.error(error);
    return gate?.future ?? Future.value('stored-token');
  }
}

class _Repository implements VisitorRepository {
  int reads = 0;
  Completer<Visitor>? gate;
  final loginGate = Completer<VisitorLoginResult>();
  final logoutGate = Completer<void>();

  @override
  Future<VisitorLoginResult> login(String phone, String code) =>
      loginGate.future;

  @override
  Future<void> logout() => logoutGate.future;

  @override
  Future<Visitor> me() {
    reads++;
    return gate?.future ?? Future.value(_visitor);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ProviderContainer _container(_Storage storage, _Repository repository) =>
    ProviderContainer(
      overrides: [
        secureStorageProvider.overrideWithValue(storage),
        visitorRepositoryProvider.overrideWithValue(repository),
      ],
    );

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'unavailable secure storage leaves restore quiet and retryable',
    () async {
      final repository = _Repository();
      final storage = _Storage()..readError = StateError('storage unavailable');
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final container = _container(storage, repository);
        try {
          container.read(visitorSessionProvider);
          await _flush();
          expect(container.read(visitorSessionProvider).isLoggedIn, isFalse);
          expect(repository.reads, 0);
          storage.readError = null;
          container.invalidate(visitorSessionProvider);
          container.read(visitorSessionProvider);
          await _flush();
          expect(container.read(visitorSessionProvider).visitor, _visitor);
        } finally {
          container.dispose();
        }
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    },
  );

  test(
    'disposal does not interrupt login but ignores its late UI response',
    () async {
      final repository = _Repository();
      final container = _container(_Storage(), repository);
      final notifier = container.read(visitorSessionProvider.notifier);
      await _flush();
      final login = notifier.login('13800000000', 'test-code');
      container.dispose();
      repository.loginGate.complete(
        const VisitorLoginResult(
          accessToken: 'access',
          refreshToken: 'refresh',
          visitorId: 'v1',
          visitorNo: 'V001',
          name: 'Visitor',
        ),
      );
      await expectLater(login, completes);
    },
  );

  test(
    'disposal does not interrupt logout but ignores its late UI response',
    () async {
      final repository = _Repository();
      final container = _container(_Storage(), repository);
      final notifier = container.read(visitorSessionProvider.notifier);
      await _flush();
      final logout = notifier.logout();
      container.dispose();
      repository.logoutGate.complete();
      await expectLater(logout, completes);
    },
  );

  test('live session still restores and handles expiration', () async {
    final container = _container(_Storage(), _Repository());
    addTearDown(container.dispose);
    container.read(visitorSessionProvider);
    await _flush();
    expect(container.read(visitorSessionProvider).visitor, _visitor);
    VisitorSessionEventBus.instance.expire();
    await _flush();
    expect(container.read(visitorSessionProvider).isLoggedIn, isFalse);
  });

  test(
    'disposal before restore starts avoids storage and network reads',
    () async {
      final storage = _Storage();
      final repository = _Repository();
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final container = _container(storage, repository);
        container.read(visitorSessionProvider);
        container.dispose();
        await _flush();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
      expect(storage.reads, 0);
      expect(repository.reads, 0);
    },
  );

  test(
    'disposed providers unsubscribe from the global expiration stream',
    () async {
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final container = _container(_Storage(), _Repository());
        container.read(visitorSessionProvider);
        await _flush();
        container.dispose();
        VisitorSessionEventBus.instance.expire();
        await _flush();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    },
  );

  test(
    'a disposed pending token read cannot start a profile request',
    () async {
      final storage = _Storage()..gate = Completer<String?>();
      final repository = _Repository();
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final container = _container(storage, repository);
        container.read(visitorSessionProvider);
        await _flush();
        container.dispose();
        storage.gate!.complete('stored-token');
        await _flush();
      }, (error, _) => errors.add(error));
      expect(repository.reads, 0);
      expect(errors, isEmpty);
    },
  );

  test(
    'a disposed profile response does not publish or access the old ref',
    () async {
      final repository = _Repository()..gate = Completer<Visitor>();
      final errors = <Object>[];
      await runZonedGuarded(() async {
        final container = _container(_Storage(), repository);
        container.read(visitorSessionProvider);
        await _flush();
        expect(repository.reads, 1);
        container.dispose();
        repository.gate!.complete(_visitor);
        await _flush();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
    },
  );
}
