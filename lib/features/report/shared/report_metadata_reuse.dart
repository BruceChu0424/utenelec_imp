import 'package:flutter/foundation.dart';

import 'report_data.dart';
import 'report_column.dart';

/// Bounded print previews use rows and columns without global metadata scans.
const reportRowsOnlyQuery = <String, dynamic>{
  'includeCount': false,
  'includeFacets': false,
  'includeTotals': false,
};

/// Reuses server metadata only for explicit pagination of the same read scope.
/// A new load owns a private candidate; failed or superseded loads cannot make
/// metadata available to a later request. Call [accept] only after publication.
class ReportMetadataReuse {
  ReportMetadataReuse({
    Duration lease = const Duration(seconds: 30),
    int Function()? monotonicMicros,
  }) : _leaseMicros = lease.inMicroseconds,
       _providedClock = monotonicMicros;
  final int _leaseMicros;
  final int Function()? _providedClock;
  final _clock = Stopwatch()..start();
  int _now() => _providedClock?.call() ?? _clock.elapsedMicroseconds;
  _ReportMetadata? _accepted;
  _ReportQuery? _acceptedQuery;
  final _schemas = <(_ReportQuery, List<ReportColumn>)>[];
  List<ReportColumn> _loadingColumns = const [];
  int _generation = 0;

  /// Only confirmed server columns may survive a category switch. This is a
  /// visual shell, never an accepted result or an empty-data assertion.
  ReportData get loadingData => ReportData(
    columns: _loadingColumns,
    rows: const [],
    facets: const {},
    page: 1,
    totalPages: 0,
    total: 0,
    meta: const {},
  );

  ReportMetadataRead begin({
    required String endpoint,
    required Map<String, dynamic> query,
    required int readerEpoch,
    bool reuseMetadata = false,
  }) {
    final identity = _ReportQuery(endpoint, query, readerEpoch);
    _schemas.removeWhere((entry) => entry.$1.readerEpoch != readerEpoch);
    _loadingColumns = const [];
    for (final entry in _schemas) {
      if (identity.matches(entry.$1)) {
        _loadingColumns = entry.$2;
        break;
      }
    }
    final previous = reuseMetadata && identity.matches(_acceptedQuery)
        ? _accepted
        : null;
    // Even a same-query retry must not inherit an unfinished/failed candidate.
    _accepted = null;
    _acceptedQuery = null;
    return ReportMetadataRead._(
      ++_generation,
      identity,
      previous,
      _now,
      _leaseMicros,
    );
  }

  void accept(ReportMetadataRead read) {
    if (read._generation != _generation || read._metadata == null) return;
    _acceptedQuery = read._query;
    _accepted = read._metadata;
    if (read._columns != null) {
      _schemas.removeWhere((entry) => read._query.matches(entry.$1));
      _schemas.add((read._query, List.unmodifiable(read._columns!)));
      if (_schemas.length > 12) _schemas.removeAt(0);
    }
  }

  void invalidate() {
    ++_generation;
    _accepted = null;
    _acceptedQuery = null;
    _schemas.clear();
    _loadingColumns = const [];
  }
}

class ReportMetadataRead {
  ReportMetadataRead._(
    this._generation,
    this._query,
    this._metadata,
    this._now,
    this._leaseMicros,
  );

  final int _generation;
  final _ReportQuery _query;
  _ReportMetadata? _metadata;
  List<ReportColumn>? _columns;
  final int Function() _now;
  final int _leaseMicros;

  /// A speculative page prepares its own candidate. Merging its response must
  /// not mutate the metadata owned by the accepted page or another read.
  ReportMetadataRead fork() =>
      ReportMetadataRead._(_generation, _query, _metadata, _now, _leaseMicros)
        .._columns = _columns;
  bool get _reusable =>
      _metadata != null &&
      _metadata!.source.statisticsGeneratedAt != null &&
      _now() - _metadata!.receivedAtMicros >= 0 &&
      _now() - _metadata!.receivedAtMicros < _leaseMicros;

  /// The first refresh page asks for complete metadata. Further pages in that
  /// same load can reuse its private candidate, without caching it prematurely.
  Map<String, dynamic> queryForPage(int page) {
    final version = _metadata?.source.readScopeVersion;
    return {
      ..._query.parameters,
      'page': page,
      if (_reusable && version != null && version.isNotEmpty) ...{
        ...reportRowsOnlyQuery,
        'metadataReuse': true,
        'readScopeVersion': version,
      },
    };
  }

  ReportData merge(ReportData response) {
    // Legacy/special endpoints may ignore the demand flags and return ALL.
    // Empty fresh facets/totals are authoritative too; never revive old values.
    if (response.total >= 0 && response.totalPages >= 0) {
      final previousVersion = _metadata?.source.readScopeVersion;
      if (previousVersion != null &&
          response.readScopeVersion != null &&
          previousVersion != response.readScopeVersion) {
        throw StateError('Report access scope changed during the read');
      }
      _metadata = _ReportMetadata(response, _now());
      _columns = response.columns;
      return response;
    }
    final metadata = _metadata;
    if (metadata != null &&
        metadata.source.readScopeVersion != response.readScopeVersion) {
      throw StateError('Report access scope changed during the read');
    }
    if (response.total != -1 ||
        response.totalPages != -1 ||
        metadata == null ||
        metadata.source.readScopeVersion?.isNotEmpty != true ||
        metadata.source.readScopeVersion != response.readScopeVersion) {
      throw StateError('Report metadata was omitted without a valid read');
    }
    _columns = response.columns;
    return ReportData(
      columns: response.columns,
      rows: response.rows,
      facets: metadata.source.facets,
      page: response.page,
      totalPages: metadata.source.totalPages,
      total: metadata.source.total,
      meta: response.meta,
      totals: metadata.source.totals,
      columnSearchKeys: response.columnSearchKeys,
      readScopeVersion: response.readScopeVersion,
      statisticsGeneratedAt: metadata.source.statisticsGeneratedAt,
    );
  }
}

class _ReportMetadata {
  _ReportMetadata(ReportData response, this.receivedAtMicros)
    : source = ReportData(
        columns: const [],
        rows: const [],
        facets: response.facets,
        page: 1,
        totalPages: response.totalPages,
        total: response.total,
        meta: const {},
        totals: response.totals,
        readScopeVersion: response.readScopeVersion,
        statisticsGeneratedAt: response.statisticsGeneratedAt,
        columnSearchKeys: response.columnSearchKeys,
      );

  // Rows and page-specific metadata are deliberately absent from this cache.
  final ReportData source;
  final int receivedAtMicros;
}

class _ReportQuery {
  _ReportQuery(this.endpoint, Map<String, dynamic> query, this.readerEpoch)
    : parameters = Map.unmodifiable({
        for (final entry in query.entries)
          if (!const {
            'page',
            'includeCount',
            'includeFacets',
            'includeTotals',
            'metadataReuse',
            'readScopeVersion',
          }.contains(entry.key))
            entry.key: entry.value,
      });

  final String endpoint;
  final Map<String, dynamic> parameters;
  final int readerEpoch;

  bool matches(_ReportQuery? other) =>
      other != null &&
      endpoint == other.endpoint &&
      readerEpoch == other.readerEpoch &&
      mapEquals(parameters, other.parameters);
}
