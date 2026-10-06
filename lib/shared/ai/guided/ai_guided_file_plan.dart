import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/server_config.dart';
import '../../auth/permissions.dart';
import '../../providers/authenticated_scope_provider.dart';
import '../../../core/network/api_exception.dart';
import '../ai_job_models.dart';
import '../ai_job_repository.dart';
import '../chat/ai_chat_models.dart' show checkedAiChatId, safeAiChatPath;
import '../chat/ai_chat_repository.dart' show safeAiChatRoute;

enum AiGuidedWorkflow {
  salesOrder('SALES_ORDER'),
  salesQuote('SALES_QUOTE'),
  expenseClaim('EXPENSE_CLAIM'),
  none('NONE');

  const AiGuidedWorkflow(this.code);
  final String code;
  static AiGuidedWorkflow parse(Object? value) =>
      values.where((item) => item.code == value).firstOrNull ?? none;
  Set<String> get permissions => switch (this) {
    salesOrder => {Perm.salesOrderView, Perm.salesOrderCreate},
    salesQuote => {Perm.salesQuoteView, Perm.salesQuoteCreate},
    expenseClaim => {Perm.expenseApply},
    none => const {},
  };
}

typedef AiGuidedFileIdentity = ({
  AuthenticatedScope scope,
  String server,
  String permissions,
});

final aiGuidedFileIdentityProvider = Provider<AiGuidedFileIdentity?>((ref) {
  final scope = ref.watch(authenticatedScopeProvider);
  if (scope == null) return null;
  final permissions = ref.watch(currentPermissionsProvider).toList()..sort();
  return (
    scope: scope,
    server: ref.watch(apiBaseUrlProvider),
    permissions: permissions.join('\n'),
  );
});

const aiGuidedContentTypes = <String, String>{
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'xls': 'application/vnd.ms-excel',
  'csv': 'text/csv',
  'txt': 'text/plain',
  'pdf': 'application/pdf',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
  'docx':
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
};
const aiGuidedRouteKind = 'ERP_DOCUMENT_ROUTE';

/// Optional classification context, never a destination or access grant.
String? safeAiGuidedPageRoute(String? raw) {
  final path = safeAiChatRoute(raw);
  return path != null && path.length <= 240 ? path : null;
}

String aiGuidedRequestMessage(String message) {
  final value = _normalizedGuidedMessage(message);
  if (value.length <= 512) return value;
  final last = value.codeUnitAt(511);
  return value.substring(0, last >= 0xd800 && last <= 0xdbff ? 511 : 512);
}

bool aiGuidedRequestIsTruncated(String message) =>
    _normalizedGuidedMessage(message).length > 512;
String _normalizedGuidedMessage(String message) =>
    message.replaceAll(RegExp(r'[\x00-\x20\x7f-\x9f]+'), ' ').trim();

class AiGuidedChoice {
  const AiGuidedChoice(this.workflow, this.title);
  final AiGuidedWorkflow workflow;
  final String title;
}

/// A page the server offers for this file (already filtered by the caller's
/// permissions). The route is a fixed local path; the chat re-checks the
/// client route guard before going there.
class AiDocumentPage {
  const AiDocumentPage(this.key, this.title, this.route);
  final String key, title, route;
}

/// A follow-up the caller may not do, with a plain reason (display only).
class AiDocumentBlocked {
  const AiDocumentBlocked(this.title, this.reason);
  final String title, reason;
}

/// Non-PII structure the server read from one sheet (names and header labels
/// only, digit runs already masked by the server).
class AiDocumentSheet {
  const AiDocumentSheet(this.name, this.dataRows, this.columns);
  final String name;
  final int dataRows;
  final List<String> columns;
}

/// A route result is a proposed local form workflow, never an executable route
/// or a business write. Unknown fields and all server-internal evidence stay out.
class AiGuidedFileResult {
  AiGuidedFileResult.fromJson(Map<String, dynamic> json)
    : workflow = AiGuidedWorkflow.parse(json['workflow']),
      documentType = _text(json['documentType'], 80),
      title = _text(json['title'], 200),
      summary = _text(json['summary'], 2000),
      needsChoice = json['needsChoice'] != false,
      requiresReview = json['requiresReview'] != false,
      choices = [
        for (final choice in _maps(json['choices']))
          if (AiGuidedWorkflow.parse(choice['workflow']) !=
              AiGuidedWorkflow.none)
            AiGuidedChoice(
              AiGuidedWorkflow.parse(choice['workflow']),
              _text(choice['title'], 200),
            ),
      ],
      steps = _texts(json['steps'], 12),
      missingFields = _texts(json['missingFields'], 30),
      fields = {
        for (final entry in _map(json['fields']).entries)
          if (invoiceFields.contains(entry.key) && entry.value is String)
            entry.key: _text(entry.value, 2000),
      },
      fieldConfidence = {
        for (final entry in _map(json['fieldConfidence']).entries)
          if (invoiceFields.contains(entry.key))
            entry.key: _text(entry.value, 20),
      },
      fileName = _text(_map(json['source'])['fileName'], 500),
      sha256Hex = _sha256(_map(json['source'])['sha256']),
      typeSource = _oneOf(json['typeSource'], const {'RULES', 'AI'}, 'NONE'),
      intent = _oneOf(json['intent'], const {
        'RECONCILE',
        'IMPORT',
        'FILL',
        'ANALYZE',
        'QUESTION',
      }, 'NONE'),
      pages = [for (final page in _maps(json['pages'])) ?_page(page)],
      blocked = [
        for (final item in _maps(json['blocked']))
          if (_text(item['title'], 80).trim().isNotEmpty &&
              _text(item['reason'], 400).trim().isNotEmpty)
            AiDocumentBlocked(
              _text(item['title'], 80).trim(),
              _text(item['reason'], 400).trim(),
            ),
      ],
      sheets = [
        for (final sheet in _maps(_map(json['profile'])['sheets']))
          AiDocumentSheet(
            _text(sheet['name'], 40),
            sheet['dataRows'] is int && (sheet['dataRows'] as int) >= 0
                ? sheet['dataRows'] as int
                : 0,
            _texts(sheet['columns'], 40).map((c) => _text(c, 24)).toList(),
          ),
      ];

