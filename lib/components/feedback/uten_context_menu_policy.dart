import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 右键只交给业务菜单；文字拖选、键盘复制和触屏长按继续使用 Flutter 的选择能力。
///
/// 放在 MaterialApp.builder 中，覆盖路由、弹窗及 Overlay。只清理右键抬起后的
/// 工具条不够：SelectionArea 也会在按住右键时的 tap-down deadline 弹「全选」。
/// 提前赢得次级按键的竞技场，阻止默认选择菜单产生；业务菜单走原始 Listener，
/// 不参与该竞技场，因此仍能正常打开。
class UtenContextMenuPolicy extends StatelessWidget {
  const UtenContextMenuPolicy({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.buttons & kSecondaryButton != 0) {
          ContextMenuController.removeAny();
        }
      },
      child: RawGestureDetector(
        behavior: HitTestBehavior.translucent,
        excludeFromSemantics: true,
        gestures: <Type, GestureRecognizerFactory>{
          EagerGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<EagerGestureRecognizer>(
                () => EagerGestureRecognizer(
                  allowedButtonsFilter: (buttons) =>
                      buttons & kSecondaryButton != 0,
                ),
                (_) {},
              ),
        },
        child: child,
      ),
    );
  }
}

final Expando<bool> _claimedContextMenuPointers = Expando<bool>();

/// 原始指针事件从最深命中节点向祖先分发；同一次右键只让最内层菜单处理。
///
/// 使用 original 保证缩放/位移后的事件共享所有权，Expando 随事件回收，
/// 不依赖全局 pointer id 或组件重建/抬键时机。表头也必须参与该仲裁。
bool claimUtenContextMenuPointer(PointerDownEvent event) {
  if (event.buttons & kSecondaryButton == 0) return false;
  final original = event.original ?? event;
  if (_claimedContextMenuPointers[original] ?? false) return false;
  _claimedContextMenuPointers[original] = true;
  return true;
}
