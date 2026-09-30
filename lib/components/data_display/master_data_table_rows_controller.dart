/// The rows currently available in a table, including pages appended by scrolling.
///
/// Hosts use this snapshot for selection and batch actions instead of looking up
/// selected IDs in only the most recent server page. It does not own selection,
/// fetch data, or notify during a widget build.
class MasterDataTableRowsController<T> {
  MasterDataTableRowsController();
  MasterDataTableRowsController._(this._onChanged);

  void Function(List<T>)? _onChanged;
  void Function(Object, Future<void> Function(), bool)? _onBind;
  void Function(Object)? _onDetach;
  Object? _owner;
  Future<void> Function()? _loadNextPage;
  bool _isAppending = false;
  List<T> _items = const [];

  List<T> get items => _items;
  bool get isAppending => _isAppending;

  Future<void> loadNextPage() async => _loadNextPage?.call();

  void bindPagination(Object owner, Future<void> Function() load, bool busy) {
    _owner = owner;
    _loadNextPage = load;
    _isAppending = busy;
    _onBind?.call(owner, load, busy);
  }

  void detachPagination(Object owner) {
    if (!identical(_owner, owner)) return;
    _owner = null;
    _loadNextPage = null;
    _isAppending = false;
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
