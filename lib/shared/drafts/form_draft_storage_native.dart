import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'form_draft_storage_api.dart';

FormDraftStorage createFormDraftStorage() => NativeFormDraftStorage();

/// Append-only metadata and payload files with a flushed write-ahead journal.
/// A page touches at most [limit] sequence slots, never history payloads.
class NativeFormDraftStorage
    implements FormDraftStorage, FormDraftHistoryStorage {
  NativeFormDraftStorage({this.directoryProvider, this.afterJournalFlush});

  final Future<Directory> Function()? directoryProvider;

  /// Fault-injection seam for interruption/reopen tests.
  final Future<void> Function()? afterJournalFlush;
  static final Map<String, Future<void>> _recordTails = {};

  Future<Directory> _directory() async {
    final provider = directoryProvider;
    if (provider != null) return (await provider()).create(recursive: true);
    final root = await getApplicationSupportDirectory();
    return Directory('${root.path}/form_drafts_v1').create(recursive: true);
  }

  Future<File> _file(String key) async {
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(key)) {
      throw const FormatException('草稿存储标识无效');
    }
    return File('${(await _directory()).path}/$key.json');
  }

  Future<T> _locked<T>(String key, Future<T> Function(File) action) async {
    final target = await _file(key);
    final lockPath = '${target.path}.lock';
    final previous = _recordTails[lockPath] ?? Future<void>.value();
    final release = Completer<void>();
    final tail = release.future;
    _recordTails[lockPath] = tail;
    await previous;
    try {
      // Stable lock files also coordinate with still-running v1 processes.
      final handle = await File(lockPath).open(mode: FileMode.append);
      try {
        await handle.lock(FileLock.blockingExclusive);
        try {
          return await action(target);
        } finally {
          await handle.unlock();
        }
      } finally {
        await handle.close();
      }
    } finally {
      release.complete();
      if (identical(_recordTails[lockPath], tail)) {
        _recordTails.remove(lockPath);
      }
    }
  }

  Future<String?> _read(File file) async =>
      await file.exists() ? file.readAsString() : null;

  Future<void> _replace(File target, String value) async {
    await target.parent.create(recursive: true);
    final temporary = File('${target.path}.${const Uuid().v4()}.tmp');
    try {
      await temporary.writeAsString(value, flush: true);
      await temporary.rename(target.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  File _active(Directory directory, String key) =>
      File('${directory.path}/active/$key.json');
  File _slot(Directory directory, int sequence, String kind) =>
      File('${directory.path}/$kind/${sequence ~/ 1000}/$sequence.json');

  Future<int> _head(Directory directory) async {
    final raw = await _read(File('${directory.path}/head'));
    final witness = await _read(File('${directory.path}/high-water'));
    if (raw != null &&
        RegExp(r'^[1-9][0-9]{0,14}$').hasMatch(raw) &&
        raw == witness) {
      return int.parse(raw);
    }
    if (raw != null || witness != null) {
      throw StateError('草稿历史序号控制损坏，原记录已保留');
    }
    // A missing head is initial state only when there are no durable records.
    // This recovery-only scan never runs on the ordinary append/page path.
    for (final kind in ['index', 'payload', 'active']) {
      final records = Directory('${directory.path}/$kind');
      if (!await records.exists()) continue;
      await for (final entity in records.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! Directory) {
          throw StateError('草稿历史序号丢失，原记录已保留');
        }
      }
    }
    return 0;
  }

  Future<bool> _verifyImmutable(File file, String value) async {
    if (!await file.exists()) return false;
    final existing = await file.readAsBytes();
    final expected = utf8.encode(value);
    if (existing.length != expected.length) {
      throw StateError('草稿历史序号冲突，原记录已保留');
    }
    for (var index = 0; index < existing.length; index++) {
      if (existing[index] != expected[index]) {
        throw StateError('草稿历史序号冲突，原记录已保留');
      }
    }
    return true;
  }

  Future<void> _importKey(Directory directory, File legacy, String key) async {
    if (await _active(directory, key).exists()) return;
    final value = await _read(legacy);
    final change = formDraftHistoryChange(key, null, value, importing: true);
    if (change != null) await _commit(directory, legacy, key, value, change);
  }

  Future<T> _scope<T>(String prefix, Future<T> Function(Directory) action) {
    validateFormDraftHistoryPrefix(prefix);
    // Draft IDs permit letters, digits and hyphens only. An underscore-bearing
    // control suffix cannot alias a record lock (for example ID history-v2).
    return _locked('${prefix}__history_v2_control', (_) async {
      final root = await _directory();
      final directory = await Directory(
        '${root.path}/history_v2/$prefix',
      ).create(recursive: true);
      final pending = await _read(File('${directory.path}/pending.json'));
      if (pending != null) {
        final journal = jsonDecode(pending) as Map<String, dynamic>;
        final key = journal['key'] as String;
        if (formDraftHistoryPrefix(key) != prefix) {
          throw const FormatException('草稿历史事务身份无效');
        }
        await _locked(key, (legacy) => _apply(directory, legacy, journal));
      }
      final migrated = File('${directory.path}/migration-complete');
      if (!await migrated.exists()) {
        // Each committed item fences its original source. A repeated scan after
        // interruption cannot import a committed item a second time.
        await for (final entity in root.list()) {
          final name = entity.uri.pathSegments.last;
          if (entity is! File ||
              !name.startsWith(prefix) ||
              !name.endsWith('.json')) {
            continue;
          }
          final key = name.substring(0, name.length - 5);
          if (formDraftHistoryPrefix(key) != prefix) continue;
          await _locked(key, (legacy) async {
            String? value;
            try {
              value = await _read(legacy);
            } on FormatException {
              return; // Preserve damaged source bytes in their original file.
            }
            final change = formDraftHistoryChange(
              key,
              null,
              value,
              importing: true,
            );
            if (change != null) {
              await _commit(directory, legacy, key, value, change);
            }
          });
        }
        await _replace(migrated, '2');
      }
      return action(directory);
    });
  }

  Future<void> _commit(
    Directory directory,
    File legacy,
    String key,
    String? value,
    FormDraftHistoryChange change,
  ) async {
    final sequence = await _head(directory) + 1;
    final entry = change.entry(sequence);
    final terminal = value == null
        ? jsonEncode({
            'version': 1,
            'id': change.draft.id,
            'completed': true,
            'historyAction': 'deleted',
            'revision': const Uuid().v4(),
          })
        : compactFormDraftTerminalMarker(value)!;
    final journal = <String, dynamic>{
      'key': key,
      'sequence': sequence,
      'entry': entry.toJson(),
      'payload': change.payload,
      'value': terminal,
      'legacyExpected': await _read(legacy),
    };
    await _replace(File('${directory.path}/pending.json'), jsonEncode(journal));
    await afterJournalFlush?.call();
    await _apply(directory, legacy, journal);
  }

  Future<void> _apply(
    Directory directory,
    File legacy,
    Map<String, dynamic> journal,
  ) async {
    final key = journal['key'] as String;
    final sequence = journal['sequence'] as int;
    formDraftHistorySequence('$sequence');
    // If a v1 process wrote during a crash interval before its source fence was
    // installed, retain that revision too. Persist the recovery decision before
    // replacing any source, so a second interruption cannot lose it.
    if (!journal.containsKey('lateEntry')) {
      final legacyNow = await _read(legacy);
      if (legacyNow != journal['legacyExpected'] &&
          !isFormDraftTerminalMarker(legacyNow)) {
        final late = formDraftHistoryChange(
          key,
          null,
          legacyNow,
          importing: true,
        );
        if (late != null) {
          journal['lateEntry'] = late.entry(sequence + 1).toJson();
          journal['latePayload'] = late.payload;
          await _replace(
            File('${directory.path}/pending.json'),
            jsonEncode(journal),
          );
        }
      }
    }
    final finalSequence = sequence + (journal['lateEntry'] == null ? 0 : 1);
    final witness = await _read(File('${directory.path}/high-water'));
    if (witness != null &&
        (!RegExp(r'^[1-9][0-9]{0,14}$').hasMatch(witness) ||
            int.parse(witness) > finalSequence)) {
      throw StateError('草稿历史事务序号回退，原记录已保留');
    }
    final immutable = <(File, String)>[
      (_slot(directory, sequence, 'payload'), journal['payload'] as String),
      (_slot(directory, sequence, 'index'), jsonEncode(journal['entry'])),
      if (journal['lateEntry'] != null) ...[
        (
          _slot(directory, sequence + 1, 'payload'),
          journal['latePayload'] as String,
        ),
        (
          _slot(directory, sequence + 1, 'index'),
          jsonEncode(journal['lateEntry']),
        ),
      ],
    ];
    final absent = <(File, String)>[];
    // Preflight every immutable slot before any file changes. Replay accepts
    // identical bytes only, and does not rewrite an already committed original.
    for (final record in immutable) {
      if (!await _verifyImmutable(record.$1, record.$2)) absent.add(record);
    }
    for (final record in absent) {
      await _replace(record.$1, record.$2);
    }
    await _replace(
      _active(directory, key),
      (journal['latePayload'] ?? journal['value']) as String,
    );
    await _replace(
      legacy,
      jsonEncode({
        'version': 1,
        'id': key.substring(formDraftHistoryPrefix(key)!.length),
        'completed': true,
        'storageVersion': 2,
        'revision': 'history-v2',
      }),
    );
    await _replace(File('${directory.path}/high-water'), '$finalSequence');
    await _replace(File('${directory.path}/head'), '$finalSequence');
    await File('${directory.path}/pending.json').delete();
  }

  @override
  Future<Map<String, String>> readAll(String prefix) async {
    Future<Map<String, String>> collect(Directory directory) async {
      final result = <String, String>{};
      if (!await directory.exists()) return result;
      await for (final entity in directory.list()) {
        final name = entity.uri.pathSegments.last;
        if (entity is File &&
            name.startsWith(prefix) &&
            name.endsWith('.json')) {
          try {
            final value = await _read(entity);
            if (value != null) {
              result[name.substring(0, name.length - 5)] = value;
            }
          } on FormatException {
            // A damaged record does not hide healthy sibling records.
          }
        }
      }
      return result;
    }

    if (!prefix.endsWith('_')) return collect(await _directory());
    return _scope(prefix, (directory) async {
      final legacy = await collect(await _directory());
      // A v1 process may create a new ID after migration. Import sources when
      // active listing encounters them; history paging never rescans payloads.
      for (final record in legacy.entries) {
        if (formDraftHistoryPrefix(record.key) == prefix &&
            decodeFormDraftHistoryPayload(record.value) != null) {
          await _locked(
            record.key,
            (file) => _importKey(directory, file, record.key),
          );
        }
      }
      return {
        ...legacy,
        ...await collect(Directory('${directory.path}/active')),
      };
    });
  }

  @override
  Future<String?> read(String key) async {
    final prefix = formDraftHistoryPrefix(key);
    if (prefix == null) return _locked(key, _read);
    return _scope(
      prefix,
      (directory) => _locked(key, (legacy) async {
        await _importKey(directory, legacy, key);
        return await _read(_active(directory, key)) ?? await _read(legacy);
      }),
    );
  }

  Future<bool> _mutate(
    String key,
    String? value, {
    String? expectedValue,
    bool compare = false,
  }) async {
    final prefix = formDraftHistoryPrefix(key);
    Future<bool> perform(File legacy, Directory? directory) async {
      if (directory != null) await _importKey(directory, legacy, key);
      final active = directory == null ? legacy : _active(directory, key);
      final existing = await _read(active) ?? await _read(legacy);
      if (compare && existing != expectedValue) return false;
      if (value == null && isFormDraftTerminalMarker(existing)) return true;
      final change = formDraftHistoryChange(key, existing, value);
      if (directory != null && change != null) {
        await _commit(directory, legacy, key, value, change);
      } else if (value == null) {
        if (await active.exists()) await active.delete();
      } else {
        await _replace(await active.exists() ? active : legacy, value);
      }
      return true;
    }

    if (prefix == null) return _locked(key, (file) => perform(file, null));
    return _scope(
      prefix,
      (directory) => _locked(key, (file) => perform(file, directory)),
    );
  }

  @override
  Future<void> write(String key, String value) async {
    await _mutate(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await _mutate(key, null);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) => _mutate(key, value, expectedValue: expectedValue, compare: true);

  @override
  Future<FormDraftHistoryPage> readHistoryPage(
    String prefix, {
    String? before,
    int limit = 30,
  }) {
    formDraftHistoryLimit(limit);
    final boundary = before == null ? null : formDraftHistorySequence(before);
    return _scope(prefix, (directory) async {
      final head = await _head(directory);
      var sequence = boundary == null || boundary > head ? head : boundary - 1;
      final entries = <FormDraftHistoryEntry>[];
      for (
        var scanned = 0;
        scanned < limit && sequence > 0;
        scanned++, sequence--
      ) {
        try {
          final raw = await _read(_slot(directory, sequence, 'index'));
          if (raw != null) {
            final entry = FormDraftHistoryEntry.fromJson(
              jsonDecode(raw) as Map<String, dynamic>,
            );
            if (entry.id == '$sequence') entries.add(entry);
          }
        } on FormatException {
          // Sequence seek steps past a missing or corrupt metadata slot.
        } on TypeError {
          // Preserve damaged records for dedicated recovery.
        } on ArgumentError {
          // Unknown metadata does not hide other records.
        }
      }
      return FormDraftHistoryPage(
        entries: entries,
        nextCursor: sequence > 0 ? '${sequence + 1}' : null,
      );
    });
  }

  @override
  Future<FormDraftHistoryRecord?> readHistoryRecord(String prefix, String id) {
    final sequence = formDraftHistorySequence(id);
    return _scope(prefix, (directory) async {
      try {
        final metadata = await _read(_slot(directory, sequence, 'index'));
        if (metadata == null) return null;
        final entry = FormDraftHistoryEntry.fromJson(
          jsonDecode(metadata) as Map<String, dynamic>,
        );
        final draft = decodeFormDraftHistoryPayload(
          await _read(_slot(directory, sequence, 'payload')),
        );
        if (entry.id != id ||
            draft == null ||
            draft.id != entry.draftId ||
            draft.revision != entry.revision ||
            draft.module != entry.module ||
            draft.route != entry.route ||
            draft.permission != entry.permission ||
            draft.draftKind != entry.draftKind) {
          return null;
        }
        return FormDraftHistoryRecord(entry: entry, draft: draft);
      } on FormatException {
        return null;
      } on TypeError {
        return null;
      } on ArgumentError {
        return null;
      }
    });
  }
}
