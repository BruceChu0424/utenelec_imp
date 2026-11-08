import '../../core/network/api_exception.dart';
import '../models/paged_result.dart';
import 'complete_paged_snapshot.dart';
import 'paged_query_identity.dart';
import 'paged_read_intent.dart';
import 'paged_read_window_binding.dart';

/// Confirmed access rejection retires accepted private rows. Ordinary failures
/// keep the last authorized snapshot available for an explicit retry.
bool pagedReadAccessDenied(Object error) =>
    error is ApiException &&
    (error.httpStatus == 401 ||
        error.httpStatus == 403 ||
        const {
          'UNAUTHORIZED',
          'FORBIDDEN',
          'READ_SCOPE_CHANGED',
        }.contains(error.code));

/// A typed response and its row list remain one immutable, authorized result.
class PagedReadSnapshot<RowT, SnapshotT> extends PagedResult<RowT>
    implements PagedResultRevision {
  PagedReadSnapshot({
    required PagedResult<RowT> page,
    required this.snapshot,
    Object? revision,
    this.rebuildSnapshot,
  }) : pageCacheRevision = revision ?? page.readScopeVersion,
       super(
         items: page.items,
         page: page.page,
         size: page.size,
         total: page.total,
         totalPages: page.totalPages,
         totals: page.totals,
         facets: page.facets,
         facetNullCounts: page.facetNullCounts,
         readScopeVersion: page.readScopeVersion,
       );

  final SnapshotT snapshot;
  final SnapshotT Function(PagedResult<RowT> combined)? rebuildSnapshot;
  final Object? pageCacheRevision;
  @override
  Object? get snapshotRevision => pageCacheRevision;

  @override
  PagedReadSnapshot<RowT, SnapshotT> withRows(
    List<RowT> rows, {
    int page = 1,
    int? size,
    int? total,
    int? totalPages,
  }) {
    var combined = super.withRows(
      rows,
      page: page,
      size: size,
      total: total,
      totalPages: totalPages,
    );
    final rebuild = rebuildSnapshot;
    late final SnapshotT typed;
    if (rebuild != null) {
      typed = rebuild(combined);
    } else if (snapshot is PagedResult<RowT>) {
      final result = (snapshot as PagedResult<RowT>).withRows(
        combined.items,
        page: combined.page,
        size: combined.size,
        total: combined.total,
        totalPages: combined.totalPages,
      );
      typed = result as SnapshotT;
      combined = result;
    } else if (identical(rows, items) ||
        snapshot == null ||
        snapshot is String ||
        snapshot is num ||
        snapshot is bool) {
      typed = snapshot;
    } else {
      throw StateError(
        'Typed complete results require rebuildSnapshot to retain all rows',
      );
    }
    return PagedReadSnapshot(
      page: combined,
      snapshot: typed,
      revision: pageCacheRevision,
      rebuildSnapshot: rebuild,
    );
  }
}

/// A typed snapshot whose response carries the server's complete-read proofs.
/// Only such batches may join a concurrent continuation; the proof survives
/// every local rebuild of the same accepted result.
class VersionedPagedReadSnapshot<RowT, SnapshotT>
    extends PagedReadSnapshot<RowT, SnapshotT>
    implements VersionedPagedResultProof {
  VersionedPagedReadSnapshot({
    required super.page,
    required super.snapshot,
    super.rebuildSnapshot,
    required this.readSnapshotRevision,
    required this.readDataVersion,
  }) : super(revision: (readSnapshotRevision, readDataVersion));

  @override
  final String readSnapshotRevision;
  @override
  final String? readDataVersion;

  @override
  VersionedPagedReadSnapshot<RowT, SnapshotT> withRows(
    List<RowT> rows, {
    int page = 1,
    int? size,
    int? total,
    int? totalPages,
  }) {
    final combined = super.withRows(
      rows,
      page: page,
      size: size,
      total: total,
      totalPages: totalPages,
    );
    return VersionedPagedReadSnapshot(
      page: combined,
      snapshot: combined.snapshot,
      rebuildSnapshot: combined.rebuildSnapshot,
      readSnapshotRevision: readSnapshotRevision,
      readDataVersion: readDataVersion,
    );
  }
}

/// One complete result per query/owner. Internal batches are sequential and
/// cancellable; there is no neighboring-page cache or scroll-triggered read.
class ScopedPagedRead<T> {
  ScopedPagedRead({this.idOf});
  final Object? Function(T row)? idOf;
  Object? _scope;
  bool Function()? _ownerCurrent;
  int _owner = 0;
  int _request = 0;
  bool _disposed = false;
  PagedReadWindowSession<T>? _session;
  PagedResult<T>? _accepted;
  _CompleteFlight<T>? _flight;

  void invalidate() {
    _owner++;
    _request++;
    _session?.invalidate();
    _session = null;
    _scope = null;
    _ownerCurrent = null;
    _accepted = null;
    _flight = null;
  }

