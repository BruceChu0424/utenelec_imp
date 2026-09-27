import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_catalog.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

import 'memory_form_draft_storage.dart';

FormDraft _saved(
  FormDraftSpec spec, {
  String id = 'draft-1',
  String? route,
  String? permission,
  BadgeModule? module,
  String? draftKind,
}) => FormDraft(
  id: id,
  title: spec.title,
  module: module ?? spec.module,
  route: route ?? spec.route,
  permission: permission ?? spec.permission,
  draftKind: draftKind ?? spec.draftKind,
  updatedAt: DateTime.utc(2026, 9, 26),
  data: const {'input': 'unfinished'},
);

void main() {
  test('every declared descriptor belongs to the single catalog index', () {
    final source = File(
      'lib/shared/drafts/form_draft_catalog.dart',
    ).readAsStringSync();
    final declared = RegExp(
      r'static const (\w+) = FormDraftDescriptor\(',
    ).allMatches(source).map((match) => match.group(1)!).toSet();
    expect(FormDraftCatalog.all.keys.toSet(), declared);
    expect(FormDraftCatalog.all.values.toSet().length, declared.length);
    for (final entry in FormDraftCatalog.all.entries) {
      final descriptor = entry.value;
      final route = descriptor.route.replaceAllMapped(
        RegExp(r':\w+'),
        (match) => switch (match.group(0)) {
          ':receiptType' => 'PURCHASE',
          ':code' => 'OTHER_IN',
          _ => 'fixture-id',
        },
      );
      final spec = descriptor.spec(route: route);
      expect(spec.permission, descriptor.permission, reason: entry.key);
      expect(spec.module, descriptor.module, reason: entry.key);
      expect(
        Uri.parse(spec.route).queryParameters['draftForm'],
        descriptor.dialogKind,
        reason: entry.key,
      );
      expect(
        spec.canRestore(_saved(spec), currentRoute: spec.route),
        isTrue,
        reason: entry.key,
      );
    }
  });

  test('descriptor rejects a foreign route and a substituted dialog kind', () {
    for (final route in [
      'https://outside.invalid/basicinfo/client',
      '//outside.invalid/basicinfo/client',
      '/basicinfo/supplier',
      '/basicinfo/client#fragment',
    ]) {
      expect(
        () => FormDraftCatalog.client.spec(route: route),
        throwsArgumentError,
      );
    }
    expect(
      () => FormDraftCatalog.supplier.spec(
        routeParameters: {'draftForm': 'supplierQuick'},
      ),
      throwsArgumentError,
    );
    expect(
      () => FormDraftCatalog.employeeOffboarding.spec(
        route: '/employee/encoded%2Fpath/offboarding',
      ),
      throwsArgumentError,
    );
  });

  test(
    'same permission and path cannot restore another dialog payload kind',
    () {
      final normal = FormDraftCatalog.supplier.spec();
      final quick = FormDraftCatalog.supplierQuick.spec();
      expect(normal.permission, quick.permission);
      expect(Uri.parse(normal.route).path, Uri.parse(quick.route).path);
      expect(
        normal.canRestore(_saved(quick), currentRoute: normal.route),
        isFalse,
      );
      expect(
        quick.canRestore(_saved(normal), currentRoute: quick.route),
        isFalse,
      );
      expect(
        normal.canRestore(
          _saved(normal, route: '${normal.route}&draftForm=supplierQuick'),
          currentRoute: normal.route,
        ),
        isFalse,
      );
    },
  );

  test('restore rejects changed permission module path and draft kind', () {
    final spec = FormDraftCatalog.expense.spec();
    for (final changed in [
      _saved(spec, permission: Perm.expenseApprove),
      _saved(spec, module: BadgeModule.finance),
      _saved(spec, route: '/suggestion/new'),
      _saved(spec, draftKind: 'unknown-kind'),
      _saved(spec, route: '//outside.invalid/expense/new'),
    ]) {
      expect(spec.canRestore(changed, currentRoute: spec.route), isFalse);
    }
    expect(spec.canRestore(_saved(spec), currentRoute: '/other/new'), isFalse);
  });

  test(
    'legacy snapshots and legitimate stock document kinds remain compatible',
    () {
      for (final entry in {
        'TRANSFER': 'stockTransfer',
        'CHECK': 'stockCheck',
        'OTHER_IN': 'stockDocument',
      }.entries) {
        final spec = FormDraftCatalog.stockDocument.spec(
          route: '/warehouse/${entry.key}/new',
          draftKind: entry.value,
        );
        final json = _saved(spec).toJson();
        expect(json.containsKey('policyId'), isFalse);
        final legacy = FormDraft.fromJson(json);
        expect(
          spec.canRestore(legacy, currentRoute: legacy.resumeLocation),
          isTrue,
        );
        expect(
          spec.canRestore(
            _saved(spec, draftKind: 'unknown-kind'),
            currentRoute: spec.route,
          ),
          isFalse,
        );
      }
    },
  );

  test(
    'store denies a missing business permission and nonlocal drafts without writing',
    () async {
      final storage = MemoryFormDraftStorage();
      final container = ProviderContainer(
        overrides: [
          authenticatedScopeProvider.overrideWithValue(
            const AuthenticatedScope(userId: 'user-1'),
          ),
          currentPermissionsProvider.overrideWithValue({Perm.supplierView}),
          apiBaseUrlProvider.overrideWithValue(
            'https://draft-test.invalid/api',
          ),
          formDraftStorageProvider.overrideWithValue(storage),
        ],
      );
      addTearDown(container.dispose);
      final store = container.read(formDraftsProvider.notifier);
      await store.ready;
      final spec = FormDraftCatalog.supplier.spec();
      await expectLater(store.save(_saved(spec)), throwsStateError);
      await expectLater(
        store.save(_saved(spec, route: '//outside.invalid/basicinfo/supplier')),
        throwsStateError,
      );
      expect(storage.records, isEmpty);
      expect(container.read(formDraftsProvider), isEmpty);
    },
  );
}
