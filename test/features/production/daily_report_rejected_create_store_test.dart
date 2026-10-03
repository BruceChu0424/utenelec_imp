import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/features/production/models/production_daily_report_create_request.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import '../../shared/drafts/memory_form_draft_storage.dart';

final _scope = StateProvider<AuthenticatedScope>(
  (_) => const AuthenticatedScope(userId: 'original-user'),
);
final _server = StateProvider<String>((_) => 'https://original.invalid/api');

class _Storage extends MemoryFormDraftStorage {
  int casCalls = 0;
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) {
    casCalls++;
    return super.compareAndSet(key, expectedValue: expectedValue, value: value);
  }
}

Future<
  ({
    ProviderContainer container,
    _Storage storage,
    FormDraft draft,
    FrozenDailyReportCreate command,
  })
>
_setup() async {
  final storage = _Storage();
  final container = ProviderContainer(
    overrides: [
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      currentPermissionsProvider.overrideWithValue({
        Perm.productionDailyReportCreate,
        Perm.productionDailyReportView,
      }),
      formDraftStorageProvider.overrideWithValue(storage),
    ],
  );
  final command = FrozenDailyReportCreate.capture(
    server: 'https://original.invalid/api',
    userId: 'original-user',
    actorId: null,
    body: {
      'idempotencyKey': 'original-create-operation',
      'billDate': '2026-10-02',
      'items': [
        {
          'goodsId': '00000000-0000-0000-0000-000000000001',
          'qty': 37,
          'unitRate': 1,
        },
      ],
    },
  );
  final store = container.read(formDraftsProvider.notifier);
  await store.ready;
  final draft = await store.save(
    FormDraft(
      id: 'rejected-draft',
      title: '原输入',
      module: BadgeModule.workshop,
      route: '/production/daily-reports/new',
      permission: Perm.productionDailyReportCreate,
      draftKind: 'productionDailyReport',
      updatedAt: DateTime.utc(2026, 10, 2),
      data: {
        'rows': [
          {'qty': '37', 'note': 'original'},
        ],
        'attachments': {
          'items': [
            {'name': 'original.txt', 'bytes': 'AQID'},
          ],
        },
        dailyReportCreateCommandKey: command.toJson(),
        dailyReportCreateStateKey: 'UNKNOWN',
        formDraftUnknownSubmissionKey: true,
        '_formDraftSubmissionPending': true,
      },
    ),
  );
  return (
    container: container,
    storage: storage,
    draft: draft,
    command: command,
  );
}

void main() {
  test(
    'receipt422 and unknown responses cannot release original protocol; generic save still preserves it',
    () async {
      final env = await _setup();
      addTearDown(env.container.dispose);
      final store = env.container.read(formDraftsProvider.notifier);
      final projected = env.container.read(formDraftsProvider).single;
      final ordinary = FormDraft.fromJson({
        ...projected.toJson(),
        'data': {...projected.data}..remove(dailyReportCreateCommandKey),
      });
      final saved = await store.save(
        ordinary,
        expectedRevision: env.draft.revision,
      );
      expect(saved.data[dailyReportCreateCommandKey], env.command.toJson());
      final original = Map<String, String>.from(env.storage.records),
          calls = env.storage.casCalls;
      for (final outcome in [(422, true), (500, false), (403, false)]) {
        await expectLater(
          store.releaseRejectedDailyReportCreate(
            saved.id,
            expectedRevision: saved.revision,
            expectedOperationKey: env.command.idempotencyKey,
            expectedBodyHash: env.command.bodyHash,
            httpStatus: outcome.$1,
            createAcknowledged: outcome.$2,
          ),
          throwsStateError,
        );
        expect(env.storage.records, original);
        expect(env.storage.casCalls, calls);
      }
    },
  );
  test(
    'stale or foreign rejection cannot clear another operation, revision, actor, server or created parent',
    () async {
      for (final mismatch in [
        'key',
        'body',
        'revision',
        'user',
        'actor',
        'server',
        'created',
      ]) {
        final env = await _setup();
        try {
          if (mismatch == 'user') {
            env.container.read(_scope.notifier).state =
                const AuthenticatedScope(userId: 'other-user');
          }
          if (mismatch == 'actor') {
            env.container
                .read(_scope.notifier)
                .state = const AuthenticatedScope(
              userId: 'original-user',
              actorId: 'other-actor',
            );
          }
          if (mismatch == 'server') {
            env.container.read(_server.notifier).state =
                'https://other.invalid/api';
          }
          if (mismatch == 'created') {
            final key = env.storage.records.keys.single;
            final record = Map<String, dynamic>.from(
              jsonDecode(env.storage.records[key]!) as Map,
            );
            (record['data'] as Map)['createdReportId'] = 'already-created';
            env.storage.records[key] = jsonEncode(record);
          }
          final store = env.container.read(formDraftsProvider.notifier);
          await store.ready;
          final original = Map<String, String>.from(env.storage.records),
              calls = env.storage.casCalls;
          await expectLater(
            store.releaseRejectedDailyReportCreate(
              env.draft.id,
              expectedRevision: mismatch == 'revision'
                  ? 'stale'
                  : env.draft.revision,
              expectedOperationKey: mismatch == 'key'
                  ? 'other-operation'
                  : env.command.idempotencyKey,
              expectedBodyHash: mismatch == 'body'
                  ? '0' * 64
                  : env.command.bodyHash,
              httpStatus: 422,
              createAcknowledged: false,
            ),
            throwsA(anyOf(isA<FormDraftConflict>(), isA<StateError>())),
          );
          expect(env.storage.records, original);
          expect(env.storage.casCalls, calls);
        } finally {
          env.container.dispose();
        }
      }
    },
  );
}
