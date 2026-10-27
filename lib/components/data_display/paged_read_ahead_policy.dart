/// Page-based preparation is independent of the bounded presentation window.
/// Targets stay close to the reader and never recursively follow fetched pages.
abstract final class PagedReadAheadPolicy {
  static const pagesAhead = 2;
  static const maximumTargets = pagesAhead * 2;

  static Iterable<int> next(int page) sync* {
    for (var distance = 1; distance <= pagesAhead; distance++) {
      yield page + distance;
    }
  }

  static Iterable<int> around(int page, {bool prepend = false}) sync* {
    for (final direction in [if (prepend) -1 else 1, if (prepend) 1 else -1]) {
      for (var distance = 1; distance <= pagesAhead; distance++) {
        yield page + direction * distance;
      }
    }
  }
}
