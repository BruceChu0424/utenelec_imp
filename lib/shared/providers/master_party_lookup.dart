import 'dart:async';
import 'dart:collection';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import 'master_lookup_queue.dart';
import 'master_dictionary_repository.dart';
import 'export_context_epoch_provider.dart';

enum MasterPartyKind {
  client('/master/clients'),
  supplier('/master/suppliers');

  const MasterPartyKind(this.endpoint);
  final String endpoint;
}

/// This scope stays local to party references. The general master-data key is
/// also used by HR/payroll and must not inherit a new scoped dependency chain.
final masterPartyLookupProvider = Provider<MasterPartyLookup>((ref) {
  ref.watch(exportContextEpochProvider);
  final dictionaries = ref.watch(masterDictionaryRepositoryProvider);
  final lookup = MasterPartyLookup(ref.watch(apiClientProvider));
  final invalidations = dictionaries.invalidations.listen((key) {
    if (key == '/master/clients/dict') {
      lookup.invalidate(MasterPartyKind.client);
    }
    if (key == '/master/suppliers/dict') {
      lookup.invalidate(MasterPartyKind.supplier);
    }
  });
  ref.onDispose(() {
    lookup.dispose();
    unawaited(invalidations.cancel());
  });
  return lookup;
}, dependencies: [exportContextEpochProvider]);

/// Session-owned ID references, shared by Sales, Finance and procurement.
/// Calls made in the same UI turn coalesce before the existing bounded queue
/// starts, so per-row display misses never become per-row HTTP requests.
class MasterPartyLookup {
  MasterPartyLookup(this.api);
  final ApiClient api;
  static const maxCachedRows = 4096;
  static const _maxConcurrentPerKind = 2;
  // Ownership retirement ends logical waits, not an HTTP transport. Keep the
  // actual permits shared across replacement providers and generations.
  static final _physicalReads = {
    for (final kind in MasterPartyKind.values)
      kind: _PartyPhysicalReadBudget(_maxConcurrentPerKind),
  };
  final _cache = <MasterPartyKind, Map<String, Map<String, dynamic>?>>{};
  final _pending = <MasterPartyKind, Map<String, _PartyRead>>{};
  final _queued = <MasterPartyKind, List<_PartyRead>>{};
  final _readsByKey = <String, _PartyRead>{};
  final _latest = <MasterPartyKind, Map<String, int>>{};
  final _scheduled = <MasterPartyKind>{};
  final _queues = <MasterPartyKind, MasterLookupQueue>{};
  final _generation = <MasterPartyKind, int>{};
  final _pins = <MasterPartyKind, Map<String, int>>{};
  final _boundTimers = <MasterPartyKind, Timer>{};
  final _denied = <MasterPartyKind>{};
  final _dataRevisions = <MasterPartyKind, int>{};
  int _sequence = 0;
  int revision = 0;
  bool _disposed = false;

  Map<String, Map<String, dynamic>?> _rows(MasterPartyKind kind) =>
      _cache.putIfAbsent(kind, () => {});
  // Local data revisions schedule redraws; they are not authorization proof.
  int dataRevision(MasterPartyKind kind) => _dataRevisions[kind] ?? 0;
  void _changed(MasterPartyKind kind) {
    revision++;
    _dataRevisions[kind] = dataRevision(kind) + 1;
  }

  bool resolved(MasterPartyKind kind, String id) =>
      _denied.contains(kind) || _rows(kind).containsKey(id);
  Map<String, dynamic>? reference(MasterPartyKind kind, String? id) =>
      id == null || _denied.contains(kind) ? null : _rows(kind)[id];
  Iterable<String> ids(MasterPartyKind kind) => _denied.contains(kind)
      ? const <String>[]
      : _rows(kind).entries
            .where((entry) => entry.value != null)
            .map((entry) => entry.key);

  bool positive(MasterPartyKind kind, String? id) =>
      reference(kind, id) != null;
  bool selectable(MasterPartyKind kind, String? id) {
    final row = reference(kind, id);
    return switch (kind) {
      MasterPartyKind.client => row?['selectable'] == true,
      MasterPartyKind.supplier => row?['status'] == '使用',
    };
  }

