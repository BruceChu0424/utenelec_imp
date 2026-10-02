import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_history_projection.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

const _server = 'https://daily-history/api';
const _owner = AuthenticatedScope(userId: 'owner');
final _scope = StateProvider<AuthenticatedScope?>((_) => _owner);
final _backend = StateProvider<String>((_) => _server);
final _permissions = StateProvider<Set<String>>(
  (_) => {Perm.productionDailyReportView},
);
String get _prefix => formDraftStoragePrefix(_server, _owner);
String get _key => '${_prefix}daily-1';

Map<String, dynamic> _command() {
  final body = jsonEncode({
    'idempotencyKey': 'daily-key-123',
    'remark': 'PRIVATE-BODY',
    'qty': '1.',
  });
  return {
    'schema': 1,
    'bodyJson': body,
    'bodyHash': sha256.convert(utf8.encode(body)).toString(),
    'server': _server,
    'userId': _owner.userId,
    'actorId': null,
    'idempotencyKey': 'daily-key-123',
    'requestHash': sha256
        .convert(utf8.encode('native-request-fixture'))
        .toString(),
    'fullPayloadHash': sha256
        .convert(utf8.encode('full-request-fixture'))
        .toString(),
  };
}

Map<String, dynamic> _receipt([Map<String, dynamic>? original]) {
  final frozen = original ?? _command();
  return {
    'status': 'COMMITTED',
    'fullPayloadVersion': 1,
    'reportId': 'report-1',
    for (final key in ['idempotencyKey', 'requestHash', 'fullPayloadHash'])
      key: frozen[key],
  };
}

FormDraft _draft({
  Map<String, dynamic>? command,
  Map<String, dynamic>? extra,
}) => FormDraft(
  id: 'daily-1',
  title: 'PRIVATE-TITLE',
  module: BadgeModule.workshop,
  route: '/production/daily-reports/new',
  permission: Perm.productionDailyReportCreate,
  draftKind: 'productionDailyReport',
  updatedAt: DateTime.utc(2026, 10),
  revision: 'r1',
  data: {
    'rows': [
      {'qty': '1.', 'price': 'PRIVATE-PRICE', 'phone': 'PRIVATE-PHONE'},
    ],
    'attachments': {
      'items': [
        {
          'filename': 'PRIVATE-FILE.pdf',
          'bytes': [0, 127, 255],
        },
      ],
    },
    dailyReportCreateCommandKey: command ?? _command(),
    dailyReportCreateStateKey: 'UNKNOWN',
    formDraftUnknownSubmissionKey: true,
    ...?extra,
  },
);

class _ControlledStorage implements FormDraftStorage, FormDraftHistoryStorage {
  _ControlledStorage(this.storage);
  final NativeFormDraftStorage storage;
  bool rejectCas = false;
  int casAttempts = 0;
  int readAttempts = 0;
  int historyReadAttempts = 0;
  Completer<void>? readGate;
  Completer<void>? readStarted;
  Completer<void>? casGate;
  Completer<void>? casCommitted;
  @override
  Future<String?> read(String key) async {
    readAttempts++;
    final value = await storage.read(key);
    if (readStarted case final started? when !started.isCompleted) {
      started.complete();
    }
    await readGate?.future;
    return value;
  }

  @override
  Future<Map<String, String>> readAll(String prefix) => storage.readAll(prefix);
  @override
  Future<void> write(String key, String value) => storage.write(key, value);
  @override
  Future<void> remove(String key) => storage.remove(key);
  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    casAttempts++;
    if (rejectCas) return false;
    final written = await storage.compareAndSet(
      key,
      expectedValue: expectedValue,
      value: value,
    );
    if (casCommitted case final committed? when !committed.isCompleted) {
      committed.complete();
    }
    await casGate?.future;
    return written;
  }

  @override
  Future<FormDraftHistoryPage> readHistoryPage(
    String prefix, {
    String? before,
    int limit = 30,
  }) {
    historyReadAttempts++;
    return storage.readHistoryPage(prefix, before: before, limit: limit);
  }

  @override
  Future<FormDraftHistoryRecord?> readHistoryRecord(String prefix, String id) {
    historyReadAttempts++;
    return storage.readHistoryRecord(prefix, id);
  }
}

