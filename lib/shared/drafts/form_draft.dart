import '../badges/badge_module.dart';
import '../../core/router/route_names.dart';

export '../badges/badge_module.dart';

/// A recoverable editor snapshot, never a submitted business document.
class FormDraftSpec {
  const FormDraftSpec({
    required this.title,
    required this.module,
    required this.route,
    required this.permission,
    this.draftKind,
  });

  final String title;
  final BadgeModule module;
  final String route;
  final String permission;
  final String? draftKind;

  /// The active editor is the authority for legacy and catalog-created drafts.
  /// Same-page dialogs can share a permission yet have incompatible payloads.
  bool canRestore(FormDraft draft, {required String currentRoute}) {
    if (!formDraftRouteIsLocal(draft.route) ||
        !formDraftRouteIsLocal(currentRoute) ||
        !formDraftRouteIsLocal(route)) {
      return false;
    }
    final stored = Uri.parse(draft.route);
    final expected = Uri.parse(route);
    final current = Uri.parse(currentRoute);
    return stored.path == current.path &&
        stored.path == expected.path &&
        draft.permission == permission &&
        draft.module == module &&
        draft.draftKind == draftKind &&
        _singleDraftForm(stored) == _singleDraftForm(expected) &&
        (stored.queryParametersAll['draftForm']?.length ?? 0) <= 1;
  }
}

String? _singleDraftForm(Uri uri) => uri.queryParameters['draftForm'];

bool formDraftRouteIsLocal(String route) {
  final uri = Uri.tryParse(route);
  return uri != null &&
      route.startsWith('/') &&
      !route.startsWith('//') &&
      !uri.hasScheme &&
      !uri.hasAuthority &&
      !uri.hasFragment &&
      !uri.path.contains('\\');
}

const dailyReportCreateCommandKey = '_dailyReportCreateRequest';
const dailyReportCreateReceiptKey = '_dailyReportCreateReceipt';
const dailyReportCreateStateKey = '_dailyReportCreateState';
const dailyReportReadRecoveryOnlyKey = '_dailyReportReadRecoveryOnly';
const formDraftUnknownSubmissionKey = '_formDraftHasUnknownSubmission';
const formDraftUnknownSubmissionMessage = '提交结果待核对，请先核对提交，原记录不能删除';

bool _isFqcDraftRoute(String route) {
  final path = Uri.tryParse(route)?.path ?? '';
  return path.startsWith('${RouteName.productionFqcSheetHandlingBase}/') ||
      path.startsWith('${RouteName.productionFqcInspectionHandlingBase}/');
}

List<Map<Object?, Object?>> _fqcRows(Map<String, dynamic> data) {
  final rows = data['rows'];
  return [
    if (data['row'] case final Map<Object?, Object?> row) row,
    if (rows is List) ...rows.whereType<Map<Object?, Object?>>(),
  ];
}

bool _fqcRowUnknown(Map<Object?, Object?> row) =>
    row['submissionState'] == 'unknown' ||
    (row['completed'] != true && row['submission'] is Map);

/// A persisted false marker is an editor's positive outcome distinction, not
/// permission to ignore a still-frozen legacy batch/FQC command.
bool hasUnknownFormDraftSubmission(
  Map<String, dynamic> data, {
  required String route,
  bool pendingFallback = false,
  bool honorMarker = true,
}) {
  final marker = honorMarker ? data[formDraftUnknownSubmissionKey] : null;
  if (marker == true) return true;
  if (Uri.tryParse(route)?.path ==
      RouteName.warehouseProductionDrawBatchIssue) {
    if (data['uncertain'] == true) return true;
    if (data['confirmedResult'] case final Map<Object?, Object?> receipt) {
      final counts = [
        receipt['issuedCount'],
        receipt['skippedCount'],
        receipt['replayedCount'],
      ];
      if (counts.every((value) => value is num && value >= 0) &&
          counts.cast<num>().fold<num>(0, (sum, value) => sum + value) > 0) {
        return false;
      }
    }
  }
  if (Uri.tryParse(route)?.path == '/production/daily-reports/new' &&
      data[dailyReportCreateStateKey] == 'UNKNOWN') {
    return true;
  }
  if (_isFqcDraftRoute(route)) {
    final rows = _fqcRows(data);
    if (rows.any(_fqcRowUnknown)) return true;
    // Completed commands and fresh unsent remainder rows are not forever held
    // by the former submission's generic pending flag.
    if (rows.isNotEmpty &&
        rows.every(
          (row) =>
              row['inspectionId'] is String &&
              (row['completed'] == true ||
                  const [
                    'notSent',
                    'rejected',
                    'confirmed',
                  ].contains(row['submissionState'])),
        )) {
      return false;
    }
  }
  if (marker == false) return false;
  // A single acknowledged creation can finish attachments. A partial list of
  // createdOrders/createdShipments does not prove every command was confirmed.
  if (['createdDocId', 'createdReportId', 'createdId'].any(
    (key) => data[key] is String && (data[key] as String).trim().isNotEmpty,
  )) {
    return false;
  }
  return pendingFallback || data['_formDraftSubmissionPending'] == true;
}

