// 页面可见性(前台/后台)的全局来源——所有后台轮询的暂停开关(ADR-108)。
//
// 浏览器标签页切走、窗口最小化、手机切后台时 Flutter 报 hidden / paused;
// 此时徽章汇总、通知到达等轮询全部停下, 回到前台(resumed / inactive)立即拉一次。
// inactive 仍算可见: 桌面/Web 窗口只是失去焦点, 用户还看得见页面。
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// true = 页面可见(应当轮询); false = 已隐藏/在后台(暂停轮询)。
final appVisibilityProvider = NotifierProvider<AppVisibilityNotifier, bool>(
  AppVisibilityNotifier.new,
);

class AppVisibilityNotifier extends Notifier<bool> {
  @override
  bool build() {
    final binding = _bindingOrNull();
    if (binding == null) return true;
    final observer = _VisibilityObserver((lifecycle) {
      final visible = isVisibleLifecycle(lifecycle);
      if (visible != state) state = visible;
    });
    binding.addObserver(observer);
    ref.onDispose(() => binding.removeObserver(observer));
    return isVisibleLifecycle(binding.lifecycleState);
  }

  /// 测试与特殊宿主(如嵌入式预览)直接指定可见性。
  void debugSet(bool visible) => state = visible;
}

/// 生命周期 → 是否可见; 还没收到任何生命周期事件(null)按可见处理。
bool isVisibleLifecycle(AppLifecycleState? lifecycle) =>
    lifecycle == null ||
    lifecycle == AppLifecycleState.resumed ||
    lifecycle == AppLifecycleState.inactive;

WidgetsBinding? _bindingOrNull() {
  try {
    return WidgetsBinding.instance;
  } catch (_) {
    // 纯 Dart 的 provider 测试可能没有初始化 binding: 按一直可见处理。
    return null;
  }
}

class _VisibilityObserver extends WidgetsBindingObserver {
  _VisibilityObserver(this._onChange);

  final void Function(AppLifecycleState state) _onChange;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _onChange(state);
}
