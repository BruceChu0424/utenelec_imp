// FQC（自制产成品）质检办理页——2026-09-12 对齐采购/委外 IQC 处置页范式。
//
// 用户口径：待检处置与生产成品质检里，自制产成品不管是双击还是右下角批量审批，
// 都进独立页面办理，不再叠弹窗；页面效果与采购收货（ProcurementInspectionDetailPage）
// 一样：单据摘要卡 + 行级可编辑明细表 + 右下角「提交报告」。
//   - ProductionFqcSheetHandlingPage：一张品质检查单（V547 同仓一次送检）的
//     办理页。一行 = 一批实物(ADR-148：同一报工、同一产出批次、同一去向的需求份 /
//     计划公共 / 实际超产)，行内直接改整批的合格/不合格数量(默认全合格)，含不合格
//     时行内选处置方式、确认弹窗收结论原因；提交按批逐条整批判定(服务端瀑布：合格先
//     满足需求份，不良先扣实际超产)，批级幂等键重试不重复。
//   - ProductionFqcInspectionPage：单条 FQC 任务（含无检查单的历史任务）的
//     详情 + 办理页。摘要卡展示送检登记事实，检验图片/文件就近挂载；决定表单
//     与检查单页同一套数量/处置口径。
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import '../../../shared/drafts/form_draft_mixin.dart';
import '../../../shared/drafts/form_draft_catalog.dart';
import '../../../shared/drafts/form_draft_values.dart';

import '../../../components/buttons/uten_app_bar_action_button.dart';
import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/data_display/uten_goods_identity_cell.dart';
import '../../../components/data_display/uten_status_badge.dart';
import '../../../components/feedback/uten_context_menu.dart';
import '../../../components/feedback/uten_empty.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/feedback/uten_busy_overlay.dart';
import '../../../components/feedback/uten_skeleton.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_grid_page_scrollbar.dart';
import '../../../core/network/api_exception.dart';
import '../../../shared/presentation/workflow_field_guidance.dart';
import '../../../core/network/server_config.dart';
import '../../../core/router/nav_helpers.dart';
import '../../../core/router/route_names.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/utils/china_datetime.dart';
import '../../../shared/attachments/business_attachment_section.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../basic_data/widgets/master_data_table_view.dart';
import '../models/production_fqc_inspection.dart';
import '../repositories/production_fqc_repository.dart';
import '../widgets/inspection_report_confirm_dialog.dart';
import '../widgets/production_fqc_dialogs.dart' show fqcStatusLabel;
import '../../../shared/badges/badge_registry.dart';

/// 数量展示（去尾零，保留实际精度）——与 production_fqc_dialogs.fqcQtyText 同口径。
String fqty(double value) => value
    .toStringAsFixed(4)
    .replaceFirst(RegExp(r'0+$'), '')
    .replaceFirst(RegExp(r'\.$'), '');

/// 不合格处置方式（与服务端 dispositionCode 同域）。
/// 先入库后检(V597)：已上架到成品仓库位的待检行，品质部到储放区域检验。
/// 没有上架行时返回 null(不渲染)。
Widget? fqcPreStockedNotice(
  Iterable<ProductionFqcInspection> inspections, {
  required Key key,
}) {
  final shelved = [
    for (final item in inspections)
      if (item.preStocked != null) item,
  ];
  if (shelved.isEmpty) return null;
  final shown = shelved.take(3).toList(growable: false);
  return UtenInlineNotice(
    key: key,
    level: UtenInlineNoticeLevel.error,
    title: '货品已入库，需到对应储放区域检查',
    message: [
      for (final item in shown)
        '${item.goodsName ?? item.goodsCode ?? '货品'} → ${item.preStocked!.label}',
      if (shelved.length > shown.length)
        '另 ${shelved.length - shown.length} 行见明细',
      '合格由系统按上架位置自动点收入库，不合格由仓库从库位取出处理',
    ].join('；'),
  );
}

/// 储放位置文本：已上架行「已入库 · 仓 / 库位」，否则登记库位。
String fqcStorageText(ProductionFqcInspection inspection) {
  final shelf = inspection.preStocked;
  if (shelf != null) return '已入库 · ${shelf.label}';
  return inspection.place ?? '—';
}

const List<(String, String)> kFqcDispositions = [
  ('REWORK', '返工'),
  ('SCRAP', '报废'),
  ('REJECT', '拒收/退回'),
];

String _dispositionLabel(String code) =>
    kFqcDispositions
        .where((entry) => entry.$1 == code)
        .map((entry) => entry.$2)
        .firstOrNull ??
    code;

/// 决定能力 = 审批权限 + 服务端品质组织校验（canDecide），与列表页同一口径。
bool _hasFqcApprovalPermission(WidgetRef ref) =>
    ref.read(isSuperAdminProvider) ||
    ref
        .read(currentPermissionsProvider)
        .contains(Perm.productionQualityInspectionApprove);

Future<bool> _canDecideFqc(WidgetRef ref) async {
  if (!_hasFqcApprovalPermission(ref)) return false;
  try {
    return await ref.read(productionFqcRepositoryProvider).canDecide();
  } catch (_) {
    return false;
  }
}

enum FqcSubmissionState { notSent, rejected, unknown, confirmed }

class _FqcSubmissionNotSent implements Exception {
  const _FqcSubmissionNotSent();
}

/// A late original-server response may finish there, but must not notify or pop
/// a different user's/server's page or a route pushed over this editor.
bool Function() _captureFqcResponseView(
  BuildContext context,
  WidgetRef ref,
  String Function() documentId, {
  required bool Function() identityIsCurrent,
}) {
  final scope = ref.read(authenticatedScopeProvider);
  final server = ref.read(apiBaseUrlProvider);
  final route = ModalRoute.of(context);
  final originalDocumentId = documentId();
  return () =>
      context.mounted &&
      identityIsCurrent() &&
      documentId() == originalDocumentId &&
      ref.read(authenticatedScopeProvider) == scope &&
      ref.read(apiBaseUrlProvider) == server &&
      (route == null || route.isCurrent);
}

// These structured application responses reject this attempt. After an earlier
// unknown attempt, even a later rejection cannot disprove that earlier commit.
bool _isFqcRejection(ApiException error) =>
    switch ((error.httpStatus, error.code)) {
      (400, 'MALFORMED_REQUEST' || 'BUSINESS' || 'VALIDATION_FAILED') ||
      (422, 'VALIDATION_FAILED') ||
      (409, 'CONFLICT') ||
      (401, 'UNAUTHORIZED') ||
      (403, 'FORBIDDEN') => true,
      _ => false,
    };

/// 一行可编辑的 FQC 检验报告（合格默认=待检、不合格默认=0），与 IQC 报告行同构。
class FqcReportRow {
  FqcReportRow(this.inspection)
    : pass = TextEditingController(text: fqty(inspection.remainingQty)),
      fail = TextEditingController(text: '0');

  final ProductionFqcInspection inspection;
  final TextEditingController pass;
  final TextEditingController fail;

  /// 不合格处置方式（含不合格数量的行在提交时必带；REWORK 为默认）。
  String disposition = 'REWORK';

  /// 行级幂等键：确认报告后冻结；服务端按 inspection + key 核对 request_hash。
  String idempotencyKey = 'fqc-report-${const Uuid().v4()}';
  bool selected = true;
  bool completed = false;
  Map<String, dynamic>? submission;
  FqcSubmissionState submissionState = FqcSubmissionState.notSent;
  String? submissionMessage;
  String? decisionEventId;
  int confirmedSubmissionCount = 0;
  Map<String, dynamic>? lastConfirmedSubmission;

  int get totalConfirmedSubmissions =>
      confirmedSubmissionCount + (completed ? 1 : 0);

  bool get needsReconciliation =>
      !completed && submissionState == FqcSubmissionState.unknown;

  String get submissionLabel => completed
      ? '已确认'
      : switch (submissionState) {
          FqcSubmissionState.notSent => '未提交',
          FqcSubmissionState.rejected => '明确拒绝',
          FqcSubmissionState.unknown => '待核对',
          FqcSubmissionState.confirmed => '已确认',
        };

