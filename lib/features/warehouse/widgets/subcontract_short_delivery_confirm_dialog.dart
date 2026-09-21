// ADR-098 到货登记的「回厂短交确认」弹窗。
//
// 服务端在登记前评估委外订货行：累计回厂低于允许损耗下限时先以 409
// SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED 拒绝，fieldErrors 逐行给出大白话数字。
// 仓库看过后点「继续登记并通知委外」，原请求体加 shortDeliveryAcknowledged=true 原样重发；
// 登记成功即开立短交案件并通知委外跟单员判定。仓库只登记事实并确认知情，判定权在委外。
import 'package:flutter/material.dart';

import '../../../components/feedback/uten_dialog.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/models/procurement_inbound.dart';

const String kSubcontractShortDeliveryUnacknowledgedCode =
    'SUBCONTRACT_SHORT_DELIVERY_UNACKNOWLEDGED';

bool isSubcontractShortDeliveryUnacknowledged(ApiException error) =>
    error.code == kSubcontractShortDeliveryUnacknowledgedCode;

/// 弹窗：逐行列出短交明细；true = 继续登记并通知委外，false = 返回修改。
Future<bool> showSubcontractShortDeliveryConfirmDialog(
  BuildContext context,
  ApiException error,
) async {
  final lines = error.fieldErrors ?? const [];
  final confirmed = await UtenDialog.show(
    context,
    title: '到货数量明显少于订货量',
    danger: true,
    confirmLabel: '继续登记并通知委外',
    cancelLabel: '返回修改',
    content: Column(
      key: const Key('subcontract-short-delivery-confirm'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: UtenSpacing.s8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('• '),
                Expanded(child: Text(line.message)),
              ],
            ),
          ),
        Text(
          error.message,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// 登记并在需要时确认短交：返回 null 表示仓库选择「返回修改」，调用方原地停下不报错。
/// 其余异常原样抛出，由页面按既有方式提示。
///
/// [setBusy] 是登记页的「正在登记」全屏遮罩开关，必填：UtenBusyOverlay 把遮罩直接插进
/// root Overlay，而 Navigator 每次路由历史变动都会 rearrange 一次，把这条不属于任何路由的
/// 裸图层**重新抬到最顶**——后推的弹窗一定被它盖住、两个按钮都点不动(2026-09-21 批量登记
/// 页实测)，靠调整先后顺序绕不开。唯一可靠的做法是弹窗前 setBusy(false) 把遮罩整个撤掉并
/// 等这一帧画完，确认后再 setBusy(true) 接着重发。
Future<WarehouseArrivalRegistration?> registerArrivalConfirmingShortDelivery({
  required BuildContext context,
  required Map<String, dynamic> body,
  required Future<WarehouseArrivalRegistration> Function(
    Map<String, dynamic> body,
  )
  register,
  required void Function(bool busy) setBusy,
}) async {
  try {
    return await register(body);
  } on ApiException catch (error) {
    if (!isSubcontractShortDeliveryUnacknowledged(error)) rethrow;
    if (!context.mounted) return null;
    // 先撤遮罩再弹窗：endOfFrame 等的是遮罩那帧真的画完(OverlayEntry 在 dispose 时才移除)。
    setBusy(false);
    await WidgetsBinding.instance.endOfFrame;
    if (!context.mounted) return null;
    final confirmed = await showSubcontractShortDeliveryConfirmDialog(
      context,
      error,
    );
    // 「返回修改」不恢复遮罩：调用方收到 null 后原地停下，自己会收尾。
    if (!confirmed) return null;
    setBusy(true);
    return register({...body, 'shortDeliveryAcknowledged': true});
  }
}
