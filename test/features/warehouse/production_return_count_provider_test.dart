import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/warehouse/models/stock_doc.dart';
import 'package:uten_imp/features/warehouse/providers/production_return_count_provider.dart';
import 'package:uten_imp/features/warehouse/repositories/stock_doc_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/models/user.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

class _Session extends SessionNotifier {
  @override
  SessionState build() =>
      SessionState(status: AuthStatus.authenticated, user: _user('A'));
  void change({
    String id = 'A',
    String? employee,
    String? actor,
    bool readOnly = false,
  }) {
    state = SessionState(
      status: AuthStatus.authenticated,
      user: _user(id, employee: employee),
      actor: actor == null ? null : _user(actor),
      impersonationReadOnly: readOnly,
    );
  }
}

AppUser _user(String id, {String? employee}) => AppUser(
  id: id,
  code: id,
  name: id,
  employeeId: employee ?? 'employee-$id',
  permissions: const [Perm.stockDocView],
);

class _Repository extends StockDocRepository {
  _Repository() : super(ApiClient(Dio()), StockDocType.wdraw);
  final requests = <Completer<int>>[];
  @override
  Future<int> pendingProductionReturnCount() {
    final request = Completer<int>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  for (final change in ['user', 'employee', 'actor', 'readOnly']) {
    test(
      'same-permission $change scope change clears the old return count before the next response',
      () async {
        final repository = _Repository();
        final container = ProviderContainer(
          overrides: [
            sessionProvider.overrideWith(_Session.new),
            stockDocRepositoryProvider(
              StockDocType.wdraw,
            ).overrideWithValue(repository),
          ],
        );
        addTearDown(container.dispose);
        final subscription = container.listen(
          warehouseProductionReturnPendingCountProvider,
          (_, _) {},
        );
        addTearDown(subscription.close);
        await Future<void>.delayed(Duration.zero);
        repository.requests.first.complete(9);
        await Future<void>.delayed(Duration.zero);
        expect(
          container
              .read(warehouseProductionReturnPendingCountProvider)
              .valueOrNull,
          9,
        );
        final session = container.read(sessionProvider.notifier) as _Session;
        switch (change) {
          case 'user':
            session.change(id: 'B');
          case 'employee':
            session.change(employee: 'other-employee');
          case 'actor':
            session.change(actor: 'supervisor');
          case 'readOnly':
            session.change(readOnly: true);
        }
        await Future<void>.delayed(Duration.zero);
        expect(repository.requests, hasLength(2));
        expect(
          container
              .read(warehouseProductionReturnPendingCountProvider)
              .valueOrNull,
          isNull,
        );
        repository.requests.last.complete(2);
        await Future<void>.delayed(Duration.zero);
        expect(
          container
              .read(warehouseProductionReturnPendingCountProvider)
              .valueOrNull,
          2,
        );
      },
    );
  }

  test(
    'a late response from the former actor cannot overwrite the new actor count',
    () async {
      final repository = _Repository();
      final container = ProviderContainer(
        overrides: [
          sessionProvider.overrideWith(_Session.new),
          stockDocRepositoryProvider(
            StockDocType.wdraw,
          ).overrideWithValue(repository),
        ],
      );
      addTearDown(container.dispose);
      container.listen(
        warehouseProductionReturnPendingCountProvider,
        (_, _) {},
      );
      await Future<void>.delayed(Duration.zero);
      (container.read(sessionProvider.notifier) as _Session).change(id: 'B');
      await Future<void>.delayed(Duration.zero);
      repository.requests.last.complete(2);
      await Future<void>.delayed(Duration.zero);
      repository.requests.first.complete(99);
      await Future<void>.delayed(Duration.zero);
      expect(
        container
            .read(warehouseProductionReturnPendingCountProvider)
            .valueOrNull,
        2,
      );
    },
  );
}
