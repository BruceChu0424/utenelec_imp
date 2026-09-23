import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/operations_workbench/repositories/operations_workbench_repository.dart';
import 'package:uten_imp/features/subcontract/providers/subcontract_task_count_provider.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/auth/session_epoch_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';

void main() {
  testWidgets('red and yellow share one request, poll and concurrent refresh', (
    tester,
  ) async {
    final repository = _CountsRepository();
    final container = _container(repository);
    container.listen(subcontractTaskCountProvider, (_, _) {});
    container.listen(subcontractTaskInProgressCountProvider, (_, _) {});
    expect(repository.requests, hasLength(1));
    final notifier = container.read(subcontractTaskCountsProvider.notifier);
    final first = notifier.refresh();
    final same = notifier.refresh();
    expect(identical(first, same), isTrue);
    repository.requests.single.complete((pending: 7, inProgress: 3));
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.read(subcontractTaskCountProvider), 7);
    expect(container.read(subcontractTaskInProgressCountProvider), 3);

    notifier.refresh();
    notifier.refresh();
    expect(repository.requests, hasLength(2));
    expect(container.read(subcontractTaskCountsProvider), (
      pending: 7,
      inProgress: 3,
    ));
    repository.requests.last.completeError(StateError('service unavailable'));
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.read(subcontractTaskCountsProvider), (
      pending: 7,
      inProgress: 3,
    ));

    await tester.pump(const Duration(seconds: 60));
    expect(repository.requests, hasLength(3));
    repository.requests.last.complete((pending: 4, inProgress: 8));
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.read(subcontractTaskCountProvider), 4);
    expect(container.read(subcontractTaskInProgressCountProvider), 8);
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('new session clears both counts and ignores old completion', (
    tester,
  ) async {
    final repository = _CountsRepository();
    final container = _container(repository);
    container.listen(subcontractTaskCountProvider, (_, _) {});
    container.listen(subcontractTaskInProgressCountProvider, (_, _) {});
    repository.requests.single.complete((pending: 9, inProgress: 8));
    await tester.pump(const Duration(milliseconds: 1));
    container.read(subcontractTaskCountsProvider.notifier).refresh();
    final oldRequest = repository.requests.last;
    container.read(sessionEpochProvider.notifier).state++;
    await tester.pump(const Duration(milliseconds: 1));
    expect(repository.requests, hasLength(3));
    expect(container.read(subcontractTaskCountsProvider), (
      pending: 0,
      inProgress: 0,
    ));
    repository.requests.last.complete((pending: 2, inProgress: 1));
    await tester.pump(const Duration(milliseconds: 1));
    oldRequest.complete((pending: 99, inProgress: 99));
    await tester.pump(const Duration(milliseconds: 1));
    expect(container.read(subcontractTaskCountsProvider), (
      pending: 2,
      inProgress: 1,
    ));
    container.dispose();
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets(
    'unauthorized viewers send no request including polls and refresh',
    (tester) async {
      final repository = _CountsRepository();
      final container = _container(repository, permissions: const {});
      container.listen(subcontractTaskCountProvider, (_, _) {});
      container.listen(subcontractTaskInProgressCountProvider, (_, _) {});
      await tester.pump(const Duration(milliseconds: 1));
      container.read(subcontractTaskCountsProvider.notifier).refresh();
      await tester.pump(const Duration(seconds: 60));
      expect(repository.requests, isEmpty);
      expect(container.read(subcontractTaskCountsProvider), (
        pending: 0,
        inProgress: 0,
      ));
      container.dispose();
      await tester.pump(const Duration(milliseconds: 1));
    },
  );
}

ProviderContainer _container(
  _CountsRepository repository, {
  Set<String> permissions = const {Perm.subcontractApplicationView},
}) => ProviderContainer(
  overrides: [
    operationsWorkbenchRepositoryProvider.overrideWithValue(repository),
    currentPermissionsProvider.overrideWithValue(permissions),
    isSuperAdminProvider.overrideWithValue(false),
    masterDataSessionKeyProvider.overrideWithValue('subcontract-count-test'),
  ],
);

class _CountsRepository implements OperationsWorkbenchRepository {
  final requests = <Completer<SubcontractTaskCounts>>[];

  @override
  Future<SubcontractTaskCounts> subcontractTaskCounts() {
    final request = Completer<SubcontractTaskCounts>();
    requests.add(request);
    return request.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
