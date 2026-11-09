import '../models/paged_result.dart';
import 'paged_query_identity.dart';

final _readOwners = Expando<Object>('complete result owner');

/// Authorization/lifecycle proof for one query, independent of local scrolling.
class PagedReadWindowSession<T> {
  PagedReadWindowSession({required bool Function() isCurrent})
    : _core = _ResultOwner(isCurrent);
  final _ResultOwner _core;
  bool get isCurrent => _core.isCurrent;
  bool get pending => _core.pending;
  bool get failed => _core.failed;
  bool get empty => _core.empty;
  bool get growing => _core.growing;

  void invalidate() => _core.invalidate();
  void beginRead() {
    _core.pending = true;
    _core.failed = false;
    _core.empty = false;
  }

  void fail({bool accessDenied = false}) {
    if (accessDenied) {
      invalidate();
    } else {
      _core.pending = false;
      _core.failed = true;
      _core.growing = false;
    }
  }

  /// [growing] marks progressive rows of a complete read still continuing.
  PagedResult<T> bindResult(
    PagedResult<T> result, {
    bool pending = false,
    bool growing = false,
  }) {
    if (result.items.isEmpty && !isIndependentPagedRows(result.items)) {
      result = result.withRowsFrom(
        const <Object?>[],
        page: result.page,
        size: result.size,
        total: result.total,
        totalPages: result.totalPages,
      );
      if (!isIndependentPagedRows(result.items)) {
        throw StateError(
          'Typed empty results must use freezePagedRows in withRows',
        );
      }
    }
    _core.pending = pending;
    _core.failed = false;
    _core.growing = growing;
    _core.empty = !pending && result.items.isEmpty;
    _readOwners[result.items] = PagedReadWindowBinding<T>._(_core, null);
    return result;
  }
}

/// The historical name is retained for source compatibility. It carries only
/// owner proof; it cannot fetch, retain, navigate or replace page windows.
class PagedReadWindowBinding<T> {
  PagedReadWindowBinding._(this._core, this.projectionKey);
  final _ResultOwner _core;
  final Object? projectionKey;
  bool get isCurrent => _core.isCurrent;
  bool get pending => _core.pending;
  bool get failed => _core.failed;
  bool get empty => _core.empty;

  /// The rows are a validated prefix of a complete read that is still
  /// loading; the complete result replaces them as a whole.
  bool get growing => _core.growing && _core.isCurrent;

  bool sameSession(PagedReadWindowBinding<Object?>? other) =>
      other != null &&
      identical(_core, other._core) &&
      samePagedReadQuery(projectionKey, other.projectionKey);
}

PagedReadWindowBinding<T>? readWindowBindingOf<T>(List<T> rows) {
  final binding = _readOwners[rows];
  if (binding is PagedReadWindowBinding<T>) return binding;
  if (binding is PagedReadWindowBinding<Object?>) {
    return PagedReadWindowBinding<T>._(binding._core, binding.projectionKey);
  }
  return null;
}

/// Business projections must retain the same reader proof as their raw rows.
List<V> projectReadWindowBinding<R, V>(
  List<R> source,
  List<V> view, {
  required List<V> Function(List<R>) project,
  required Object projectionKey,
}) {
  if (identical(source, view) ||
      view.isEmpty && !isIndependentPagedRows(view)) {
    view = freezePagedRows<V>(view);
  }
  final sourceOwner = readWindowBindingOf(source);
  if (sourceOwner == null) return view;
  _readOwners[view] = PagedReadWindowBinding<V>._(
    sourceOwner._core,
    freezePagedReadQuery(projectionKey),
  );
  return view;
}

class _ResultOwner {
  _ResultOwner(this.ownerCurrent);
  final bool Function() ownerCurrent;
  bool _valid = true;
  bool pending = false;
  bool failed = false;
  bool empty = false;
  bool growing = false;
  bool get isCurrent => _valid && ownerCurrent();
  void invalidate() {
    _valid = false;
    pending = false;
    failed = false;
    growing = false;
  }
}
