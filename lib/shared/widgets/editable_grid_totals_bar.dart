// 编辑页明细网格的合计条：把各单据编辑页手写的「合计 ¥…」文本收口到
// UtenTotalsSummaryBar（全站统一口径），并解决「数量改动不触发重建」的刷新问题。
//
// 刷新信号有三个来源：
//   1. 网格增删行（controller 本身是 ChangeNotifier）；
//   2. 金额合计（controller.totalListenable）；
//   3. 逐行数量等文本控制器（[watchOf]）——单价为 0 时金额不变，只靠 1/2 会漏刷。
//
// 合计数量必须用 utenQuantityTotalEntry 按 unitId 分组：不同单位的数量绝不相加。
import 'package:flutter/material.dart';

import '../../components/data_display/uten_totals_summary_bar.dart';
import '../../components/layout/uten_editable_grid.dart';

class EditableGridTotalsBar<T extends EditableGridRow> extends StatefulWidget {
  const EditableGridTotalsBar({
    super.key,
    required this.controller,
    required this.entriesBuilder,
    this.watchOf,
    this.density = true,
    this.showDivider = true,
  });

  final UtenEditableGridController<T> controller;

  /// 按当前行重算合计项；数量项一律走 [utenQuantityTotalEntry]。
  final List<UtenTotalEntry> Function(List<T> rows) entriesBuilder;

  /// 逐行需要监听的文本控制器（通常是数量列）；null = 只跟随增删行与金额合计。
  final Iterable<TextEditingController> Function(T row)? watchOf;

  final bool density;
  final bool showDivider;

  @override
  State<EditableGridTotalsBar<T>> createState() =>
      _EditableGridTotalsBarState<T>();
}

class _EditableGridTotalsBarState<T extends EditableGridRow>
    extends State<EditableGridTotalsBar<T>> {
  final Set<TextEditingController> _watched = {};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onRowsChanged);
    widget.controller.totalListenable.addListener(_onTick);
    _rebind();
  }

  @override
  void didUpdateWidget(covariant EditableGridTotalsBar<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_onRowsChanged);
      oldWidget.controller.totalListenable.removeListener(_onTick);
      widget.controller.addListener(_onRowsChanged);
      widget.controller.totalListenable.addListener(_onTick);
    }
    _rebind();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onRowsChanged);
    widget.controller.totalListenable.removeListener(_onTick);
    for (final c in _watched) {
      c.removeListener(_onTick);
    }
    _watched.clear();
    super.dispose();
  }

  void _onRowsChanged() {
    _rebind();
    _onTick();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  /// 行增删后重新绑定逐行监听（只增删差集，已绑定的行不动）。
  void _rebind() {
    final watchOf = widget.watchOf;
    final current = <TextEditingController>{};
    if (watchOf != null) {
      for (final row in widget.controller.rows) {
        current.addAll(watchOf(row));
      }
    }
    for (final c in _watched.difference(current)) {
      c.removeListener(_onTick);
    }
    for (final c in current.difference(_watched)) {
      c.addListener(_onTick);
    }
    _watched
      ..clear()
      ..addAll(current);
  }

  @override
  Widget build(BuildContext context) {
    return UtenTotalsSummaryBar(
      density: widget.density,
      showDivider: widget.showDivider,
      entries: widget.entriesBuilder(widget.controller.rows),
    );
  }
}
