import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

class MasterDataPagination {
  const MasterDataPagination(this.currentPage, this.totalPages, this.busy);
  final int currentPage;
  final int totalPages;
  final bool busy;
}

/// The rows currently available in a table, including pages appended by scrolling.
///
/// Hosts use this snapshot for selection and batch actions instead of looking up
/// selected IDs in only the most recent server page. It does not own selection,
/// fetch data, or notify during a widget build.
class MasterDataTableRowsController<T> {
  MasterDataTableRowsController();
  MasterDataTableRowsController._(this._onChanged);

  void Function(List<T>)? _onChanged;
  void Function(
    Object,
    Future<void> Function(),
    bool, {
    Future<void> Function()? loadPrevious,
    void Function(RenderBox)? updateVisiblePage,
    required int currentPage,
    required int totalPages,
    void Function(int)? goToPage,
    VoidCallback? onScrollIntent,
    Future<void> Function()? settlePresentation,
  })?
  _onBind;
  void Function(Object)? _onDetach;
  Object? _owner;
  Future<void> Function()? _loadNextPage;
  Future<void> Function()? _loadPreviousPage;
  void Function(RenderBox)? _updateVisiblePage;
  bool _isAppending = false;
  List<T> _items = const [];
  final _pagination = ValueNotifier<MasterDataPagination?>(null);
  MasterDataPagination? _pendingPagination;
  bool _paginationScheduled = false;
  void Function(int)? _goToPage;
  VoidCallback? _onScrollIntent;
  Future<void> Function()? _settlePresentation;

  ValueListenable<MasterDataPagination?> get pagination => _pagination;

  /// The latest reading position, including a change not yet notified this
  /// frame. A fetched/prepared page is deliberately not the reading position.
  int? get visiblePage =>
      _pendingPagination?.currentPage ?? _pagination.value?.currentPage;
  void goToPage(int page) => _goToPage?.call(page);

  /// Ancestor-scrolled tables report actual user movement separately from
  /// measuring a viewport or applying their own anchor correction.
  void noteScrollIntent() => _onScrollIntent?.call();

  /// Completes after the owning table's current rows have real layout.
  Future<void> get settled async => await _settlePresentation?.call();

  void _publishPagination(MasterDataPagination? next) {
    if (_pendingPagination?.currentPage == next?.currentPage &&
        _pendingPagination?.totalPages == next?.totalPages &&
        _pendingPagination?.busy == next?.busy) {
      return;
    }
    _pendingPagination = next;
    if (_paginationScheduled) return;
    _paginationScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _paginationScheduled = false;
      final value = _pendingPagination;
      final previous = _pagination.value;
      if (previous?.currentPage == value?.currentPage &&
          previous?.totalPages == value?.totalPages &&
          previous?.busy == value?.busy) {
        return;
      }
      _pagination.value = value;
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  List<T> get items => _items;
  bool get isAppending => _isAppending;

  Future<void> loadNextPage() async => _loadNextPage?.call();
  Future<void> loadPreviousPage() async => _loadPreviousPage?.call();

  /// For embedded tables scrolled by an ancestor. [viewport] is that ancestor's
  /// actual viewport, so page detection uses the same local coordinates as rows.
  void updateVisiblePage(RenderBox viewport) =>
      _updateVisiblePage?.call(viewport);

  void bindPagination(
    Object owner,
    Future<void> Function() load,
    bool busy, {
    Future<void> Function()? loadPrevious,
    void Function(RenderBox)? updateVisiblePage,
    int currentPage = 1,
    int totalPages = 1,
    void Function(int)? goToPage,
    VoidCallback? onScrollIntent,
    Future<void> Function()? settlePresentation,
  }) {
    _owner = owner;
    _loadNextPage = load;
    _loadPreviousPage = loadPrevious;
    _updateVisiblePage = updateVisiblePage;
    _isAppending = busy;
    _goToPage = goToPage;
    _onScrollIntent = onScrollIntent;
    _settlePresentation = settlePresentation;
    _publishPagination(MasterDataPagination(currentPage, totalPages, busy));
    _onBind?.call(
      owner,
      load,
      busy,
      loadPrevious: loadPrevious,
      updateVisiblePage: updateVisiblePage,
      currentPage: currentPage,
      totalPages: totalPages,
      goToPage: goToPage,
      onScrollIntent: onScrollIntent,
      settlePresentation: settlePresentation,
    );
  }

  void detachPagination(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _loadNextPage = null;
    _loadPreviousPage = null;
    _updateVisiblePage = null;
    _isAppending = false;
    _goToPage = null;
    _onScrollIntent = null;
    _settlePresentation = null;
    _publishPagination(null);
    _onDetach?.call(owner);
  }

  void update(List<T> items) {
    _items = List<T>.unmodifiable(items);
    _onChanged?.call(_items);
  }

  /// Keeps typed business rows accessible through a presentation-row wrapper.
  MasterDataTableRowsController<S> adapt<S>(
    Iterable<T> Function(List<S>) convert,
  ) =>
      MasterDataTableRowsController<S>._(
          (rows) => update(convert(rows).toList()),
        )
        .._onBind = bindPagination
        .._onDetach = detachPagination;
}
