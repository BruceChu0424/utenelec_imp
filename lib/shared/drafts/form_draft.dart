import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:uuid/uuid.dart';

import '../badges/badge_module.dart';
import '../../core/router/route_names.dart';
import '../auth/document_permission_set.dart';

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
const financeBatchReadRecoveryOnlyKey = '_financeBatchReadRecoveryOnly';
const financeBatchOriginalAvailableKey = '_financeBatchOriginalAvailable';

class FinanceBatchDraftFamily {
  const FinanceBatchDraftFamily(this.segment, this.kind, this.permissions);
  final String segment, kind;
  final DocumentPermissionSet permissions;
  String get recoveryForm => '${kind}BatchRecovery';
  String get editorPath => '/finance/$segment/new';
}

const financeBatchDraftFamilies = <String, FinanceBatchDraftFamily>{
  'receipts': FinanceBatchDraftFamily(
    'receipts',
    'financeReceipt',
    DocumentPermissionCatalog.financeReceipt,
  ),
  'payments': FinanceBatchDraftFamily(
    'payments',
    'financePayment',
    DocumentPermissionCatalog.financePayment,
  ),
  'expenses': FinanceBatchDraftFamily(
    'expenses',
    'financeExpense',
    DocumentPermissionCatalog.financeExpense,
  ),
  'incomes': FinanceBatchDraftFamily(
    'incomes',
    'financeOtherIncome',
    DocumentPermissionCatalog.financeOtherIncome,
  ),
  'bank-transfers': FinanceBatchDraftFamily(
    'bank-transfers',
    'financeBankTransfer',
    DocumentPermissionCatalog.financeBankTransfer,
  ),
};

/// Only an original family/key-bearing batch can enter read-only recovery.
/// Unsent ordinary drafts and unrelated local records keep their write gate.
FinanceBatchDraftFamily? financeBatchRecoveryFamily(FormDraft draft) {
  if (!formDraftRouteIsLocal(draft.route) ||
      draft.module != BadgeModule.finance ||
      Uri.parse(draft.route).queryParameters.containsKey('draftForm') ||
      draft.data['entrySchema'] != 1) {
    return null;
  }
  final path = Uri.parse(draft.route).path;
  final family = financeBatchDraftFamilies.values
      .where((family) => family.editorPath == path)
      .firstOrNull;
  if (family == null ||
      draft.permission != family.permissions.create ||
      draft.draftKind != family.kind) {
    return null;
  }
  final command = draft.data['batchCommand'];
  final retired = draft.data['batchRetiredReceipt'];
  final key = command is Map
      ? command['idempotencyKey']
      : retired is Map && retired['outcome'] == 'CANCELLED_UNWRITTEN'
      ? retired['idempotencyKey']
      : draft.data[financeBatchReadRecoveryOnlyKey] == true &&
            draft.data[financeBatchOriginalAvailableKey] == true
      ? draft.data['createIdempotencyKey']
      : null;
  if (key is! String || !RegExp(r'^[A-Za-z0-9._:-]{8,120}$').hasMatch(key)) {
    return null;
  }
  return family;
}

