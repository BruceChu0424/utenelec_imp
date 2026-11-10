import 'dart:collection';

/// Optional structural profiling, with counts only and no business values.
/// Metadata counts new leaf-row/branch-child/snapshot-root references, not bytes
/// or every local assignment. It exposes path-copy growth without profiling rows.
void Function(int rows, int metadataReferences)? debugPagedRowsCopyObserver;

/// Returns the unchanged prefix length only for snapshots made by the same
/// append-only owner. This proves list membership/reference stability, not deep
/// immutability of row objects, authorization, or a caller's projection policy.
int? pagedRowsAppendStart(Object? previous, Object? next) {
  if (previous is! _ImmutablePagedRows<Object?> ||
      next is! _ImmutablePagedRows<Object?> ||
      !identical(previous._lineage, next._lineage) ||
      previous.length > next.length) {
    return null;
  }
  // Only one append-only builder can issue this private lineage. No public
  // constructor can fork a snapshot or replace a member of an existing prefix.
  return previous.length;
}

/// A small presentation suffix (for example footer/summary slots) can move as
/// data grows without copying the data prefix. Only a private sealed data root
/// is accepted; callers own the suffix's bounded size and immutable row values.
List<T> immutablePagedRowsWithTail<T>(List<T> prefix, Iterable<T> tail) {
  if (prefix is! _ImmutablePagedRows<T>) {
    throw ArgumentError('A presentation tail requires sealed paged rows');
  }
  return _ImmutablePagedRowsWithTail<T>(prefix, List<T>.unmodifiable(tail));
}

/// Strict membership proof for a common data prefix, allowing a moved/replaced
/// presentation suffix. It does not grant append-only semantics to the suffix
/// and does not prove geometry, permission or deep row-value immutability.
int? immutablePagedRowsCommonPrefix(Object? previous, Object? next) {
  final before = switch (previous) {
    final _ImmutablePagedRows<Object?> value => value,
    final _ImmutablePagedRowsWithTail<Object?> value => value.prefix,
    _ => null,
  };
  final after = switch (next) {
    final _ImmutablePagedRows<Object?> value => value,
    final _ImmutablePagedRowsWithTail<Object?> value => value.prefix,
    _ => null,
  };
  if (before == null ||
      after == null ||
      !identical(before._lineage, after._lineage)) {
    return null;
  }
  return before.length < after.length ? before.length : after.length;
}

bool isImmutablePagedRows(Object? rows) =>
    rows is _ImmutablePagedRows<Object?> ||
    rows is _ImmutablePagedRowsWithTail<Object?>;

/// A new list identity lets each response own its read-window binding, including
/// empty responses. Only privately constructed, immutable chunks can be reused.
List<T>? independentImmutablePagedRows<T>(Iterable<T> rows) => switch (rows) {
  final _ImmutablePagedRows<T> value => _ImmutablePagedRows<T>(
    value._lineage,
    value._root,
    value.length,
  ),
  final _ImmutablePagedRowsWithTail<T> value => _ImmutablePagedRowsWithTail<T>(
    value.prefix,
    value.tail,
  ),
  _ => null,
};

/// Accumulates one validated read. The response's reified row type owns this
/// builder, so a Base reader receiving a Child page still validates Child rows.
/// A snapshot never retains this builder or chunks appended in the future.
class ImmutablePagedRowsBuilder<T> {
  final Object _lineage = Object();
  _PagedRowsNode<T>? _root;
  List<T> _pending = [];
  int _length = 0;

  int get length => _length;

  void add(Object? row) {
    _pending.add(row as T);
    _length++;
  }

  /// Call only after the entire pending batch passed the read's validation.
  List<T> snapshot() {
    final copied = _pending.length;
    var metadataReferences = 1; // The independent snapshot's root reference.
    if (_pending.isNotEmpty) {
      final leaf = _PagedRowsLeaf<T>(List<T>.unmodifiable(_pending));
      metadataReferences++; // This new leaf's row-block reference.
      final appended = _append(_root, leaf);
      _root = appended.$1;
      metadataReferences += appended.$2;
      _pending = [];
    }
    debugPagedRowsCopyObserver?.call(copied, metadataReferences);
    return _ImmutablePagedRows<T>(_lineage, _root, _length);
  }
}

/// Complete left subtrees and one growing right path keep height logarithmic.
/// Only that path is copied on append; every node is immutable and has no
/// parent, builder or future-snapshot reference.
(_PagedRowsNode<T>, int) _append<T>(
  _PagedRowsNode<T>? before,
  _PagedRowsLeaf<T> leaf,
) {
  if (before == null) return (leaf, 0);
  if (before.full) return (_PagedRowsBranch<T>(before, leaf), 2);
  final branch = before as _PagedRowsBranch<T>;
  final right = _append(branch.right, leaf);
  return (_PagedRowsBranch<T>(branch.left, right.$1), right.$2 + 2);
}

