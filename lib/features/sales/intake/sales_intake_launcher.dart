// 销售客户文件识别的入口流程(ADR-134, SPEC §7.3):
//   选文件 → (PDF/图片先确认整份发给 AI) → 公共 AI 进度弹窗(分步显示) → 核对面板 → 补丁。
// 另有「改为新建报价单」: 订货单识别结果里有没标价的货品时, 报价页用同一个作业 id
// 直接恢复结果(resumeSalesIntake), 不用重新上传。
// 文件里别的工作表也像明细表时, 核对面板可改为识别那一张: 同一个文件加参数 `sheet`
// (工作表序号)重新提交, 同一套进度弹窗, 新结果整个替换面板(从不合并几张表)。
//
// 识别作业走公共 AI 作业接口(lib/shared/ai), 本文件只负责销售这一种用法。
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_dialog.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/ai/ai_job_models.dart';
import '../../../shared/ai/ai_job_runner.dart';
import '../../../shared/ai/ai_progress_dialog.dart';
import '../../../shared/ai/ai_status_provider.dart';
import '../../../shared/formatters/exact_decimal.dart';
import '../../basic_data/widgets/uten_client_picker.dart';
import '../../basic_data/widgets/uten_goods_picker.dart';
import '../models/sales_doc.dart';
import 'sales_intake_apply.dart';
import 'sales_intake_l10n.dart';
import 'sales_intake_models.dart';
import 'sales_intake_repository.dart';
import 'sales_intake_review_panel.dart';

/// 服务端读取上限(SPEC §3.6 / §4): 文件 15 MiB, 图片 8 MiB。
const int kSalesIntakeMaxFileBytes = 15 * 1024 * 1024;
const int kSalesIntakeMaxImageBytes = 8 * 1024 * 1024;

/// 可识别的扩展名 → 上传时的内容类型。
const Map<String, String> kSalesIntakeContentTypes = {
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'xls': 'application/vnd.ms-excel',
  'csv': 'text/csv',
  'pdf': 'application/pdf',
  'png': 'image/png',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'webp': 'image/webp',
};

const Set<String> _imageExtensions = {'png', 'jpg', 'jpeg', 'webp'};

String? _extensionOf(String name) {
  final dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return null;
  return name.substring(dot + 1).toLowerCase();
}

/// 进度弹窗的呈现方式(默认公共 [showAiProgressDialog]; 测试可替换)。
typedef SalesIntakeProgressPresenter =
    Future<AiJobSnapshot?> Function(
      BuildContext context, {
      required String title,
      String? subtitle,
      required List<AiProgressStage> stages,
      required AiProgressTask task,
    });

final salesIntakeProgressPresenterProvider =
    Provider<SalesIntakeProgressPresenter>((ref) => showAiProgressDialog);

/// 进度弹窗的分步: 上传文件 / 读取表格 / 识别表头与列 / 匹配货品 / 匹配客户 / 计算折扣。
List<AiProgressStage> salesIntakeProgressStages(AppLocalizations l10n) => [
  AiProgressStage(
    key: 'upload',
    label: l10n.salesIntakeStageUpload,
    serverStages: const [AiJobSnapshot.uploadingStage],
  ),
  AiProgressStage(
    key: 'read',
    label: l10n.salesIntakeStageRead,
    serverStages: const ['READING'],
  ),
  AiProgressStage(
    key: 'layout',
    label: l10n.salesIntakeStageLayout,
    serverStages: const ['LAYOUT', 'EXTRACTING'],
  ),
  AiProgressStage(
    key: 'goods',
    label: l10n.salesIntakeStageGoods,
    serverStages: const ['MATCHING_GOODS'],
  ),
  AiProgressStage(
    key: 'client',
    label: l10n.salesIntakeStageClient,
    serverStages: const ['MATCHING_CLIENT'],
  ),
  AiProgressStage(
    key: 'pricing',
    label: l10n.salesIntakeStagePricing,
    serverStages: const ['PRICING'],
  ),
];

/// 入口流程的结果: 要么是补丁(+原文件, 页面存进附件), 要么是「改为新建报价单」。
class SalesIntakeLaunchResult {
  const SalesIntakeLaunchResult.apply({
    required SalesIntakePatch this.patch,
    this.file,
  }) : handoffJobId = null;

