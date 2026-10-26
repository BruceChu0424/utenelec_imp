import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/features/finance/providers/finance_name_provider.dart';
import 'package:uten_imp/features/sales/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/master_dictionary_repository.dart';
import 'package:uten_imp/shared/providers/master_name_provider.dart';
import 'package:uten_imp/shared/providers/master_party_lookup.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/export_context_epoch_provider.dart';

class _Styles implements PaymentStyleRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api extends ApiClient {
  _Api() : super(Dio());
  final calls = <({String path, List<String> ids})>[];
  final readZones = <Object?>[];
  int active = 0, maxActive = 0;
  int generation = 0;
  bool fail = false;
  bool forbidden = false;
  bool freezeResponseAtStart = false;
  final missing = <String>{};
  final disabled = <String>{};
  final unknownStatus = <String>{};
  Completer<void>? gate;
  Completer<void>? selectiveGate;
  Set<String> heldIds = {};
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (!path.endsWith('/lookup')) {
      expect(
        path,
        isNot(anyOf('/master/clients/dict', '/master/suppliers/dict')),
      );
      return [];
    }
    final ids = (query!['ids'] as String).split(',');
    readZones.add(Zone.current[#partyReadOwner]);
    calls.add((path: path, ids: ids));
    if (path.contains('/clients/')) {
      expect(query['excludeLegacyFinanceStub'], isTrue);
    }
    final version = generation;
    final hiddenAtStart = Set<String>.of(missing);
    final deniedAtStart = forbidden;
    final failedAtStart = fail;
    final pending = gate ?? (ids.any(heldIds.contains) ? selectiveGate : null);
    active++;
    if (active > maxActive) maxActive = active;
    try {
      if (pending != null) await pending.future;
      await Future<void>.delayed(Duration.zero);
      if (freezeResponseAtStart ? failedAtStart : fail) {
        throw StateError('fixture lookup failed');
      }
      if (freezeResponseAtStart ? deniedAtStart : forbidden) {
        throw ApiException('FORBIDDEN', '引用范围已撤销', httpStatus: 403);
      }
      return [
        for (final id in ids)
          if (!(freezeResponseAtStart ? hiddenAtStart : missing).contains(id))
            {
              'id': id,
              'name': 'name-$version-$id',
              'code': 'code-$id',
              'selectable': !disabled.contains(id),
              if (!unknownStatus.contains(id))
                'status': disabled.contains(id) ? '禁用' : '使用',
              'defaultSettlementMethodId': 'settlement-$id',
            },
      ];
    } finally {
      active--;
    }
  }
}

void main() {
  test(
    'retired owners retain physical HTTP slots until transport completes',
    () async {
      final gate = Completer<void>();
      final api = _Api()..gate = gate;
      final old = MasterPartyLookup(api);
      final queued = MasterPartyLookup(api);
      final fresh = MasterPartyLookup(api);
      addTearDown(() {
        old.dispose();
        queued.dispose();
        fresh.dispose();
        if (!gate.isCompleted) gate.complete();
      });
      final ids = [for (var i = 0; i < 200; i++) 'owner-$i'];
      final stopped = expectLater(
        runZoned(
          () => Future.wait([
            old.load(MasterPartyKind.client, ids),
            old.load(MasterPartyKind.supplier, ids),
          ]),
          zoneValues: {#partyReadOwner: 'old'},
        ),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(api.active, 4);
      old.dispose();
      await stopped;
      api.gate = null;
      api.generation = 1;
      final discarded = expectLater(
        Future.wait([
          queued.load(MasterPartyKind.client, ids),
          queued.load(MasterPartyKind.supplier, ids),
        ]),
        throwsStateError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(api.calls, hasLength(4));
      queued.dispose();
      await discarded;
      final completed = expectLater(
        runZoned(
          () => Future.wait([
            fresh.load(MasterPartyKind.client, ids),
            fresh.load(MasterPartyKind.supplier, ids),
          ]),
          zoneValues: {#partyReadOwner: 'fresh'},
        ),
        completes,
      );
      await Future<void>.delayed(Duration.zero);
      expect(api.calls, hasLength(4));
      expect(api.maxActive, 4);
      gate.complete();
      await completed;
      expect(api.calls, hasLength(8));
      expect(api.maxActive, 4);
      expect(api.readZones, [
        ...List.filled(4, 'old'),
        ...List.filled(4, 'fresh'),
      ]);
      expect(
        fresh.reference(MasterPartyKind.client, ids.first)?['name'],
        'name-1-${ids.first}',
      );
    },
  );
  for (final failNewRead in [false, true]) {
    test(
      'fresh ${failNewRead ? 'failure' : 'revocation'} cannot adopt an older started HTTP positive',
      () async {
        final api = _Api()..freezeResponseAtStart = true;
        final names = SalesMasterNameService(api);
        addTearDown(names.dispose);
        final gate = Completer<void>();
        api.gate = gate;
        addTearDown(() {
          if (!gate.isCompleted) gate.complete();
        });
        final old = names.loadClientNames(['same']);
        await Future<void>.delayed(Duration.zero);
        expect(api.calls, hasLength(1));
        api.gate = null;
        if (failNewRead) {
          api.fail = true;
        } else {
          api.missing.add('same');
        }
        await names
            .loadClientNames(['same'])
            .timeout(const Duration(seconds: 1));
        expect(api.calls, hasLength(2));
        expect(
          names.partyReferences.reference(MasterPartyKind.client, 'same'),
          isNull,
        );
        gate.complete();
        await old;
        await Future<void>.delayed(Duration.zero);
        expect(
          names.partyReferences.reference(MasterPartyKind.client, 'same'),
          isNull,
        );
      },
    );
  }
  test(
    'an older delayed denial cannot clear a newer fresh authorized reference',
    () async {
      final api = _Api()
        ..freezeResponseAtStart = true
        ..forbidden = true;
      final names = SalesMasterNameService(api);
      addTearDown(names.dispose);
      final gate = Completer<void>();
      api.gate = gate;
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final old = names.loadClientNames(['same']);
      await Future<void>.delayed(Duration.zero);
      api.gate = null;
      api.forbidden = false;
      api.generation = 1;
      await names.loadClientNames(['same']);
      expect(names.client('same'), 'name-1-same');
      gate.complete();
      await old;
      await Future<void>.delayed(Duration.zero);
      expect(names.client('same'), 'name-1-same');
      expect(api.calls, hasLength(2));
    },
  );
  test(
    'fresh client read retires a revoked positive reference without an epoch change',
    () async {
      final api = _Api();
      final names = SalesMasterNameService(api);
      addTearDown(names.dispose);
      const originalId = 'client-a';
      await names.loadClientNames([originalId]);
      expect(names.client(originalId), 'name-0-client-a');
      api.missing.add(originalId);
      await names.loadClientNames([originalId]);
      expect(api.calls, hasLength(2));
      expect(names.client(originalId), '—');
      expect(originalId, 'client-a');
    },
  );
  test(
    'completed HTTP batches are not treated as in-flight while another batch waits',
    () async {
      final api = _Api();
      final names = SalesMasterNameService(api);
      addTearDown(names.dispose);
      final ids = [for (var index = 0; index < 200; index++) 'batch-$index'];
      final gate = Completer<void>();
      api.selectiveGate = gate;
      api.heldIds = {ids.last};
      final first = names.loadClientNames(ids);
      for (
        var turn = 0;
        turn < 30 && names.clientEntries[ids.first] == null;
        turn++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(names.client(ids.first), 'name-0-${ids.first}');
      api.missing.add(ids.first);
      await names
          .loadClientNames([ids.first])
          .timeout(const Duration(seconds: 1));
      expect(api.calls, hasLength(3));
      expect(names.client(ids.first), '—');
      gate.complete();
      await first;
      expect(names.client(ids.first), '—');
    },
  );
  test(
    'authoritative denial retires cached references without an implicit retry storm',
    () async {
      final api = _Api();
      final names = SalesMasterNameService(api);
      addTearDown(names.dispose);
      await names.loadClientNames(['known']);
      api.forbidden = true;
      await names.loadClientNames(['known']);
      await Future<void>.delayed(Duration.zero);
      expect(names.client('known'), '—');
      expect(names.client('another'), '—');
      await Future<void>.delayed(Duration.zero);
      expect(api.calls, hasLength(2));
      api.forbidden = false;
      await names.loadClientNames(['known']);
      expect(api.calls, hasLength(3));
      expect(names.client('known'), 'name-0-known');
    },
  );
  test(
    'party reference provider retires cached names through permission ABA',
    () async {
      final api = _Api();
      final permissions = StateProvider<Set<String>>((ref) => {});
      final container = ProviderContainer(
        overrides: [
          apiClientProvider.overrideWithValue(api),
          currentPermissionsProvider.overrideWith(
            (ref) => ref.watch(permissions),
          ),
        ],
      );
      addTearDown(container.dispose);
      var notifications = 0;
      container.listen(masterNameServiceProvider, (_, _) => notifications++);
      final old = container.read(masterNameServiceProvider);
      await old.loadSupplierNames(['same']);
      expect(old.supplier('same'), 'name-0-same');
      await Future<void>.delayed(Duration.zero);
      expect(notifications, 1);
      expect(identical(old, container.read(masterNameServiceProvider)), isTrue);
      final epoch = container.read(exportContextEpochProvider);
      container.read(permissions.notifier).state = {'changed'};
      expect(container.read(exportContextEpochProvider), greaterThan(epoch));
      container.read(permissions.notifier).state = {};
      expect(
        container.read(exportContextEpochProvider),
        greaterThan(epoch + 1),
      );
      final fresh = container.read(masterNameServiceProvider);
      expect(identical(old, fresh), isFalse);
      api.generation = 1;
      await fresh.loadSupplierNames(['same']);
      expect(fresh.supplier('same'), 'name-1-same');
      expect(old.supplier('same'), '—');
    },
  );

  test(
    'mixed client and supplier enrichment shares at most four HTTP slots',
    () async {
      final api = _Api();
      final lookup = MasterPartyLookup(api);
      addTearDown(lookup.dispose);
      final ids = [for (var i = 0; i < 450; i++) 'mixed-$i'];
      await Future.wait([
        lookup.load(MasterPartyKind.client, ids),
        lookup.load(MasterPartyKind.supplier, ids),
      ]);
      expect(api.calls, hasLength(10));
      expect(api.maxActive, lessThanOrEqualTo(4));
    },
  );
  test(
    'row display misses coalesce into bounded shared lookup batches',
    () async {
      final api = _Api();
      final dictionaries = MasterDictionaryRepository(api);
      final sales = SalesMasterNameService(api, dictionaries);
      final master = MasterNameService(api, dictionaries);
      final finance = FinanceNameService(api, _Styles(), dictionaries);
      var salesNotifications = 0;
      var financeNotifications = 0;
      sales.addListener(() => salesNotifications++);
      finance.addListener(() => financeNotifications++);
      addTearDown(() {
        sales.dispose();
        master.dispose();
        finance.dispose();
        dictionaries.dispose();
      });
      final ids = [for (var i = 0; i < 450; i++) 'id-$i'];
      for (final id in ids) {
        expect(sales.client(id), '—');
        finance.client(id);
      }
      await Future.wait([
        sales.loadClientNames(ids),
        finance.loadPartyNames(clientIds: ids),
      ]);
      expect(api.calls, hasLength(5));
      expect(api.calls.every((call) => call.ids.length <= 100), isTrue);
      expect(api.maxActive, lessThanOrEqualTo(4));
      expect(sales.client(ids.first), 'name-0-${ids.first}');
      expect(finance.client(ids.last), 'name-0-${ids.last}');
      await Future<void>.delayed(Duration.zero);
      // Each completed 100-row HTTP group can redraw progressively; never one
      // provider notification for each of the 450 display misses.
      expect(salesNotifications, inInclusiveRange(1, 5));
      expect(financeNotifications, inInclusiveRange(1, 5));
      await master.loadSupplierNames(ids.take(2));
      expect(master.supplier(ids.first), 'name-0-${ids.first}');
      expect(
        master.supplierDefaultSettlement(ids.first),
        'settlement-${ids.first}',
      );
    },
  );

  test(
    'disabled names survive but missing status is never known enabled',
    () async {
      final api = _Api()
        ..disabled.add('disabled')
        ..unknownStatus.add('unknown');
      final names = MasterNameService(api);
      addTearDown(names.dispose);
      await names.loadSupplierNames(['disabled', 'unknown', 'enabled']);
      expect(names.supplier('disabled'), 'name-0-disabled');
      expect(names.isSupplierDisabled('disabled'), isTrue);
      expect(names.supplierReferenceKnown('disabled'), isTrue);
      expect(names.supplierReferenceKnown('unknown'), isFalse);
      expect(names.supplierActiveEntries.keys, ['enabled']);
    },
  );

  test(
    'absent IDs are negatively cached while failures remain retryable',
    () async {
      final api = _Api()..missing.add('missing');
      final lookup = MasterPartyLookup(api);
      addTearDown(lookup.dispose);
      await lookup.load(MasterPartyKind.client, ['missing']);
      await lookup.load(MasterPartyKind.client, ['missing']);
      expect(api.calls, hasLength(1));
      expect(lookup.reference(MasterPartyKind.client, 'missing'), isNull);
      api.fail = true;
      await expectLater(
        lookup.load(MasterPartyKind.client, ['retry']),
        throwsStateError,
      );
      api.fail = false;
      await lookup.load(MasterPartyKind.client, ['retry']);
      expect(api.calls, hasLength(3));
      expect(lookup.reference(MasterPartyKind.client, 'retry')?['id'], 'retry');
    },
  );

  test(
    'invalidation rejects old waits and late data cannot replace fresh names',
    () async {
      final api = _Api()..gate = Completer<void>();
      final lookup = MasterPartyLookup(api);
      addTearDown(lookup.dispose);
      final old = lookup.load(MasterPartyKind.supplier, ['same']);
      final failure = expectLater(old, throwsStateError);
      await Future<void>.delayed(Duration.zero);
      final gate = api.gate!;
      lookup.invalidate(MasterPartyKind.supplier);
      api.gate = null;
      api.generation = 1;
      await lookup.load(MasterPartyKind.supplier, ['same']);
      gate.complete();
      await failure;
      await Future<void>.delayed(Duration.zero);
      expect(
        lookup.reference(MasterPartyKind.supplier, 'same')?['name'],
        'name-1-same',
      );
    },
  );

  test(
    'complete large snapshot is readable before inactive cache eviction',
    () async {
      final api = _Api();
      final lookup = MasterPartyLookup(api);
      addTearDown(lookup.dispose);
      final ids = [for (var i = 0; i < 5001; i++) 'id-$i'];
      await lookup.load(MasterPartyKind.supplier, ids);
      expect(
        ids.every(
          (id) => lookup.reference(MasterPartyKind.supplier, id) != null,
        ),
        isTrue,
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        lookup.ids(MasterPartyKind.supplier).length,
        lessThanOrEqualTo(MasterPartyLookup.maxCachedRows),
      );
      expect(api.maxActive, lessThanOrEqualTo(4));
    },
  );
}
