import '../../core/theme/uten_tokens.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/network/api_client.dart';
import '../../core/network/api_exception.dart';
import '../../core/router/nav_helpers.dart';
import '../../core/ui/app_notification.dart';
import '../providers/authenticated_scope_provider.dart';

const documentUnapprovalConfirmation =
    '反审会撤回这次审核产生的数量、库存和金额，保留原审核记录，并返回可编辑草稿。'
    '下游已使用的单据须先处理下游。确认反审？';

Future<Map<String, dynamic>> unapproveDocument(
  ApiClient api,
  String family,
  String id,
) async {
  final scope = await api.captureRequestScope(isCurrent: () => true);
  final confirmed = Zone.current[_unapprovalSnapshotKey];
  final capability = await scope.run(
    () => fetchDocumentUnapprovalCapability(api, family, id),
  );
  if (!capability.eligible && capability.nextAction != 'OPEN_SUCCESSOR') {
    throw ApiException('UNAPPROVAL_BLOCKED', capability.blockReason);
  }
  if (confirmed is _UnapprovalSnapshot &&
      confirmed.family == family &&
      confirmed.id == id &&
      capability.nextAction != 'OPEN_SUCCESSOR' &&
      confirmed.value != capability.factsSnapshot) {
    throw ApiException('CONFLICT', '反审条件在确认期间已变化，请重新核对。');
  }
  final response = await scope.run(
    () => api.post(
      '/documents/$family/$id/unapprove',
      body: {
        'idempotencyKey': 'unapprove:${const Uuid().v4()}',
        'reason': '反审后修订并重新审核',
        'expectedSnapshot': capability.factsSnapshot,
      },
    ),
  );
  requireUnapprovalEvidence(id, response);
  return response;
}

final Object _unapprovalSnapshotKey = Object();

class _UnapprovalSnapshot {
  const _UnapprovalSnapshot(this.family, this.id, this.value);
  final String family;
  final String id;
  final String value;
}

/// Binds the existing confirmation and its repository call to one reviewed generation.
Future<void> withDocumentUnapprovalSnapshot(
  String family,
  String id,
  String snapshot,
  FutureOr<void> Function() command,
) => runZoned(
  () async => await command(),
  zoneValues: {
    _unapprovalSnapshotKey: _UnapprovalSnapshot(family, id, snapshot),
  },
);

class DocumentUnapprovalCapability {
  const DocumentUnapprovalCapability({
    required this.eligible,
    required this.nextAction,
    required this.factsSnapshot,
    required this.reasons,
  });

  factory DocumentUnapprovalCapability.fromJson(Map<String, dynamic> value) {
    final snapshot = value['factsSnapshot'];
    final reasons = value['reasons'];
    final eligible = value['eligible'];
    final action = value['nextAction'];
    if (eligible is! bool ||
        action is! String ||
        snapshot is! String ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(snapshot) ||
        reasons is! List ||
        (eligible &&
            (value['supported'] != true ||
                value['permitted'] != true ||
                action != 'UNAPPROVE_TO_DRAFT')) ||
        reasons.any(
          (reason) =>
              reason is! Map ||
              reason['code'] is! String ||
              reason['message'] is! String,
        )) {
      throw ApiException('UNAPPROVAL_UNCONFIRMED', '反审条件尚未核实，请重新核对。');
    }
    return DocumentUnapprovalCapability(
      eligible: eligible,
      nextAction: action,
      factsSnapshot: snapshot,
      reasons: List.unmodifiable(
        reasons.map((reason) => (reason as Map)['message'] as String),
      ),
    );
  }

  final bool eligible;
  final String nextAction;
  final String factsSnapshot;
  final List<String> reasons;
  String get blockReason =>
      reasons.isEmpty ? '当前单据不能反审，请重新核对。' : reasons.join('\n');
}

Future<DocumentUnapprovalCapability> fetchDocumentUnapprovalCapability(
  ApiClient api,
  String family,
  String id,
) async => DocumentUnapprovalCapability.fromJson(
  await api.get('/documents/$family/$id/unapproval-capability'),
);

class DocumentUnapprovalEvidence {
  const DocumentUnapprovalEvidence(this.successorId, this.status);
  final String successorId;
  final int status;
  bool get isDraft => status == 0;
  String get message => documentUnapprovalStatusMessage(status);
}

/// A new-looking ID or a changed original status alone does not prove a successor relationship.
DocumentUnapprovalEvidence requireUnapprovalEvidence(
  String originalId,
  Map<String, dynamic> response,
) {
  final successorId = response['id'];
  final boundOriginal = response['unapprovalOriginalId'];
  final status = response['status'];
  if (successorId is! String ||
      successorId.trim().isEmpty ||
      successorId.toLowerCase() == originalId.toLowerCase() ||
      boundOriginal is! String ||
      boundOriginal.toLowerCase() != originalId.toLowerCase() ||
      status is! int ||
      !const {0, 1, -1, 2}.contains(status)) {
    throw ApiException('UNAPPROVAL_UNCONFIRMED', '反审结果的前后单据或当前状态尚未核实，请重新核对。');
  }
  return DocumentUnapprovalEvidence(successorId, status);
}

String documentUnapprovalStatusMessage(int? status) => switch (status) {
  0 => '已反审，进入草稿',
  1 => '原审核已撤回，后续单据已审核，请核对后续单据。',
  -1 => '原审核已撤回，后续单据又已反审，请沿关联核对。',
  2 => '原审核已撤回，后续单据已取消，请核对。',
  _ => '反审后续单据的当前状态尚未核实，请重新核对。',
};

