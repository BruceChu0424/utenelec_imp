import 'package:flutter/material.dart';
import 'package:uten_imp/components/layout/uten_editable_grid.dart';
import 'package:uten_imp/components/layout/uten_grid_header_filter_cell.dart';

/// Local performance harness. Uses the same grid/controller/cell subscriptions
/// as document editors; the complete 1000-row model remains authoritative.
class B0EditableGridFixture extends StatefulWidget {
  const B0EditableGridFixture({super.key, this.onMetrics});
  final ValueChanged<Map<String, Object?>>? onMetrics;
  @override
  State<B0EditableGridFixture> createState() => B0EditableGridFixtureState();
}

class _FixtureRow extends EditableGridRow with AmountRowMixin {
  _FixtureRow(this.index) {
    note.text = '物料 ${index.toString().padLeft(4, '0')}';
    quantity.addListener(_recalculate);
    _recalculate();
  }
  final int index;
  final note = TextEditingController();
  final quantity = TextEditingController(text: '1');
  void _recalculate() =>
      recalcAmount(() => (double.tryParse(quantity.text) ?? 0) * 12.5);
  @override
  void dispose() {
    note.dispose();
    quantity.dispose();
    super.dispose();
  }
}

class B0EditableGridFixtureState extends State<B0EditableGridFixture> {
  final _scroll = ScrollController();
  final _rows = UtenEditableGridController<_FixtureRow>();
  late final List<_FixtureRow> _models;
  int _cellBuilds = 0;
  int _inputCallbacks = 0;
  double _modelCreationMs = 0;
  double _controllerBindingMs = 0;
  Map<String, Object?> get metrics => {
    'modelRows': _rows.length,
    'mountedRows': _rows.mountedRowCount,
    'cellBuilds': _cellBuilds,
    'inputCallbacks': _inputCallbacks,
    'firstNote': _models.first.note.text,
    'lastNote': _models.last.note.text,
    'total': _rows.total,
    'scrollPixels': _scroll.hasClients ? _scroll.offset : 0,
    'modelCreationMs': _modelCreationMs,
    'controllerBindingMs': _controllerBindingMs,
  };

  @override
  void initState() {
    super.initState();
    final clock = Stopwatch()..start();
    _models = List.generate(1000, _FixtureRow.new);
    _modelCreationMs = clock.elapsedMicroseconds / 1000;
    clock.reset();
    _rows.addRows(_models);
    _controllerBindingMs = clock.elapsedMicroseconds / 1000;
    WidgetsBinding.instance.addPostFrameCallback((_) => _publish());
  }

  void _publish() {
    if (mounted) widget.onMetrics?.call(metrics);
  }

  Future<bool> revealLastRow() async {
    final result = await _rows.revealCell(_models.last, 'note');
    _publish();
    return result;
  }

  Future<void> waitUntilRowsReady() => _rows.settled;

  void scrollToFraction(double fraction) {
    if (_scroll.hasClients) {
      _scroll.jumpTo(_scroll.position.maxScrollExtent * fraction.clamp(0, 1));
    }
  }

  W? _find<W extends Widget>(bool Function(W) predicate) {
    W? found;
    void visit(Element element) {
      final widget = element.widget;
      if (widget is W && predicate(widget)) {
        found = widget;
        return;
      }
      if (found == null) element.visitChildren(visit);
    }

    context.visitChildElements(visit);
    return found;
  }

  /// Dispatches through live widgets and their production callbacks. Browser
  /// keyboard/pointer validation is intentionally a separate harness step.
  Future<Map<String, Object?>> runActions({
    ValueChanged<String>? onPhase,
  }) async {
    await _rows.settled;
    if (!mounted) return {'cancelled': true};
    onPhase?.call('grid-input');
    final input = _find<TextField>(
      (field) => identical(field.controller, _models.first.note),
    );
    if (input?.controller == null || input?.onChanged == null) {
      throw StateError('Initial grid input did not mount');
    }
    input!.controller!.text = '输入验证';
    input.onChanged!('输入验证');
    for (final fraction in [.2, .55, .9, .1]) {
      onPhase?.call('grid-scroll-$fraction');
      scrollToFraction(fraction);
      await _rows.settled;
      if (!mounted) return {'cancelled': true};
    }
    onPhase?.call('grid-search');
    final header = _find<GridHeaderFilterCell>(
      (header) => header.label == '物料备注',
    );
    header?.onSearch?.call('物料 0999');
    await WidgetsBinding.instance.endOfFrame;
    await _rows.settled;
    if (!mounted) return {'cancelled': true};
    final filteredMounted = _rows.mountedRowCount;
    // Explicit reveal clears presentation-only search, then mounts and focuses
    // the same target used by a business page's first-invalid navigation.
    onPhase?.call('grid-reveal');
    final revealed = await _rows.revealCell(_models[500], 'note');
    if (!mounted) return {'cancelled': true};
    final result = {
      ...metrics,
      'filteredMountedRows': filteredMounted,
      'revealed': revealed,
      'windowSettled': !_rows.isMounting,
    };
    widget.onMetrics?.call(result);
    return result;
  }

  @override
  Widget build(BuildContext context) => ListView(
    controller: _scroll,
    children: [
      Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Text('1000 行大单据：表头搜索 · 输入 · 页面滚动'),
            const SizedBox(width: 16),
            OutlinedButton(onPressed: revealLastRow, child: const Text('定位末行')),
          ],
        ),
      ),
      UtenEditableGrid<_FixtureRow>(
        controller: _rows,
        showAddRow: false,
        selectable: true,
        showColumnSettings: false,
        initialPinnedColumnKeys: const {'id'},
        columns: [
          EditableGridColumn<_FixtureRow>(
            key: 'id',
            label: '序号',
            width: 100,
            cellBuilder: (_, row) => Text('${row.index + 1}'),
          ),
          EditableGridColumn<_FixtureRow>(
            key: 'note',
            label: '物料备注',
            width: 420,
            textOf: (row) => row.note.text,
            listenableOf: (row) => row.note,
            cellBuilder: (_, row) {
              _cellBuilds++;
              return TextField(
                key: ValueKey('b0-grid-note-${row.index}'),
                controller: row.note,
                onChanged: (_) => _inputCallbacks++,
              );
            },
          ),
          EditableGridColumn<_FixtureRow>(
            key: 'qty',
            label: '数量',
            width: 240,
            numeric: true,
            cellBuilder: (_, row) => TextField(
              key: ValueKey('b0-grid-qty-${row.index}'),
              controller: row.quantity,
              keyboardType: TextInputType.number,
              onChanged: (_) => _inputCallbacks++,
            ),
          ),
          EditableGridColumn<_FixtureRow>(
            key: 'amount',
            label: '金额',
            width: 240,
            numeric: true,
            cellBuilder: (_, row) => ValueListenableBuilder<double>(
              valueListenable: row.amountNotifier,
              builder: (_, value, _) => Text(value.toStringAsFixed(2)),
            ),
          ),
        ],
        footer: ValueListenableBuilder<double>(
          valueListenable: _rows.totalListenable,
          builder: (_, total, _) =>
              Text('1000 行合计 ${total.toStringAsFixed(2)}'),
        ),
      ),
    ],
  );

  @override
  void dispose() {
    _scroll.dispose();
    _rows.dispose();
    super.dispose();
  }
}