  Future<void> load(
    MasterPartyKind kind,
    Iterable<String> requested, {
    bool refresh = false,
  }) async {
    if (_disposed) throw StateError('名称读取作用域已结束');
    final ids = requested.where((id) => id.isNotEmpty).toSet();
    if (ids.isEmpty) return;
    final pending = _pending.putIfAbsent(kind, () => {});
    final latest = _latest.putIfAbsent(kind, () => {});
    final pins = _pins.putIfAbsent(kind, () => {});
    final waits = <Future<void>>[];
    var retiredCache = false;
    if (refresh) _denied.remove(kind);
    for (final id in ids) {
      pins[id] = (pins[id] ?? 0) + 1;
      var read = pending[id];
      // Only a request not yet sent can prove authority for both fresh reads.
      // Already-started HTTP must not lend an older grant to a later view.
      if (refresh && read?.started == true) {
        _complete(read!, StateError('引用读取已被新的授权读取取代'));
        read = null;
      }
      if (refresh && read == null && _rows(kind).containsKey(id)) {
        _rows(kind).remove(id);
        retiredCache = true;
      }
      if (!refresh && resolved(kind, id)) continue;
      if (read == null) {
        read = _PartyRead(kind, id, ++_sequence);
        pending[id] = read;
        latest[id] = read.sequence;
        _readsByKey[read.key] = read;
        _queued.putIfAbsent(kind, () => []).add(read);
      }
      waits.add(read.completion.future);
    }
    if (retiredCache) _changed(kind);
    if (_queued[kind]?.isNotEmpty == true && _scheduled.add(kind)) {
      scheduleMicrotask(() => _flush(kind));
    }
    try {
      await Future.wait(waits);
      if (_disposed) throw StateError('名称读取作用域已结束');
    } finally {
      for (final id in ids) {
        final count = (pins[id] ?? 1) - 1;
        if (count == 0) {
          pins.remove(id);
        } else {
          pins[id] = count;
        }
      }
      // Snapshot continuations must run first, but a retired owner must never
      // leave a new timer behind (including finally after provider disposal).
      if (!_disposed &&
          _rows(kind).length > maxCachedRows &&
          !_boundTimers.containsKey(kind)) {
        _boundTimers[kind] = Timer(Duration.zero, () {
          _boundTimers.remove(kind);
          if (!_disposed) _bound(kind);
        });
      }
    }
  }

  void _flush(MasterPartyKind kind) {
    _scheduled.remove(kind);
    if (_disposed) return;
    final reads = _queued.remove(kind) ?? const <_PartyRead>[];
    if (reads.isEmpty) return;
    final generation = _generation[kind] ?? 0;
    final queue = _queues.putIfAbsent(
      kind,
      () => MasterLookupQueue(
        batchSize: 100,
        maxConcurrent: _maxConcurrentPerKind,
        fetch: (keys) => _readBatch(kind, keys, generation),
      ),
    );
    unawaited(() async {
      Object? failure;
      StackTrace? trace;
      try {
        await queue.load(reads.map((read) => read.key));
        if (_disposed || generation != (_generation[kind] ?? 0)) {
          throw StateError('名称读取作用域已变化');
        }
      } catch (error, stack) {
        failure = error;
        trace = stack;
      }
      for (final read in reads) {
        if (!read.completion.isCompleted) _complete(read, failure, trace);
      }
    }());
  }

  Future<void> _readBatch(
    MasterPartyKind kind,
    List<String> keys,
    int generation,
  ) => _physicalReads[kind]!.run(
    this,
    () => _readAuthorizedBatch(kind, keys, generation),
  );

  Future<void> _readAuthorizedBatch(
    MasterPartyKind kind,
    List<String> keys,
    int generation,
  ) async {
    final reads = [
      for (final key in keys)
        if (_readsByKey[key] case final _PartyRead read) read,
    ];
    try {
      if (_disposed || generation != (_generation[kind] ?? 0)) {
        throw StateError('名称读取作用域已变化');
      }
      for (final read in reads) {
        read.started = true;
      }
      final requested = reads.map((read) => read.id).toSet();
      final rows = await api.getList(
        '${kind.endpoint}/lookup',
        query: {
          'ids': requested.join(','),
          if (kind == MasterPartyKind.client) 'excludeLegacyFinanceStub': true,
        },
      );
      if (_disposed || generation != (_generation[kind] ?? 0)) {
        throw StateError('名称读取作用域已变化');
      }
      final found = <String, Map<String, dynamic>>{};
      for (final row in rows) {
        final id = row['id'];
        if (id is! String || !requested.contains(id) || found.containsKey(id)) {
          throw const FormatException('主档名称返回了不属于请求的身份');
        }
        found[id] = Map.unmodifiable(row);
      }
      var changed = false;
      final cache = _rows(kind);
      for (final read in reads) {
        if (_latest[kind]?[read.id] != read.sequence) continue;
        cache[read.id] = found[read.id];
        changed = true;
      }
      if (changed) _changed(kind);
      for (final read in reads) {
        _complete(
          read,
          _latest[kind]?[read.id] == read.sequence
              ? null
              : StateError('引用读取已被新的授权读取取代'),
        );
      }
    } catch (error, stack) {
      if (error is ApiException &&
          {401, 403}.contains(error.httpStatus) &&
          !_disposed &&
          generation == (_generation[kind] ?? 0)) {
        final newestInBatch = reads.fold<int>(
          0,
          (value, read) => value > read.sequence ? value : read.sequence,
        );
        final hasNewerRead =
            _latest[kind]?.values.any((value) => value > newestInBatch) ??
            false;
        if (!hasNewerRead) {
          invalidate(kind);
          _denied.add(kind);
        } else {
          // A delayed denial from an older request cannot retire a newer
          // authorized view. Only its still-current IDs become unresolved.
          var changed = false;
          for (final read in reads) {
            if (_latest[kind]?[read.id] == read.sequence) {
              _rows(kind)[read.id] = null;
              changed = true;
            }
          }
          if (changed) _changed(kind);
        }
      }
      for (final read in reads) {
        _complete(read, error, stack);
      }
      rethrow;
    }
  }

