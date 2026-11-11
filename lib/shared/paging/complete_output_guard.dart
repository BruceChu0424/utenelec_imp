import 'paged_query_identity.dart';

/// One qualification contract for complete lists and their output consumers.
/// Validated prefixes are display-only. A same-query read can retain an
/// accepted result; a confirmed write retires it before the replacement read.
final class CompleteOutputGuard {
  PagedReadQueryKey? _accepted;
  int _generation = 0;
  int _retirement = 0;
  int get retirement => _retirement;

  bool hasComplete(Object identity) =>
      _accepted != null && _accepted == PagedReadQueryKey(identity);

  CompleteOutputRead<T> begin<T>({
    required Object identity,
    T? previous,
    bool preserveEditorInput = false,
  }) {
    final key = PagedReadQueryKey(identity);
    final accepted = _accepted == key;
    if (!accepted && _accepted != null) {
      _accepted = null;
      _retirement++;
    }
    final scaffold = preserveEditorInput && previous != null;
    return CompleteOutputRead._(
      ++_generation,
      key,
      accepted || scaffold ? previous : null,
      !accepted && !scaffold,
    );
  }

  bool isCurrent(CompleteOutputRead<Object?> read) =>
      read.generation == _generation;

  bool mayPublishPrefix(CompleteOutputRead<Object?> read) =>
      isCurrent(read) && read.publishPrefixes;

  bool accept(CompleteOutputRead<Object?> read) {
    if (!isCurrent(read)) return false;
    _accepted = read.identity;
    return true;
  }

  void retire() {
    _generation++;
    _retirement++;
    _accepted = null;
  }

  void retireAfterConfirmedWrite({bool confirmed = true}) {
    if (confirmed) retire();
  }
}

final class CompleteOutputRead<T> {
  const CompleteOutputRead._(
    this.generation,
    this.identity,
    this.fallback,
    this.publishPrefixes,
  );
  final int generation;
  final PagedReadQueryKey identity;
  final T? fallback;
  final bool publishPrefixes;
}