/// Known legacy protocols must retain their frozen identities even if GET
/// failed and the editor could not reconstruct rows. No feature dependencies.
Set<String> unknownFormDraftCommandIdentities(
  Map<String, dynamic> data, {
  required String route,
}) {
  if (Uri.tryParse(route)?.path == '/production/daily-reports/new' &&
      hasUnknownFormDraftSubmission(data, route: route)) {
    final command = data[dailyReportCreateCommandKey];
    return {
      command is Map
          ? 'daily-report-create:${command['idempotencyKey']}:${command['bodyHash']}'
          : 'daily-report-create:${data['idempotencyKey']}',
    };
  }
  if (_isFqcDraftRoute(route)) {
    return {
      for (final row in _fqcRows(data))
        if (_fqcRowUnknown(row))
          '${row['inspectionId']}:${row['idempotencyKey']}',
    };
  }
  if (Uri.tryParse(route)?.path ==
          RouteName.warehouseProductionDrawBatchIssue &&
      hasUnknownFormDraftSubmission(data, route: route)) {
    return {'batch:${data['requestKey']}'};
  }
  return {};
}

/// Legacy active records omit lifecycle. Completed or retired history records
/// are never eligible for recovery or a new local confirmation revision.
bool isActiveFormDraftRecord(Map<String, dynamic> json) =>
    json['completed'] != true &&
    (json['lifecycle'] == null || json['lifecycle'] == 'ACTIVE');

/// Only the original local daily-report submission gets a view-only recovery
/// route. Arbitrary drafts do not gain create/edit permission through this gate.
bool isDailyReportCreateRecoveryDraft(FormDraft draft) =>
    formDraftRouteIsLocal(draft.route) &&
    draft.module == BadgeModule.workshop &&
    draft.draftKind == 'productionDailyReport' &&
    draft.permission == 'production_daily_report:create' &&
    Uri.tryParse(draft.route)?.path == '/production/daily-reports/new' &&
    !Uri.parse(draft.route).queryParameters.containsKey('draftForm') &&
    (draft.hasUnknownSubmission ||
        draft.data[dailyReportCreateCommandKey] is Map ||
        draft.data[dailyReportReadRecoveryOnlyKey] == true);

class FormDraft {
  const FormDraft({
    required this.id,
    required this.title,
    required this.module,
    required this.route,
    required this.permission,
    required this.updatedAt,
    required this.data,
    this.draftKind,
    this.revision = '',
  });

  final String id;
  final String title;
  final BadgeModule module;
  final String route;
  final String permission;
  final String? draftKind;
  final DateTime updatedAt;
  final Map<String, dynamic> data;
  final String revision;

  bool get hasUnknownSubmission =>
      hasUnknownFormDraftSubmission(data, route: route);

  String get resumeLocation {
    if (isDailyReportCreateRecoveryDraft(this)) {
      return RoutePath.productionDailyReportCreateRecovery(id);
    }
    final uri = Uri.parse(route);
    return uri
        .replace(queryParameters: {...uri.queryParameters, 'draftId': id})
        .toString();
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'title': title,
    'module': module.name,
    'route': route,
    'permission': permission,
    'draftKind': draftKind,
    'updatedAt': updatedAt.toUtc().toIso8601String(),
    'data': data,
    'revision': revision,
  };

  factory FormDraft.fromJson(Map<String, dynamic> json) {
    if (json['version'] != 1) throw const FormatException('草稿版本不受支持');
    final route = json['route'] as String;
    if (!formDraftRouteIsLocal(route)) {
      throw const FormatException('草稿路径无效');
    }
    return FormDraft(
      id: json['id'] as String,
      title: json['title'] as String,
      module: BadgeModule.values.byName(json['module'] as String),
      route: route,
      permission: json['permission'] as String,
      draftKind: json['draftKind'] as String?,
      updatedAt: DateTime.parse(json['updatedAt'] as String),
      data: Map<String, dynamic>.from(json['data'] as Map),
      revision: json['revision'] as String? ?? '',
    );
  }
}
