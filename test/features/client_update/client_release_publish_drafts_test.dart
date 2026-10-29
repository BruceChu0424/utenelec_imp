import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/client_update/client_release_publish_drafts.dart';
import 'package:uten_imp/features/client_update/client_release_publish_queue.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

class _Storage implements FormDraftStorage {
  final values = <String, String>{};
  bool reject = false;
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<Map<String, String>> readAll(String prefix) async => Map.fromEntries(
    values.entries.where((entry) => entry.key.startsWith(prefix)),
  );
  @override
  Future<void> remove(String key) async => values.remove(key);
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (reject || values[key] != expectedValue) return false;
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }
}

const _owner = AuthenticatedScope(
  userId: 'publisher',
  epoch: 1,
  businessDatasetId: 'dataset-a',
);
Map<String, dynamic> _snapshot() => {
  'schemaVersion': 1,
  'rows': [
    ClientReleaseQueueItem(
      localId: '12345678-1234-1234-1234-123456789012',
      metadata: const ClientReleasePublishMetadata(
        version: '2.5.34',
        buildNumber: '2534',
      ),
      file: ClientReleasePickedFile.bytes(
        'uten.zip',
        Uint8List.fromList([1, 2, 3]),
      ),
    ).toDraft(),
  ],
  'withdrawals': <Map<String, dynamic>>[],
  formDraftUnknownSubmissionKey: false,
};
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Storage storage;
  late ClientReleasePublishDraftLease lease;
  setUp(() {
    storage = _Storage();
    lease = ClientReleasePublishDraftLease(
      storage: storage,
      server: 'https://company.example/api',
      owner: _owner,
    );
  });

  test(
    'metadata draft preserves only owning namespace, and file bytes never serialize',
    () async {
      final snapshot = _snapshot();
      await lease.save(snapshot);
      final raw = storage.values[lease.key]!;
      final draft = FormDraft.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      expect(draft.route, clientReleasePublishRoute);
      expect(draft.draftKind, clientReleasePublishDraftKind);
      expect(raw, isNot(contains('Uint8List')));
      expect(raw, isNot(contains('openRead')));
      expect(raw, isNot(contains('accessToken')));
      final other = ClientReleasePublishDraftLease(
        storage: storage,
        server: 'https://other.example/api',
        owner: _owner,
        draftId: lease.id,
      );
      expect(other.key, isNot(lease.key));
      expect(await other.load(), isNull);
      final ownerB = ClientReleasePublishDraftLease(
        storage: storage,
        server: 'https://company.example/api',
        owner: const AuthenticatedScope(
          userId: 'publisher',
          epoch: 2,
          businessDatasetId: 'dataset-b',
        ),
        draftId: lease.id,
      );
      expect(ownerB.key, isNot(lease.key));
      expect(await ownerB.load(), isNull);
    },
  );

  test(
    'local lease can preserve original owner metadata after UI owner retires',
    () async {
      final snapshot = _snapshot();
      await lease.save(snapshot);
      (snapshot['rows'] as List).clear();
      snapshot['context'] = const ClientReleasePublishMetadata(
        version: '2.5.35',
      ).toJson();
      // Saving has no current-auth argument: this capability is only original-key
      // local preservation. It cannot authorize requests or move to the new key.
      await lease.save(snapshot);
      expect(storage.values.keys, [lease.key]);
      expect(
        FormDraft.fromJson(
          jsonDecode(storage.values[lease.key]!) as Map<String, dynamic>,
        ).data['context'],
        snapshot['context'],
      );
      await expectLater(
        lease.discard(isCurrent: () => false),
        throwsStateError,
      );
      expect(storage.values[lease.key], isNotNull);
    },
  );

  test('CAS conflict preserves competing metadata without overwrite', () async {
    await lease.save(_snapshot());
    storage.values[lease.key] = 'competing-record';
    await expectLater(
      lease.save(_snapshot()),
      throwsA(isA<FormDraftConflict>()),
    );
    expect(storage.values[lease.key], 'competing-record');
  });

  test(
    'explicit discard uses CAS and cannot be resurrected by late dispose save',
    () async {
      await lease.save(_snapshot());
      await lease.discard(isCurrent: () => true);
      expect(storage.values[lease.key], isNull);
      await expectLater(lease.save(_snapshot()), throwsStateError);
      expect(storage.values[lease.key], isNull);
    },
  );

  test('unknown mutation prevents discard even after lease reload', () async {
    final snapshot = _snapshot();
    final row = Map<String, dynamic>.from(
      (snapshot['rows'] as List).single as Map,
    );
    row['requestId'] = 'abcdef12-1234-1234-1234-123456789012';
    row['pendingOperation'] = 'publish';
    row['stage'] = 'unknown';
    snapshot['rows'] = [row];
    snapshot[formDraftUnknownSubmissionKey] = true;
    await lease.save(snapshot);
    final resumed = ClientReleasePublishDraftLease(
      storage: storage,
      server: 'https://company.example/api',
      owner: _owner,
      draftId: lease.id,
    );
    expect((await resumed.load())!.hasUnknownSubmission, isTrue);
    await expectLater(
      resumed.discard(isCurrent: () => true),
      throwsA(isA<FormDraftUnknownSubmission>()),
    );
    expect(storage.values[lease.key], isNotNull);
  });

  test('unknown marker cannot be removed from pending row', () {
    final snapshot = _snapshot();
    final row = Map<String, dynamic>.from(
      (snapshot['rows'] as List).single as Map,
    );
    row['pendingOperation'] = 'prepare';
    row['stage'] = 'unknown';
    snapshot['rows'] = [row];
    expect(() => lease.save(snapshot), throwsFormatException);
  });

  for (final location in ['row', 'metadata', 'context', 'withdrawal']) {
    test('metadata-only allowlist rejects secrets in $location', () {
      final snapshot = _snapshot();
      if (location == 'row') {
        final row = Map<String, dynamic>.from(
          (snapshot['rows'] as List).single as Map,
        );
        row['localPath'] = 'C:/secret/package.zip';
        snapshot['rows'] = [row];
      } else if (location == 'metadata') {
        final row = Map<String, dynamic>.from(
          (snapshot['rows'] as List).single as Map,
        );
        row['metadata'] = {
          ...Map<String, dynamic>.from(row['metadata'] as Map),
          'accessToken': 'secret',
        };
        snapshot['rows'] = [row];
      } else if (location == 'context') {
        snapshot['context'] = {
          ...const ClientReleasePublishMetadata().toJson(),
          'bytes': [1, 2, 3],
        };
      } else {
        snapshot['withdrawals'] = [
          {
            'id': 'abcdef12-1234-1234-1234-123456789012',
            'state': 'unknown',
            'password': 'secret',
          },
        ];
      }
      expect(() => lease.save(snapshot), throwsFormatException);
      expect(storage.values, isEmpty);
    });
  }

  test(
    'failed resume identity validation cannot overwrite another draft kind',
    () async {
      await lease.save(_snapshot());
      final raw =
          jsonDecode(storage.values[lease.key]!) as Map<String, dynamic>;
      raw['draftKind'] = 'other-workspace';
      final original = jsonEncode(raw);
      storage.values[lease.key] = original;
      final resumed = ClientReleasePublishDraftLease(
        storage: storage,
        server: 'https://company.example/api',
        owner: _owner,
        draftId: lease.id,
      );
      await expectLater(resumed.load(), throwsFormatException);
      await expectLater(resumed.save(_snapshot()), throwsFormatException);
      expect(storage.values[lease.key], original);
    },
  );

  test(
    'parallel new lease cannot overwrite existing draft without resume',
    () async {
      await lease.save(_snapshot());
      final duplicate = ClientReleasePublishDraftLease(
        storage: storage,
        server: 'https://company.example/api',
        owner: _owner,
      );
      // A fresh unique lease has its own key; external collision remains CAS protected.
      storage.reject = true;
      await expectLater(
        duplicate.save(_snapshot()),
        throwsA(isA<FormDraftConflict>()),
      );
      expect(storage.values.length, 1);
    },
  );

  test(
    'impersonated and read-only contexts never acquire publishing lease',
    () {
      expect(
        () => ClientReleasePublishDraftLease(
          storage: storage,
          server: 'https://company.example',
          owner: const AuthenticatedScope(
            userId: 'publisher',
            actorId: 'actor',
          ),
        ),
        throwsStateError,
      );
      expect(
        () => ClientReleasePublishDraftLease(
          storage: storage,
          server: 'https://company.example',
          owner: const AuthenticatedScope(userId: 'publisher', readOnly: true),
        ),
        throwsStateError,
      );
    },
  );
}