class _FailedReadinessStorage extends _ControlledStorage {
  _FailedReadinessStorage(super.storage);
  final started = Completer<void>();
  final result = Completer<Map<String, String>>();
  @override
  Future<Map<String, String>> readAll(String prefix) {
    started.complete();
    return result.future;
  }
}

ProviderContainer _container(
  _ControlledStorage storage, {
  bool writable = false,
  bool readOnly = false,
}) {
  final container = ProviderContainer(
    overrides: [
      formDraftStorageProvider.overrideWithValue(storage),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_backend)),
      currentPermissionsProvider.overrideWith((ref) => ref.watch(_permissions)),
    ],
  );
  container.read(_scope.notifier).state = AuthenticatedScope(
    userId: _owner.userId,
    readOnly: readOnly,
  );
  container.read(_permissions.notifier).state = {
    Perm.productionDailyReportView,
    if (writable) Perm.productionDailyReportCreate,
  };
  addTearDown(container.dispose);
  return container;
}

void main() {
  late Directory directory;
  late NativeFormDraftStorage disk;
  late _ControlledStorage storage;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('uten-daily-history-');
    disk = NativeFormDraftStorage(directoryProvider: () async => directory);
    storage = _ControlledStorage(disk);
  });
  tearDown(() async {
    expect(
      directory.absolute.path.startsWith(Directory.systemTemp.absolute.path),
      isTrue,
    );
    await directory.delete(recursive: true);
  });

  test(
    'view-only authority confirms proof, preserves original and adds one history revision',
    () async {
      final original = _draft();
      await disk.write(
        _key,
        jsonEncode({
          ...original.toJson(),
          'lifecycle': 'ACTIVE',
          'preservedEnvelope': 'original',
        }),
      );
      final first = (await disk.readHistoryPage(_prefix)).entries.single;
      final preimageFile = File(
        '${directory.path}/history_v2/$_prefix/payload/0/${first.id}.json',
      );
      final preimageSha = sha256.convert(await preimageFile.readAsBytes());
      final container = _container(storage);
      final notifier = container.read(formDraftsProvider.notifier);
      await notifier.ready;
      expect(
        jsonEncode(container.read(formDraftsProvider).single.toJson()),
        isNot(contains('PRIVATE')),
      );
      await expectLater(
        notifier.save(original, expectedRevision: 'r1'),
        throwsStateError,
      );
      await expectLater(
        notifier.delete(original.id, expectedRevision: 'r1'),
        throwsStateError,
      );
      await expectLater(
        notifier.complete(original.id, expectedRevision: 'r1'),
        throwsStateError,
      );
      final confirmed = await notifier.confirmDailyReportCreateRecovery(
        original.id,
        expectedRevision: 'r1',
        receipt: _receipt(),
      );
      expect(
        confirmed.data[dailyReportCreateCommandKey],
        original.data[dailyReportCreateCommandKey],
      );
      expect(confirmed.data['rows'], original.data['rows']);
      expect(confirmed.data['attachments'], original.data['attachments']);
      expect(confirmed.data['createdReportId'], 'report-1');
      expect(confirmed.hasUnknownSubmission, isFalse);
      expect(
        (jsonDecode((await disk.read(_key))!) as Map)['preservedEnvelope'],
        'original',
      );
      expect(
        sha256.convert(await preimageFile.readAsBytes()).toString(),
        preimageSha.toString(),
      );
      expect(
        (await disk.readHistoryRecord(_prefix, first.id))!.draft.data,
        original.data,
      );
      expect((await disk.readHistoryPage(_prefix)).entries, hasLength(2));
      expect(storage.casAttempts, 1);
      expect(
        jsonEncode(container.read(formDraftsProvider).single.toJson()),
        isNot(contains('PRIVATE')),
      );
    },
  );

  for (final failure in ['stale', 'cas']) {
    test(
      '$failure confirmation creates no checkpoint or phantom history',
      () async {
        final original = jsonEncode(_draft().toJson());
        await disk.write(_key, original);
        final container = _container(storage);
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        storage.rejectCas = failure == 'cas';
        await expectLater(
          notifier.confirmDailyReportCreateRecovery(
            'daily-1',
            expectedRevision: failure == 'stale' ? 'old' : 'r1',
            receipt: _receipt(),
          ),
          throwsA(isA<FormDraftConflict>()),
        );
        expect(await disk.read(_key), original);
        expect((await disk.readHistoryPage(_prefix)).entries, hasLength(1));
        expect(
          container.read(formDraftsProvider).single.data['createdReportId'],
          isNull,
        );
      },
    );
  }

  test(
    'simulated readonly identity reads typed history but cannot read or confirm original command',
    () async {
      await disk.write(_key, jsonEncode(_draft().toJson()));
      final container = _container(storage, readOnly: true);
      final notifier = container.read(formDraftsProvider.notifier);
      await notifier.ready;
      expect(container.read(formDraftsProvider), isEmpty);
      expect((await notifier.historyPage()).entries, hasLength(1));
      final history = await notifier.readHistory('1');
      expect(history, isNotNull);
      expect(jsonEncode(history!.draft.toJson()), isNot(contains('bodyJson')));
      expect(
        projectFormDraftHistory(history.draft, {
          Perm.productionDailyReportView,
        })!.sections,
        isEmpty,
      );
      await expectLater(
        notifier.readDailyReportCreateRecovery('daily-1'),
        throwsStateError,
      );
      await expectLater(
        notifier.confirmDailyReportCreateRecovery(
          'daily-1',
          expectedRevision: 'r1',
          receipt: _receipt(),
        ),
        throwsStateError,
      );
      expect(storage.casAttempts, 0);
      expect((await disk.readHistoryPage(_prefix)).entries, hasLength(1));
    },
  );

  for (final readOnly in [false, true]) {
    test(
      'sales view without create retains history quantity and removes protocol; simulatedReadonly=$readOnly',
      () async {
        final sales = FormDraft(
          id: 'sales-1',
          title: 'PRIVATE-SALES-TITLE',
          module: BadgeModule.sales,
          route: '/sales/orders/new',
          permission: Perm.salesOrderCreate,
          updatedAt: DateTime.utc(2026, 10),
          revision: 'sales-r1',
          data: {
            'rows': [
              {
                'text': {'qty': '7.', 'price': 'PRIVATE-PRICE'},
              },
            ],
            dailyReportCreateCommandKey: _command(),
            'phone': 'PRIVATE-PHONE',
            'extension': {'value': 'PRIVATE-EXTENSION'},
            'attachments': [
              {
                'filename': 'PRIVATE-FILE',
                'bytes': [0, 255],
              },
            ],
          },
        );
        await disk.write('${_prefix}sales-1', jsonEncode(sales.toJson()));
        final container = _container(storage, readOnly: readOnly);
        container.read(_permissions.notifier).state = {Perm.salesOrderView};
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        final history = await notifier.readHistory('1');
        expect(history, isNotNull);
        expect(history!.draft.title, isNot(contains('PRIVATE')));
        final row = (history.draft.data['rows'] as List).single as Map;
        expect((row['text'] as Map)['qty'], '7.');
        expect((row['text'] as Map).containsKey('price'), isFalse);
        expect(
          history.draft.data[formDraftHistoryReadOnlyProjectionKey],
          isTrue,
        );
        expect(jsonEncode(history.draft.toJson()), isNot(contains('PRIVATE')));
        expect(
          (await disk.readHistoryRecord(_prefix, '1'))!.draft.data,
          sales.data,
        );
        expect(jsonEncode(history.draft.toJson()), isNot(contains('bodyJson')));
        final projection = projectFormDraftHistory(history.draft, {
          Perm.salesOrderView,
        })!;
        final fields = projection.sections.expand((section) => section.fields);
        expect(
          fields.any((field) => field.label == '数量' && field.value == '7.'),
          isTrue,
        );
        expect(fields.any((field) => field.value.contains('PRIVATE')), isFalse);
      },
    );
  }

  for (final lifecycle in [
    'COMPLETED',
    'DISCARDED',
    'SUBMITTED',
    'DELETED',
    'ARCHIVED',
  ]) {
    test(
      '$lifecycle rejects raw recovery, confirmation and ordinary resurrection',
      () async {
        await disk.write(
          _key,
          jsonEncode({
            ..._draft().toJson(),
            if (lifecycle == 'COMPLETED')
              'completed': true
            else
              'lifecycle': lifecycle,
          }),
        );
        final container = _container(storage, writable: true);
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        final before = await disk.read(_key);
        final count = (await disk.readHistoryPage(_prefix)).entries.length;
        expect(container.read(formDraftsProvider), isEmpty);
        expect(await notifier.readDailyReportCreateRecovery('daily-1'), isNull);
        await expectLater(
          notifier.confirmDailyReportCreateRecovery(
            'daily-1',
            expectedRevision: 'r1',
            receipt: _receipt(),
          ),
          throwsA(isA<FormDraftConflict>()),
        );
        await expectLater(
          notifier.save(_draft(), expectedRevision: 'r1'),
          throwsA(isA<FormDraftConflict>()),
        );
        expect(await disk.read(_key), before);
        expect((await disk.readHistoryPage(_prefix)).entries.length, count);
        expect(storage.casAttempts, 0);
      },
    );
  }

  for (final writable in [false, true]) {
    test(
      'public projections never contain protocol bodyJson; create=$writable',
      () async {
        await disk.write(_key, jsonEncode(_draft().toJson()));
        final container = _container(storage, writable: writable);
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        expect(
          jsonEncode(container.read(formDraftsProvider).single.toJson()),
          isNot(contains('bodyJson')),
        );
        expect(
          (await notifier.readDailyReportCreateRecovery(
            'daily-1',
          ))!.data[dailyReportCreateCommandKey],
          _command(),
        );
        if (writable) {
          final history = await notifier.readHistory('1');
          expect(history, isNotNull);
          expect(
            jsonEncode(history!.draft.toJson()),
            isNot(contains('bodyJson')),
          );
        }
      },
    );
  }

  for (final malformed in [
    'command-string',
    'command-list',
    'nested-proof',
    'receipt-string',
  ]) {
    test(
      'malformed $malformed cannot reappear in public protocol projection',
      () async {
        final data = <String, dynamic>{
          dailyReportCreateCommandKey: switch (malformed) {
            'command-string' => 'PRIVATE-MALFORMED',
            'command-list' => [
              {'bodyJson': 'PRIVATE-MALFORMED'},
            ],
            _ => {
              ..._command(),
              'bodyHash': {'price': 'PRIVATE-MALFORMED'},
            },
          },
          dailyReportCreateReceiptKey: malformed == 'receipt-string'
              ? 'PRIVATE-MALFORMED'
              : {
                  'requestHash': {'phone': 'PRIVATE-MALFORMED'},
                  'fullPayloadVersion': {'version': 'PRIVATE-MALFORMED'},
                  'bodyJson': 'PRIVATE-MALFORMED',
                },
        };
        await disk.write(_key, jsonEncode(_draft(extra: data).toJson()));
        final container = _container(storage, writable: true);
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        final visible = jsonEncode(
          container.read(formDraftsProvider).single.toJson(),
        );
        expect(visible, isNot(contains('PRIVATE-MALFORMED')));
        expect(visible, isNot(contains('bodyJson')));
      },
    );
  }

  for (final field in ['server', 'userId', 'actorId', 'schema']) {
    test(
      'frozen $field mismatch denies private read and receipt confirmation',
      () async {
        final command = _command()
          ..[field] = field == 'schema' ? 2 : 'other-owner';
        await disk.write(_key, jsonEncode(_draft(command: command).toJson()));
        final container = _container(storage);
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        expect(await notifier.readDailyReportCreateRecovery('daily-1'), isNull);
        await expectLater(
          notifier.confirmDailyReportCreateRecovery(
            'daily-1',
            expectedRevision: 'r1',
            receipt: _receipt(command),
          ),
          throwsStateError,
        );
        expect((await disk.readHistoryPage(_prefix)).entries, hasLength(1));
        expect(storage.casAttempts, 0);
      },
    );
  }

  for (final field in ['idempotencyKey', 'requestHash', 'fullPayloadHash']) {
    test('null $field cannot satisfy receipt proof by matching null', () async {
      final command = _command()..[field] = null;
      await disk.write(_key, jsonEncode(_draft(command: command).toJson()));
      final notifier = _container(storage).read(formDraftsProvider.notifier);
      await notifier.ready;
      await expectLater(
        notifier.confirmDailyReportCreateRecovery(
          'daily-1',
          expectedRevision: 'r1',
          receipt: _receipt(command),
        ),
        throwsStateError,
      );
      expect(storage.casAttempts, 0);
      expect((await disk.readHistoryPage(_prefix)).entries, hasLength(1));
    });
  }

  for (final change in ['server', 'actor', 'permission']) {
    test(
      '$change change during original read prevents a late metadata CAS',
      () async {
        final original = jsonEncode(_draft().toJson());
        await disk.write(_key, original);
        final container = _container(storage);
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        storage.readGate = Completer<void>();
        storage.readStarted = Completer<void>();
        final confirming = notifier.confirmDailyReportCreateRecovery(
          'daily-1',
          expectedRevision: 'r1',
          receipt: _receipt(),
        );
        final assertion = expectLater(confirming, throwsStateError);
        await storage.readStarted!.future;
        switch (change) {
          case 'server':
            container.read(_backend.notifier).state = 'https://other/api';
          case 'actor':
            container.read(_scope.notifier).state = const AuthenticatedScope(
              userId: 'owner',
              actorId: 'other',
            );
          case 'permission':
            container.read(_permissions.notifier).state = {};
        }
        container.read(formDraftsProvider);
        storage.readGate!.complete();
        await assertion;
        // Rebuilding for a new server/actor starts its own native readAll.
        // Its scope lock must finish before the container and temp files go.
        await container.read(formDraftsProvider.notifier).ready;
        expect(await disk.read(_key), original);
        expect((await disk.readHistoryPage(_prefix)).entries, hasLength(1));
        expect(storage.casAttempts, 0);
      },
    );
  }

  test(
    'legacy UNKNOWN without original proof remains unresolved and unchanged',
    () async {
      final record = _draft().toJson();
      (record['data'] as Map).remove(dailyReportCreateCommandKey);
      final original = jsonEncode(record);
      await disk.write(_key, original);
      final notifier = _container(storage).read(formDraftsProvider.notifier);
      await notifier.ready;
      expect(await notifier.readDailyReportCreateRecovery('daily-1'), isNull);
      await expectLater(
        notifier.confirmDailyReportCreateRecovery(
          'daily-1',
          expectedRevision: 'r1',
          receipt: _receipt(),
        ),
        throwsStateError,
      );
      expect(await disk.read(_key), original);
      expect((await disk.readHistoryPage(_prefix)).entries, hasLength(1));
      expect(storage.casAttempts, 0);
    },
  );

  for (final malformed in ['body-json', 'body-key', 'version-type']) {
    test(
      'malformed $malformed proof cannot confirm metadata despite matching outer values',
      () async {
        final command = _command();
        if (malformed != 'version-type') {
          command['bodyJson'] = malformed == 'body-json'
              ? '{'
              : jsonEncode({'idempotencyKey': 'another-key'});
          command['bodyHash'] = sha256
              .convert(utf8.encode(command['bodyJson'] as String))
              .toString();
        }
        await disk.write(_key, jsonEncode(_draft(command: command).toJson()));
        final notifier = _container(storage).read(formDraftsProvider.notifier);
        await notifier.ready;
        final receipt = _receipt(command);
        if (malformed == 'version-type') receipt['fullPayloadVersion'] = 1.0;
        await expectLater(
          notifier.confirmDailyReportCreateRecovery(
            'daily-1',
            expectedRevision: 'r1',
            receipt: receipt,
          ),
          throwsStateError,
        );
        expect(storage.casAttempts, 0);
        expect((await disk.readHistoryPage(_prefix)).entries, hasLength(1));
      },
    );
  }

  for (final change in ['actor', 'permission']) {
    test(
      'late $change after committed CAS cannot return old raw data to a new context',
      () async {
        await disk.write(_key, jsonEncode(_draft().toJson()));
        final container = _container(storage);
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        storage.casGate = Completer<void>();
        storage.casCommitted = Completer<void>();
        final confirming = notifier.confirmDailyReportCreateRecovery(
          'daily-1',
          expectedRevision: 'r1',
          receipt: _receipt(),
        );
        final assertion = expectLater(confirming, throwsStateError);
        await storage.casCommitted!.future;
        if (change == 'actor') {
          container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'owner',
            actorId: 'another',
          );
        } else {
          container.read(_permissions.notifier).state = {};
        }
        container.read(formDraftsProvider);
        storage.casGate!.complete();
        await assertion;
        await container.read(formDraftsProvider.notifier).ready;
        expect(container.read(formDraftsProvider), isEmpty);
        final persisted =
            jsonDecode((await disk.read(_key))!) as Map<String, dynamic>;
        expect((persisted['data'] as Map)['createdReportId'], 'report-1');
        expect((await disk.readHistoryPage(_prefix)).entries, hasLength(2));
      },
    );
  }

  for (final omitCommand in [false, true]) {
    test(
      'saving public projection retains private frozen body and files; omitCommand=$omitCommand',
      () async {
        final original = _draft();
        await disk.write(_key, jsonEncode(original.toJson()));
        final container = _container(storage, writable: true);
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        final public = container.read(formDraftsProvider).single;
        expect(jsonEncode(public.toJson()), isNot(contains('bodyJson')));
        final data = Map<String, dynamic>.from(public.data);
        if (omitCommand) data.remove(dailyReportCreateCommandKey);
        await notifier.save(
          FormDraft.fromJson({...public.toJson(), 'data': data}),
          expectedRevision: public.revision,
        );
        final restored = await notifier.readDailyReportCreateRecovery(
          public.id,
        );
        expect(
          restored!.data[dailyReportCreateCommandKey],
          original.data[dailyReportCreateCommandKey],
        );
        expect(restored.data['attachments'], original.data['attachments']);
        expect(restored.data['rows'], original.data['rows']);
        expect((await disk.readHistoryPage(_prefix)).entries, hasLength(2));
        expect(
          jsonEncode(container.read(formDraftsProvider).single.toJson()),
          isNot(contains('bodyJson')),
        );
      },
    );
  }

  for (final field in [
    'idempotencyKey',
    'bodyJson',
    'bodyHash',
    'requestHash',
    'fullPayloadHash',
    'newOpaqueField',
  ]) {
    test('ordinary save cannot replace frozen command field $field', () async {
      final original = jsonEncode(_draft().toJson());
      await disk.write(_key, original);
      final container = _container(storage, writable: true);
      final notifier = container.read(formDraftsProvider.notifier);
      await notifier.ready;
      final public = container.read(formDraftsProvider).single;
      final proposed = Map<String, dynamic>.from(
        public.data[dailyReportCreateCommandKey] as Map,
      )..[field] = 'changed-original-proof';
      final changed = FormDraft.fromJson({
        ...public.toJson(),
        'data': {...public.data, dailyReportCreateCommandKey: proposed},
      });
      await expectLater(
        notifier.save(changed, expectedRevision: public.revision),
        throwsA(isA<FormDraftConflict>()),
      );
      expect(await disk.read(_key), original);
      expect((await disk.readHistoryPage(_prefix)).entries, hasLength(1));
      expect(storage.casAttempts, 0);
    });
  }

  test(
    'mismatched key and JSON id stays private and unchanged while healthy sibling remains readable',
    () async {
      final bad = jsonEncode({..._draft().toJson(), 'id': 'other-id'});
      await disk.write(_key, bad);
      await disk.write(
        '${_prefix}healthy',
        jsonEncode({..._draft().toJson(), 'id': 'healthy'}),
      );
      final container = _container(storage, writable: true);
      final notifier = container.read(formDraftsProvider.notifier);
      await notifier.ready;
      expect(container.read(formDraftsProvider).map((draft) => draft.id), [
        'healthy',
      ]);
      expect(await notifier.readDailyReportCreateRecovery('daily-1'), isNull);
      expect(
        (await notifier.readDailyReportCreateRecovery('healthy'))!.id,
        'healthy',
      );
      await expectLater(
        notifier.confirmDailyReportCreateRecovery(
          'daily-1',
          expectedRevision: 'r1',
          receipt: _receipt(),
        ),
        throwsA(isA<FormDraftConflict>()),
      );
      await expectLater(
        notifier.save(_draft(), expectedRevision: 'r1'),
        throwsA(isA<FormDraftConflict>()),
      );
      await expectLater(
        notifier.delete('daily-1', expectedRevision: 'r1'),
        throwsA(isA<FormDraftConflict>()),
      );
      await expectLater(
        notifier.complete('daily-1', expectedRevision: 'r1'),
        throwsA(isA<FormDraftConflict>()),
      );
      expect(await disk.read(_key), bad);
      expect(
        (await disk.readHistoryPage(_prefix)).entries.single.draftId,
        'healthy',
      );
      expect(storage.casAttempts, 0);
    },
  );

  test(
    'corrupt active JSON never embeds private source in visible recovery or mutation errors',
    () async {
      await disk.write(_key, jsonEncode(_draft().toJson()));
      final active = File(
        '${directory.path}/history_v2/$_prefix/active/$_key.json',
      );
      const damaged = '{"private":"PRIVATE-ERROR-SOURCE",';
      await active.writeAsString(damaged);
      final container = _container(storage, writable: true);
      final notifier = container.read(formDraftsProvider.notifier);
      await notifier.ready;
      expect(container.read(formDraftsProvider), isEmpty);
      final safeConflict = throwsA(
        predicate(
          (Object? error) =>
              error is FormDraftConflict &&
              !error.toString().contains('PRIVATE-ERROR-SOURCE'),
        ),
      );
      await expectLater(
        notifier.readDailyReportCreateRecovery('daily-1'),
        safeConflict,
      );
      await expectLater(
        notifier.confirmDailyReportCreateRecovery(
          'daily-1',
          expectedRevision: 'r1',
          receipt: _receipt(),
        ),
        safeConflict,
      );
      await expectLater(
        notifier.save(_draft(), expectedRevision: 'r1'),
        safeConflict,
      );
      await expectLater(
        notifier.delete('daily-1', expectedRevision: 'r1'),
        safeConflict,
      );
      await expectLater(
        notifier.complete('daily-1', expectedRevision: 'r1'),
        safeConflict,
      );
      expect(await active.readAsString(), damaged);
      expect(storage.casAttempts, 0);
    },
  );

  test(
    'corrupt transaction JSON makes readiness fail safely without echoing its retained body',
    () async {
      await disk.write(_key, jsonEncode(_draft().toJson()));
      final pending = File(
        '${directory.path}/history_v2/$_prefix/pending.json',
      );
      const damaged = '{"payload":"PRIVATE-WAL-SOURCE",';
      await pending.writeAsString(damaged);
      final notifier = _container(storage).read(formDraftsProvider.notifier);
      await expectLater(
        notifier.ready,
        throwsA(
          predicate(
            (Object? error) =>
                error is FormDraftConflict &&
                !error.toString().contains('PRIVATE-WAL-SOURCE'),
          ),
        ),
      );
      expect(await pending.readAsString(), damaged);
      expect(storage.casAttempts, 0);
    },
  );

  for (final marker in [true, false]) {
    test(
      'authorized creator cannot save a readonly history projection back; marker=$marker',
      () async {
        final original = _draft();
        final bytes = jsonEncode(original.toJson());
        await disk.write(_key, bytes);
        final container = _container(storage, writable: true);
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        final history = (await notifier.readHistory('1'))!.draft;
        expect(history.data[formDraftHistoryReadOnlyProjectionKey], isTrue);
        expect(jsonEncode(history.toJson()), isNot(contains('PRIVATE')));
        final copy = FormDraft.fromJson({
          ...history.toJson(),
          'data': {
            ...history.data,
            formDraftHistoryReadOnlyProjectionKey: marker,
          },
        });
        await expectLater(
          notifier.save(copy, expectedRevision: 'r1'),
          throwsA(
            predicate(
              (Object? error) =>
                  error is StateError && error.toString().contains('历史仅供查看'),
            ),
          ),
        );
        expect(await disk.read(_key), bytes);
        expect(
          (await disk.readHistoryRecord(_prefix, '1'))!.draft.data,
          original.data,
        );
        expect((await disk.readHistoryPage(_prefix)).entries, hasLength(1));
        expect(storage.casAttempts, 0);
      },
    );
  }

  test(
    'public history API reprojects current price authority without changing its original',
    () async {
      final original = FormDraft(
        id: 'sales-1',
        title: 'PRIVATE-TITLE',
        module: BadgeModule.sales,
        route: '/sales/orders/new',
        permission: Perm.salesOrderCreate,
        updatedAt: DateTime.utc(2026, 10),
        revision: 'sales-r1',
        data: {
          'rows': [
            {
              'text': {'qty': '3.', 'price': '345.67'},
            },
          ],
          'attachments': [
            {'filename': 'PRIVATE-FILE'},
          ],
        },
      );
      await disk.write('${_prefix}sales-1', jsonEncode(original.toJson()));
      final container = _container(storage);
      container.read(_permissions.notifier).state = {
        Perm.salesOrderView,
        Perm.salesOrderPriceView,
      };
      final notifier = container.read(formDraftsProvider.notifier);
      await notifier.ready;
      final granted = (await notifier.readHistory('1'))!.draft;
      expect(jsonEncode(granted.data), contains('345.67'));
      container.read(_permissions.notifier).state = {Perm.salesOrderView};
      container.read(formDraftsProvider);
      await notifier.ready;
      final revoked = (await notifier.readHistory('1'))!.draft;
      expect(jsonEncode(revoked.data), isNot(contains('345.67')));
      expect(jsonEncode(revoked.data), contains('3.'));
      expect(jsonEncode(revoked.toJson()), isNot(contains('PRIVATE')));
      container.read(_permissions.notifier).state = {};
      container.read(formDraftsProvider);
      await notifier.ready;
      expect(await notifier.readHistory('1'), isNull);
      expect(
        (await disk.readHistoryRecord(_prefix, '1'))!.draft.data,
        original.data,
      );
      expect(storage.casAttempts, 0);
    },
  );

  for (final action in ['private read', 'save', 'confirm']) {
    test(
      'disposed notifier rejects fresh $action without accessing its former owner',
      () async {
        final original = jsonEncode(_draft().toJson());
        await disk.write(_key, original);
        final container = _container(storage, writable: true);
        final notifier = container.read(formDraftsProvider.notifier);
        await notifier.ready;
        final reads = storage.readAttempts;
        final historyReads = storage.historyReadAttempts;
        container.dispose();
        final attempt = switch (action) {
          'private read' => notifier.readDailyReportCreateRecovery('daily-1'),
          'save' => notifier.save(_draft(), expectedRevision: 'r1'),
          _ => notifier.confirmDailyReportCreateRecovery(
            'daily-1',
            expectedRevision: 'r1',
            receipt: _receipt(),
          ),
        };
        await expectLater(attempt, throwsStateError);
        expect(notifier.ownerKey, isNull);
        expect((await notifier.historyPage()).entries, isEmpty);
        expect(await notifier.readHistory('1'), isNull);
        // Default revision lookup may reject synchronously after provider disposal.
        await expectLater(
          Future<void>.sync(() => notifier.delete('daily-1')),
          throwsStateError,
        );
        await expectLater(
          Future<void>.sync(() => notifier.complete('daily-1')),
          throwsStateError,
        );
        expect(storage.readAttempts, reads);
        expect(storage.historyReadAttempts, historyReads);
        expect(storage.casAttempts, 0);
        expect(await disk.read(_key), original);
        expect((await disk.readHistoryPage(_prefix)).entries, hasLength(1));
      },
    );
  }

  test(
    'disposed readiness failure is observed without an unhandled background error',
    () async {
      final uncaught = <Object>[];
      final drained = Completer<void>();
      var pendingMicrotasks = 0;
      var draining = false;
      late _FailedReadinessStorage failing;
      late ProviderContainer container;
      runZonedGuarded<void>(
        () {
          failing = _FailedReadinessStorage(disk);
          container = _container(failing);
          container.read(formDraftsProvider.notifier);
        },
        (error, _) => uncaught.add(error),
        zoneSpecification: ZoneSpecification(
          scheduleMicrotask: (self, parent, zone, task) {
            pendingMicrotasks++;
            parent.scheduleMicrotask(zone, () {
              try {
                task();
              } finally {
                pendingMicrotasks--;
                if (draining &&
                    pendingMicrotasks == 0 &&
                    !drained.isCompleted) {
                  drained.complete();
                }
              }
            });
          },
        ),
      );
      await failing.started.future;
      container.dispose();
      draining = true;
      failing.result.completeError(
        StateError('controlled readAll failure after dispose'),
      );
      // Wait for the entire guarded microtask queue, not a timed sleep. Deliberately
      // do not await/catch notifier.ready: its production background handler must
      // observe this error after the caller has gone away.
      await drained.future;
      expect(uncaught, isEmpty);
      expect(failing.casAttempts, 0);
    },
  );
}
