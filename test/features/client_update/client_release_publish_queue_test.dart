import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/client_update/client_release.dart';
import 'package:uten_imp/features/client_update/client_release_publish_queue.dart';

const _metadata = ClientReleasePublishMetadata(
  version: '2.5.34',
  buildNumber: '2534',
  releaseNotes: '本次更新',
);
ClientReleasePickedFile _file([
  String name = 'uten.zip',
  List<int> content = const [1, 2, 3],
]) => ClientReleasePickedFile.bytes(name, Uint8List.fromList(content));
Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

class _ListApi extends ApiClient {
  _ListApi(this.rows)
    : super(Dio(BaseOptions(baseUrl: 'https://fixture.test/api')));
  final List<Map<String, dynamic>> rows;
  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => rows;
}

class _Gateway implements ClientReleasePublishGateway {
  final records = <String, Map<String, dynamic>>{};
  final creates = <Map<String, dynamic>>[];
  final uploads = <String>[], publishes = <String>[], withdraws = <String>[];
  Future<void> Function(Map<String, dynamic>)? onCreate;
  Future<void> Function(String)? onUpload, onPublish, onWithdraw;
  Map<String, dynamic> Function(Map<String, dynamic>)? changeRead;
  @override
  Future<void> begin(bool Function() isCurrent) async {
    if (!isCurrent()) throw StateError('retired');
  }

  @override
  Future<Map<String, dynamic>> prepare(Map<String, dynamic> body) async {
    creates.add(_copy(body));
    await onCreate?.call(body);
    final id = body['requestId'] as String;
    final family = body['runtimeFamily'] ?? 'flutter';
    return _copy(
      records.putIfAbsent(
        id,
        () => {
          ...body,
          'id': id,
          'state': 'DRAFT',
          'runtimeFamily': family,
          'sha256': '',
          'sizeBytes': 0,
          'installMode': body['storeUrl'] != null
              ? 'store'
              : body['platform'] == 'android'
              ? 'android_package'
              : family == 'wpf_legacy'
              ? body['packageKind'] == 'installer'
                    ? 'windows_wpf_setup'
                    : 'windows_wpf_archive'
              : body['packageKind'] == 'installer'
              ? 'windows_setup'
              : 'windows_archive',
          'deliveryContract': body['platform'] == 'windows'
              ? 'paired_v1'
              : 'audited_v1',
        },
      ),
    );
  }

  @override
  Future<void> upload(
    String id,
    Uint8List bytes,
    void Function(int, int) onProgress,
  ) async {
    uploads.add(id);
    records[id]!['sha256'] = sha256.convert(bytes).toString();
    records[id]!['sizeBytes'] = bytes.length;
    onProgress(bytes.length, bytes.length);
    await onUpload?.call(id);
  }

  @override
  Future<Map<String, dynamic>> publish(String id) async {
    publishes.add(id);
    await onPublish?.call(id);
    records[id]!['state'] = 'PUBLISHED';
    return _copy(records[id]!);
  }

  @override
  Future<Map<String, dynamic>> read(String id) async {
    if (!records.containsKey(id)) {
      throw ApiException(
        'NOT_FOUND',
        '不存在',
        httpStatus: 404,
        hasResponseCode: true,
      );
    }
    final record = _copy(records[id]!);
    return changeRead?.call(record) ?? record;
  }