  /// 「改为新建报价单」: 带上作业 id 与本次上传的原文件(报价页恢复识别后把原文件存进附件)。
  const SalesIntakeLaunchResult.handoff(String this.handoffJobId, {this.file})
    : patch = null;

  final SalesIntakePatch? patch;

  /// 本次上传的原文件(恢复已有作业时为 null)。
  final PlatformFile? file;
  final String? handoffJobId;
}

/// 选文件并识别。取消/失败返回 null(失败已提示)。
Future<SalesIntakeLaunchResult?> launchSalesIntake(
  BuildContext context,
  WidgetRef ref, {
  required SalesDocType docType,
  String? clientId,
  String? clientName,
  String? docId,
  bool canHandoffToQuote = false,
}) async {
  final l10n = salesIntakeL10n(context);
  final FilePickerResult? picked;
  try {
    picked = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: kSalesIntakeContentTypes.keys.toList(),
      withData: true,
      allowCompression: false,
    );
  } on Object {
    if (context.mounted) context.appError(l10n.salesIntakeFileUnreadable);
    return null;
  }
  if (!context.mounted || picked == null || picked.files.isEmpty) return null;
  return launchSalesIntakeWithFile(
    context,
    ref,
    file: picked.files.single,
    docType: docType,
    clientId: clientId,
    clientName: clientName,
    docId: docId,
    canHandoffToQuote: canHandoffToQuote,
  );
}

/// 识别一份已拿到的客户文件（文件选择框与拖入共用）。取消/失败返回 null(失败已提示)。
Future<SalesIntakeLaunchResult?> launchSalesIntakeWithFile(
  BuildContext context,
  WidgetRef ref, {
  required PlatformFile file,
  required SalesDocType docType,
  String? clientId,
  String? clientName,
  String? docId,
  bool canHandoffToQuote = false,
}) async {
  final l10n = salesIntakeL10n(context);
  final Uint8List? bytes = file.bytes;
  final extension = _extensionOf(file.name);
  final contentType = extension == null
      ? null
      : kSalesIntakeContentTypes[extension];
  if (contentType == null) {
    context.appError(l10n.salesIntakeFileTypeUnsupported);
    return null;
  }
  if (bytes == null || bytes.isEmpty) {
    context.appError(l10n.salesIntakeFileUnreadable);
    return null;
  }
  final isImage = _imageExtensions.contains(extension);
  final limit = isImage ? kSalesIntakeMaxImageBytes : kSalesIntakeMaxFileBytes;
  if (bytes.length > limit) {
    context.appError(
      l10n.salesIntakeFileTooLarge('${limit ~/ (1024 * 1024)}MB'),
    );
    return null;
  }
  if (isImage || extension == 'pdf') {
    // PDF/图片只能靠 AI 识别: 先看 AI 是否可用, 再请用户确认整份文件会发给 AI 服务。
    final status = await _readAiStatus(ref);
    if (!context.mounted) return null;
    if (!status.usable) {
      context.appError(
        l10n.salesIntakeAiRequired,
        title: l10n.salesIntakeFailedTitle,
      );
      return null;
    }
    if (isImage && !status.supportsVision) {
      context.appError(
        l10n.salesIntakeVisionRequired,
        title: l10n.salesIntakeFailedTitle,
      );
      return null;
    }
    final ok = await UtenDialog.show(
      context,
      title: l10n.salesIntakeSendWholeFileTitle,
      content: Text(l10n.salesIntakeSendWholeFileMessage),
      confirmLabel: l10n.salesIntakeSendWholeFileConfirm,
      cancelLabel: l10n.salesIntakeCancel,
    );
    if (ok != true || !context.mounted) return null;
  }
  final request = AiJobRequest(
    kind: kSalesIntakeJobKind,
    params: {
      'docType': docType == SalesDocType.quote ? 'quote' : 'order',
      'clientId': ?clientId,
      'docId': ?docId,
    },
    bytes: bytes,
    fileName: file.name,
    contentType: contentType,
  );
  final runner = ref.read(aiJobRunnerProvider);
  final snapshot = await _runWithProgress(
    context,
    ref,
    subtitle: file.name,
    task: (onProgress, cancelToken) =>
        runner.run(request, onProgress: onProgress, cancelToken: cancelToken),
  );
  if (snapshot == null || !context.mounted) return null;
  return _review(
    context,
    ref,
    snapshot: snapshot,
    docType: docType,
    clientId: clientId,
    clientName: clientName,
    file: file,
    request: request,
    canHandoffToQuote: canHandoffToQuote,
  );
}