  static const invoiceFields = {
    'invoiceType',
    'invoiceCode',
    'invoiceNo',
    'issueDate',
    'sellerName',
    'sellerTaxNo',
    'buyerName',
    'buyerTaxNo',
    'amountExclTax',
    'taxAmount',
    'totalAmount',
    'itemSummary',
  };
  final AiGuidedWorkflow workflow;
  final String documentType, title, summary, fileName, sha256Hex;
  final bool needsChoice, requiresReview;
  final List<AiGuidedChoice> choices;
  final List<String> steps, missingFields;
  final Map<String, String> fields, fieldConfidence;

  /// How the file type was decided: RULES (titles/headers), AI (model
  /// fallback over non-PII structure) or NONE. Shown in the chat only.
  final String typeSource;

  /// What the user appears to want (RECONCILE/IMPORT/FILL/ANALYZE/QUESTION/NONE).
  final String intent;

  /// Chat-only follow-ups; never stored in a form draft ([toJson]).
  final List<AiDocumentPage> pages;
  final List<AiDocumentBlocked> blocked;
  final List<AiDocumentSheet> sheets;
  bool isHighConfidence(String field) => fieldConfidence[field] == 'HIGH';
  bool matchesSource(PlatformFile file) =>
      file.bytes != null &&
      fileName == file.name &&
      RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256Hex) &&
      sha256.convert(file.bytes!).toString() == sha256Hex;
  Map<String, dynamic> toJson() => {
    'workflow': workflow.code,
    'documentType': documentType,
    'title': title,
    'summary': summary,
    'needsChoice': needsChoice,
    'requiresReview': requiresReview,
    'choices': [
      for (final choice in choices)
        {'workflow': choice.workflow.code, 'title': choice.title},
    ],
    'steps': steps,
    'missingFields': missingFields,
    'fields': fields,
    'fieldConfidence': fieldConfidence,
    'source': {'fileName': fileName, 'sha256': sha256Hex},
  };
}

/// Typed router extra retains the original bytes and their verified identity.
/// Destination pages must recheck this fence before reading or applying it.
class AiGuidedFilePlan {
  factory AiGuidedFilePlan({
    required String jobId,
    required PlatformFile file,
    required AiGuidedFileResult result,
    required AiGuidedWorkflow workflow,
    required AiGuidedFileIdentity identity,
    String? pageRoute,
  }) {
    final bytes = Uint8List.fromList(
      file.bytes ?? const <int>[],
    ).asUnmodifiableView();
    final retained = PlatformFile(
      name: file.name,
      size: bytes.length,
      bytes: bytes,
    );
    return AiGuidedFilePlan._retained(
      jobId: jobId,
      file: retained,
      result: result,
      workflow: workflow,
      identity: identity,
      sourceSha256: sha256.convert(bytes).toString(),
      pageRoute: safeAiGuidedPageRoute(pageRoute),
    );
  }
  AiGuidedFilePlan._retained({
    required this.jobId,
    required this.file,
    required this.result,
    required this.workflow,
    required this.identity,
    required this.sourceSha256,
    required this.pageRoute,
  }) : _sourceMatches =
           file.bytes?.isNotEmpty == true &&
           result.fileName == file.name &&
           result.sha256Hex == sourceSha256;
  final String jobId;
  final PlatformFile file;
  final AiGuidedFileResult result;
  final AiGuidedWorkflow workflow;
  final AiGuidedFileIdentity identity;
  final String sourceSha256;
  final String? pageRoute;
  final bool _sourceMatches;
  String? _draftBytes;
  bool matches(WidgetRef ref) =>
      ref.read(aiGuidedFileIdentityProvider) == identity &&
      !identity.scope.readOnly &&
      workflow != AiGuidedWorkflow.none &&
      checkedAiChatId(jobId) != null &&
      ref.read(currentPermissionsProvider).containsAll(workflow.permissions) &&
      _sourceMatches;

