import 'dart:async';

/// A pager may prepare one page before an explicit destination without making
/// that buffer the reader's new destination. Its read must not recursively
/// predict another predecessor. The intent follows async callbacks only.
abstract final class PagedReadIntent {
  static final _bufferSeedKey = Object();
  static final _readingPageKey = Object();
  static final _acceptedPageKey = Object();
  static final _replaceWindowKey = Object();

  static bool get isBufferSeed => Zone.current[_bufferSeedKey] == true;

  static int? get readingPage => Zone.current[_readingPageKey] as int?;
  static bool get replaceWindow => Zone.current[_replaceWindowKey] == true;

  /// Separates a reader's visible page from the last fetched page. A completed
  /// cache hit can acknowledge navigation even when every DTO is unchanged.
  static R navigation<R>(
    int readingPage,
    R Function() read, {
    void Function(int)? onAccepted,
    bool replaceWindow = false,
  }) => runZoned(
    read,
    zoneValues: {
      _readingPageKey: readingPage,
      _acceptedPageKey: onAccepted,
      _replaceWindowKey: replaceWindow,
    },
  );

  static void accepted(int page) {
    final listener = Zone.current[_acceptedPageKey] as void Function(int)?;
    if (!isBufferSeed) listener?.call(page);
  }

  static R bufferSeed<R>(R Function() read) =>
      runZoned(read, zoneValues: {_bufferSeedKey: true});
}
