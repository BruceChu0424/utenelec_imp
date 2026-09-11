// 编辑页右下角悬浮操作组（取消 / 保存）—— 全站单据编辑页的唯一形态。
//
// 2026-09-11 用户口径：新建/编辑页原来在页面最底下挂一条固定操作条
// （`bottomNavigationBar` + 居中的「合计 取消 保存」），与列表/任务页右下角的
// 悬浮动作组两种长相、两种尺寸。现统一为**右下角悬浮**：
//
//   Scaffold(
//     floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
//     floatingActionButton: UtenEditFloatingActions(
//       onCancel: ...,
//       onSave: ...,
//       saving: _saving,
//     ),
//   )
//
// 三条口径：
// 1. **合计不进这里**。明细表下方已有 `UtenTotalsSummaryBar`，底部再报一遍是重复
//    （用户原话：「合计那个就不用了 因为表格下面有了」）。
// 2. **主动作红底白字**（`UtenButtonType.danger`）。全站「点了就往下走一步」的
//    右下角按钮统一这个色（提交采购需求 / 创建生产计划 / 保存 …），用户要的是
//    「看得明显」；取消走 secondary。
// 3. 尺寸由 [UtenFloatingActionGroup] 统一（每个孩子 minHeight 52），与其它页面
//    右下角的按钮严格等高。

import 'package:flutter/material.dart';

import '../layout/uten_floating_action_group.dart';
import 'uten_button.dart';

class UtenEditFloatingActions extends StatelessWidget {
  const UtenEditFloatingActions({
    super.key,
    required this.onCancel,
    required this.onSave,
    this.saving = false,
    this.cancelLabel = '取消',
    this.saveLabel = '保存',
    this.saveIcon = Icons.save_outlined,
    this.extraLeading = const [],
  });

  /// 取消（通常是 `popOrBackTo`）；null = 禁用。
  final VoidCallback? onCancel;

  /// 保存；null = 禁用（保存中请改传 [saving] 而不是把它置空，
  /// 否则按钮会同时失去 loading 态和禁用原因）。
  final VoidCallback? onSave;

  /// 保存中：主按钮转圈并禁用，取消同时禁用（避免半途离开）。
  final bool saving;

  final String cancelLabel;
  final String saveLabel;
  final IconData saveIcon;

  /// 排在「取消」左侧的页面自有动作（如「另存为草稿」）。
  final List<Widget> extraLeading;

  @override
  Widget build(BuildContext context) {
    return UtenFloatingActionGroup(
      children: [
        ...extraLeading,
        UtenButton(
          key: const ValueKey('uten-edit-cancel'),
          type: UtenButtonType.secondary,
          size: UtenButtonSize.large,
          onPressed: saving ? null : onCancel,
          child: Text(cancelLabel),
        ),
        UtenButton(
          key: const ValueKey('uten-edit-save'),
          type: UtenButtonType.danger,
          size: UtenButtonSize.large,
          isLoading: saving,
          icon: saveIcon,
          onPressed: saving ? null : onSave,
          child: Text(saveLabel),
        ),
      ],
    );
  }
}
