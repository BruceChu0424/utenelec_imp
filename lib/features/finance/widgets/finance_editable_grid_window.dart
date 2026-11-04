import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/layout/uten_action_overflow.dart';
import '../../../components/layout/uten_editable_grid.dart';
import '../../../components/layout/uten_pagination.dart';
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
  final _view = UtenEditableGridController<T>();
  final _bodyScroll = ScrollController();
  int _page = 1;
  int get _pages => math.max(
    1,
    (widget.controller.length + widget.pageSize - 1) ~/ widget.pageSize,
  );
  @override
  void initState() {
    super.initState();
    _page = widget.initialPage;
    widget.controller.addListener(_sourceChanged);
    _refresh();
  }

  @override
  void didUpdateWidget(covariant FinanceEditableGridWindow<T> old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_sourceChanged);
      widget.controller.addListener(_sourceChanged);
      _page = widget.initialPage;
    }
    if (old.initialPage != widget.initialPage) _page = widget.initialPage;
    _refresh();
  }

  void _refresh() {
    _page = _page.clamp(1, _pages);
    final begin = (_page - 1) * widget.pageSize,
        end = math.min(_page * widget.pageSize, widget.controller.length);
    final visible = widget.controller.rows.sublist(
      math.min(begin, widget.controller.length),
      end,
    );
    var changed = _view.length != visible.length;
    if (!changed) {
      for (var index = 0; index < visible.length; index++) {
        if (!identical(_view[index], visible[index])) {
          changed = true;
          break;
        }
      }
    }
    if (changed) {
      _view.clearSelection();
      _view.swapRows(visible);
    }
  }

  void _sourceChanged() {
    if (mounted) setState(_refresh);
  }

  void _change(int page) {
    setState(() {
      _page = page;
      _refresh();
    });
    if (_bodyScroll.hasClients) _bodyScroll.jumpTo(0);
    widget.onPageChanged?.call(_page);
  }

  void _add() {
    final create = widget.createBlankRow;
    if (!widget.showAddRow || create == null) return;
    widget.controller.addRow(create());
    _change(_pages);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_sourceChanged);
    _view.swapRows(<T>[]);
    _view.dispose();
    _bodyScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final grid = UtenEditableGrid<T>(
        controller: _view,
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
              Text(
                '共${widget.controller.length}行；每页${widget.pageSize}行，草稿与提交保留完整清单',
              ),
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
              height: math.min(360, 90 + _view.length * 48).toDouble(),
              child: body,
            ),
          UtenPagination(
            currentPage: _page,
            totalPages: _pages,
            onPageChanged: _change,
          ),
        ],
      );
    },
  );
}