  /// The guard durably checkpoints this row before the network closure begins.
  /// Its return value confirms the business write; later local work is separate.
  Future<ProductionFqcDecisionResult?> send({
    required String reason,
    required ProductionFqcRepository repository,
    required Future<ProductionFqcDecisionResult> Function(
      Future<ProductionFqcDecisionResult> Function() send,
      bool Function(ApiException) isDefiniteRejection,
    )
    guard,
  }) async {
    if (completed) return null;
    final wasUnknown = needsReconciliation;
    var dispatched = false;
    ApiException? definiteRejection;
    freezeSubmission(reason);
    submissionState = FqcSubmissionState.unknown;
    submissionMessage = null;
    try {
      if (idempotencyKey.trim().isEmpty) {
        throw StateError('旧草稿缺少原提交标识，请保留草稿并联系管理员核对');
      }
      final value = command;
      final result = await guard(
        () {
          dispatched = true;
          // ADR-148：检查单办理页一行是一批实物，走整批判定；单份任务仍逐份决定。
          if (inspection.lot != null) {
            return repository.decideLot(
              lotId: inspection.id,
              passQty: value.passQty ?? 0,
              failQty: value.failQty ?? 0,
              idempotencyKey: idempotencyKey,
              dispositionCode: submission?['disposition'] as String?,
              reason: submission?['reason'] as String?,
              sheetId: inspection.sheetId,
              sheetNo: inspection.sheetNo,
            );
          }
          return repository.decide(
            id: inspection.id,
            decision: value.decision,
            idempotencyKey: idempotencyKey,
            passQty: value.passQty,
            failQty: value.failQty,
            dispositionCode: submission?['disposition'] as String?,
            reason: submission?['reason'] as String?,
          );
        },
        (error) {
          final rejected = !wasUnknown && _isFqcRejection(error);
          if (rejected) definiteRejection = error;
          return rejected;
        },
      );
      if (result.decisionEventId.isEmpty ||
          result.inspection.id != inspection.id) {
        throw StateError('服务器回执不完整');
      }
      completed = true;
      selected = false;
      submissionState = FqcSubmissionState.confirmed;
      decisionEventId = result.decisionEventId;
      return result;
    } catch (error) {
      if (!wasUnknown && error is ApiException && _isFqcRejection(error)) {
        definiteRejection ??= error;
      }
      if (definiteRejection != null) {
        submissionState = FqcSubmissionState.rejected;
        submission = null;
        submissionMessage = definiteRejection!.message;
      } else if (!dispatched && !wasUnknown) {
        submissionState = FqcSubmissionState.notSent;
        submission = null;
        submissionMessage = error is _FqcSubmissionNotSent
            ? '页面已变化，本行未发送。返回原页面后可继续办理。'
            : '本机草稿尚未保存，本行未发送。请保留页面后重试。';
      } else {
        submissionState = FqcSubmissionState.unknown;
        submissionMessage = error is ApiException
            ? error.message
            : '暂时未收到可确认的结果';
      }
      return null;
    }
  }

  void freezeSubmission(String reason) {
    if (submission != null) return;
    final value = command;
    submission = {
      'decision': value.decision,
      'passQty': value.passQty,
      'failQty': value.failQty,
      'disposition': value.decision == 'PASS' ? null : disposition,
      'reason': value.decision == 'PASS' ? null : reason.trim(),
    };
  }

  Map<String, dynamic> toFormDraft() => {
    'inspectionId': inspection.id,
    'pass': pass.text,
    'fail': fail.text,
    'disposition': disposition,
    'idempotencyKey': idempotencyKey,
    'selected': selected,
    'completed': completed,
    'submission': submission,
    'submissionState': submissionState.name,
    'submissionMessage': submissionMessage,
    'decisionEventId': decisionEventId,
    'confirmedSubmissionCount': confirmedSubmissionCount,
    if (lastConfirmedSubmission != null)
      'lastConfirmedSubmission': lastConfirmedSubmission,
  };

  void restoreFormDraft(
    Map<String, dynamic> data, {
    bool allowConfirmedRemainder = false,
  }) {
    if (data['inspectionId'] != inspection.id) return;
    confirmedSubmissionCount =
        (data['confirmedSubmissionCount'] as num?)?.toInt() ?? 0;
    lastConfirmedSubmission = data['lastConfirmedSubmission'] is Map
        ? draftMap(data['lastConfirmedSubmission'])
        : null;
    if (allowConfirmedRemainder &&
        data['completed'] == true &&
        inspection.active &&
        inspection.remainingQty > 0) {
      // A confirmed command is not a completed inspection. Only a fresh read
      // may start its remaining quantity as a new, initially unselected command.
      if (lastConfirmedSubmission?['idempotencyKey'] !=
          data['idempotencyKey']) {
        confirmedSubmissionCount++;
      }
      lastConfirmedSubmission = {
        'idempotencyKey': data['idempotencyKey'],
        'decisionEventId': data['decisionEventId'],
        'submission': data['submission'],
      };
      pass.text = fqty(inspection.remainingQty);
      fail.text = '0';
      disposition = 'REWORK';
      idempotencyKey = 'fqc-report-${const Uuid().v4()}';
      selected = false;
      completed = false;
      submission = null;
      submissionState = FqcSubmissionState.notSent;
      submissionMessage =
          '上次提交已确认，仍有待检 ${fqty(inspection.remainingQty)}；可继续办理剩余数量。';
      decisionEventId = null;
      return;
    }
    pass.text = draftText(data, 'pass');
    fail.text = draftText(data, 'fail');
    disposition = draftText(data, 'disposition');
    idempotencyKey = draftText(data, 'idempotencyKey');
    selected = data['selected'] == true;
    completed = data['completed'] == true;
    submission = data['submission'] is Map
        ? draftMap(data['submission'])
        : null;
    // Earlier drafts only stored completed + frozen body. Conservatively keep
    // every unfinished frozen command pending, regardless of a fresh GET state.
    submissionState = completed
        ? FqcSubmissionState.confirmed
        : submission != null
        ? FqcSubmissionState.unknown
        : data['submissionState'] == 'rejected'
        ? FqcSubmissionState.rejected
        : FqcSubmissionState.notSent;
    submissionMessage = data['submissionMessage'] as String?;
    decisionEventId = data['decisionEventId'] as String?;
    if (submission != null) {
      pass.text = fqty(command.passQty ?? 0);
      fail.text = fqty(command.failQty ?? 0);
    }
  }

  double get passValue => double.tryParse(pass.text.trim()) ?? 0;
  double get failValue => double.tryParse(fail.text.trim()) ?? 0;

  /// null = 校验通过；否则 [message] 进行内红字、[category] 供批量提交按问题
  /// 归类汇总（合计超量的文案带本行待检量，按文案分组会分成几十组）。
  ({String category, String message})? get problem {
    // An uncertain response must replay the exact command even when a fresh
    // read already shows its quantity consumed. The endpoint owns idempotency.
    if (submission != null) return null;
    final remaining = inspection.remainingQty;
    if (passValue < 0 || failValue < 0) {
      return (category: '数量为负', message: '数量不能为负');
    }
    if (passValue + failValue <= 0) {
      return (category: '合格与不合格同时为 0', message: '合格与不合格不能同时为 0');
    }
    if (passValue + failValue > remaining + 1e-9) {
      return (category: '合计超过待检数量', message: '合计不能超过待检 ${fqty(remaining)}');
    }
    return null;
  }

  /// null = 校验通过；否则为错误文案。
  String? validate() => problem?.message;

  /// 由两个数量推导决定类型：纯合格 PASS、纯不合格 FAIL、混合 PARTIAL。
  ({String decision, double? passQty, double? failQty}) get command {
    final frozen = submission;
    if (frozen != null) {
      return (
        decision: frozen['decision'] as String,
        passQty: (frozen['passQty'] as num?)?.toDouble(),
        failQty: (frozen['failQty'] as num?)?.toDouble(),
      );
    }
    return failValue <= 0
        ? (decision: 'PASS', passQty: passValue, failQty: null)
        : passValue <= 0
        ? (decision: 'FAIL', passQty: null, failQty: failValue)
        : (decision: 'PARTIAL', passQty: passValue, failQty: failValue);
  }

  /// Bind the confirmation to the command it displayed. Pending commands use
  /// their frozen body, so factual refreshes cannot change a recovery request.
  String get _reviewFingerprint {
    final value = command;
    return jsonEncode({
      'key': idempotencyKey,
      'completed': completed,
      'selected': selected,
      'body':
          submission ??
          {
            'decision': value.decision,
            'passQty': value.passQty,
            'failQty': value.failQty,
            'disposition': value.decision == 'PASS' ? null : disposition,
          },
    });
  }

  String get label => [
    inspection.reportNo == null || inspection.reportNo!.isEmpty
        ? inspection.id
        : inspection.reportNo,
    inspection.goodsName,
    if (inspection.colorName?.isNotEmpty == true) '(${inspection.colorName})',
  ].whereType<String>().join(' · ');

  void dispose() {
    pass.dispose();
    fail.dispose();
  }
}

