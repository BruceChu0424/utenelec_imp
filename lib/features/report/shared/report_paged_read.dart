import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/widgets.dart';

import '../../../core/network/api_exception.dart';
import '../../../shared/models/paged_result.dart';
import '../../../shared/paging/paged_read_intent.dart';
import '../../../shared/paging/scoped_paged_read.dart';
import '../../../shared/paging/read_view_activity.dart';
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

  @override
  ReportPageSnapshot withRows(
    List<Map<String, dynamic>> rows, {
    int page = 1,
    int? size,
    int? total,
    int? totalPages,
  }) {
    final combined = PagedResult<Map<String, dynamic>>(
      items: freezePagedRows(rows),
      page: page,
      size: size ?? rows.length,
      total: total ?? this.total,
      totalPages: totalPages ?? (rows.isEmpty ? 0 : 1),
      totals: totals,
      facets: facets,
      facetNullCounts: facetNullCounts,
      readScopeVersion: readScopeVersion,
    );
    return ReportPageSnapshot._(
      snapshot.withPage(combined),
      combined.size,
      _read,
      _owner,
    );
  }
}

/// Reports retain server-owned schema/statistics while sharing the complete
/// authorized query reader. View activity retires pending work independently
/// from accepted rows and their authorization session.
class ReportPagedRead {
  ReportPagedRead(this.metadata);

  final ReportMetadataReuse metadata;
  final _pages = ScopedPagedRead<Map<String, dynamic>>();
  FutureOr<void> Function()? _onViewResume;
  late final _activity = ReadViewActivity(
    onResume: () => _onViewResume?.call(),
  );

  void bindView(BuildContext context, {FutureOr<void> Function()? onResume}) {
    if (onResume != null) _onViewResume = onResume;
    _activity.bindView(context);
  }

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
    // Compatibility with former neighboring-page scheduling; neither option
    // controls complete-read continuation or foreground visibility.
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
      // Reuse only the same complete authorized query; no adjacent-page work
      // is scheduled. The legacy flag remains a compatibility input.
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
    _activity.dispose();
  }
}

class _ReportPageRevision {
  _ReportPageRevision(ReportData report, {bool includeStatistics = true})
    : _values = [
        report.readScopeVersion,
        report.columnSearchKeys.toList()..sort(),
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
    // An outer complete reader (fetchComplete) offers its progressive slot:
    // this report read owns the rows, so its batches are published there.
    final slot = PagedReadIntent.currentProgressive;
    final publish = slot != null && slot.claim() ? slot.publish : null;
    try {
      final fresh = _freshRead;
      _freshRead = false;
      return await _owner._activity.runRead(
        () => !_owner._disposed && _isCurrent(),
        () => _owner._pages.read(
          page,
          scope: _scope,
          fetchPage: _read,
          fetchPageSized: _read,
          isCurrent: () => !_owner._disposed && _isCurrent(),
          useCache: !fresh,
          revalidateWindow: !_revalidatingWindow,
          canPrefetch: () =>
              !_revalidatingWindow && (_canPrefetch?.call() ?? true),
          onPrefetchError: _onPrefetchError,
          onProgressiveBatch: publish == null
              ? null
              : (partial) => publish(partial as PagedResult<Object?>),
        ),
      );
    } catch (error) {
      if (isCurrent() && pagedReadAccessDenied(error)) _owner.invalidate();
      rethrow;
    }
  }

  Future<PagedResult<Map<String, dynamic>>> _read(int page, [int? size]) async {
    try {
      final candidate = _candidate.fork();
      final json = await _fetch(candidate.queryForPage(page, size: size));
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
          columnSearchKeys: report.columnSearchKeys,
        );
      }
      // This seed remains private to the query reader. Advancing it lets a
      // serial window transaction omit duplicate counts/statistics; only
      // ReportPagedRead.accept publishes metadata to the visible controller.
      _candidate = candidate;
      return ReportPageSnapshot._(report, size ?? _size, candidate, this);
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
