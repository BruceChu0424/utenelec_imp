import 'package:flutter/foundation.dart';

/// 表格行拖拽的落点形态。
enum UtenTableRowDropMode {
  /// 插到目标行的同层上方。
  above,

  /// 插到目标行的同层下方。
  below,

  /// 移入目标行之下成为其子级（树表层级拖拽）。
  into,
}

/// MasterDataTableView 的行拖拽配置（长按启动）。
///
/// 默认所有表格**不**支持拖拽：只有宿主显式传入本配置的表才有长按拾起
/// （2026-10-19 用户口径：普通清单页（如货品列表）、自带排序口径的表不挂；
/// 需要人工排层的表（如货品「组装信息」BOM）才接）。
///
/// 交互契约：
/// - 拾起有两条路（2026-10-19 二轮用户口径「长按也触发、按住上下移动了就触发」）：
///   按住不动约 250ms（官方默认 500ms 太钝）拾起，或鼠标按住纵向移出 slop 立即
///   拾起——横向移动仍归文字框选，两个方向两种语义互不抢；触屏纵向拖保留给
///   列表滚动，只有长按路径对触屏开放；
/// - 拾起时若该行已在多选勾选集中，则整批勾选行一起拖（批量移动）；
/// - 拾起即把该行纳入勾选（用户口径「长按首先是选中这一行」）；
/// - 拖动中按 ESC 取消；
/// - 松手时按光标在目标行内的位置判定 [UtenTableRowDropMode]：上缘=上方插入、
///   下缘=下方插入、中部=移入子级（[canDropInto] 放行时）；
/// - 悬停某个目标行约 700ms 触发一次 [onHoverAutoExpand]（树表悬停自动展开，
///   展开与否、要不要懒加载由宿主决定）；
/// - 持久化与加载反馈（busy 遮罩/失败提示/重载）由宿主在 [onDrop] 里负责。
class UtenTableRowDrag<T> {
  const UtenTableRowDrag({
    required this.canDragRow,
    required this.dragRowsOf,
    required this.canDrop,
    required this.onDrop,
    this.canDropInto,
    this.onHoverAutoExpand,
    this.dragLabelOf,
    this.hoverAutoExpandDelay = const Duration(milliseconds: 700),
  });

  /// 该行是否可发起拖拽（长按拾起）。false 的行长按无效果。
  final bool Function(T row) canDragRow;

  /// 拖拽载荷：按下的是已勾选行 → 整批勾选行（按可见顺序）；否则只有本行。
  final List<T> Function(T pressedRow) dragRowsOf;

  /// 拖拽中悬停的目标行是否可接收「上方/下方插入」。
  /// 目标自身在被拖行里、或目标在被拖行的子树里时应返回 false（防成环/自嵌套）。
  final bool Function(T target, List<T> dragged) canDrop;

  /// 目标行是否可接收「移入作为子级」。null = 本表不支持移入（拖拽全程只有
  /// 上/下插入两种落点）。
  final bool Function(T target, List<T> dragged)? canDropInto;

  /// 松手落点。宿主负责校验后的持久化（服务端是成环/重复的最终权威）、
  /// busy 遮罩与成功/失败反馈、数据重载。
  final Future<void> Function(
    List<T> dragged,
    T target,
    UtenTableRowDropMode mode,
  )
  onDrop;

  /// 悬停目标行一小段时间后的回调（每次拖拽对每个目标行至多触发一次）。
  /// 树表用它做「悬停自动展开」：展开状态与子级懒加载归宿主管。
  final void Function(T target)? onHoverAutoExpand;

  /// 拖拽幽灵卡上的主标签（通常取行名称列）；缺省只显示行数徽记。
  final String? Function(T firstRow)? dragLabelOf;

  /// 悬停多久触发自动展开。
  final Duration hoverAutoExpandDelay;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UtenTableRowDrag && other.canDragRow == canDragRow;

  @override
  int get hashCode => Object.hash('UtenTableRowDrag', canDragRow);
}

/// 拖拽中的即时快照（测试与宿主动画用）。
@immutable
class UtenTableRowDragSnapshot<T> {
  const UtenTableRowDragSnapshot({
    required this.dragged,
    required this.target,
    required this.mode,
  });

  final List<T> dragged;
  final T? target;
  final UtenTableRowDropMode? mode;
}
