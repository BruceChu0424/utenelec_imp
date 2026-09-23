// 应用根部的不渲染宿主：全局采集人为输入，写进 UserActivity (ADR-110)。
//
// 挂在指针路由与硬件键盘的全局入口上，而不是某一页的 Listener 里：根导航器上的弹窗
// (再认证、确认框) 里的点击与输入同样算操作。只记时间，不拦截、不消费任何事件。
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/network/user_activity.dart';

class UserActivityTracker extends StatefulWidget {
  const UserActivityTracker({super.key});

  @override
  State<UserActivityTracker> createState() => _UserActivityTrackerState();
}

class _UserActivityTrackerState extends State<UserActivityTracker> {
  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent ||
        event is PointerMoveEvent ||
        event is PointerHoverEvent ||
        event is PointerSignalEvent ||
        event is PointerPanZoomUpdateEvent) {
      UserActivity.record();
    }
  }

  bool _onKey(KeyEvent event) {
    UserActivity.record();
    return false;
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