Widget? _fqcSubmissionNotice(
  List<FqcReportRow> rows, {
  required Key key,
  required bool canDecide,
}) {
  if (!rows.any(
    (row) =>
        row.totalConfirmedSubmissions > 0 ||
        row.needsReconciliation ||
        row.submissionMessage != null,
  )) {
    return null;
  }
  final completedRows = rows.where((row) => row.completed).length;
  final confirmed = rows.fold<int>(
    0,
    (count, row) => count + row.totalConfirmedSubmissions,
  );
  final unknown = rows.where((row) => row.needsReconciliation).length;
  final rejected = rows
      .where((row) => row.submissionState == FqcSubmissionState.rejected)
      .length;
  final notSent = rows.length - completedRows - unknown - rejected;
  return UtenInlineNotice(
    key: key,
    level: unknown > 0 || rejected > 0
        ? UtenInlineNoticeLevel.warning
        : UtenInlineNoticeLevel.info,
    title: unknown > 0
        ? '提交结果待核对'
        : rejected > 0
        ? '本次提交未通过'
        : '提交进度',
    message: [
      '已确认 $confirmed 次提交 · 明确拒绝 $rejected 行 · 待核对 $unknown 行 · 未提交 $notSent 行。',
      for (final row
          in rows.where((row) => row.submissionMessage != null).take(3))
        '${row.label}：${row.submissionMessage}',
      if (unknown > 0)
        canDecide
            ? '原提交内容已保留。刷新可查看当前进度；点击「核对并继续原提交」按原内容继续办理。'
            : '原提交内容已保留，当前无办理权限；请恢复权限后继续核对。',
      if (rejected > 0) '已明确拒绝的行可以修改后重新提交。',
      if (confirmed > 0) '已确认的原提交不会重发；剩余待检数量刷新后另行办理。',
    ].join('\n'),
  );
}

/// A recovery action only handles frozen rows. New rows keep their ordinary
/// report confirmation and are submitted after the uncertain command is settled.
Future<bool> _confirmOriginalFqcReport(
  BuildContext context,
  List<FqcReportRow> rows,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('核对并继续原提交'),
        content: Text(
          [
            '将按以下原内容继续办理。服务器已登记的决定会返回已有结果，其余行继续登记；遇到未确认或拒绝时停止。',
            for (final row in rows)
              '${row.label}：合格 ${fqty(row.command.passQty ?? 0)}，不合格 ${fqty(row.command.failQty ?? 0)}'
                  '${row.submission?['reason'] == null ? '' : '；${row.submission!['reason']}'}',
            '本次先核对待确认行，尚未提交的其他行保留，核对完成后可继续提交。',
          ].join('\n\n'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('继续原提交'),
          ),
        ],
      ),
    ) ??
    false;

/// 按单位分组的数量合计文本（跨单位绝不相加，与全站口径一致）。
String _fqcTotalsText(
  Iterable<FqcReportRow> rows,
  double Function(FqcReportRow) valueOf,
) {
  final byUnit = <String, double>{};
  for (final row in rows) {
    final unit = row.inspection.unitName?.trim();
    final key = unit == null || unit.isEmpty ? '' : unit;
    byUnit.update(
      key,
      (sum) => sum + valueOf(row),
      ifAbsent: () => valueOf(row),
    );
  }
  return [
    for (final entry in byUnit.entries)
      '${fqty(entry.value)}${entry.key.isEmpty ? '' : ' ${entry.key}'}',
  ].join(' · ');
}

/// 批量校验的问题行清单：最多列前 8 条，其余折成「等 N 行」——顶部通知里十几条
/// 会刷屏，前几条足够定位，改完再提交剩下的还会继续提示。
String _joinRowLabels(List<String> labels) {
  const limit = 8;
  final shown = labels.take(limit).join('；');
  return labels.length <= limit ? shown : '$shown 等 ${labels.length} 行';
}

/// ———————————————————— 检查单办理页（V547 一单一页） ————————————————————

class ProductionFqcSheetHandlingPage extends ConsumerStatefulWidget {
  const ProductionFqcSheetHandlingPage({super.key, required this.sheetId});

  /// GoRouter's page key identifies the route pattern, not its dynamic ID.
  /// A different document/draft must own a new State and draft lifecycle.
  static Widget route(BuildContext context, GoRouterState state) {
    final id = state.pathParameters['sheetId']!;
    return ProductionFqcSheetHandlingPage(
      key: ValueKey((id, state.uri.queryParameters['draftId'])),
      sheetId: id,
    );
  }

  final String sheetId;

  @override
  ConsumerState<ProductionFqcSheetHandlingPage> createState() =>
      _ProductionFqcSheetHandlingPageState();
}