const formDraftUnknownSubmissionKey = '_formDraftHasUnknownSubmission';
const formDraftRetirementConflictKey = '_formDraftRetirementConflict';
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
  if (Uri.tryParse(route)?.path == RouteName.productionMaterialAnalysis &&
      (data['legacyOriginalCommand'] is Map ||
          data['submittedBodyJson'] is String)) {
    return true;
  }
  if (Uri.tryParse(route)?.path == '${RouteName.workshopMaterialIssue}/batch') {
    final commands = data['commands'];
    if (commands is Map &&
        commands.values.any(
          (entry) => entry is Map && entry['state'] == 'unknown',
        )) {
      return true;
    }
  }
  if (Uri.tryParse(route)?.path == RouteName.workshopMaterialIssue &&
      data['command'] != null) {
    return true;
  }
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
  final form = Uri.tryParse(route)?.queryParameters['draftForm'];
  if (Uri.tryParse(route)?.path == RouteName.productionMaterialAnalysis &&
      hasUnknownFormDraftSubmission(data, route: route)) {
    final identities = <String>{};
    final legacy = data['legacyOriginalCommand'];
    if (legacy is Map && legacy['bodyJson'] is String) {
      final bytes = utf8.encode(
        jsonEncode([
          legacy['analysisId'],
          legacy['operation'],
          legacy['bodyJson'],
        ]),
      );
      identities.add('material-original:${crypto.sha256.convert(bytes)}');
    }
    final aggregate = data['submittedBodyJson'];
    if (aggregate is String) {
      identities.add(
        'material-aggregate:${crypto.sha256.convert(utf8.encode(jsonEncode([data['submittedAnalysisId'], aggregate])))}',
      );
    }
    return identities.isEmpty
        ? {'material-preparation:missing-original'}
        : identities;
  }
  if (const {'financeDocumentReview', 'financeDocumentEdit'}.contains(form)) {
    final intent = form == 'financeDocumentReview'
        ? data['intent']
        : data['editIntent'];
    final body = intent is Map ? intent['body'] : null;
    if (intent is Map && body is Map) {
      return {
        'finance-document:${intent['operation']}:${intent['documentId']}:${body['requestId']}',
      };
    }
    return hasUnknownFormDraftSubmission(data, route: route)
        ? {'finance-document:missing-original'}
        : {};
  }
  if (const {
        'applicationPayment',
        'applicationPrepaymentFinance',
      }.contains(Uri.tryParse(route)?.queryParameters['draftForm']) &&
      hasUnknownFormDraftSubmission(data, route: route)) {
    final command = data['_applicationPaymentCommand'];
    if (command is Map && command['fields'] is Map) {
      final fields = command['fields'] as Map;
      return {
        'application-payment:${command['action'] ?? 'pay'}:${command['applicationId']}:${command['expectedVersion']}:${fields['financeDocumentType']}:${fields['financeDocumentId']}:${fields['paymentDate']}:${fields['paymentReference']}',
      };
    }
    return {'application-payment:missing-command'};
  }
  if (Uri.tryParse(route)?.path == '${RouteName.workshopMaterialIssue}/batch') {
    final commands = data['commands'];
    return {
      if (commands is Map)
        for (final entry in commands.entries)
          if (entry.value is Map && (entry.value as Map)['state'] == 'unknown')
            'workshop-material:${entry.key}:${(entry.value as Map)['key']}',
    };
  }
  if (Uri.tryParse(route)?.path == RouteName.workshopMaterialIssue &&
      hasUnknownFormDraftSubmission(data, route: route)) {
    final command = data['command'];
    return {
      'workshop-material:${command is Map ? command['idempotencyKey'] : null}',
    };
  }
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

/// Lifecycle of an editor that autosaved back to its initial values (ADR-151):
/// no user fact remains, nothing is listed or restored, and the same identity
/// may be saved again. Unlike a `deleted` tombstone it is not terminal.
const formDraftCleanDiscardedLifecycle = 'DISCARDED_CLEAN';

bool isCleanDiscardedFormDraftRecord(Map<String, dynamic> json) =>
    json['completed'] != true &&
    json['lifecycle'] == formDraftCleanDiscardedLifecycle;

/// The record carries no payload: earlier revisions remain only in history.
Map<String, dynamic> cleanDiscardedFormDraftRecord(String id) => {
  'version': 1,
  'id': id,
  'lifecycle': formDraftCleanDiscardedLifecycle,
  'revision': 'clean:${const Uuid().v4()}',
  'discardedAt': DateTime.now().toUtc().toIso8601String(),
};

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
    final batch = financeBatchRecoveryFamily(this);
    if (batch != null && data[financeBatchReadRecoveryOnlyKey] == true) {
      return Uri(
        path: '/finance/${batch.segment}/batch-recovery',
        queryParameters: {'draftId': id},
      ).toString();
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
