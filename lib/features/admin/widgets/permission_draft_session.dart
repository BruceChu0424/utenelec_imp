// 权限草稿的统一「闲置自动保存 + 离开前三选一」（按员工 / 按部门 / 全员基础包 /
// 可查看数据 / 页面权限抽屉共用）。
//
// 权限保存接口都要求再认证（ADR-110，一次密码 = 一张一次性凭证 = 一次请求），
// 所以授权编辑一律本地攒草稿：每次改动不再立即保存，停止操作一段时间后自动
// 保存一次，切换员工/部门/分区或离开页面时先问「保存 / 不保存 / 继续编辑」。
// 密码只在保存那一刻输一次，输错或取消则草稿保留、手动保存仍是重试入口。
import 'dart:async';

import 'package:flutter/material.dart';

import '../../../components/feedback/uten_dialog.dart';
import '../../../core/theme/uten_tokens.dart';

/// 停止操作多久后自动保存待提交的权限修改。
const Duration kPermissionDraftIdleAutoSaveDelay = Duration(minutes: 1);

/// 离开询问三选一的结果。
enum PermissionDraftLeaveChoice { save, discard, cancel }

/// 闲置自动保存计时：只在有待保存草稿时走表，弹框期间暂停。
class PermissionDraftSession {
  PermissionDraftSession({
    required this.onIdleSave,
    this.delay = kPermissionDraftIdleAutoSaveDelay,
  });

  /// 闲置到点时调用；宿主自行判断无草稿/保存中时直接返回。
  final Future<void> Function() onIdleSave;
  final Duration delay;

  Timer? _timer;
  bool _hasPendingEdits = false;
  bool _paused = false;

  /// 每次本地改动后调用：重置闲置计时。
  void noteEdit() {
    _hasPendingEdits = true;
    if (_paused) return;
    _timer?.cancel();
    _timer = Timer(delay, () {
      _timer = null;
      // 自动保存失败/被取消时保留草稿，不打断用户；下一次编辑重新计时。
      onIdleSave();
    });
  }

  /// 草稿清空（保存成功 / 撤销 / 丢弃）后调用：停止自动保存。
  void clear() {
    _hasPendingEdits = false;
    _timer?.cancel();
    _timer = null;
  }

  /// 保存/离开等弹框在途时暂停，避免自动保存插进对话框之间。
  void pause() {
    _paused = true;
    _timer?.cancel();
    _timer = null;
  }

  /// 弹框结束后恢复；仍有草稿则从现在起重新计满一个闲置窗口。
  void resume() {
    _paused = false;
    if (_hasPendingEdits) noteEdit();
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}

/// 离开前的三选一弹窗（保存并离开 / 不保存离开 / 继续编辑）。
Future<PermissionDraftLeaveChoice> showPermissionDraftLeaveDialog(
  BuildContext context, {
  required String subject,
  int changeCount = 0,
}) {
  final countText = changeCount > 0 ? '$changeCount 项' : '一些';
  return UtenDialog.showAndWaitForExit<PermissionDraftLeaveChoice>(
    context,
    barrierDismissible: false,
    builder: (dialogContext) => UtenAlertDialog(
      maxWidth: 520,
      title: const UtenDialogHeading(
        title: Text('保存未提交的修改？'),
        icon: Icons.save_as_outlined,
      ),
      content: Padding(
        padding: const EdgeInsets.only(top: UtenSpacing.s4),
        child: Text(
          '$subject有 $countText修改尚未提交。'
          '保存并离开会立即生效（需要重新输入你的登录密码）；'
          '不保存离开将丢弃这些修改。',
          style: const TextStyle(height: 1.5),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(
            dialogContext,
          ).pop(PermissionDraftLeaveChoice.cancel),
          child: const Text('继续编辑'),
        ),
        TextButton(
          onPressed: () => Navigator.of(
            dialogContext,
          ).pop(PermissionDraftLeaveChoice.discard),
          child: const Text('不保存离开'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(dialogContext).pop(PermissionDraftLeaveChoice.save),
          child: const Text('保存并离开'),
        ),
      ],
    ),
  ).then((value) => value ?? PermissionDraftLeaveChoice.cancel);
}

/// 离开守卫：有三选一；[save] 返回 true 表示草稿已全部落库（允许离开）。
Future<bool> guardPermissionDraftLeave(
  BuildContext context, {
  required String subject,
  required Future<bool> Function() save,
  int changeCount = 0,
}) async {
  final choice = await showPermissionDraftLeaveDialog(
    context,
    subject: subject,
    changeCount: changeCount,
  );
  switch (choice) {
    case PermissionDraftLeaveChoice.save:
      return save();
    case PermissionDraftLeaveChoice.discard:
      return true;
    case PermissionDraftLeaveChoice.cancel:
      return false;
  }
}
