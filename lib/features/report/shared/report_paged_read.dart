import 'package:collection/collection.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import 'report_data.dart';
import 'report_metadata_reuse.dart';

/// Rows and their complete display/authority metadata are one cached value.
class ReportPageSnapshot
    extends PagedReadSnapshot<Map<String, dynamic>, ReportData> {
  ReportPageSnapshot._(ReportData report, int size, this._read, this._owner)
    : super(
        page: PagedResult(
          items: report.rows,
          page: report.page,
          size: size,
          total: report.total,
          totalPages: report.totalPages,
          totals: report.totals,
          facets: report.facets,
          readScopeVersion: report.readScopeVersion,
        ),
        snapshot: report,
        revision: _ReportPageRevision(report),
      );

  final ReportMetadataRead _read;
  final ReportPageRead _owner;
}

/// Only report metadata differs from ordinary paged reads. The same bounded
/// cache, latest-center queue and reader retirement serve every manual pager.
class ReportPagedRead {
  ReportPagedRead(this.metadata);

  final ReportMetadataReuse metadata;
  final _pages = ScopedPagedRead<Map<String, dynamic>>();
  ReportPageRead? _active;
  Object? _snapshotRevision;
  int _revision = 0;
  bool _disposed = false;
  static const _equality = DeepCollectionEquality();
  Object? get snapshotRevision => _snapshotRevision;

  ReportPageRead begin({
    required String endpoint,
    required Map<String, dynamic> query,
    required int readerEpoch,
    required Future<Map<String, dynamic>> Function(Map<String, dynamic>) fetch,
    required bool Function() isCurrent,
    required bool reusePages,
    bool revalidatingWindow = false,
    bool Function()? canPrefetch,
    void Function(Object)? onPrefetchError,
    String? failureMessage,
  }) {
    final scope = [
      endpoint,
      Map<String, dynamic>.unmodifiable(query),
      readerEpoch,
    ];
    final previous = _active;
    if (reusePages &&
        previous != null &&
        previous.isCurrent() &&
        _equality.equals(previous._scope, scope)) {
      // A completed return-refresh window becomes an ordinary browser again;
      // keep its fresh cached pages while resuming adjacent preparation.
      previous._revalidatingWindow = revalidatingWindow;
      return previous;
    }
    // A fresh transaction for the same query retains its presentation session.
    // The read's new revision still rejects every earlier parser/UI receipt.
    if (previous == null ||
        !previous.isCurrent() ||
        !_equality.equals(previous._scope, scope)) {
      _pages.invalidate();
    }
    final candidate = metadata.begin(
      endpoint: endpoint,
      query: query,
      readerEpoch: readerEpoch,
      reuseMetadata: reusePages,
    );
    return _active = ReportPageRead._(
      this,
      ++_revision,
      scope,
      candidate,
      fetch,
      isCurrent,
      revalidatingWindow,
      !reusePages,
      canPrefetch,
      onPrefetchError,
      failureMessage,
      (query['size'] as num?)?.toInt() ?? 50,
    );
  }

  bool accept(PagedResult<Map<String, dynamic>>? result) {
    if (result is! ReportPageSnapshot || !result._owner.isCurrent()) {
      return false;
    }
    result._owner._candidate = result._read;
    // A statistics refresh replaces the retained rows atomically through the
    // controller. Only schema/access changes start a different table window.
    _snapshotRevision = _ReportPageRevision(
      result.snapshot,
      includeStatistics: false,
    );
    metadata.accept(result._read);
    return true;
  }

  void invalidate() {
    _revision++;
    _active = null;
    _snapshotRevision = null;
    _pages.invalidate();
    metadata.invalidate();
  }

  void dispose() {
    _disposed = true;
    invalidate();
    _pages.dispose();
  }
}

class _ReportPageRevision {
  _ReportPageRevision(ReportData report, {bool includeStatistics = true})
    : _values = [
        report.readScopeVersion,
        if (includeStatistics) report.statisticsGeneratedAt,
        for (final column in report.columns)
          [
            column.key,
            column.label,
            column.type,
            column.width,
            column.unitKey,
            column.unitLabel,
          ],
      ];

  final List<Object?> _values;
  static const _equality = DeepCollectionEquality();
  @override
  bool operator ==(Object other) =>
      other is _ReportPageRevision && _equality.equals(_values, other._values);
  @override
  int get hashCode => _equality.hash(_values);
}

class ReportPageRead {
  ReportPageRead._(
    this._owner,
    this._revision,
    this._scope,
    this._candidate,
    this._fetch,
    this._isCurrent,
    this._revalidatingWindow,
    this._freshRead,
    this._canPrefetch,
    this._onPrefetchError,
    this._failureMessage,
    this._size,
  );

  final ReportPagedRead _owner;
  final int _revision;
  final Object _scope;
  ReportMetadataRead _candidate;
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) _fetch;
  final bool Function() _isCurrent;
  bool _revalidatingWindow;
  bool _freshRead;
  final bool Function()? _canPrefetch;
  final void Function(Object)? _onPrefetchError;
  final String? _failureMessage;
  final int _size;

  bool isCurrent() =>
      !_owner._disposed &&
      _revision == _owner._revision &&
      identical(this, _owner._active) &&
      _isCurrent();

  Future<PagedResult<Map<String, dynamic>>> read(int page) async {
    try {
      final fresh = _freshRead;
      _freshRead = false;
      return await _owner._pages.read(
        page,
        scope: _scope,
        fetchPage: _read,
        isCurrent: () => !_owner._disposed && _isCurrent(),
        useCache: !fresh,
        revalidateWindow: !_revalidatingWindow,
        canPrefetch: () =>
            !_revalidatingWindow && (_canPrefetch?.call() ?? true),
        onPrefetchError: _onPrefetchError,
      );
    } catch (error) {
      if (isCurrent() && pagedReadAccessDenied(error)) _owner.invalidate();
      rethrow;
    }
  }

  Future<PagedResult<Map<String, dynamic>>> _read(int page) async {
    try {
      final candidate = _candidate.fork();
      final json = await _fetch(candidate.queryForPage(page));
      if (!isCurrent()) throw StateError('Report query changed');
      var report = candidate.merge(
        await parseReportResponseResponsive(json, page, isCurrent: isCurrent),
      );
      if (!isCurrent()) throw StateError('Report query changed');
      if (report.totalPages == 0) {
        report = ReportData(
          columns: report.columns,
          rows: const [],
          facets: report.facets,
          page: 1,
          totalPages: 0,
          total: report.total,
          meta: report.meta,
          totals: report.totals,
          readScopeVersion: report.readScopeVersion,
          statisticsGeneratedAt: report.statisticsGeneratedAt,
        );
      }
      // This seed remains private to the query reader. Advancing it lets a
      // serial window transaction omit duplicate counts/statistics; only
      // ReportPagedRead.accept publishes metadata to the visible controller.
      _candidate = candidate;
      return ReportPageSnapshot._(report, _size, candidate, this);
    } on ApiException {
      rethrow;
    } catch (error) {
      if (error is StateError &&
          error.message == 'Report access scope changed during the read') {
        throw ApiException('READ_SCOPE_CHANGED', '报表读取范围已变化，请刷新后重试');
      }
      if (!isCurrent() || _failureMessage == null) rethrow;
      throw ApiException('REPORT_LOAD_FAILED', _failureMessage);
    }
  }
}