class _ProductionFqcSheetHandlingPageState
    extends ConsumerState<ProductionFqcSheetHandlingPage>
    with FormDraftMixin<ProductionFqcSheetHandlingPage> {
  String _draftReason = '';
  @override
  bool get formDraftBusy => _confirming || _submitting || _loading;
  @override
  bool get formDraftHasUnknownSubmission => _rows == null
      ? super.formDraftHasUnknownSubmission
      : _rows!.any((row) => row.needsReconciliation);
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.fqcSheet.spec(
    title: '自制产成品质检报告',
    route: RouteName.productionFqcSheetHandling(widget.sheetId),
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    for (final row in _rows ?? <FqcReportRow>[]) ...[row.pass, row.fail],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'reason': _draftReason,
    'rows': [for (final row in _rows ?? <FqcReportRow>[]) row.toFormDraft()],
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    _draftReason = draftText(data, 'reason');
    final saved = {
      for (final row in draftMaps(data['rows'])) row['inspectionId']: row,
    };
    for (final inspection
        in _detail?.lotInspections ?? <ProductionFqcInspection>[]) {
      final value = saved[inspection.id];
      if ((value?['submission'] is Map || value?['completed'] == true) &&
          !(_rows ?? <FqcReportRow>[]).any(
            (row) => row.inspection.id == inspection.id,
          )) {
        (_rows ??= []).add(FqcReportRow(inspection));
      }
    }
    for (final row in _rows ?? <FqcReportRow>[]) {
      final value = saved[row.inspection.id];
      if (value != null) {
        row.restoreFormDraft(value, allowConfirmedRemainder: true);
      }
    }
  }

  ProductionFqcInspectionSheetDetail? _detail;
  List<FqcReportRow>? _rows;
  bool _loading = true;
  bool _confirming = false;
  bool _submitting = false;
  int _loadGeneration = 0;
  bool _canDecide = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    _load();
  }

  @override
  void dispose() {
    _rows?.forEach((row) => row.dispose());
    super.dispose();
  }

  Future<void> _load({
    bool preserveInput = true,
    bool afterSubmission = false,
  }) async {
    if (!formDraftIdentityIsCurrent ||
        _confirming ||
        (_submitting && !afterSubmission)) {
      return;
    }
    final generation = ++_loadGeneration;
    bool accepts() =>
        formDraftIdentityIsCurrent &&
        generation == _loadGeneration &&
        !_confirming &&
        (!_submitting || afterSubmission);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final detail = await ref
          .read(productionFqcRepositoryProvider)
          .sheetDetail(widget.sheetId);
      if (!accepts()) return;
      final canDecide = await _canDecideFqc(ref);
      if (!accepts()) return;
      // ADR-148：一批实物一行(批内各份合计)，整批判定。
      final rows = [
        for (final inspection in detail.activeLotInspections)
          FqcReportRow(inspection),
      ];
      final previousRows = _rows ?? <FqcReportRow>[];
      if (preserveInput) {
        final saved = {
          for (final row in previousRows) row.inspection.id: row.toFormDraft(),
        };
        for (final inspection in detail.lotInspections) {
          final value = saved[inspection.id];
          if ((value?['submission'] is Map || value?['completed'] == true) &&
              !rows.any((row) => row.inspection.id == inspection.id)) {
            rows.add(FqcReportRow(inspection));
          }
        }
        for (final row in rows) {
          if (saved[row.inspection.id] case final value?) {
            row.restoreFormDraft(value, allowConfirmedRemainder: true);
          }
        }
        for (final previous in previousRows) {
          if ((previous.submission != null || previous.completed) &&
              !rows.any((row) => row.inspection.id == previous.inspection.id)) {
            rows.add(
              FqcReportRow(previous.inspection)
                ..restoreFormDraft(previous.toFormDraft()),
            );
          }
        }
      }
      setState(() {
        _detail = detail;
        _canDecide = canDecide;
        _rows = rows;
        _loading = false;
      });
      for (final row in previousRows) {
        row.dispose();
      }
      await initializeFormDraft();
    } on ApiException catch (error) {
      if (!accepts()) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!accepts()) return;
      setState(() {
        _error = '品质检查单加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  List<FqcReportRow> get _selected => (_rows ?? const [])
      .where((row) => row.selected && !row.completed)
      .toList();

  Future<void> _submitReport() async {
    if (_loading ||
        _confirming ||
        _submitting ||
        !_canDecide ||
        !_hasFqcApprovalPermission(ref) ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    final requested = _selected;
    final pending = requested.where((row) => row.needsReconciliation).toList();
    final selected = pending.isEmpty ? requested : pending;
    if (selected.isEmpty) {
      context.appWarning('请先勾选要提交的明细行');
      return;
    }
    final problems = <String, List<String>>{};
    for (final row in selected) {
      final problem = row.problem;
      if (problem != null) {
        problems.putIfAbsent(problem.category, () => []).add(row.label);
      }
    }
    if (problems.isNotEmpty) {
      context.appWarning(
        [
          for (final entry in problems.entries)
            '以下 ${entry.value.length} 行${entry.key}，请改正后再提交：${_joinRowLabels(entry.value)}',
        ].join('\n'),
      );
      return;
    }
    final reviewed = {for (final row in selected) row: row._reviewFingerprint};
    final canPublish = _captureFqcResponseView(
      context,
      ref,
      () => widget.sheetId,
      identityIsCurrent: () => formDraftIdentityIsCurrent,
    );
    // A queued or older read cannot replace the rows owned by this review.
    ++_loadGeneration;
    setState(() => _confirming = true);
    String? reason;
    try {
      if (pending.isNotEmpty) {
        if (!await _confirmOriginalFqcReport(context, selected) || !mounted) {
          return;
        }
        reason = '';
      } else {
        reason = await showInspectionReportConfirmDialog(
          context,
          lineCount: selected.length,
          passTotalText: _fqcTotalsText(selected, (row) => row.passValue),
          failTotalText: _fqcTotalsText(selected, (row) => row.failValue),
          requireReason: selected.any((row) => row.failValue > 0),
          initialReason: _draftReason,
          onReasonChanged: (value) => setState(() => _draftReason = value),
          lines: [
            for (final row in selected)
              InspectionReportConfirmLine(
                label: row.label,
                passText: fqty(row.passValue),
                failText: fqty(row.failValue),
                dim: row.inspection.unitName,
              ),
          ],
        );
      }
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (reason == null ||
        !mounted ||
        !canPublish() ||
        !_canDecide ||
        !_hasFqcApprovalPermission(ref)) {
      return;
    }
    if (!reviewed.entries.every(
      (entry) =>
          (_rows?.contains(entry.key) ?? false) &&
          entry.key._reviewFingerprint == entry.value,
    )) {
      context.appWarning('明细已变化，请重新核对检验数量后确认');
      return;
    }
    if (pending.isEmpty &&
        selected.any((row) => row.failValue > 0) &&
        reason.trim().length < 2) {
      context.appWarning('含不合格数量时结论原因至少 2 个字');
      return;
    }
    setState(() => _submitting = true);
    var confirmed = 0;
    try {
      for (final row in selected) {
        if (!mounted || !canPublish()) return;
        final result = await row.send(
          reason: reason,
          repository: ref.read(productionFqcRepositoryProvider),
          guard: (send, reject) => runFormDraftSubmission(() {
            if (!canPublish() || !_hasFqcApprovalPermission(ref)) {
              throw const _FqcSubmissionNotSent();
            }
            return send();
          }, isDefiniteRejection: reject),
        );
        if (!mounted || !canPublish()) return;
        setState(() {});
        if (result == null) {
          try {
            await saveFormDraftNow();
          } catch (_) {
            _error = '本机恢复记录暂存失败，请保留页面；提交结果见上方说明';
          }
          await _load(afterSubmission: true);
          return;
        }
        confirmed++;
        // Confirmed rows are fenced in memory before any local checkpoint.
        await checkpointFormDraftAfterCreation();
      }
      if (!mounted || !canPublish()) return;
      context.appSuccess(
        pending.isNotEmpty
            ? '原提交已确认：$confirmed 行；请以当前任务状态为准'
            : '检验报告已确认：$confirmed 行决定已登记',
      );
      refreshBadges(ref);
      await _load(afterSubmission: true);
      if (_error == null &&
          !(_rows ?? <FqcReportRow>[]).any((row) => !row.completed)) {
        await completeFormDraft();
      }
    } catch (_) {
      // This boundary contains only local persistence, refresh and navigation.
      // Every successful response has already fenced its row as confirmed.
      if (canPublish()) {
        setState(() => _error = '提交结果已保留，页面更新或本机保存未完成，请刷新查看；已确认行不会再次提交');
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: detail == null
              ? '品质检查单办理'
              : '品质检查单办理 · ${detail.sheet.sheetNo}',
          leading: UtenBackButton(
            onPressed: () => popOrBackTo(
              context,
              defaultPath: RouteName.warehouseInspections,
            ),
          ),
          actions: [
            UtenAppBarActionButton(
              label: '刷新',
              icon: Icons.refresh_rounded,
              isLoading: _loading,
              onPressed: _loading || _confirming || _submitting ? null : _load,
            ),
          ],
        ),
        body: SafeArea(
          child: _loading && detail == null
              ? const UtenSkeletonList()
              : _error != null && detail == null
              ? UtenEmpty.error(
                  message: _error,
                  actionLabel: '重新加载',
                  onAction: _load,
                )
              : Stack(
                  children: [
                    AbsorbPointer(
                      absorbing: _loading || _confirming || _submitting,
                      child: _buildBody(context),
                    ),
                    // 2026-09-12 用户口径：逐行提交期间屏幕中间加载动画。
                    if (_submitting)
                      const Positioned.fill(
                        child: UtenBusyOverlay(
                          title: '正在提交检验报告',
                          description: '逐行登记质检决定，已完成行不会重复提交。',
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    final theme = Theme.of(context);
    final detail = _detail!;
    final rows = _rows!;
    final activeRows = rows
        .where((row) => !row.completed)
        .toList(growable: false);
    return UtenContentContainer.wide(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (fqcPreStockedNotice(
                  activeRows.map((row) => row.inspection),
                  key: const Key('fqc-sheet-pre-stocked-notice'),
                )
                case final notice?) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s16,
                ),
                child: notice,
              ),
              const SizedBox(height: UtenSpacing.s8),
            ],
            _buildSummaryCard(theme, detail, activeRows.length),
            if (_fqcSubmissionNotice(
                  rows,
                  key: const Key('fqc-sheet-submission-result'),
                  canDecide: _canDecide,
                )
                case final notice?)
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                child: notice,
              ),
            if (_error != null) ...[
              const SizedBox(height: UtenSpacing.s8),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: UtenSpacing.s16,
                ),
                child: Text(
                  '刷新失败：$_error',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            ],
            if (_submitting) ...[
              const SizedBox(height: UtenSpacing.s8),
              const LinearProgressIndicator(key: Key('fqc-sheet-progress')),
            ],
            const SizedBox(height: UtenSpacing.s8),
            Expanded(
              child: activeRows.isEmpty
                  ? UtenEmpty(
                      icon: Icons.verified_outlined,
                      message:
                          _error == null && detail.activeLotInspections.isEmpty
                          ? '本检查单当前待检已全部处理完成'
                          : '本次提交已确认，待检状态尚未刷新',
                      description:
                          _error == null && detail.activeLotInspections.isEmpty
                          ? '请以当前品质结果与仓库记录为准；返回待检处置继续下一单。'
                          : '刷新后核对剩余待检数量，再继续办理。已确认的原提交不会重发。',
                      actionLabel:
                          _error == null && detail.activeLotInspections.isEmpty
                          ? '返回待检处置'
                          : '刷新待检状态',
                      onAction:
                          _error == null && detail.activeLotInspections.isEmpty
                          ? () => popOrBackTo(
                              context,
                              defaultPath: RouteName.warehouseInspections,
                            )
                          : _load,
                    )
                  : AbsorbPointer(
                      absorbing: !_canDecide,
                      child: MasterDataTableView<FqcReportRow>(
                        tableKey:
                            'features.quality.pages.production_fqc_handling_page.ProductionFqcSheetHandlingPageState._buildBody.1',
                        key: const Key('fqc-sheet-report-table'),
                        columns: _rowColumns(theme),
                        items: activeRows,
                        facets: const {},
                        nullCounts: const {},
                        filters: const {},
                        onFilterChanged: (_, _) {},
                        selectable: _canDecide,
                        idOf: (row) => row.inspection.id,
                        selectedIds: {
                          for (final row in activeRows)
                            if (row.selected) row.inspection.id,
                        },
                        onSelectedIdsChanged: (next) => setState(() {
                          for (final row in activeRows) {
                            row.selected = next.contains(row.inspection.id);
                          }
                        }),
                        batchActionsBuilder: _canDecide ? _batchActions : null,
                        rowMenuBuilder: (row) => [
                          UtenMenuItem(
                            label: '查看详情与证据',
                            icon: Icons.visibility_outlined,
                            // 单任务办理页里登记了决定的话，返回时重拉本检查单
                            // （fire-and-forget push 此前不重载，行状态停在旧值）。
                            // 一行是一批实物：详情页看批内第一份(证据挂在报工份上)。
                            onTap: () async {
                              final member =
                                  row.inspection.lot?.members.firstOrNull;
                              await context.push(
                                RouteName.productionFqcInspectionHandling(
                                  member?.inspectionId ?? row.inspection.id,
                                ),
                                extra: member == null ? row.inspection : null,
                              );
                              if (mounted) _load();
                            },
                          ),
                        ],
                        isLoading: _loading,
                        emptyMessage: '本检查单已无待检行',
                        showFullscreenToggle: false,
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _batchActions(BuildContext context, Set<String> selectedIds) {
    return [
      UtenButton(
        key: const Key('fqc-sheet-submit-report'),
        size: UtenButtonSize.large,
        type: UtenButtonType.danger,
        icon: Icons.fact_check_outlined,
        isLoading: _submitting,
        onPressed: _loading || _confirming || _submitting || selectedIds.isEmpty
            ? null
            : _submitReport,
        onDisabledTap: selectedIds.isEmpty
            ? () => context.appWarning('请先勾选要提交的明细行')
            : null,
        child: Text(
          _selected.any((row) => row.needsReconciliation) ? '核对并继续原提交' : '提交报告',
        ),
      ),
    ];
  }

  /// 单据摘要卡（对齐 IQC 处置页：徽章 + 单号 + 事实横表 + 操作提示）。
  Widget _buildSummaryCard(
    ThemeData theme,
    ProductionFqcInspectionSheetDetail detail,
    int activeCount,
  ) {
    final sheet = detail.sheet;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: UtenSpacing.s16),
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenStatusBadge(
                  label: sheet.active ? '待检' : '已办结',
                  type: sheet.active
                      ? UtenStatusBadgeType.info
                      : UtenStatusBadgeType.neutral,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '品质检查单 ${sheet.sheetNo}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            MasterDataTableView<_SheetHeaderRow>(
              tableKey:
                  'features.quality.pages.production_fqc_handling_page.ProductionFqcSheetHandlingPageState._buildSummaryCard.1',
              key: const Key('fqc-sheet-header-table'),
              embedded: true,
              showColumnChooser: false,
              columns: [
                MasterColumnDef<_SheetHeaderRow>(
                  key: 'warehouseName',
                  label: '成品仓',
                  width: 140,
                  value: (row) => row.warehouseName,
                ),
                MasterColumnDef<_SheetHeaderRow>(
                  key: 'receiverName',
                  label: '收货人',
                  width: 110,
                  value: (row) => row.receiverName,
                ),
                MasterColumnDef<_SheetHeaderRow>(
                  key: 'reportNos',
                  label: '报工单',
                  width: 200,
                  value: (row) => row.reportNos,
                ),
                MasterColumnDef<_SheetHeaderRow>(
                  key: 'pending',
                  label: '待检',
                  width: 200,
                  value: (row) => row.pending,
                ),
                MasterColumnDef<_SheetHeaderRow>(
                  key: 'createdAt',
                  label: '进入质检',
                  width: 150,
                  value: (row) => row.createdAt,
                ),
              ],
              items: [
                _SheetHeaderRow(
                  warehouseName: sheet.warehouseName ?? '—',
                  receiverName: sheet.receiverName ?? '—',
                  reportNos: sheet.reportNos ?? '—',
                  pending:
                      '$activeCount 行待检'
                      '${sheet.pendingQtyText == null ? '' : ' · ${sheet.pendingQtyText}'}',
                  createdAt: ChinaDateTime.formatInstant(sheet.createdAt),
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
            if (sheet.remark?.isNotEmpty == true) ...[
              const SizedBox(height: UtenSpacing.s4),
              Text('登记备注：${sheet.remark}', style: theme.textTheme.bodySmall),
            ],
            const Divider(height: UtenSpacing.s24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    _canDecide
                        ? '一行是一批实物(需求份 / 计划公共 / 实际超产合在一起)，行内直接修改整批的'
                              '合格数量/不合格数量(默认全合格)，合格先满足需求份、不合格先扣实际超产；'
                              '含不合格的行另选处置方式；勾选后点「提交报告」逐批登记，遇到未确认或拒绝时停止。'
                        : '当前为只读查看；登记决定需要生产质检审批权限，且账号必须属于品质任务组织。',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<MasterColumnDef<FqcReportRow>> _rowColumns(ThemeData theme) => [
    MasterColumnDef<FqcReportRow>(
      key: 'submissionState',
      label: '提交状态',
      width: 100,
      value: (row) => row.submissionLabel,
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'reportNo',
      label: '报工单',
      width: 160,
      value: (row) => row.inspection.reportNo ?? row.inspection.id,
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'planNo',
      label: '生产计划',
      width: 150,
      value: (row) => row.inspection.planNo ?? '—',
    ),
    // 2026-09-14 用户口径（全站表格统一）：名称 / 编号 / 颜色各占一列。同名不同
    // 编号的自制成品很常见（V5 插面既有自制件也有委外件），只看名称会把检验
    // 结果登到错的货上；颜色/单位本表本来就有独立列。
    MasterColumnDef<FqcReportRow>(
      key: 'goods',
      label: '货品名称',
      width: 200,
      value: (row) => row.inspection.goodsName ?? '—',
      cellBuilderHandlesSemantics: true,
      cellBuilder: (_, row) =>
          UtenGoodsIdentityCell(name: row.inspection.goodsName),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'goodsCode',
      label: '编号',
      width: 130,
      value: (row) => UtenGoodsAttributeCell.text(row.inspection.goodsCode),
      cellBuilder: (_, row) => UtenGoodsAttributeCell(row.inspection.goodsCode),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'colorName',
      label: '颜色',
      width: 100,
      value: (row) => row.inspection.colorName ?? '—',
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'unit',
      label: '单位',
      width: 80,
      value: (row) => row.inspection.unitName ?? '—',
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'reportedQty',
      label: '报工数量',
      width: 100,
      type: 'number',
      value: (row) => fqty(row.inspection.reportedQty),
      exactValueOf: (row) => row.inspection.reportedQty.toString(),
    ),
    // ADR-148：这批实物里需求份 / 计划公共 / 实际超产各多少(服务端算好)。
    MasterColumnDef<FqcReportRow>(
      key: 'split',
      label: workflowFieldText(context).handoffLotSplitColumn,
      info: workflowFieldText(context).handoffLotSplitColumnInfo,
      width: 200,
      value: (row) => row.inspection.lot?.splitText ?? '—',
    ),
    // 先入库后检(V597)：已上架行红字「已入库 · 仓 / 库位」，品质部按此到储放区域检验。
    MasterColumnDef<FqcReportRow>(
      key: 'place',
      label: '储放位置',
      width: 150,
      value: (row) => fqcStorageText(row.inspection),
      cellBuilder: (context, row) {
        final text = fqcStorageText(row.inspection);
        if (row.inspection.preStocked == null) return Text(text);
        return Text(
          text,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: UtenColors.error,
            fontWeight: FontWeight.w700,
          ),
        );
      },
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'passedQty',
      label: '已合格',
      width: 90,
      type: 'number',
      value: (row) => fqty(row.inspection.passedQty),
      exactValueOf: (row) => row.inspection.passedQty.toString(),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'failedQty',
      label: '已不合格',
      width: 95,
      type: 'number',
      value: (row) => fqty(row.inspection.failedQty),
      exactValueOf: (row) => row.inspection.failedQty.toString(),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'remainingQty',
      label: '待检数量',
      width: 100,
      type: 'number',
      value: (row) => fqty(row.inspection.remainingQty),
      exactValueOf: (row) => row.inspection.remainingQty.toString(),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'pass',
      label: '合格数量',
      width: 120,
      type: 'number',
      value: (row) => row.pass.text,
      exactValueOf: (row) => row.pass.text,
      exactListenableOf: (row) => row.pass,
      cellBuilder: (context, row) => _qtyField(
        context,
        row,
        row.pass,
        key: Key('fqc-sheet-pass-${row.inspection.id}'),
        label: '合格数量',
      ),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'fail',
      label: '不合格数量',
      width: 120,
      type: 'number',
      value: (row) => row.fail.text,
      exactValueOf: (row) => row.fail.text,
      exactListenableOf: (row) => row.fail,
      cellBuilder: (context, row) => _qtyField(
        context,
        row,
        row.fail,
        key: Key('fqc-sheet-fail-${row.inspection.id}'),
        label: '不合格数量',
      ),
    ),
    MasterColumnDef<FqcReportRow>(
      key: 'disposition',
      label: '不合格处置',
      width: 140,
      // 通用说明收进列头 ⓘ（全站口径）：不合格才需要处置；处置方式随行选。
      info: '仅「不合格数量 > 0」的行需要选择；纯合格行不需要处置方式。',
      value: (row) =>
          row.failValue > 0 ? _dispositionLabel(row.disposition) : '—',
      cellBuilder: (context, row) => UtenDropdownField(
        key: Key('fqc-sheet-disposition-${row.inspection.id}'),
        dense: true,
        value: row.disposition,
        items: [
          for (final entry in kFqcDispositions)
            UtenDropdownItem(value: entry.$1, label: entry.$2),
        ],
        enabled:
            _canDecide &&
            !_loading &&
            !_confirming &&
            !_submitting &&
            row.failValue > 0 &&
            row.submission == null,
        onChanged: (value) =>
            setState(() => row.disposition = value ?? 'REWORK'),
      ),
    ),
  ];

  Widget _qtyField(
    BuildContext context,
    FqcReportRow row,
    TextEditingController controller, {
    required Key key,
    required String label,
  }) {
    return Semantics(
      textField: true,
      label: '${row.inspection.goodsName ?? '明细'} $label',
      child: TextField(
        key: key,
        controller: controller,
        enabled:
            _canDecide &&
            !_loading &&
            !_confirming &&
            !_submitting &&
            row.submission == null,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        decoration: UtenInputDecoration(
          InputDecoration(
            isDense: true,
            error: row.validate() == null
                ? null
                : UtenFieldMessage.error(row.validate()!),
          ),
        ),
      ),
    );
  }
}

/// 处置页表头信息的一行（一张检查单恰好一行）：供表格按列呈现单据级事实。
class _SheetHeaderRow {
  const _SheetHeaderRow({
    required this.warehouseName,
    required this.receiverName,
    required this.reportNos,
    required this.pending,
    required this.createdAt,
  });

  final String warehouseName;
  final String receiverName;
  final String reportNos;
  final String pending;
  final String createdAt;
}

/// ———————————————————— 单条 FQC 任务办理页（详情 + 决定 + 证据） ————————————————————

class ProductionFqcInspectionPage extends ConsumerStatefulWidget {
  const ProductionFqcInspectionPage({
    super.key,
    required this.inspectionId,
    this.extra,
  });

  static Widget route(BuildContext context, GoRouterState state) {
    final id = state.pathParameters['inspectionId']!;
    return ProductionFqcInspectionPage(
      key: ValueKey((id, state.uri.queryParameters['draftId'])),
      inspectionId: id,
      extra: state.extra,
    );
  }

  final String inspectionId;

  /// 列表行携带的任务快照（加载中先显示单号）；深链直达时为空。
  final Object? extra;

  @override
  ConsumerState<ProductionFqcInspectionPage> createState() =>
      _ProductionFqcInspectionPageState();
}

class _ProductionFqcInspectionPageState
    extends ConsumerState<ProductionFqcInspectionPage>
    with FormDraftMixin<ProductionFqcInspectionPage> {
  String _draftReason = '';
  @override
  bool get formDraftBusy => _confirming || _saving || _loading;
  @override
  bool get formDraftHasUnknownSubmission => _row == null
      ? super.formDraftHasUnknownSubmission
      : _row!.needsReconciliation;
  @override
  bool get formDraftCanReplaySubmission => true;
  @override
  FormDraftSpec get formDraftSpec => FormDraftCatalog.fqcInspection.spec(
    title: '自制产成品质检报告',
    route: RouteName.productionFqcInspectionHandling(widget.inspectionId),
  );
  @override
  Iterable<Listenable> get formDraftListenables => [
    if (_row case final row?) ...[row.pass, row.fail],
  ];
  @override
  Map<String, dynamic> captureFormDraft() => {
    'reason': _draftReason,
    'row': _row?.toFormDraft(),
  };
  @override
  Future<void> restoreFormDraft(Map<String, dynamic> data) async {
    _draftReason = draftText(data, 'reason');
    final saved = draftMap(data['row']);
    if (_row == null && saved['submission'] is Map && _inspection != null) {
      _row = FqcReportRow(_inspection!);
    }
    _row?.restoreFormDraft(saved, allowConfirmedRemainder: true);
  }

  ProductionFqcInspection? _inspection;
  FqcReportRow? _row;
  bool _loading = true;
  bool _confirming = false;
  bool _saving = false;
  int _loadGeneration = 0;
  bool _canDecide = false;
  String? _error;

  // 2026-09-22 全站表格滚动口径：事实表/判定表表头吸顶，任一表置顶后才显示
  // 页面滚动条（UtenGridPageScrollbar 门控）。
  final ScrollController _pageScroll = ScrollController();
  final ValueNotifier<bool> _factsPinned = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _decisionPinned = ValueNotifier<bool>(false);

  @override
  void initState() {
    super.initState();
    startFormDraftIdentityGuard();
    _inspection = widget.extra is ProductionFqcInspection
        ? widget.extra! as ProductionFqcInspection
        : null;
    _load();
  }

  @override
  void dispose() {
    _row?.dispose();
    _pageScroll.dispose();
    _factsPinned.dispose();
    _decisionPinned.dispose();
    super.dispose();
  }

  Future<void> _load({
    bool preserveInput = true,
    bool afterSubmission = false,
  }) async {
    if (!formDraftIdentityIsCurrent ||
        _confirming ||
        (_saving && !afterSubmission)) {
      return;
    }
    final generation = ++_loadGeneration;
    bool accepts() =>
        formDraftIdentityIsCurrent &&
        generation == _loadGeneration &&
        !_confirming &&
        (!_saving || afterSubmission);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final inspection = await ref
          .read(productionFqcRepositoryProvider)
          .detail(widget.inspectionId);
      if (!accepts()) return;
      final canDecide = await _canDecideFqc(ref);
      if (!accepts()) return;
      final oldRow = _row;
      // ADR-148：多份实物批只能在检查单里整批判定，单份页只读(待核对的原提交仍可续办)。
      final row =
          (inspection.active && !inspection.wholeLotOnly) ||
              (preserveInput && oldRow?.submission != null)
          ? FqcReportRow(inspection)
          : null;
      if (preserveInput && row != null && oldRow != null) {
        row.restoreFormDraft(
          oldRow.toFormDraft(),
          allowConfirmedRemainder: true,
        );
      }
      setState(() {
        _inspection = inspection;
        _canDecide = canDecide;
        _row?.dispose();
        _row = row;
        _loading = false;
      });
      await initializeFormDraft();
    } on ApiException catch (error) {
      if (!accepts()) return;
      setState(() {
        _error = error.message;
        _loading = false;
      });
    } catch (_) {
      if (!accepts()) return;
      setState(() {
        _error = '生产成品质检详情加载失败，请检查网络后重试';
        _loading = false;
      });
    }
  }

  Future<void> _submitReport() async {
    final row = _row;
    if (_loading ||
        _confirming ||
        _saving ||
        row == null ||
        row.completed ||
        !_canDecide ||
        !_hasFqcApprovalPermission(ref) ||
        !formDraftIdentityIsCurrent) {
      return;
    }
    final problem = row.validate();
    if (problem != null) {
      context.appWarning(problem);
      return;
    }
    final reviewed = row._reviewFingerprint;
    final canPublish = _captureFqcResponseView(
      context,
      ref,
      () => widget.inspectionId,
      identityIsCurrent: () => formDraftIdentityIsCurrent,
    );
    ++_loadGeneration;
    setState(() => _confirming = true);
    String? reason;
    try {
      if (row.needsReconciliation) {
        if (!await _confirmOriginalFqcReport(context, [row]) || !mounted) {
          return;
        }
        reason = '';
      } else {
        reason = await showInspectionReportConfirmDialog(
          context,
          lineCount: 1,
          passTotalText: _fqcTotalsText([row], (row) => row.passValue),
          failTotalText: _fqcTotalsText([row], (row) => row.failValue),
          requireReason: row.failValue > 0,
          initialReason: _draftReason,
          onReasonChanged: (value) => setState(() => _draftReason = value),
          lines: [
            InspectionReportConfirmLine(
              label: row.label,
              passText: fqty(row.passValue),
              failText: fqty(row.failValue),
              dim: row.inspection.unitName,
            ),
          ],
        );
      }
    } finally {
      if (mounted) setState(() => _confirming = false);
    }
    if (reason == null ||
        !mounted ||
        !canPublish() ||
        !_canDecide ||
        !_hasFqcApprovalPermission(ref)) {
      return;
    }
    if (!identical(_row, row) || row._reviewFingerprint != reviewed) {
      context.appWarning('明细已变化，请重新核对检验数量后确认');
      return;
    }
    if (!row.needsReconciliation &&
        row.failValue > 0 &&
        reason.trim().length < 2) {
      context.appWarning('含不合格数量时结论原因至少 2 个字');
      return;
    }
    setState(() => _saving = true);
    try {
      final result = await row.send(
        reason: reason,
        repository: ref.read(productionFqcRepositoryProvider),
        guard: (send, reject) => runFormDraftSubmission(() {
          if (!canPublish() || !_hasFqcApprovalPermission(ref)) {
            throw const _FqcSubmissionNotSent();
          }
          return send();
        }, isDefiniteRejection: reject),
      );
      if (!mounted || !canPublish()) return;
      setState(() {
        if (result != null) _inspection = result.inspection;
      });
      if (result == null) {
        try {
          await saveFormDraftNow();
        } catch (_) {
          _error = '本机恢复记录暂存失败，请保留页面；提交结果见上方说明';
        }
        await _load(afterSubmission: true);
        return;
      }
      await checkpointFormDraftAfterCreation();
      if (!mounted || !canPublish()) return;
      context.appSuccess(result.replay ? '原提交已确认，请以当前任务状态为准' : '质检决定已确认保存');
      refreshBadges(ref);
      if (context.canPop()) {
        await completeFormDraft();
        if (!mounted || !canPublish()) return;
        context.pop(result.inspection);
        return;
      }
      await _load(afterSubmission: true);
      if (_error == null && !(_inspection?.active ?? true)) {
        await completeFormDraft();
      }
    } catch (_) {
      if (canPublish()) {
        setState(() => _error = '提交结果已保留，页面更新或本机保存未完成，请刷新查看；已确认行不会再次提交');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inspection = _inspection;
    return withFormDraft(
      Scaffold(
        appBar: UtenAppBar(
          title: '自制产成品质检 · ${inspection?.reportNo ?? widget.inspectionId}',
          leading: UtenBackButton(
            onPressed: () => popOrBackTo(
              context,
              defaultPath: RouteName.warehouseInspections,
            ),
          ),
          actions: [
            UtenAppBarActionButton(
              label: '刷新',
              icon: Icons.refresh_rounded,
              isLoading: _loading && inspection != null,
              onPressed: _loading || _confirming || _saving ? null : _load,
            ),
          ],
        ),
        floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
        floatingActionButtonAnimator: FloatingActionButtonAnimator.noAnimation,
        floatingActionButton: _canDecide && _row != null && !_row!.completed
            ? UtenFloatingActionGroup(
                children: [
                  UtenButton(
                    key: const Key('fqc-inspection-submit-report'),
                    type: UtenButtonType.danger,
                    size: UtenButtonSize.large,
                    icon: Icons.fact_check_outlined,
                    isLoading: _saving,
                    onPressed: _loading || _confirming || _saving
                        ? null
                        : _submitReport,
                    child: Text(
                      _row!.needsReconciliation ? '核对并继续原提交' : '提交报告',
                    ),
                  ),
                ],
              )
            : null,
        body: SafeArea(
          child: _loading && inspection == null
              ? const UtenSkeletonList()
              : _error != null && inspection == null
              ? UtenEmpty.error(
                  message: _error,
                  actionLabel: '重新加载',
                  onAction: _load,
                )
              : UtenGridPageScrollbar(
                  pinned: _factsPinned,
                  extraPinned: [_decisionPinned],
                  controller: _pageScroll,
                  child: UtenContentContainer.wide(
                    child: ListView(
                      controller: _pageScroll,
                      padding: const EdgeInsets.fromLTRB(
                        UtenSpacing.s16,
                        UtenSpacing.s16,
                        UtenSpacing.s16,
                        UtenFloatingActionGroup.scrollClearance,
                      ),
                      children: [
                        if (fqcPreStockedNotice(
                              [inspection!],
                              key: const Key(
                                'fqc-inspection-pre-stocked-notice',
                              ),
                            )
                            case final notice?) ...[
                          notice,
                          const SizedBox(height: UtenSpacing.s12),
                        ],
                        _buildFactsCard(theme, inspection),
                        const SizedBox(height: UtenSpacing.s12),
                        if (_fqcSubmissionNotice(
                              [?_row],
                              key: const Key(
                                'fqc-inspection-submission-result',
                              ),
                              canDecide: _canDecide,
                            )
                            case final notice?) ...[
                          notice,
                          const SizedBox(height: UtenSpacing.s12),
                        ],
                        if (_error != null) ...[
                          Text(
                            '刷新或本机保存未完成：$_error',
                            style: TextStyle(color: theme.colorScheme.error),
                          ),
                          const SizedBox(height: UtenSpacing.s12),
                        ],
                        if (_canDecide && _row != null && !_row!.completed) ...[
                          _buildDecisionForm(theme, _row!),
                          const SizedBox(height: UtenSpacing.s12),
                        ] else
                          ..._readOnlyHint(theme, inspection),
                        _buildAttachments(theme, inspection),
                        const SizedBox(height: UtenSpacing.s24),
                      ],
                    ),
                  ),
                ),
        ),
      ),
    );
  }

  /// 送检登记事实卡（报工/货品/检查单/仓/库位/数量全貌）。
  Widget _buildFactsCard(ThemeData theme, ProductionFqcInspection inspection) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                UtenStatusBadge(
                  label: fqcStatusLabel(inspection),
                  type: inspection.active
                      ? UtenStatusBadgeType.info
                      : UtenStatusBadgeType.neutral,
                ),
                const SizedBox(width: UtenSpacing.s8),
                Expanded(
                  child: Text(
                    '报工 ${inspection.reportNo ?? inspection.id}',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: UtenSpacing.s12),
            MasterDataTableView<_FactRow>(
              tableKey:
                  'features.quality.pages.production_fqc_handling_page.ProductionFqcInspectionPageState._buildFactsCard.1',
              key: const Key('fqc-inspection-facts-table'),
              embedded: true,
              stickyHeaderPinned: _factsPinned,
              showColumnChooser: false,
              columns: [
                MasterColumnDef<_FactRow>(
                  key: 'planNo',
                  label: '生产计划',
                  width: 150,
                  value: (row) => row.planNo,
                ),
                // 身份格：本卡无独立编号/颜色列，名称、编号、颜色三属性合并一格，
                // 办理前一眼确认「同名不同色」的是不是手上这批货。
                MasterColumnDef<_FactRow>(
                  key: 'goods',
                  label: '货品名称',
                  width: 200,
                  value: (row) => row.goodsName ?? '—',
                  cellBuilderHandlesSemantics: true,
                  cellBuilder: (_, row) =>
                      UtenGoodsIdentityCell(name: row.goodsName),
                ),
                MasterColumnDef<_FactRow>(
                  key: 'goodsCode',
                  label: '编号',
                  width: 130,
                  value: (row) => UtenGoodsAttributeCell.text(row.goodsCode),
                  cellBuilder: (_, row) =>
                      UtenGoodsAttributeCell(row.goodsCode),
                ),
                MasterColumnDef<_FactRow>(
                  key: 'colorName',
                  label: '颜色',
                  width: 96,
                  value: (row) => UtenGoodsAttributeCell.text(row.colorName),
                  cellBuilder: (_, row) =>
                      UtenGoodsAttributeCell(row.colorName),
                ),
                MasterColumnDef<_FactRow>(
                  // 2026-09-25 单号列统一：明细就地排序+按值筛选。
                  key: 'sheetNo',
                  sortable: true,
                  filterFromRows: true,
                  label: '检查单号',
                  width: 150,
                  value: (row) => row.sheetNo,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'warehouse',
                  label: '实际成品仓',
                  width: 140,
                  value: (row) => row.warehouse,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'place',
                  label: '储放位置',
                  width: 150,
                  value: (row) => row.place,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'receiver',
                  label: '收货人',
                  width: 110,
                  value: (row) => row.receiver,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'qty',
                  label: '数量（报工/合格/不合格/待检/已生成待点收）',
                  width: 300,
                  value: (row) => row.qty,
                ),
                MasterColumnDef<_FactRow>(
                  key: 'time',
                  label: '进入质检 / 更新',
                  width: 300,
                  value: (row) => row.time,
                ),
              ],
              items: [
                _FactRow(
                  planNo: inspection.planNo ?? '—',
                  goodsName: inspection.goodsName,
                  goodsCode: inspection.goodsCode,
                  colorName: inspection.colorName,
                  sheetNo: inspection.sheetNo ?? '无检查单',
                  warehouse: inspection.warehouseName ?? '—',
                  place: fqcStorageText(inspection),
                  receiver: inspection.receiverName ?? '—',
                  qty:
                      '${fqty(inspection.reportedQty)} / '
                      '${fqty(inspection.passedQty)} / '
                      '${fqty(inspection.failedQty)} / '
                      '${fqty(inspection.remainingQty)} / '
                      '${fqty(inspection.authorizedInboundQty)}'
                      '${inspection.unitName == null ? '' : ' ${inspection.unitName}'}',
                  time:
                      '${ChinaDateTime.formatInstant(inspection.createdAt)}'
                      ' / ${ChinaDateTime.formatInstant(inspection.updatedAt)}',
                ),
              ],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
            if (inspection.registrationRemark?.isNotEmpty == true) ...[
              const SizedBox(height: UtenSpacing.s4),
              Text(
                '登记备注：${inspection.registrationRemark}',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 决定表单：合格/不合格数量 + 不合格处置；提交前由总结弹窗收结论原因。
  Widget _buildDecisionForm(ThemeData theme, FqcReportRow row) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '检验明细',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: UtenSpacing.s8),
            Text(
              row.inspection.preStocked != null
                  ? '已上架货品的合格部分由系统自动点收，不合格部分交仓库处理。'
                  : '合格部分提交后转仓库待最终点收，不合格部分按处置方式办理。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            MasterDataTableView<FqcReportRow>(
              tableKey:
                  'features.quality.pages.production_fqc_handling_page.ProductionFqcInspectionPageState._buildDecisionForm.1',
              key: const Key('fqc-inspection-decision-table'),
              embedded: true,
              stickyHeaderPinned: _decisionPinned,
              showColumnChooser: false,
              columns: [
                // 决定表原来只有名称：本表没有编号/颜色列，判定合格与不合格前
                // 必须能分清「同名不同色」的两条（自制白色 / 委外香槟金），
                // 故名称 + 编号 + 颜色合并进身份格（单位另有独立列）。
                MasterColumnDef(
                  key: 'goods',
                  label: '货品名称',
                  width: 200,
                  value: (row) => row.inspection.goodsName ?? '—',
                  cellBuilderHandlesSemantics: true,
                  cellBuilder: (_, row) =>
                      UtenGoodsIdentityCell(name: row.inspection.goodsName),
                ),
                MasterColumnDef(
                  key: 'goodsCode',
                  label: '编号',
                  width: 130,
                  value: (row) =>
                      UtenGoodsAttributeCell.text(row.inspection.goodsCode),
                  cellBuilder: (_, row) =>
                      UtenGoodsAttributeCell(row.inspection.goodsCode),
                ),
                MasterColumnDef(
                  key: 'colorName',
                  label: '颜色',
                  width: 96,
                  value: (row) =>
                      UtenGoodsAttributeCell.text(row.inspection.colorName),
                  cellBuilder: (_, row) =>
                      UtenGoodsAttributeCell(row.inspection.colorName),
                ),
                MasterColumnDef(
                  key: 'pass',
                  label: '合格数量',
                  width: 150,
                  type: 'number',
                  info: '本次判定合格的数量；与不合格数量合计不能超过本行待检量。',
                  value: (row) => row.pass.text,
                  exactValueOf: (row) => row.pass.text,
                  exactListenableOf: (row) => row.pass,
                  cellBuilder: (context, row) =>
                      _singleQuantityField(row, passed: true),
                ),
                MasterColumnDef(
                  key: 'fail',
                  label: '不合格数量',
                  width: 150,
                  type: 'number',
                  info: '含不合格数量时，选择不合格处置并在提交时说明原因。',
                  value: (row) => row.fail.text,
                  exactValueOf: (row) => row.fail.text,
                  exactListenableOf: (row) => row.fail,
                  cellBuilder: (context, row) =>
                      _singleQuantityField(row, passed: false),
                ),
                MasterColumnDef(
                  key: 'disposition',
                  label: '不合格处置',
                  width: 170,
                  value: (row) => row.failValue > 0
                      ? _dispositionLabel(row.disposition)
                      : '—',
                  cellBuilder: (context, row) => UtenDropdownField(
                    key: const Key('fqc-inspection-disposition'),
                    dense: true,
                    value: row.disposition,
                    items: [
                      for (final entry in kFqcDispositions)
                        UtenDropdownItem(value: entry.$1, label: entry.$2),
                    ],
                    enabled:
                        !_loading &&
                        !_confirming &&
                        !_saving &&
                        row.failValue > 0 &&
                        row.submission == null,
                    onChanged: (value) =>
                        setState(() => row.disposition = value ?? 'REWORK'),
                  ),
                ),
                MasterColumnDef(
                  key: 'remaining',
                  label: '待检数量',
                  width: 110,
                  type: 'number',
                  value: (row) => fqty(row.inspection.remainingQty),
                  exactValueOf: (row) => row.inspection.remainingQty.toString(),
                ),
                MasterColumnDef(
                  key: 'unit',
                  label: '单位',
                  width: 80,
                  value: (row) => row.inspection.unitName ?? '—',
                ),
              ],
              items: [row],
              facets: const {},
              nullCounts: const {},
              filters: const {},
              onFilterChanged: (_, _) {},
            ),
          ],
        ),
      ),
    );
  }

  Widget _singleQuantityField(
    FqcReportRow row, {
    required bool passed,
  }) => Semantics(
    textField: true,
    label: '${row.inspection.goodsName ?? '明细'} ${passed ? '合格数量' : '不合格数量'}',
    child: TextField(
      key: Key('fqc-inspection-${passed ? 'pass' : 'fail'}'),
      controller: passed ? row.pass : row.fail,
      enabled: !_loading && !_confirming && !_saving && row.submission == null,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      textAlign: TextAlign.right,
      decoration: UtenInputDecoration(
        InputDecoration(
          isDense: true,
          error: row.validate() == null
              ? null
              : UtenFieldMessage.error(row.validate()!),
        ),
      ),
    ),
  );

  List<Widget> _readOnlyHint(
    ThemeData theme,
    ProductionFqcInspection inspection,
  ) => [
    Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          Icons.lock_outline_rounded,
          size: 18,
          color: theme.colorScheme.onSurfaceVariant,
        ),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Text(
            inspection.active && inspection.wholeLotOnly
                ? workflowFieldText(context).fqcWholeLotOnlyHint
                : inspection.active
                ? '当前为只读查看；登记决定需要生产质检审批权限，且账号必须属于品质任务组织。'
                : inspection.status == 'CANCELLED'
                ? '来源报工已红冲或仓库登记已撤回，本任务只读且不能再登记检验决定。'
                : '该任务已完成决定，当前详情只读。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (inspection.active &&
            inspection.wholeLotOnly &&
            inspection.sheetId?.isNotEmpty == true)
          UtenButton(
            key: const Key('fqc-inspection-open-sheet-for-lot'),
            type: UtenButtonType.secondary,
            icon: Icons.open_in_new_rounded,
            onPressed: () => context.push(
              RouteName.productionFqcSheetHandling(inspection.sheetId!),
            ),
            child: Text(workflowFieldText(context).fqcOpenSheetForLot),
          ),
      ],
    ),
    const SizedBox(height: UtenSpacing.s12),
  ];

  Widget _buildAttachments(
    ThemeData theme,
    ProductionFqcInspection inspection,
  ) {
    final permissions = ref.watch(currentPermissionsProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BusinessAttachmentSection(
              ownerType: 'PRODUCTION_QUALITY_INSPECTION',
              ownerId: inspection.id,
              canView: permissions.contains(
                Perm.productionQualityInspectionView,
              ),
              canManage:
                  _canDecide &&
                  permissions.contains(
                    Perm.productionQualityInspectionApprove,
                  ) &&
                  inspection.status == 'PENDING' &&
                  inspection.passedQty == 0 &&
                  inspection.failedQty == 0 &&
                  inspection.remainingQty > 0,
              title: '检验图片和文件',
              categories: const ['检验照片', '检验报告', '其他证据'],
            ),
            if (permissions.contains(Perm.attachmentView)) ...[
              const SizedBox(height: UtenSpacing.s8),
              Text(
                '请在登记检验结果前添加证据。登记结果后（包括部分检验），文件保留供查阅，不能替换或删除。',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FactRow {
  const _FactRow({
    required this.planNo,
    required this.goodsName,
    required this.goodsCode,
    required this.colorName,
    required this.sheetNo,
    required this.warehouse,
    required this.place,
    required this.receiver,
    required this.qty,
    required this.time,
  });

  final String planNo;

  /// 货品身份三件套（未维护时为空，身份格自然省略，不显示「无」这类占位词）。
  final String? goodsName;
  final String? goodsCode;
  final String? colorName;
  final String sheetNo;
  final String warehouse;
  final String place;
  final String receiver;
  final String qty;
  final String time;
}