  @override
  Future<List<ClientRelease>> list() async =>
      records.values.map((row) => ClientRelease.fromJson(_copy(row))).toList();
  @override
  Future<Map<String, dynamic>> withdraw(String id) async {
    withdraws.add(id);
    records[id]!['state'] = 'WITHDRAWN';
    await onWithdraw?.call(id);
    return _copy(records[id]!);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Gateway api;
  late ClientReleasePublishQueue queue;
  late bool current;
  late List<Map<String, dynamic>> snapshots;
  setUp(() {
    api = _Gateway();
    current = true;
    snapshots = [];
    queue = ClientReleasePublishQueue(
      gateway: api,
      isCurrent: () => current,
      checkpoint: (snapshot) async {
        snapshots.add(_copy(snapshot));
      },
    );
  });
  tearDown(() => queue.dispose());

  test(
    'installer context mixed selection has exact format roles and no filename target inference',
    () async {
      queue.addFiles(
        [_file('windows-arm64-setup.exe'), _file('windows-x86.zip')],
        _metadata.copyWith(
          packageKind: 'installer',
          runtimeFamily: 'wpf_legacy',
        ),
      );
      expect(queue.items.map((r) => r.metadata.packageKind), [
        'installer',
        'update',
      ]);
      expect(
        queue.items.every((r) => r.metadata.architecture == 'x64'),
        isTrue,
      );
      await queue.run();
      expect(queue.confirmedCount, 2);
      expect(api.creates.length, 2);
      expect(api.uploads.length, 2);
      expect(api.publishes.length, 2);
      expect(
        api.creates.every((r) => r['runtimeFamily'] == 'wpf_legacy'),
        isTrue,
      );
      await queue.run();
      expect(api.publishes.length, 2);
      final encoded = jsonEncode(snapshots.last);
      expect(encoded, isNot(contains('bytes')));
      expect(encoded, isNot(contains('openRead')));
    },
  );

  test(
    'one known publish rejection retains other success and retries only same publish',
    () async {
      queue.addFiles([_file('setup.exe'), _file()], _metadata);
      var rejected = false;
      api.onPublish = (id) async {
        if (!rejected) {
          rejected = true;
          throw ApiException(
            'PAIR_CONFLICT',
            '版本不一致',
            httpStatus: 409,
            hasResponseCode: true,
          );
        }
      };
      await queue.run();
      expect(queue.confirmedCount, 1);
      final failed = queue.items.firstWhere((r) => !r.published);
      expect(failed.stage, ClientReleaseQueueStage.uploaded);
      expect(failed.uncertain, isFalse);
      final original = failed.requestId;
      await queue.run();
      expect(queue.confirmedCount, 2);
      expect(failed.requestId, original);
      expect(api.creates.length, 2);
      expect(api.uploads.length, 2);
      expect(api.publishes.where((id) => id == original).length, 2);
    },
  );

  test(
    'unknown Windows publish reads PUBLISHED then explicit same-id retention closeout',
    () async {
      queue.addFiles([_file()], _metadata);
      api.onPublish = (id) async {
        api.records[id]!['state'] = 'PUBLISHED';
        throw NetworkException('清理回执丢失');
      };
      await queue.run();
      final item = queue.items.single, original = item.requestId;
      expect(item.stage, ClientReleaseQueueStage.unknown);
      await queue.reconcile(item);
      expect(item.retentionPending, isTrue);
      expect(item.stage, ClientReleaseQueueStage.uploaded);
      expect(api.publishes.length, 1);
      expect(queue.confirmedCount, 0);
      api.onPublish = null;
      await queue.run();
      expect(item.requestId, original);
      expect(item.publishAcknowledged, isTrue);
      expect(api.creates.length, 1);
      expect(api.uploads.length, 1);
      expect(api.publishes, [original, original]);
      await queue.run();
      expect(api.publishes.length, 2);
      final restored = ClientReleasePublishQueue(
        gateway: api,
        isCurrent: () => true,
        checkpoint: (_) async {},
      );
      addTearDown(restored.dispose);
      restored.restore(queue.snapshot());
      expect(restored.items.single.uncertain, isTrue);
      await restored.reconcile(restored.items.single);
      expect(restored.items.single.published, isTrue);
      await restored.run();
      expect(api.publishes.length, 2);
    },
  );

  test(
    'unknown prepare authoritative 404 preserves UUID/body for explicit original retry',
    () async {
      queue.addFiles([_file()], _metadata);
      api.onCreate = (_) async {
        throw NetworkException();
      };
      await queue.run();
      final item = queue.items.single,
          original = item.requestId,
          hash = item.sha256;
      expect(item.uncertain, isTrue);
      await queue.reconcile(item);
      expect(item.uncertain, isFalse);
      expect(item.stage, ClientReleaseQueueStage.prepared);
      expect(item.requestId, original);
      expect(item.sha256, hash);
      api.onCreate = null;
      queue.replaceFile(item, _file());
      await queue.run();
      expect(queue.confirmedCount, 1);
      expect(api.creates.length, 2);
      expect(api.creates[0], api.creates[1]);
    },
  );

  test(
    'unknown prepare replacement with different bytes never changes original intent',
    () async {
      queue.addFiles([_file()], _metadata);
      api.onCreate = (_) async {
        throw NetworkException();
      };
      await queue.run();
      final item = queue.items.single,
          original = item.requestId,
          hash = item.sha256;
      await queue.reconcile(item);
      queue.replaceFile(item, _file('uten.zip', [9, 9, 9]));
      api.onCreate = null;
      await queue.run();
      expect(api.creates.length, 1);
      expect(api.uploads, isEmpty);
      expect(item.requestId, original);
      expect(item.sha256, hash);
    },
  );

  test(
    'lost upload response is reconciled by hash without re-upload',
    () async {
      queue.addFiles([_file()], _metadata);
      api.onUpload = (_) async {
        throw NetworkException();
      };
      await queue.run();
      final item = queue.items.single;
      expect(item.pendingOperation, ClientReleaseQueueOperation.upload);
      await queue.reconcile(item);
      expect(item.stage, ClientReleaseQueueStage.uploaded);
      await queue.run();
      expect(queue.confirmedCount, 1);
      expect(api.uploads.length, 1);
    },
  );

  test('checkpoint failure before dispatch never sends a mutation', () async {
    queue.dispose();
    queue = ClientReleasePublishQueue(
      gateway: api,
      isCurrent: () => current,
      checkpoint: (_) async {
        throw StateError('disk full');
      },
    );
    queue.addFiles([_file()], _metadata);
    await queue.run();
    expect(api.creates, isEmpty);
    expect(api.uploads, isEmpty);
    expect(api.publishes, isEmpty);
    expect(queue.items.single.uncertain, isFalse);
    expect(queue.error, isNotNull);
  });

  test(
    'owner retirement during prepare retains metadata and cannot revive after ABA',
    () async {
      final gate = Completer<void>();
      api.onCreate = (_) => gate.future;
      queue.addFiles([_file()], _metadata);
      final pending = queue.run();
      while (api.creates.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }
      current = false;
      queue.retire();
      gate.complete();
      await pending;
      expect(queue.retired, isTrue);
      expect(queue.items.single.file, isNull);
      expect(api.uploads, isEmpty);
      expect(api.publishes, isEmpty);
      current = true;
      await queue.run();
      expect(api.creates.length, 1);
      expect(snapshots.last['rows'], isNotEmpty);
    },
  );

  test(
    'bounded lazy reading rejects truncated or oversized streams before prepare',
    () async {
      queue.addFiles([
        ClientReleasePickedFile(
          name: 'uten.zip',
          size: 3,
          openRead: () => Stream.value([1, 2]),
        ),
      ], _metadata);
      await queue.run();
      expect(api.creates, isEmpty);
      expect(queue.items.single.error, contains('不完整'));
      queue.addFiles([
        ClientReleasePickedFile(
          name: 'second.zip',
          size: 3,
          openRead: () => Stream.value([1, 2, 3, 4]),
        ),
      ], _metadata.copyWith(architecture: 'x86'));
      await queue.run();
      expect(api.creates, isEmpty);
    },
  );

  for (final field in [
    'installMode',
    'fileName',
    'expectedSha256',
    'sha256',
    'sizeBytes',
    'releaseNotes',
    'mandatory',
    'architecture',
  ]) {
    test(
      'readback mismatch $field keeps original unknown and cannot publish',
      () async {
        queue.addFiles([_file()], _metadata);
        api.onUpload = (_) async {
          throw NetworkException();
        };
        await queue.run();
        final item = queue.items.single, original = item.requestId;
        api.changeRead = (r) => {
          ...r,
          field: field == 'sizeBytes'
              ? 99
              : field == 'mandatory'
              ? true
              : 'wrong',
        };
        await queue.reconcile(item);
        expect(item.uncertain, isTrue);
        expect(item.requestId, original);
        await queue.run();
        expect(api.publishes, isEmpty);
        expect(api.uploads.length, 1);
      },
    );
  }

  test('published read cannot bypass actual hash checks', () async {
    queue.addFiles([_file()], _metadata);
    api.onPublish = (id) async {
      api.records[id]!['state'] = 'PUBLISHED';
      throw NetworkException();
    };
    await queue.run();
    api.changeRead = (r) => {...r, 'sha256': '0' * 64};
    await queue.reconcile(queue.items.single);
    expect(queue.confirmedCount, 0);
    expect(queue.items.single.uncertain, isTrue);
    expect(api.publishes.length, 1);
  });

  test('store readback must preserve exact official app URL', () async {
    queue.addStore(
      _metadata.copyWith(
        platform: 'ios',
        architecture: 'arm64',
        storeUrl: 'https://apps.apple.com/cn/app/id123',
      ),
    );
    api.onCreate = (body) async {
      final id = body['requestId'] as String;
      api.records[id] = {
        ...body,
        'id': id,
        'runtimeFamily': 'flutter',
        'installMode': 'store',
        'storeUrl': 'https://apps.apple.com/cn/app/id999',
        'state': 'PUBLISHED',
      };
    };
    await queue.run();
    expect(queue.confirmedCount, 0);
    expect(api.publishes, isEmpty);
    expect(queue.items.single.uncertain, isTrue);
  });

  test(
    'unknown withdraw reads original outcome without repeating command',
    () async {
      queue.addFiles([_file()], _metadata);
      await queue.run();
      final release = queue.items.single.publishedRelease!;
      api.onWithdraw = (_) async {
        throw NetworkException();
      };
      await queue.withdraw(release);
      expect(queue.withdrawals[release.id], ClientReleaseWithdrawState.unknown);
      await queue.withdraw(release);
      expect(api.withdraws.length, 1);
      await queue.reconcileWithdrawal(release.id);
      expect(queue.items.single.publishedRelease!.state, 'WITHDRAWN');
      expect(queue.items.single.stage, ClientReleaseQueueStage.withdrawn);
      expect(queue.confirmedCount, 0);
      await queue.run();
      expect(api.publishes.length, 1);
      final restored = ClientReleasePublishQueue(
        gateway: api,
        isCurrent: () => true,
        checkpoint: (_) async {},
      );
      addTearDown(restored.dispose);
      restored.restore(queue.snapshot());
      expect(restored.items.single.stage, ClientReleaseQueueStage.withdrawn);
      expect(restored.hasUnknown, isFalse);
      await restored.run();
      expect(api.publishes.length, 1);
      expect(api.creates.length, 1);
      expect(
        queue.withdrawals[release.id],
        ClientReleaseWithdrawState.confirmed,
      );
    },
  );

  test(
    'unknown publish authoritatively withdrawn becomes closed and cannot replay',
    () async {
      queue.addFiles([_file()], _metadata);
      api.onPublish = (id) async {
        api.records[id]!['state'] = 'WITHDRAWN';
        throw NetworkException();
      };
      await queue.run();
      final item = queue.items.single, original = item.requestId;
      expect(item.uncertain, isTrue);
      await queue.reconcile(item);
      expect(item.stage, ClientReleaseQueueStage.withdrawn);
      expect(item.uncertain, isFalse);
      expect(item.requestId, original);
      await queue.run();
      expect(api.publishes.length, 1);
      expect(api.uploads.length, 1);
      queue.remove(item);
      expect(queue.items, isEmpty);
    },
  );

  test(
    'store prepare without explicit state is unknown and never confirms or publishes',
    () async {
      queue.addStore(
        _metadata.copyWith(
          platform: 'ios',
          architecture: 'arm64',
          storeUrl: 'https://apps.apple.com/cn/app/id123',
        ),
      );
      api.onCreate = (body) async {
        final id = body['requestId'] as String;
        api.records[id] = {
          ...body,
          'id': id,
          'runtimeFamily': 'flutter',
          'installMode': 'store',
          'sizeBytes': 0,
          'sha256': '',
        };
      };
      await queue.run();
      final item = queue.items.single, original = item.requestId;
      expect(item.uncertain, isTrue);
      expect(item.publishedRelease, isNull);
      expect(queue.confirmedCount, 0);
      expect(api.publishes, isEmpty);
      expect(api.uploads, isEmpty);
      await queue.reconcile(item);
      await queue.run();
      expect(item.requestId, original);
      expect(item.uncertain, isTrue);
      expect(api.creates.length, 1);
      expect(api.publishes, isEmpty);
    },
  );

  test(
    'Android uploaded read without explicit state stays original unknown before publish',
    () async {
      queue.addFiles([
        _file('uten.apk'),
      ], _metadata.copyWith(platform: 'android', architecture: 'arm64'));
      api.changeRead = (record) => record..remove('state');
      await queue.run();
      final item = queue.items.single, original = item.requestId;
      expect(item.uncertain, isTrue);
      expect(item.pendingOperation, ClientReleaseQueueOperation.upload);
      expect(item.publishedRelease, isNull);
      expect(queue.confirmedCount, 0);
      expect(api.publishes, isEmpty);
      expect(api.uploads.length, 1);
      await queue.reconcile(item);
      await queue.run();
      expect(item.requestId, original);
      expect(item.uncertain, isTrue);
      expect(api.creates.length, 1);
      expect(api.uploads.length, 1);
      expect(api.publishes, isEmpty);
    },
  );

  for (final state in [null, '', 'published', 'UNKNOWN']) {
    test('raw admin list rejects missing or invalid state $state', () async {
      final raw = <String, dynamic>{
        'id': '12345678-1234-1234-1234-123456789012',
        'platform': 'windows',
        'architecture': 'x64',
        'version': '2.5.34',
        'buildNumber': 2534,
        'installMode': 'windows_setup',
        'state': ?state,
      };
      final gateway = ApiClientReleasePublishGateway(_ListApi([raw]));
      await gateway.begin(() => true);
      await expectLater(gateway.list(), throwsFormatException);
      // The old update model remains backwards compatible outside admin parsing.
      if (state == null) expect(ClientRelease.fromJson(raw).state, 'PUBLISHED');
    });
  }
  test(
    'raw admin list preserves each explicit legitimate lifecycle state',
    () async {
      final gateway = ApiClientReleasePublishGateway(
        _ListApi([
          for (final state in ['DRAFT', 'PUBLISHED', 'WITHDRAWN'])
            {
              'id': '12345678-1234-1234-1234-123456789012',
              'platform': 'windows',
              'architecture': 'x64',
              'version': '2.5.34',
              'buildNumber': 2534,
              'installMode': 'windows_setup',
              'state': state,
            },
        ]),
      );
      await gateway.begin(() => true);
      expect((await gateway.list()).map((record) => record.state), [
        'DRAFT',
        'PUBLISHED',
        'WITHDRAWN',
      ]);
    },
  );

  test('draft identifier cannot escape endpoint', () {
    queue.addFiles([_file()], _metadata);
    final snapshot = queue.snapshot();
    final row = Map<String, dynamic>.from(
      (snapshot['rows'] as List).first as Map,
    );
    row['requestId'] = '../logout';
    snapshot['rows'] = [row];
    expect(() => queue.restore(snapshot), throwsFormatException);
  });
}