/// 恢复已有识别作业(订货单 →「改为新建报价单」), 不重新上传。
Future<SalesIntakeLaunchResult?> resumeSalesIntake(
  BuildContext context,
  WidgetRef ref, {
  required SalesDocType docType,
  required String jobId,
  String? clientId,
  String? clientName,
}) async {
  final runner = ref.read(aiJobRunnerProvider);
  final snapshot = await _runWithProgress(
    context,
    ref,
    task: (onProgress, cancelToken) =>
        runner.resume(jobId, onProgress: onProgress, cancelToken: cancelToken),
  );
  if (snapshot == null || !context.mounted) return null;
  return _review(
    context,
    ref,
    snapshot: snapshot,
    docType: docType,
    clientId: clientId,
    clientName: clientName,
  );
}

Future<AiStatus> _readAiStatus(WidgetRef ref) async {
  try {
    return await ref.read(aiStatusProvider.future);
  } on Object {
    return AiStatus.unavailable;
  }
}

Future<AiJobSnapshot?> _runWithProgress(
  BuildContext context,
  WidgetRef ref, {
  String? subtitle,
  required AiProgressTask task,
}) async {
  final l10n = salesIntakeL10n(context);
  final present = ref.read(salesIntakeProgressPresenterProvider);
  try {
    final snapshot = await present(
      context,
      title: l10n.salesIntakeProgressTitle,
      subtitle: subtitle,
      stages: salesIntakeProgressStages(l10n),
      task: task,
    );
    if (snapshot == null) return null;
    if (snapshot.status != AiJobStatus.succeeded) {
      if (context.mounted) {
        context.appError(
          snapshot.errorMessage ?? l10n.salesIntakeResultUnreadable,
          title: l10n.salesIntakeFailedTitle,
        );
      }
      return null;
    }
    return snapshot;
  } on AiJobFailure catch (failure) {
    if (context.mounted) {
      context.appError(failure.message, title: l10n.salesIntakeFailedTitle);
    }
  } on ApiException catch (error) {
    if (context.mounted) context.appApiError(error);
  } on Object catch (error, stack) {
    // 其它意外(网关回了读不懂的应答、解析出错等): 只给销售一句大白话, 细节只进调试日志。
    debugPrint('sales intake failed: ${error.runtimeType}\n$stack');
    if (context.mounted) {
      context.appError(
        l10n.aiJobFailedGeneric,
        title: l10n.salesIntakeFailedTitle,
      );
    }
  }
  return null;
}

/// 读出识别结果; 读不懂或一行明细都没有时提示并返回 null。
SalesIntakeResult? _readResult(BuildContext context, AiJobSnapshot snapshot) {
  final l10n = salesIntakeL10n(context);
  final SalesIntakeResult result;
  try {
    result = SalesIntakeResult.fromJson(snapshot.result);
  } on FormatException {
    context.appError(
      l10n.salesIntakeResultUnreadable,
      title: l10n.salesIntakeFailedTitle,
    );
    return null;
  }
  if (result.lines.isEmpty) {
    context.appError(
      l10n.salesIntakeNoLines,
      title: l10n.salesIntakeFailedTitle,
    );
    return null;
  }
  return result;
}

