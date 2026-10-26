import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/party_reference_read_controller.dart';

class _Owner extends Notifier<AuthenticatedScope?> {
  @override
  AuthenticatedScope? build() => const AuthenticatedScope(userId: 'A');
  void change(String id) => state = AuthenticatedScope(userId: id);
}

final _owner = NotifierProvider<_Owner, AuthenticatedScope?>(_Owner.new);

class _Suppliers extends MasterNameService {
  _Suppliers() : super(ApiClient(Dio()));
  final values = <String, String>{};
  final reads = <List<String>>[];
  Completer<void>? pause;
  @override
  Future<void> loadSupplierNames(Iterable<String> ids) async {
    reads.add(ids.toList());
    if (pause case final pending?) await pending.future;
  }

  @override
  String supplier(String? id) => values[id] ?? '—';
}

class _Clients extends SalesMasterNameService {
  _Clients() : super(ApiClient(Dio()));
  final values = <String, String>{};
  final reads = <List<String>>[];
  Completer<void>? pause;
  @override
  Future<void> loadClientNames(Iterable<String> ids) async {
    reads.add(ids.toList());
    if (pause case final pending?) await pending.future;
  }

  @override
  String client(String? id) => values[id] ?? '—';
}

Future<(PartyReferenceReadController, ProviderContainer)> _mount(
  WidgetTester tester,
  _Clients clients,
  _Suppliers suppliers,
) async {
  late PartyReferenceReadController controller;
  final container = ProviderContainer(
    overrides: [
      apiBaseUrlProvider.overrideWithValue('https://fixture.invalid/api'),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
      masterNameServiceProvider.overrideWithValue(suppliers),
      salesMasterNameServiceProvider.overrideWithValue(clients),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: Consumer(
        builder: (context, ref, _) {
          controller = PartyReferenceReadController(ref);
          return const SizedBox();
        },
      ),
    ),
  );
  addTearDown(controller.dispose);
  return (controller, container);
}

void main() {
  testWidgets(
    'one read freezes only its referenced names and refreshes once per read signature',
    (tester) async {
      final clients = _Clients()..values['c1'] = '客户一';
      final suppliers = _Suppliers()..values['s1'] = '供应商一';
      addTearDown(clients.dispose);
      addTearDown(suppliers.dispose);
      final (controller, _) = await _mount(tester, clients, suppliers);
      controller.prepare('read1', clients: {'c1'}, suppliers: {'s1'});
      expect(controller.snapshot.clients, isEmpty);
      await tester.pump();
      expect(controller.snapshot.clients, {'c1': '客户一'});
      expect(controller.snapshot.suppliers, {'s1': '供应商一'});
      expect(
        () => controller.snapshot.clients['c2'] = 'bad',
        throwsUnsupportedError,
      );
      clients.values.clear();
      suppliers.values['s1'] = '其他视图的名称';
      controller.prepare('read1', clients: {'c1'}, suppliers: {'s1'});
      await tester.pump();
      expect(controller.snapshot.clients, {'c1': '客户一'});
      expect(controller.snapshot.suppliers, {'s1': '供应商一'});
      expect(clients.reads, [
        ['c1'],
      ]);
      controller.prepare('read2', clients: {'c1'}, suppliers: {'s1'});
      expect(controller.snapshot.clients, isEmpty);
      await tester.pump();
      expect(controller.snapshot.clients, isEmpty);
      expect(controller.snapshot.suppliers, {'s1': '其他视图的名称'});
      expect(clients.reads, [
        ['c1'],
        ['c1'],
      ]);
    },
  );

  testWidgets(
    'later draft read wins and old delayed proof cannot overwrite it',
    (tester) async {
      final clients = _Clients()..pause = Completer<void>();
      final suppliers = _Suppliers();
      addTearDown(clients.dispose);
      addTearDown(suppliers.dispose);
      final (controller, _) = await _mount(tester, clients, suppliers);
      controller.prepare(1, clients: {'old'}, suppliers: {});
      await tester.pump();
      final old = clients.pause!;
      clients.pause = null;
      clients.values['new'] = '新读客户';
      controller.prepare(2, clients: {'new'}, suppliers: {});
      await tester.pump();
      expect(controller.snapshot.clients, {'new': '新读客户'});
      clients.values['old'] = '旧读迟到';
      old.complete();
      await tester.pump();
      expect(controller.snapshot.clients, {'new': '新读客户'});
    },
  );

  testWidgets(
    'A to B to A never revives a previous proof and disposed pending reads stay silent',
    (tester) async {
      final clients = _Clients()..values['same'] = 'A私有客户';
      final suppliers = _Suppliers();
      addTearDown(clients.dispose);
      addTearDown(suppliers.dispose);
      final (controller, container) = await _mount(tester, clients, suppliers);
      controller.prepare(1, clients: {'same'}, suppliers: {});
      await tester.pump();
      expect(controller.snapshot.clients, {'same': 'A私有客户'});
      container.read(_owner.notifier).change('B');
      await container.pump();
      expect(controller.snapshot.clients, isEmpty);
      container.read(_owner.notifier).change('A');
      await container.pump();
      expect(controller.snapshot.clients, isEmpty);
      clients.pause = Completer<void>();
      controller.prepare(2, clients: {'same'}, suppliers: {});
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      clients.pause!.complete();
      await tester.pump();
      expect(controller.snapshot.clients, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
