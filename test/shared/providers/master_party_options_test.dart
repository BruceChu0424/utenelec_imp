import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/basic_data/models/master_facet.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';
import 'package:uten_imp/shared/providers/master_party_options.dart';

class _Owner extends Notifier<AuthenticatedScope?> {
  @override
  AuthenticatedScope? build() => const AuthenticatedScope(userId: 'A');
  void change(String id) => state = AuthenticatedScope(userId: id);
}

class _Permissions extends Notifier<Set<String>> {
  @override
  Set<String> build() => {Perm.clientView, Perm.supplierView};
  void change(Set<String> value) => state = value;
}

class _Server extends Notifier<String> {
  @override
  String build() => 'https://a.invalid/api';
  void change(String value) => state = value;
}

final _owner = NotifierProvider<_Owner, AuthenticatedScope?>(_Owner.new);
final _permissions = NotifierProvider<_Permissions, Set<String>>(
  _Permissions.new,
);
final _server = NotifierProvider<_Server, String>(_Server.new);

typedef _Request = ({String path, Map<String, dynamic> query, Object? body});

class _Api extends ApiClient {
  _Api() : super(Dio());
  final requests = <_Request>[];
  Completer<Map<String, dynamic>>? paused;

  Future<Map<String, dynamic>> _respond(
    String path,
    Map<String, dynamic>? query,
    Object? body,
  ) async {
    requests.add((path: path, query: {...?query}, body: body));
    if (paused case final pending?) return pending.future;
    final page = query?['page'] as int? ?? 1;
    final supplier = path.contains('suppliers');
    return {
      'items': [
        {
          'id': '${supplier ? 'supplier' : 'client'}-${page * 100}',
          if (!supplier) 'code': 'C0100',
          'name': supplier ? '' : '历史客户',
          'description': supplier ? '历史供应商全称' : null,
          'status': '禁用',
        },
      ],
      'page': page,
      'size': 100,
      'total': 401,
      'totalPages': 5,
    };
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) => _respond(path, query, null);

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
    Object? body,
  }) => _respond(path, query, body);
}

Future<(WidgetRef, ProviderContainer)> _mount(
  WidgetTester tester,
  _Api api,
) async {
  late WidgetRef pageRef;
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_owner)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            pageRef = ref;
            ref.watch(exportContextEpochProvider);
            return const Scaffold(body: SizedBox());
          },
        ),
      ),
    ),
  );
  return (pageRef, container);
}

Future<T> _read<T extends Object>(
  WidgetTester tester,
  Future<T> Function() load,
) async => (await tester.runAsync(load))!;

