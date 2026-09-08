import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/production/providers/production_workshop_task_count_provider.dart';
import 'package:uten_imp/features/production/repositories/production_execution_workbench_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/role.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  test('latest count wins when manual refresh overtakes polling', () async {
    final (container, repository) = _harness();
    container.read(productionWorkshopTaskCountProvider);
    final latest = container
        .read(productionWorkshopTaskCountProvider.notifier)
        .refresh();
    expect(repository.requests, hasLength(2));
    repository.requests[1].complete(const WorkshopTaskCountBreakdown(count: 7));
    await latest;
    repository.requests[0].complete(const WorkshopTaskCountBreakdown(count: 3));
    await _flush();
    expect(container.read(productionWorkshopTaskCountProvider).count, 7);
  });

  test(
    'account switch clears old count and rejects late old-account response',
    () async {
      final (container, repository) = _harness();
      container.read(productionWorkshopTaskCountProvider);
      repository.requests[0].complete(
        const WorkshopTaskCountBreakdown(count: 5),
      );
      await _flush();
      final oldRequest = container
          .read(productionWorkshopTaskCountProvider.notifier)
          .refresh();
      (container.read(sessionProvider.notifier) as _Session).change('B');
      expect(container.read(productionWorkshopTaskCountProvider).count, 0);
      expect(repository.requests, hasLength(3));
      repository.requests[1].complete(
        const WorkshopTaskCountBreakdown(count: 99),
      );
      await oldRequest;
      expect(container.read(productionWorkshopTaskCountProvider).count, 0);
      repository.requests[2].complete(
        const WorkshopTaskCountBreakdown(count: 2),
      );
      await _flush();
      expect(container.read(productionWorkshopTaskCountProvider).count, 2);
    },
  );

  test(
    'revoked permission resets count and starts no unauthorized request',
    () async {
      final (container, repository) = _harness();
      container.read(productionWorkshopTaskCountProvider);
      (container.read(sessionProvider.notifier) as _Session).change(
        'A',
        allowed: false,
      );
      expect(container.read(productionWorkshopTaskCountProvider).count, 0);
      repository.requests[0].complete(
        const WorkshopTaskCountBreakdown(count: 8),
      );
      await _flush();
      expect(container.read(productionWorkshopTaskCountProvider).count, 0);
      expect(repository.requests, hasLength(1));
      (container.read(sessionProvider.notifier) as _Session).change('A');
      container.read(productionWorkshopTaskCountProvider);
      expect(repository.requests, hasLength(2));
      repository.requests[1].complete(
        const WorkshopTaskCountBreakdown(count: 4),
      );
      await _flush();
      expect(container.read(productionWorkshopTaskCountProvider).count, 4);
    },
  );

  test(
    'actor change resets a count even when effective employee is unchanged',
    () async {
      final (container, repository) = _harness();
      container.read(productionWorkshopTaskCountProvider);
      repository.requests[0].complete(
        const WorkshopTaskCountBreakdown(count: 9),
      );
      await _flush();
      (container.read(sessionProvider.notifier) as _Session).change(
        'A',
        actor: 'administrator',
      );
      expect(container.read(productionWorkshopTaskCountProvider).count, 0);
      expect(repository.requests, hasLength(2));
      repository.requests[1].complete(
        const WorkshopTaskCountBreakdown(count: 6),
      );
      await _flush();
      expect(container.read(productionWorkshopTaskCountProvider).count, 6);
    },
  );

  test('stop fences pending results and prevents later requests', () async {
    final (container, repository) = _harness();
    final notifier = container.read(
      productionWorkshopTaskCountProvider.notifier,
    );
    notifier.stop();
    repository.requests[0].complete(const WorkshopTaskCountBreakdown(count: 9));
    await _flush();
    await notifier.refresh();
    expect(container.read(productionWorkshopTaskCountProvider).count, 0);
    expect(repository.requests, hasLength(1));
  });

  test('network failure keeps current account last confirmed count', () async {
    final (container, repository) = _harness();
    container.read(productionWorkshopTaskCountProvider);
    repository.requests[0].complete(const WorkshopTaskCountBreakdown(count: 5));
    await _flush();
    final refresh = container
        .read(productionWorkshopTaskCountProvider.notifier)
        .refresh();
    repository.requests[1].completeError(StateError('offline'));
    await refresh;
    expect(container.read(productionWorkshopTaskCountProvider).count, 5);
  });
}

Future<void> _flush() => Future<void>.delayed(Duration.zero);

(ProviderContainer, _Repository) _harness() {
  final repository = _Repository();
  final container = ProviderContainer(
    overrides: [
      sessionProvider.overrideWith(_Session.new),
      productionExecutionWorkbenchRepositoryProvider.overrideWithValue(
        repository,
      ),
    ],
  );
  addTearDown(container.dispose);
  return (container, repository);
}

class _Repository extends ProductionExecutionWorkbenchRepository {
  _Repository() : super(ApiClient(Dio()));
  final requests = <Completer<WorkshopTaskCountBreakdown>>[];
  @override
  Future<WorkshopTaskCountBreakdown> workshopTaskCount() {
    final pending = Completer<WorkshopTaskCountBreakdown>();
    requests.add(pending);
    return pending.future;
  }
}

class _Session extends SessionNotifier {
  @override
  SessionState build() =>
      SessionState(status: AuthStatus.authenticated, user: _user('A'));
  void change(String id, {bool allowed = true, String? actor}) {
    state = SessionState(
      status: AuthStatus.authenticated,
      user: _user(id, allowed: allowed),
      actor: actor == null ? null : _user(actor),
    );
  }
}

AppUser _user(String id, {bool allowed = true}) => AppUser(
  id: id,
  code: id,
  name: id,
  roles: const [Role.employee],
  permissions: [if (allowed) Perm.productionExecutionView],
);
