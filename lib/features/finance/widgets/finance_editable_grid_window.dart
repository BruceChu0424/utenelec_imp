import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_action_overflow.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../core/theme/uten_tokens.dart';

/// A presentation window over an owned complete controller. Models, exact input,
/// draft extensions and server submissions stay on the source controller.
/// swapRows is the existing non-disposing Uten view operation; the view never
/// owns or copies financial row models and does not calculate money.
class FinanceEditableGridWindow<T extends EditableGridRow>
    extends StatefulWidget {
  const FinanceEditableGridWindow({
    super.key,
    required this.controller,
    required this.columns,
    this.tableKey,
    this.createBlankRow,
    this.showAddRow = false,
    this.showRowDelete = false,
    this.showRemoveRowsAction = false,
    this.showColumnSettings = false,
    this.stickyHeader = false,
    this.initialPage = 1,
    this.onPageChanged,
    this.pageSize = 30,
  });
  final UtenEditableGridController<T> controller;
  final List<EditableGridColumn<T>> columns;
  final String? tableKey;
  final T Function()? createBlankRow;
  final bool showAddRow,
      showRowDelete,
      showRemoveRowsAction,
      showColumnSettings,
      stickyHeader;
  final int initialPage, pageSize;
  final ValueChanged<int>? onPageChanged;
  @override
  State<FinanceEditableGridWindow<T>> createState() =>
      _FinanceEditableGridWindowState<T>();
}

class _FinanceEditableGridWindowState<T extends EditableGridRow>
    extends State<FinanceEditableGridWindow<T>> {
  final _bodyScroll = ScrollController();
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_sourceChanged);
  }

  @override
  void didUpdateWidget(covariant FinanceEditableGridWindow<T> old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_sourceChanged);
      widget.controller.addListener(_sourceChanged);
    }
  }

  void _sourceChanged() {
    if (mounted) setState(() {});
  }

  void _add() {
    final create = widget.createBlankRow;
    if (!widget.showAddRow || create == null) return;
    widget.controller.addRow(create());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _bodyScroll.hasClients) {
        _bodyScroll.jumpTo(_bodyScroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sourceChanged);
    _bodyScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final grid = UtenEditableGrid<T>(
        controller: widget.controller,
        columns: widget.columns,
        tableKey: widget.tableKey,
        showAddRow: false,
        showRowDelete: widget.showRowDelete,
        showRemoveRowsAction: widget.showRemoveRowsAction,
        onDeleteRow: widget.showRowDelete
            ? (row, _) {
                if (widget.showRowDelete) widget.controller.removeRows([row]);
              }
            : null,
        onRemoveRows: widget.showRemoveRowsAction
            ? widget.controller.removeRows
            : null,
        showColumnSettings: widget.showColumnSettings,
        stickyHeader: widget.stickyHeader,
      );
      final body = SingleChildScrollView(controller: _bodyScroll, child: grid);
      return Column(
        mainAxisSize: constraints.hasBoundedHeight
            ? MainAxisSize.max
            : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UtenResponsiveActionWrap(
            children: [
              Text('共${widget.controller.length}行'),
              if (widget.showAddRow)
                UtenButton(
                  type: UtenButtonType.secondary,
                  onPressed: widget.createBlankRow == null ? null : _add,
                  child: const Text('添加行'),
                ),
            ],
          ),
          const SizedBox(height: UtenSpacing.s4),
          if (constraints.hasBoundedHeight)
            Expanded(child: body)
          else
            SizedBox(
              height: math
                  .min(360, 90 + widget.controller.length * 48)
                  .toDouble(),
              child: body,
            ),
        ],
      );
    },
  );
}