void main() {
  testWidgets('party panel result stays with its opening reader across A-B-A', (
    tester,
  ) async {
    final (ref, container) = await _mount(tester, _Api());
    final pending = Completer<String?>();
    final old = guardPartyPanelResult(ref.context, () => pending.future);
    container.read(_owner.notifier).change('B');
    await tester.pump();
    container.read(_owner.notifier).change('A');
    await tester.pump();
    pending.complete('old-form-command');
    expect(await old, isNull);
    expect(
      await guardPartyPanelResult(ref.context, () async => 'current-form'),
      'current-form',
    );
    expect(tester.takeException(), isNull);
  });
  test(
    'restored UUID caption never enumerates candidates or resolves null sentinel',
    () {
      final calls = <String>[];
      String? name(String id) {
        calls.add(id);
        return null;
      }

      expect(selectedPartyFacet(null, name), isEmpty);
      expect(
        selectedPartyFacet(kMasterFilterNullValue, name).single.display,
        '(空)',
      );
      expect(calls, isEmpty);
      final selected = selectedPartyFacet('outside-bounded-cache', name).single;
      expect(selected.value, 'outside-bounded-cache');
      expect(selected.display, '已选择');
      expect(calls, ['outside-bounded-cache']);
      expect(
        partyReferenceIds([null, '', kMasterFilterNullValue, 'valid', 'valid']),
        {'valid'},
      );
    },
  );

  testWidgets(
    'complete historical candidates use bounded pages and preserve keyword/legacy contracts',
    (tester) async {
      final api = _Api();
      final (ref, _) = await _mount(tester, api);
      final clients = await _read(
        tester,
        () => clientPartyFacetLoader(ref)('', 4),
      );
      final suppliers = await _read(
        tester,
        () => supplierPartyFacetLoader(ref)('  历史  ', 5),
      );
      final legacy = await _read(
        tester,
        () => clientPartyFacetLoader(ref, excludeLegacyFinanceStub: false)(
          '特殊',
          1,
        ),
      );
      expect(clients.items.single.value, 'client-400');
      expect(clients.items.single.display, contains('历史客户'));
      expect(clients.hasMore, isTrue);
      expect(suppliers.items.single.display, '历史供应商全称');
      expect(suppliers.hasMore, isFalse);
      expect(legacy.items.single.value, 'client-100');
      expect(api.requests.map((r) => r.path), [
        '/master/clients',
        '/master/suppliers/search',
        '/master/clients/search',
      ]);
      expect(api.requests.first.query, {
        'page': 4,
        'size': 100,
        'excludeLegacyFinanceStub': true,
        'selectableOnly': false,
      });
      expect(api.requests[1].query, {'page': 5, 'size': 100});
      expect(api.requests[1].body, {'keyword': '历史'});
      expect(api.requests[2].query['excludeLegacyFinanceStub'], isFalse);
    },
  );

  testWidgets('combined candidates query only authorized domains', (
    tester,
  ) async {
    final api = _Api();
    final (ref, container) = await _mount(tester, api);
    container.read(_permissions.notifier).change({Perm.supplierView});
    await tester.pump();
    final result = await _read(
      tester,
      () => combinedPartyFacetLoader(ref)('新', 3),
    );
    expect(result.items.single.value, 'supplier-300');
    expect(api.requests.single.path, '/master/suppliers/search');
    container.read(_permissions.notifier).change({});
    await tester.pump();
    expect(
      (await _read(tester, () => combinedPartyFacetLoader(ref)('', 1))).items,
      isEmpty,
    );
    expect(api.requests, hasLength(1));
  });

  for (final transition in ['account', 'permissions', 'server', 'A-B-A']) {
    testWidgets('candidate pages reject late $transition replies', (
      tester,
    ) async {
      final api = _Api()..paused = Completer();
      final (ref, container) = await _mount(tester, api);
      final future = clientPartyFacetLoader(ref)('', 1);
      final assertion = expectLater(future, throwsStateError);
      switch (transition) {
        case 'account':
          container.read(_owner.notifier).change('B');
        case 'permissions':
          container.read(_permissions.notifier).change({});
        case 'server':
          container.read(_server.notifier).change('https://b.invalid/api');
        case 'A-B-A':
          container.read(_owner.notifier).change('B');
          await tester.pump();
          container.read(_owner.notifier).change('A');
      }
      await tester.pump();
      api.paused!.complete({
        'items': <Map<String, dynamic>>[],
        'page': 1,
        'size': 100,
        'total': 0,
        'totalPages': 0,
      });
      await tester.pumpAndSettle();
      await assertion;
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'selection waits for fresh UUID proof and rejects owner change during lookup',
    (tester) async {
      final (ref, container) = await _mount(tester, _Api());
      final loaded = <String>[];
      final pending = Completer<void>();
      final selected = resolvePickedParty<String>(
        ref,
        () async => 'chosen',
        idOf: (id) => id,
        isResolved: (_) => true,
        loadNames: (ids) {
          loaded.addAll(ids);
          return pending.future;
        },
      );
      await tester.pump();
      expect(loaded, ['chosen']);
      container.read(_owner.notifier).change('B');
      await tester.pump();
      pending.complete();
      expect(await selected, isNull);
      final current = await resolvePickedParty<String>(
        ref,
        () async => 'new',
        idOf: (id) => id,
        isResolved: (_) => true,
        loadNames: (ids) async {
          loaded.addAll(ids);
        },
      );
      expect(current, 'new');
      expect(loaded, ['chosen', 'new']);
    },
  );
  testWidgets(
    'a missing fresh UUID proof rejects the previously offered picker row',
    (tester) async {
      final (ref, _) = await _mount(tester, _Api());
      final loaded = <String>[];
      final selected = await resolvePickedParty<String>(
        ref,
        () async => 'revoked-without-auth-epoch-change',
        idOf: (id) => id,
        loadNames: (ids) async {
          loaded.addAll(ids);
        },
        isResolved: (_) => false,
      );
      expect(loaded, ['revoked-without-auth-epoch-change']);
      expect(selected, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