sealed class _PagedRowsNode<T> {
  const _PagedRowsNode(this.length, this.chunks, this.full);
  final int length;
  final int chunks;
  final bool full;
}

final class _PagedRowsLeaf<T> extends _PagedRowsNode<T> {
  _PagedRowsLeaf(this.rows) : super(rows.length, 1, true);
  final List<T> rows;
}

final class _PagedRowsBranch<T> extends _PagedRowsNode<T> {
  _PagedRowsBranch(this.left, this.right)
    : super(
        left.length + right.length,
        left.chunks + right.chunks,
        left.full && right.full && left.chunks == right.chunks,
      );
  final _PagedRowsNode<T> left;
  final _PagedRowsNode<T> right;
}

class _ImmutablePagedRows<T> extends ListBase<T> {
  _ImmutablePagedRows(this._lineage, this._root, this.length);
  final Object _lineage;
  final _PagedRowsNode<T>? _root;

  @override
  final int length;

  @override
  set length(int value) => throw UnsupportedError('Immutable paged rows');

  @override
  T operator [](int index) {
    RangeError.checkValidIndex(index, this);
    var node = _root!;
    while (node is _PagedRowsBranch<T>) {
      if (index < node.left.length) {
        node = node.left;
      } else {
        index -= node.left.length;
        node = node.right;
      }
    }
    return (node as _PagedRowsLeaf<T>).rows[index];
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Immutable paged rows');

  @override
  Iterator<T> get iterator => _PagedRowsRangeIterator<T>(_root, 0, length);

  @override
  Iterable<T> getRange(int start, int end) {
    RangeError.checkValidRange(start, end, length);
    return _PagedRowsRange<T>(_root, start, end);
  }

  // ListBase.map indexes each row. Route through an ordinary Iterable so a
  // full sequential mapping walks every node/row once instead of N log B.
  @override
  Iterable<R> map<R>(R Function(T) toElement) =>
      _PagedRowsRange<T>(_root, 0, length).map(toElement);
}

class _PagedRowsRange<T> extends Iterable<T> {
  const _PagedRowsRange(this.root, this.start, this.end);
  final _PagedRowsNode<T>? root;
  final int start;
  final int end;
  @override
  int get length => end - start;
  @override
  Iterator<T> get iterator => _PagedRowsRangeIterator(root, start, end);
}

class _ImmutablePagedRowsWithTail<T> extends ListBase<T> {
  _ImmutablePagedRowsWithTail(this.prefix, this.tail);
  final _ImmutablePagedRows<T> prefix;
  final List<T> tail;
  @override
  int get length => prefix.length + tail.length;
  @override
  set length(int value) => throw UnsupportedError('Immutable paged rows');
  @override
  T operator [](int index) {
    RangeError.checkValidIndex(index, this);
    return index < prefix.length ? prefix[index] : tail[index - prefix.length];
  }

  @override
  void operator []=(int index, T value) =>
      throw UnsupportedError('Immutable paged rows');
  @override
  Iterator<T> get iterator => _range(0, length).iterator;
  @override
  Iterable<T> getRange(int start, int end) {
    RangeError.checkValidRange(start, end, length);
    return _range(start, end);
  }

  Iterable<T> _range(int start, int end) sync* {
    if (start < prefix.length) {
      yield* prefix.getRange(start, end < prefix.length ? end : prefix.length);
    }
    if (end > prefix.length) {
      yield* tail.getRange(
        start > prefix.length ? start - prefix.length : 0,
        end - prefix.length,
      );
    }
  }

  @override
  Iterable<R> map<R>(R Function(T) toElement) =>
      _range(0, length).map(toElement);
}

class _PagedRowsRangeIterator<T> implements Iterator<T> {
  _PagedRowsRangeIterator(_PagedRowsNode<T>? root, int start, int end)
    : _pending = [if (root != null && start < end) (root, start, end)];

  final List<(_PagedRowsNode<T>, int, int)> _pending;
  List<T>? _leaf;
  int _position = 0;
  int _end = 0;
  T? _current;

  @override
  T get current => _current as T;

  @override
  bool moveNext() {
    while (true) {
      final leaf = _leaf;
      if (leaf != null && _position < _end) {
        _current = leaf[_position++];
        return true;
      }
      _leaf = null;
      if (_pending.isEmpty) {
        _current = null;
        return false;
      }
      final (node, start, end) = _pending.removeLast();
      if (node is _PagedRowsLeaf<T>) {
        _leaf = node.rows;
        _position = start;
        _end = end;
      } else {
        final branch = node as _PagedRowsBranch<T>;
        final leftLength = branch.left.length;
        if (end > leftLength) {
          _pending.add((
            branch.right,
            start > leftLength ? start - leftLength : 0,
            end - leftLength,
          ));
        }
        if (start < leftLength) {
          _pending.add((
            branch.left,
            start,
            end < leftLength ? end : leftLength,
          ));
        }
      }
    }
  }
}