  Map<String, dynamic> toLocalDraft({bool includeBytes = true}) => {
    'jobId': jobId,
    'workflow': workflow.code,
    'result': result.toJson(),
    'fileName': file.name,
    'pageRoute': ?pageRoute,
    if (includeBytes) 'bytes': _draftBytes ??= base64Encode(file.bytes!),
  };

  /// Called only after FormDraftMixin restores this account/server's own draft.
  static AiGuidedFilePlan? restoreLocalDraft(
    Object? raw,
    AiGuidedFileIdentity? identity,
  ) {
    if (raw is! Map<String, dynamic> ||
        identity == null ||
        raw['bytes'] is! String) {
      return null;
    }
    final jobId = checkedAiChatId(raw['jobId']);
    if (jobId == null) return null;
    if ((raw['bytes'] as String).length > 20 * 1024 * 1024 + 4) return null;
    final Uint8List bytes;
    try {
      bytes = base64Decode(raw['bytes'] as String);
    } on FormatException {
      return null;
    }
    if (bytes.isEmpty || bytes.length > 15 * 1024 * 1024) return null;
    final result = AiGuidedFileResult.fromJson(_map(raw['result']));
    final file = PlatformFile(
      name: _text(raw['fileName'], 500),
      size: bytes.length,
      bytes: bytes,
    );
    if (!result.matchesSource(file)) return null;
    final workflow = AiGuidedWorkflow.parse(raw['workflow']);
    if (workflow == AiGuidedWorkflow.none) return null;
    return AiGuidedFilePlan(
      jobId: jobId,
      workflow: workflow,
      result: result,
      file: file,
      identity: identity,
      pageRoute: raw['pageRoute'] is String ? raw['pageRoute'] as String : null,
    );
  }
}

/// Re-read the owner-scoped source job at every destination boundary. This
/// catches server-side department/revocation changes before /auth/me refreshes.
/// All downstream values come from this fresh result, never from router extra.
Future<AiGuidedFilePlan> validateAiGuidedFilePlan(
  WidgetRef ref,
  AiGuidedFilePlan plan,
) async {
  if (!plan.matches(ref)) throw ApiException('FORBIDDEN', '当前身份或权限已变化');
  final snapshot = await ref.read(aiJobRepositoryProvider).get(plan.jobId);
  if (!plan.matches(ref)) throw ApiException('FORBIDDEN', '当前身份或权限已变化');
  if (snapshot.id != plan.jobId ||
      snapshot.kind != aiGuidedRouteKind ||
      snapshot.status != AiJobStatus.succeeded ||
      snapshot.result == null) {
    throw ApiException('DOCUMENT_ROUTE_INVALID', '文件处理任务已失效，请重新上传');
  }
  final result = AiGuidedFileResult.fromJson(snapshot.result!);
  final allowed =
      (!result.needsChoice && result.workflow == plan.workflow) ||
      result.choices.any((choice) => choice.workflow == plan.workflow);
  if (!allowed ||
      result.fileName != plan.file.name ||
      result.sha256Hex != plan.sourceSha256) {
    throw ApiException('DOCUMENT_ROUTE_INVALID', '文件来源或可用流程已变化，请重新上传');
  }
  return AiGuidedFilePlan._retained(
    jobId: plan.jobId,
    file: plan.file,
    result: result,
    workflow: plan.workflow,
    identity: plan.identity,
    sourceSha256: plan.sourceSha256,
    pageRoute: plan.pageRoute,
  ).._draftBytes = plan._draftBytes;
}

String _text(Object? value, int limit) => value is String
    ? value.substring(0, value.length > limit ? limit : value.length)
    : '';
String _oneOf(Object? value, Set<String> allowed, String fallback) =>
    value is String && allowed.contains(value) ? value : fallback;
final _pageKey = RegExp(r'^[a-z][a-z0-9_]{0,47}$');
AiDocumentPage? _page(Map<String, dynamic> raw) {
  final key = raw['key'], title = raw['title'], route = raw['route'];
  if (key is! String || title is! String || route is! String) return null;
  final label = title.trim();
  return _pageKey.hasMatch(key) &&
          label.isNotEmpty &&
          label.length <= 40 &&
          safeAiChatPath(route) == route
      ? AiDocumentPage(key, label, route)
      : null;
}

String _sha256(Object? value) =>
    value is String && RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(value)
    ? value.toLowerCase()
    : '';
Map<String, dynamic> _map(Object? value) =>
    value is Map<String, dynamic> ? value : const {};
List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value.whereType<Map<String, dynamic>>().take(8).toList()
    : const [];
List<String> _texts(Object? value, int limit) => value is List
    ? value
          .whereType<String>()
          .take(limit)
          .map((text) => _text(text, 400))
          .toList()
    : const [];