void showDocumentUnapprovalResult(BuildContext context, int? status) {
  final message = documentUnapprovalStatusMessage(status);
  if (status == 0) {
    context.appSuccess(message);
  } else {
    context.appWarning(message);
  }
}

/// Replacing the page gives the successor its own async/identity scope and retains returnTo.
void openUnapprovedDraft(BuildContext context, String path) {
  final page = goRouterPageStateOrNull(context);
  if (page == null ||
      ModalRoute.of(context)?.isCurrent != true ||
      page.pageKey != GoRouter.of(context).state.pageKey) {
    return;
  }
  final query = Map<String, String>.from(page.uri.queryParameters)
    ..remove('history');
  context.pushReplacement(
    Uri.parse(
      path,
    ).replace(queryParameters: query.isEmpty ? null : query).toString(),
  );
}

String? unapprovalFamilyForRoute(String module, String segment) => const {
  'sales/orders': 'salesOrder',
  'sales/returns': 'salesReturn',
  'sales/other-shipments': 'salesOtherShipment',
  'purchase/orders': 'purchaseOrder',
  'purchase/receipts': 'purchaseReceipt',
  'purchase/returns': 'purchaseReturn',
  'subcontract/orders': 'subcontractOrder',
  'subcontract/inquiries': 'subcontractInquiry',
  'subcontract/receipts': 'subcontractReceipt',
  'subcontract/returns': 'subcontractReturn',
  'subcontract/material-issues': 'subcontractMaterialIssue',
  'subcontract/material-returns': 'subcontractMaterialReturn',
  'subcontract/wastes': 'subcontractWaste',
  'finance/receipts': 'financeReceipt',
  'finance/payments': 'financePayment',
  'finance/expenses': 'financeExpense',
  'finance/incomes': 'financeOtherIncome',
  'finance/bank-transfers': 'financeBankTransfer',
  'production/plans': 'productionPlan',
  'production/daily-reports': 'productionDailyReport',
}['$module/$segment'];

Widget documentUnapprovalBannerForRoute(
  String module,
  String segment,
  String id,
) {
  final family = unapprovalFamilyForRoute(module, segment);
  return family == null
      ? const SizedBox.shrink()
      : DocumentUnapprovalBanner(family: family, documentId: id);
}

/// Attachments remain on their audited original instead of sharing deletable object-storage keys.
class DocumentUnapprovalBanner extends ConsumerStatefulWidget {
  const DocumentUnapprovalBanner({
    super.key,
    required this.family,
    required this.documentId,
  });

  final String family;
  final String documentId;

  @override
  ConsumerState<DocumentUnapprovalBanner> createState() =>
      _DocumentUnapprovalBannerState();
}

class _DocumentUnapprovalBannerState
    extends ConsumerState<DocumentUnapprovalBanner> {
  List<Map<String, dynamic>> _links = const [];
  var _generation = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant DocumentUnapprovalBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.family != widget.family ||
        oldWidget.documentId != widget.documentId) {
      _links = const [];
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    final family = widget.family;
    final id = widget.documentId;
    try {
      final api = ref.read(apiClientProvider);
      final requestScope = await api.captureRequestScope(
        isCurrent: () =>
            mounted &&
            generation == _generation &&
            family == widget.family &&
            id == widget.documentId,
      );
      final result = await requestScope.run(
        () => api.get('/documents/$family/$id/unapproval'),
      );
      if (!mounted ||
          generation != _generation ||
          family != widget.family ||
          id != widget.documentId) {
        return;
      }
      final rows = result['links'];
      setState(() {
        _links = rows is List
            ? rows.whereType<Map<String, dynamic>>().toList()
            : const [];
      });
    } catch (_) {
      // Family/permission guards deliberately omit an unrelated lifecycle banner.
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(authenticatedScopeProvider, (previous, next) {
      if (previous == next) return;
      ++_generation;
      setState(() => _links = const []);
      if (next != null) _load();
    });
    if (_links.isEmpty) return const SizedBox.shrink();
    final uri = goRouterPageStateOrNull(context)?.uri;
    if (uri == null || !uri.pathSegments.contains(widget.documentId)) {
      return const SizedBox.shrink();
    }
    String relatedPath(String id) {
      final segments = List<String>.from(uri.pathSegments);
      final index = segments.indexOf(widget.documentId);
      if (index >= 0) segments[index] = id;
      if (segments.isNotEmpty && segments.last == 'edit') segments.removeLast();
      return uri.replace(pathSegments: ['', ...segments]).toString();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(UtenRadius.lg),
      ),
      child: Wrap(
        spacing: 12,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          const Text('反审记录保留；修订后可重新审核。'),
          for (final link in _links)
            if (link['draftId'] == widget.documentId)
              TextButton.icon(
                onPressed: () =>
                    context.push(relatedPath(link['originalId'] as String)),
                icon: const Icon(Icons.history, size: 18),
                label: const Text('反审前单据与附件'),
              )
            else
              TextButton.icon(
                onPressed: () =>
                    context.push(relatedPath(link['draftId'] as String)),
                icon: const Icon(Icons.edit_note, size: 18),
                label: Text('后续单据 ${link['draftBillNo']}'),
              ),
        ],
      ),
    );
  }
}