/// 改为识别另一张工作表: 同一个文件、同样的参数再加 `sheet`(工作表序号), 走同一个
/// 作业执行器与进度弹窗; 成功返回新作业的结果, 失败/取消返回 null(已提示)。
Future<SalesIntakeSheetRerun?> _rerunSheet(
  BuildContext context,
  WidgetRef ref, {
  required AiJobRequest source,
  required SalesIntakeOtherSheet sheet,
}) async {
  final index = sheet.index;
  if (index == null) return null;
  final l10n = salesIntakeL10n(context);
  final request = AiJobRequest(
    kind: source.kind,
    params: {...source.params, 'sheet': '$index'},
    bytes: source.bytes,
    fileName: source.fileName,
    contentType: source.contentType,
  );
  final runner = ref.read(aiJobRunnerProvider);
  final snapshot = await _runWithProgress(
    context,
    ref,
    subtitle: l10n.salesIntakeSheetProgressSubtitle(
      source.fileName,
      sheet.name,
    ),
    task: (onProgress, cancelToken) =>
        runner.run(request, onProgress: onProgress, cancelToken: cancelToken),
  );
  if (snapshot == null || !context.mounted) return null;
  final result = _readResult(context, snapshot);
  return result == null
      ? null
      : SalesIntakeSheetRerun(jobId: snapshot.id, result: result);
}

Future<SalesIntakeLaunchResult?> _review(
  BuildContext context,
  WidgetRef ref, {
  required AiJobSnapshot snapshot,
  required SalesDocType docType,
  String? clientId,
  String? clientName,
  PlatformFile? file,
  AiJobRequest? request,
  bool canHandoffToQuote = false,
}) async {
  final l10n = salesIntakeL10n(context);
  final result = _readResult(context, snapshot);
  if (result == null) return null;
  // 进度弹窗刚关, 等一帧再弹面板(避免与弹窗退场动画叠在一起)。
  await WidgetsBinding.instance.endOfFrame;
  if (!context.mounted) return null;
  final outcome = await showSalesIntakeReviewPanel(
    context,
    result: result,
    jobId: snapshot.id,
    docType: docType,
    presetClientId: clientId,
    presetClientName: clientName,
    actions: salesIntakeReviewActions(
      ref,
      canHandoffToQuote: docType == SalesDocType.order && canHandoffToQuote,
      rerunSheet: request == null
          ? null
          : (panelContext, sheet) =>
                _rerunSheet(panelContext, ref, source: request, sheet: sheet),
    ),
  );
  if (!context.mounted) return null;
  return switch (outcome) {
    null => null,
    SalesIntakeReviewHandoffToQuote(:final jobId) =>
      SalesIntakeLaunchResult.handoff(jobId ?? snapshot.id, file: file),
    SalesIntakeReviewApply(:final decisions, :final result, :final jobId) =>
      SalesIntakeLaunchResult.apply(
        patch: buildSalesIntakePatch(
          result: result,
          decisions: decisions,
          docType: docType,
          jobId: jobId ?? snapshot.id,
          l10n: l10n,
        ),
        file: file,
      ),
  };
}

/// 面板的真实动作: 客户/货品选择器 + 用文件信息新建客户。
SalesIntakeReviewActions salesIntakeReviewActions(
  WidgetRef ref, {
  bool canHandoffToQuote = false,
  Future<SalesIntakeSheetRerun?> Function(
    BuildContext context,
    SalesIntakeOtherSheet sheet,
  )?
  rerunSheet,
}) => SalesIntakeReviewActions(
  pickClient: (context) async {
    final client = await showUtenClientPicker(context, ref);
    if (client == null) return null;
    return SalesIntakePickedClient(
      id: client.id,
      name: client.name ?? client.fullName ?? client.code ?? client.id,
    );
  },
  pickGoods: (context) async {
    final goods = await showUtenGoodsPicker(
      context,
      ref,
      scope: UtenGoodsPickerScope.allExceptUncategorized,
    );
    if (goods == null) return null;
    return SalesIntakePickedGoods(
      id: goods.id,
      code: goods.code,
      name: goods.name,
      model: goods.model,
      series: goods.series,
      spec: goods.spec,
      colorId: goods.colorId,
      colorName: goods.colorName,
      unitId: goods.unitId,
      unitName: goods.unitName,
      // 没有货品价格查看权限时选择器不给标价(null): 面板按「标价未知」处理, 不拦截。
      price: financeExactTrimmed(goods.price?.toString()),
    );
  },
  createClient: (context, proposal) =>
      _createClientFromDocument(context, ref, proposal),
  canHandoffToQuote: canHandoffToQuote,
  rerunSheet: rerunSheet,
);