  void _complete(_PartyRead read, [Object? error, StackTrace? stack]) {
    final pending = _pending[read.kind];
    if (identical(pending?[read.id], read)) pending?.remove(read.id);
    _readsByKey.remove(read.key);
    if (error != null &&
        _latest[read.kind]?[read.id] == read.sequence &&
        !_rows(read.kind).containsKey(read.id)) {
      _latest[read.kind]?.remove(read.id);
    }
    if (read.completion.isCompleted) return;
    if (error == null) {
      read.completion.complete();
    } else {
      read.completion.completeError(error, stack);
    }
  }

  void _bound(MasterPartyKind kind) {
    final cache = _rows(kind);
    for (final id in List.of(cache.keys)) {
      if (cache.length <= maxCachedRows) break;
      if ((_pins[kind]?[id] ?? 0) == 0) {
        cache.remove(id);
        _latest[kind]?.remove(id);
      }
    }
  }

  void invalidate(MasterPartyKind kind) {
    _boundTimers.remove(kind)?.cancel();
    _generation[kind] = (_generation[kind] ?? 0) + 1;
    _physicalReads[kind]!.cancelQueued(this);
    _cache.remove(kind);
    _denied.remove(kind);
    _latest.remove(kind);
    _queues.remove(kind)?.dispose();
    _queued.remove(kind);
    final pending = _pending.remove(kind);
    for (final read in pending?.values ?? <_PartyRead>[]) {
      _complete(read, StateError('主档名称已变化'));
    }
    _changed(kind);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final kind in MasterPartyKind.values) {
      invalidate(kind);
    }
  }
}

class _PartyPhysicalReadBudget {
  _PartyPhysicalReadBudget(this.maxConcurrent);
  final int maxConcurrent;
  final _queued = Queue<_PartyPhysicalRead>();
  int _active = 0;

  Future<void> run(Object owner, Future<void> Function() read) {
    final task = _PartyPhysicalRead(owner, read);
    _queued.add(task);
    _drain();
    return task.completion.future;
  }

  void cancelQueued(Object owner) {
    final retired = _queued
        .where((task) => identical(task.owner, owner))
        .toList();
    _queued.removeWhere((task) => identical(task.owner, owner));
    for (final task in retired) {
      task.completion.completeError(StateError('名称读取作用域已结束'));
    }
  }

  void _drain() {
    while (_active < maxConcurrent && _queued.isNotEmpty) {
      final task = _queued.removeFirst();
      _active++;
      unawaited(_run(task));
    }
  }

  Future<void> _run(_PartyPhysicalRead task) async {
    try {
      await task.zone.run(task.read);
      task.completion.complete();
    } catch (error, stack) {
      task.completion.completeError(error, stack);
    } finally {
      _active--;
      _drain();
    }
  }
}

class _PartyPhysicalRead {
  _PartyPhysicalRead(this.owner, this.read) : zone = Zone.current;
  final Object owner;
  final Future<void> Function() read;
  final Zone zone;
  final completion = Completer<void>();
}

class _PartyRead {
  _PartyRead(this.kind, this.id, this.sequence);
  final MasterPartyKind kind;
  final String id;
  final int sequence;
  String get key => '$sequence';
  final completion = Completer<void>();
  bool started = false;
}

/// A reference-name view, never an enumeration of all selectable parties.
/// Display lookups schedule one coalesced ID read; async snapshot builders
/// should explicitly await their name service's load*Names before publication.
class MasterPartyNameMap extends MapBase<String, String> {
  MasterPartyNameMap(this.lookup, this.kind, this.load);
  final MasterPartyLookup lookup;
  final MasterPartyKind kind;
  final Future<void> Function(Iterable<String>) load;

  @override
  String? operator [](Object? key) {
    if (key is! String || key.isEmpty) return null;
    if (!lookup.resolved(kind, key)) unawaited(load([key]));
    return lookup.reference(kind, key)?['name'] as String?;
  }

  @override
  bool containsKey(Object? key) {
    if (key is String && key.isNotEmpty && !lookup.resolved(kind, key)) {
      unawaited(load([key]));
    }
    return key is String && lookup.reference(kind, key) != null;
  }

  @override
  Iterable<String> get keys => lookup.ids(kind);
  @override
  void operator []=(String key, String value) =>
      throw UnsupportedError('只读主档引用');
  @override
  void clear() => throw UnsupportedError('只读主档引用');
  @override
  String? remove(Object? key) => throw UnsupportedError('只读主档引用');
}
