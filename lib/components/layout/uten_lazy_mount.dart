// UtenLazyMount - 延迟挂载
//
// 首帧只渲染 [placeholder]（默认空盒），下一帧（post-frame，可选 [delay]）之后
// 才真正构建 [builder] 子树。用于把「会发起网络请求 / 重计算」的区块推迟到首帧
// 绘制之后，避免首屏一次性发起过多请求、构建重树导致卡顿。
//
// 范式同全项目 initState 里 addPostFrameCallback((_) => _load()) 的「首帧让路」
// 惯例（40+ 处列表页/编辑页在用），只是把它沉淀成可复用的包裹组件，让任意区块
// 「先占位、后并行加载、各自显示加载中」。
//
// 用法：
//   UtenLazyMount(
//     placeholder: (_) => const Skeleton(),
//     builder: (_) => const ExpensiveNetworkSection(),
//   )
//
// _ready 一旦置 true 永不回退（保活由外层 _KeepAlivePage 负责，组件内不重复延迟）。

import 'package:flutter/material.dart';

class UtenLazyMount extends StatefulWidget {
  const UtenLazyMount({
    super.key,
    required this.builder,
    this.placeholder,
    this.delay = Duration.zero,
  });

  /// 首帧后真正挂载的子树（通常含网络请求 / 重计算）。
  final WidgetBuilder builder;

  /// 首帧占位（默认 SizedBox.shrink，不占布局）。
  final WidgetBuilder? placeholder;

  /// post-frame 之后再额外等待的时长。
  /// 默认零：首帧绘制完立即挂载（≈ 并行发请求）。留作个别区块错峰用，一般保持零。
  final Duration delay;

  @override
  State<UtenLazyMount> createState() => _UtenLazyMountState();
}

class _UtenLazyMountState extends State<UtenLazyMount> {
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.delay == Duration.zero) {
        setState(() => _ready = true);
        return;
      }
      Future.delayed(widget.delay, () {
        if (!mounted) return;
        setState(() => _ready = true);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready) {
      return widget.placeholder?.call(context) ?? const SizedBox.shrink();
    }
    return widget.builder(context);
  }
}
