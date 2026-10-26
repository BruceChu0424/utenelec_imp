import '../models/paged_result.dart';
import 'paged_query_identity.dart';

/// A bounded refresh plan. Reading position remains live while requests run.
class ReadWindowPlan {
  ReadWindowPlan._(this.pages, this._visiblePage, this._isCurrent);
  final List<int> pages;
  final int? Function() _visiblePage;
  final bool Function() _isCurrent;
  int? get visiblePage => _visiblePage();
  bool get isCurrent => _isCurrent();
}

final _windowBindings = Expando<Object>('paged read window');

/// One query/reader session; cache eviction and a fresh request do not change
/// its identity. Query/owner retirement must invalidate it explicitly.
class PagedReadWindowSession<T> {
  PagedReadWindowSession({required bool Function() isCurrent})
    : _core = _ReadWindowCore(isCurrent);
  final _ReadWindowCore _core;
  bool get isCurrent => _core.isCurrent;
  bool get pending => _core.pending;
  bool get failed => _core.failed;
  bool get empty => _core.empty;
  ReadWindowPlan? capture() => _core.capture();
  void invalidate() => _core.invalidate();
  void fail({bool accessDenied = false}) {
    if (accessDenied) {
      invalidate();
      return;
    }
    _core.pending = false;
    _core.failed = true;
  }

  void bindResult(
    PagedResult<T> result, {
    Map<int, List<T>>? replacementPages,
    bool pending = false,
  }) {
    _core.pending = pending;
    _core.failed = false;
    _core.empty =
        !pending &&
        result.items.isEmpty &&
        (replacementPages == null ||
            replacementPages.values.every((rows) => rows.isEmpty));
    if (result.items.isEmpty) return;
    _windowBindings[result.items] = PagedReadWindowBinding<T>._(
      _core,
      null,
      replacementPages == null
          ? null
          : Map.unmodifiable({
              for (final entry in replacementPages.entries)
                entry.key: List<T>.unmodifiable(entry.value),
            }),
    );
  }
}

class PagedReadWindowBinding<T> {
  PagedReadWindowBinding._(
    this._core,
    this.projectionKey,
    this.replacementPages,
  );
  final _ReadWindowCore _core;
  final Object? projectionKey;
  final Map<int, List<T>>? replacementPages;
  bool get isCurrent => _core.isCurrent;
  bool get pending => _core.pending;
  bool get failed => _core.failed;
  bool get empty => _core.empty;
  bool sameSession(PagedReadWindowBinding<Object?>? other) =>
      other != null &&
      identical(_core, other._core) &&
      samePagedReadQuery(projectionKey, other.projectionKey);

  void attachPresentation(
    Object owner, {
    required List<int> Function() retainedPages,
    required int? Function() visiblePage,
    required bool Function() isCurrent,
  }) => _core.presentations[owner] = _WindowPresentation(
    retainedPages,
    visiblePage,
    isCurrent,
  );
  void detachPresentation(Object owner) => _core.presentations.remove(owner);
}

PagedReadWindowBinding<T>? readWindowBindingOf<T>(List<T> rows) {
  final binding = _windowBindings[rows];
  return binding is PagedReadWindowBinding<T> ? binding : null;
}

/// Keep a business projection attached to the raw result's refresh protocol.
/// The same projector must be used for ordinary and replacement page rows.
void projectReadWindowBinding<R, V>(
  List<R> source,
  List<V> view, {
  required List<V> Function(List<R>) project,
  required Object projectionKey,
}) {
  final sourceBinding = readWindowBindingOf(source);
  if (sourceBinding == null) return;
  _windowBindings[view] = PagedReadWindowBinding<V>._(
    sourceBinding._core,
    freezePagedReadQuery(projectionKey),
    sourceBinding.replacementPages == null
        ? null
        : Map.unmodifiable({
            for (final entry in sourceBinding.replacementPages!.entries)
              entry.key: List<V>.unmodifiable(project(entry.value)),
          }),
  );
}

class _WindowPresentation {
  _WindowPresentation(this.pages, this.visible, this.current);
  final List<int> Function() pages;
  final int? Function() visible;
  final bool Function() current;
}

class _ReadWindowCore {
  _ReadWindowCore(this.ownerCurrent);
  final bool Function() ownerCurrent;
  final presentations = <Object, _WindowPresentation>{};
  bool _valid = true;
  bool pending = false;
  bool failed = false;
  bool empty = false;
  bool get isCurrent => _valid && ownerCurrent();
  void invalidate() {
    _valid = false;
    pending = false;
    failed = false;
    presentations.clear();
  }

  ReadWindowPlan? capture() {
    if (!isCurrent) return null;
    for (final presentation in presentations.values.toList().reversed) {
      if (!presentation.current()) continue;
      final pages =
          presentation.pages().where((page) => page > 0).toSet().toList()
            ..sort();
      if (pages.isEmpty) continue;
      final visible = presentation.visible();
      final bounded =
          pages.length <= 5
                ? pages
                : (List<int>.of(pages)..sort(
                        (a, b) => (a - (visible ?? pages.first))
                            .abs()
                            .compareTo((b - (visible ?? pages.first)).abs()),
                      ))
                      .take(5)
                      .toList()
            ..sort();
      return ReadWindowPlan._(
        List.unmodifiable(bounded),
        presentation.visible,
        () => isCurrent && presentation.current(),
      );
    }
    return null;
  }
}
