// UtenRefreshButton - AppBar/工具条刷新动作的统一形态：自带忙碌转圈与防重入。
//
// 2026-10-18 全站口径：此前各页手写 IconButton(Icons.refresh_rounded)，拉取期间
// 图标毫无变化（任务中心/即时库存/货架清单等十余处），用户感知「点了没反应」。
// 本组件把「点击→等待→恢复」的 busy 生命周期收进按钮自身（与 UtenActionButton
// 同一 ClickGuard 思路）：忙碌时图标位换小转圈并禁用，占位不变、不跳布局。
//
// 页面已有自己的 loading 态时用 [busy] 联动（外部口径与本按钮自身在跑取或）；
// 纯图标形态不变——带文字的顶栏动作继续用 UtenAppBarActionButton(isLoading:)。

import 'dart:async';

import 'package:flutter/material.dart';

import 'click_guard.dart';
import 'uten_app_bar_action_button.dart';
import '../layout/uten_app_bar_action_scope.dart';

class UtenRefreshButton extends StatefulWidget {
  const UtenRefreshButton({
    super.key,
    required this.onRefresh,
    this.tooltip = '刷新', // TODO(l10n): 补 arb
    this.busy = false,
    this.enabled = true,
  });

  /// 刷新动作。组件自动防重入：忙碌期间再点不触发。
  final FutureOr<void> Function() onRefresh;

  /// 外部忙碌口径（如页面级 _loading）。为 true 时按钮转圈并禁用。
  final bool busy;

  /// Other page locks disable refresh without claiming that it is loading.
  final bool enabled;

  final String tooltip;

  @override
  State<UtenRefreshButton> createState() => _UtenRefreshButtonState();
}

class _UtenRefreshButtonState extends State<UtenRefreshButton> {
  final _guard = ClickGuard();

  Future<void> _run() async {
    if (!widget.enabled || widget.busy) return;
    final action = _guard.run(() => Future<void>.sync(widget.onRefresh));
    if (action == null) return;
    setState(() {});
    try {
      await action;
    } finally {
      if (mounted) setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = widget.busy || _guard.isBusy;
    if (UtenAppBarActionPresentation.contains(context)) {
      return UtenAppBarActionButton(
        label: '刷新',
        tooltip: widget.tooltip,
        isLoading: busy,
        onPressed: busy || !widget.enabled ? null : _run,
      );
    }
    return IconButton(
      icon: busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            )
          : const Icon(Icons.refresh_rounded),
      tooltip: widget.tooltip,
      onPressed: busy || !widget.enabled ? null : _run,
    );
  }
}
