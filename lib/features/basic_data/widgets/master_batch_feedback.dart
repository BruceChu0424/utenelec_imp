// 主档批量命令的结果反馈(ADR-111)：全部成功弹一条顶部通知；有失败就弹结果框，
// 逐条列出「哪一条、为什么」，不再只报「N 个跳过」把原因吞掉。
import 'package:uten_imp/components/feedback/uten_dialog.dart';
import 'package:flutter/material.dart';

import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/action_feedback.dart';
import '../models/master_batch.dart';

/// 整批命令被服务端拒绝时，把逐行问题([ApiException.fieldErrors])拼进失败原因：
/// 概括句 + 每行「哪里：为什么」(全角冒号，最多 10 行，超出只计数)，与组装编辑
/// 保存失败同一格式。没有明细时只返回概括句。
String masterBatchFailureReason(ApiException e) {
  final details = e.fieldErrors;
  if (details == null || details.isEmpty) return e.message;
  return [
    e.message,
    for (final d in details.take(10)) '${d.field}：${d.message}',
    if (details.length > 10) '另有 ${details.length - 10} 处问题',
  ].join('\n');
}

/// 展示一次批量命令的结果。[action] 是动作名(禁用/启用/删除)，[noun] 是主档名(客户/货品…)。
/// [labelOf] 在服务端没给 label(记录不存在/无权限)时按 id 从当前页取显示名。
Future<void> showMasterBatchOutcome(
  BuildContext context,
  MasterBatchResult result, {
  required String action,
  required String noun,
  String? Function(String id)? labelOf,
  Widget Function(BuildContext context, Widget dialog)? dialogScopeBuilder,
}) async {
  if (!context.mounted) return;
  if (result.failed == 0) {
    context.appSuccess(
      '已$action ${result.succeeded} 个$noun',
    ); // TODO(l10n): 补 arb
    return;
  }
  await showDialog<void>(
    context: context,
    builder: (ctx) {
      final dialog = SelectionArea(
        child: UtenAlertDialog(
          scrollable: false,
          key: const Key('master-batch-outcome'),
          showCloseButton: true,
          onClose: () {
            if (ctx.mounted) Navigator.pop(ctx);
          },
          title: Text(
            result.succeeded == 0
                ? '$action失败：${result.failed} 个$noun没有处理'
                : '已$action ${result.succeeded} 个，${result.failed} 个没有处理', // TODO(l10n): 补 arb
          ),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.6,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final failure in result.failures)
                    Padding(
                      padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            failure.label ?? labelOf?.call(failure.id) ?? noun,
                            style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            failure.reason ?? '处理失败', // TODO(l10n): 补 arb
                            style: Theme.of(ctx).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      return dialogScopeBuilder?.call(ctx, dialog) ?? dialog;
    },
  );
}