Future<SalesIntakePickedClient?> _createClientFromDocument(
  BuildContext context,
  WidgetRef ref,
  SalesIntakeNewClientProposal proposal,
) async {
  final l10n = salesIntakeL10n(context);
  final confirmed = await showDialog<SalesIntakeNewClientProposal>(
    context: context,
    builder: (_) => _CreateClientDialog(proposal: proposal),
  );
  if (confirmed == null || !context.mounted) return null;
  final name = confirmed.name ?? confirmed.fullName ?? confirmed.nameEn ?? '';
  try {
    final id = await ref
        .read(salesIntakeRepositoryProvider)
        .createClientFromDocument(confirmed);
    if (context.mounted) {
      context.appSuccess(l10n.salesIntakeCreateClientDone(name));
    }
    return SalesIntakePickedClient(id: id, name: name);
  } on SalesIntakeClientExists catch (exists) {
    if (!context.mounted) return null;
    final existingId = exists.existingClientId;
    if (existingId != null) {
      context.appInfo(l10n.salesIntakeCreateClientExists);
      return SalesIntakePickedClient(id: existingId, name: name);
    }
    context.appWarning(exists.message);
  } on ApiException catch (error) {
    if (context.mounted) context.appApiError(error);
  } on FormatException {
    if (context.mounted) context.appError(l10n.salesIntakeCreateClientFailed);
  }
  return null;
}

class _CreateClientDialog extends StatefulWidget {
  const _CreateClientDialog({required this.proposal});

  final SalesIntakeNewClientProposal proposal;

  @override
  State<_CreateClientDialog> createState() => _CreateClientDialogState();
}

class _CreateClientDialogState extends State<_CreateClientDialog> {
  late final TextEditingController _name = TextEditingController(
    text: _initialName(widget.proposal),
  );
  bool _showError = false;

  static String _initialName(SalesIntakeNewClientProposal p) {
    final raw = (p.name ?? p.nameEn ?? p.fullName ?? '').trim();
    return raw.length > 64 ? raw.substring(0, 64) : raw;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = salesIntakeL10n(context);
    final theme = Theme.of(context);
    final p = widget.proposal;
    final rows = <(String, String?)>[
      (l10n.salesIntakeFieldFullName, p.fullName),
      (l10n.salesIntakeFieldNameEn, p.nameEn),
      (l10n.salesIntakeFieldLinkman, p.linkman),
      (l10n.salesIntakeFieldEmail, p.email),
      (l10n.salesIntakeFieldPhone, p.phone),
      (l10n.salesIntakeFieldAddress, p.address),
      (l10n.salesIntakeFieldTaxId, p.taxId),
      (l10n.salesIntakeFieldPlace, p.placeId),
    ];
    return AlertDialog(
      title: Text(l10n.salesIntakeCreateClientTitle),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 480,
          maxHeight: MediaQuery.sizeOf(context).height * 0.6,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.salesIntakeCreateClientIntro),
              const SizedBox(height: UtenSpacing.s12),
              UtenInput(
                key: const ValueKey('sales-intake-new-client-name'),
                controller: _name,
                label: l10n.salesIntakeCreateClientName,
                required: true,
                errorMessage: _showError
                    ? l10n.salesIntakeCreateClientNameRequired
                    : null,
                onChanged: (_) {
                  if (_showError) setState(() => _showError = false);
                },
              ),
              const SizedBox(height: UtenSpacing.s12),
              for (final (label, value) in rows)
                if (value != null && value.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: UtenSpacing.s6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 88,
                          child: Text(
                            label,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(value, style: theme.textTheme.bodyMedium),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ),
      actionsAlignment: MainAxisAlignment.center,
      actions: [
        UtenButton(
          type: UtenButtonType.ghost,
          height: 48,
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l10n.salesIntakeCancel),
        ),
        UtenButton(
          key: const ValueKey('sales-intake-new-client-confirm'),
          height: 48,
          onPressed: () {
            final name = _name.text.trim();
            if (name.isEmpty) {
              setState(() => _showError = true);
              return;
            }
            Navigator.of(context).pop(widget.proposal.copyWith(name: name));
          },
          child: Text(l10n.salesIntakeCreateClientConfirm),
        ),
      ],
    );
  }
}