  /// Retire the current read and cache while the same authorized query keeps
  /// its last complete rendering with pending/failed state attached. Owner/query
  /// replacement and confirmed access rejection still invalidate the proof.
  void refresh() {
    if (_disposed || _ownerCurrent?.call() == false) {
      invalidate();
      return;
    }
    _request++;
    _accepted = null;
    _flight = null;
    _session?.beginRead();
  }

  void dispose() {
    _disposed = true;
    invalidate();
  }

  Future<PagedResult<T>> read(
    int page, {
    required Object scope,
    required Future<PagedResult<T>> Function(int) fetchPage,
    Future<PagedResult<T>> Function(int page, int size)? fetchPageSized,
    Future<PagedResult<T>> Function()? fetchComplete,
    Object? Function(T row)? idOf,
    required bool Function() isCurrent,
    bool Function()? isOwnerCurrent,
    bool useCache = false,
    bool Function()? canPrefetch,
    void Function(Object)? onPrefetchError,
    bool revalidateWindow = true,
    void Function(PagedResult<T> provisional)? onProvisionalBatch,
    // Continuation batches of one stable-total snapshot may be fetched
    // concurrently (identity, total and revision checks stay per batch).
    int maxConcurrentPages = 1,
  }) {
    final ownerCurrent = isOwnerCurrent ?? isCurrent;
    if (_disposed || !isCurrent() || !ownerCurrent()) {
      return Future.error(StateError('Paged read owner changed'));
    }
    if (_ownerCurrent?.call() == false || !samePagedReadQuery(_scope, scope)) {
      invalidate();
    }
    _scope = freezePagedReadQuery(scope);
    _ownerCurrent = ownerCurrent;
    final owner = _owner;
    bool owned() =>
        !_disposed && owner == _owner && (_ownerCurrent?.call() ?? false);
    var session = _session ??= PagedReadWindowSession<T>(isCurrent: owned);
    final active = _flight;
    if (useCache && active != null && active.current()) return active.result;
    if (useCache && _accepted != null && owned()) {
      return Future.value(_accepted);
    }

    final request = ++_request;
    final activity = PagedReadIntent.currentActivity;
    bool baseCurrent() => owned() && request == _request && isCurrent();
    bool current() => baseCurrent() && (activity?.call() ?? true);
    if (_accepted case final accepted?) {
      session.bindResult(accepted, pending: true);
    } else {
      session.beginRead();
    }
    // Provisional first-batch display (2026-11-07): only a fresh read without
    // an accepted result publishes its validated first batch as pending rows.
    // The complete frame replaces them; every failure path keeps the reader's
    // existing retirement (session.fail/invalidate), so a half list is never
    // mistaken for the complete result.
    final provisionalSink = onProvisionalBatch == null || _accepted != null
        ? null
        : PagedReadProvisionalSink((partial) {
            if (!current() || partial is! PagedResult<T>) return;
            onProvisionalBatch(session.bindResult(partial, pending: true));
          });
    late final _CompleteFlight<T> flight;
    Future<PagedResult<T>> load() async {
      try {
        final sink = provisionalSink;
        Future<PagedResult<T>> complete() => fetchComplete != null
            ? PagedReadIntent.scopedRead(
                baseCurrent,
                fetchComplete,
                bootstrap: PagedReadIntent.allowsInactiveBootstrap,
              )
            : loadCompletePagedResult<T>(
                loadPage: (batch, size) =>
                    fetchPageSized?.call(batch, size) ?? fetchPage(batch),
                isCurrent: baseCurrent,
                idOf: idOf ?? this.idOf,
                maxConcurrentPages: maxConcurrentPages,
                onProvisionalBatch: sink == null || !sink.claim()
                    ? null
                    : (partial) => sink.publish(partial as PagedResult<Object?>),
              );
        var result = await (sink == null
            ? complete()
            : PagedReadIntent.provisionalRead(sink, complete));
        if (!current()) throw StateError('Paged read owner changed');
        if (_accepted != null &&
            _accepted!.readScopeVersion != result.readScopeVersion) {
          session.invalidate();
          session = _session = PagedReadWindowSession<T>(isCurrent: owned);
        }
        result = session.bindResult(result);
        _accepted = result;
        return result;
      } catch (error) {
        if (baseCurrent()) {
          if (pagedReadAccessDenied(error)) {
            invalidate();
            onPrefetchError?.call(error);
          } else {
            session.fail();
          }
        }
        rethrow;
      } finally {
        if (identical(_flight, flight)) _flight = null;
      }
    }

    flight = _CompleteFlight<T>(current);
    _flight = flight;
    flight.result = load();
    return flight.result;
  }
}

class _CompleteFlight<T> {
  _CompleteFlight(this.current);
  final bool Function() current;
  late final Future<PagedResult<T>> result;
}
