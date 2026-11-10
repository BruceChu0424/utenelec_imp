import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../core/performance/ui_work_budget.dart';
import '../../shared/models/immutable_paged_rows.dart';
import 'src/row_extent_index.dart';

/// Optional local structural counters; contains no row values or identities.
void Function(String operation, int count)? debugAncestorRowWindowWorkObserver;

/// Presentation access only. Row values, validation and selection stay with
/// the business controller even while their widgets are outside the window.
class UtenAncestorRowWindowController<T extends Object> {
  _UtenAncestorRowWindowState<T>? _state;
  int get mountedRowCount => _state?._mountedRows.length ?? 0;
  bool get isMounting => _state?._isMounting ?? false;
  Future<void> get settled async => await _state?._waitForCurrentWindow();
  BuildContext? contextFor(T row) => _state?._rowKeys[row]?.currentContext;

  /// Retain live presentation state such as a native text selection. This is
  /// deliberately separate from business selection and visited-row history.
  void retain(T row, bool retain) => _state?._retain(row, retain);

  /// A host can resize this viewport without changing its source, screen or
  /// scroll pixels. Reuse the existing presentation and scheduler checks.
  void notifyViewportChanged() => _state?._onScroll();

  Future<bool> reveal(
    T row, {
    double alignment = .15,
    bool Function()? isCurrent,
    int maxGeometryCorrections = 16,
  }) async {
    RangeError.checkValueInInterval(
      maxGeometryCorrections,
      1,
      16,
      'maxGeometryCorrections',
    );
    return await _state?._reveal(
          row,
          alignment,
          isCurrent,
          maxGeometryCorrections,
        ) ??
        false;
  }
}

/// Limits real new row subtrees across all windows in a frame. Constructing a
/// row Widget is cheap; the expensive Element/input/theme mount happens later
/// in that frame, so a construction-time stopwatch cannot bound that work.
abstract final class _RowMountBudget {
  static bool _resetScheduled = false;
  static int _used = 0;

  static bool take({bool expensive = true}) {
    if (!_resetScheduled) {
      _resetScheduled = true;
      // Reset in the next frame's transient phase, before any widget builds.
      // Distinct frames may share a timestamp (notably WidgetTester.pump()).
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        _used = 0;
        _resetScheduled = false;
      });
    }
    // Input-heavy/unknown subtrees still consume the entire frame allowance.
    // Explicit lightweight rows share a small fixed batch; never infer the
    // next input's mount cost from a cheap preceding frame.
    final cost = expensive ? 4 : 1;
    if (_used + cost > 4) return false;
    _used += cost;
    return true;
  }
}

/// A light sliver child can be visited during a distant jump without mounting
/// its expensive business subtree. Offscreen shells use ordinary sliver
/// disposal/keep-alive rules; this adds no scroll position or row retention.
class UtenDeferredRowMountController {
  _UtenDeferredRowMountState? _state;
  bool get isMounting => _state?._isMounting ?? false;
  bool get hasMountedContent =>
      _state?._admitted == true && _state?._needsLayout == false;
  Future<void> get settled async => await _state?._settled();
}

class UtenDeferredRowMount extends StatefulWidget {
  const UtenDeferredRowMount({
    super.key,
    required this.controller,
    required this.builder,
    required this.estimatedExtent,
    this.deferNewMounts = true,
    this.admitOnFirstFrame = false,
    this.expensive = true,
    this.onExtentMeasured,
  });
  final UtenDeferredRowMountController controller;
  final WidgetBuilder builder;
  final double estimatedExtent;
  final bool deferNewMounts;

  /// A small insertion beside already mounted content can skip the empty
  /// shell frame. Admission still consumes the shared per-frame mount budget.
  final bool admitOnFirstFrame;
  final bool expensive;
  final ValueChanged<double>? onExtentMeasured;
  @override
  State<UtenDeferredRowMount> createState() => _UtenDeferredRowMountState();
}

class _UtenDeferredRowMountState extends State<UtenDeferredRowMount> {
  bool _admitted = false;
  bool _shellLaidOut = false;
  bool _active = true;
  bool _scheduled = false;
  bool _needsLayout = false;
  Stopwatch? _clock;
  bool get _isMounting => _active && (!_admitted || _needsLayout || _scheduled);

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _active =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
  }

  @override
  void didUpdateWidget(UtenDeferredRowMount oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (identical(oldWidget.controller._state, this)) {
        oldWidget.controller._state = null;
      }
      widget.controller._state = this;
    }
  }

  void _acknowledge() {
    if (!_needsLayout) return;
    _needsLayout = false;
    final clock = _clock;
    _clock = null;
    if (clock != null) {
      debugUiWorkSliceObserver?.call('row-window-element-mount', clock.elapsed);
    }
  }

  void _schedule() {
    if (_scheduled || !_active) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted || !_active) return;
      final render = context.findRenderObject();
      if (render is RenderBox && render.attached && render.hasSize) {
        _shellLaidOut = true;
      }
      if (!_admitted) {
        setState(() {});
      } else {
        if (render is RenderBox && render.attached && render.hasSize) {
          _acknowledge();
        }
      }
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _settled() async {
    while (mounted && _active && _isMounting) {
      WidgetsBinding.instance.ensureVisualUpdate();
      await WidgetsBinding.instance.endOfFrame;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_admitted &&
        _active &&
        (!widget.deferNewMounts ||
            ((_shellLaidOut || widget.admitOnFirstFrame) &&
                _RowMountBudget.take(expensive: widget.expensive)))) {
      _admitted = true;
      _needsLayout = true;
      if (debugUiWorkSliceObserver != null) _clock = Stopwatch()..start();
    }
    if (!_admitted || _needsLayout) _schedule();
    return TickerMode(
      enabled: _active,
      child: _admitted
          ? _RowExtentObserver(
              onHeight: (height) {
                _acknowledge();
                widget.onExtentMeasured?.call(height);
              },
              child: widget.builder(context),
            )
          : UtenRowMountPlaceholder(
              height: widget.estimatedExtent,
              remaining: 1,
            ),
    );
  }

  @override
  void dispose() {
    if (identical(widget.controller._state, this)) {
      widget.controller._state = null;
    }
    super.dispose();
  }
}

/// A content-height row window driven by the existing ancestor vertical
/// ScrollPosition. It creates no second vertical scrollable. Estimated spacers
/// are replaced by measured heights, keeping the visible row as the anchor.
///
/// Only viewport/overscan rows, the focused row and its keyboard neighbours,
/// and the last interacted row (a possible popup anchor) remain mounted.
class UtenAncestorRowWindow<T extends Object> extends StatefulWidget {
  const UtenAncestorRowWindow({
    super.key,
    required this.rows,
    required this.rowBuilder,
    required this.controller,
    this.onExtentChanged,
    this.threshold = minimumStagedRows,
    this.estimatedRowExtent = 52,
    this.viewportOnly = false,
    this.preserveRowAnchorOnSourceChange = true,
    this.expensiveRows = true,
    this.deferRowMounts = true,
  });

  /// Even a modest editable table can contain hundreds of input Elements.
  /// Admission is separate from whether its content needs a viewport window.
  static const int minimumStagedRows = 12;

  final List<T> rows;
  final Widget Function(BuildContext context, T row, int index) rowBuilder;
  final UtenAncestorRowWindowController<T> controller;
  final VoidCallback? onExtentChanged;
  final int threshold;
  final double estimatedRowExtent;

  /// Bounded table hosts can budget against their actual body viewport. The
  /// default keeps screen-height headroom for content-height editor hosts.
  final bool viewportOnly;
  final bool preserveRowAnchorOnSourceChange;

  /// Leave enabled for editable or unclassified custom rows. Disable only for
  /// lightweight read-only rows to admit small batches and warm more content.
  final bool expensiveRows;

  /// Continuous table browsing mounts only the visible virtualized rows, with
  /// no placeholder/admission sequence during a scroll. Standalone heavy forms
  /// retain their existing first-mount budget.
  final bool deferRowMounts;

  @override
  State<UtenAncestorRowWindow<T>> createState() =>
      _UtenAncestorRowWindowState<T>();
}

class _UtenAncestorRowWindowState<T extends Object>
    extends State<UtenAncestorRowWindow<T>> {
  final _rowKeys = HashMap<T, GlobalKey>.identity();
  final _heights = HashMap<T, double>.identity();
  final _children = HashMap<T, Widget>.identity();
  final _pendingHeights = HashMap<T, double>.identity();
  final _focused = HashSet<T>.identity();
  final _retained = HashSet<T>.identity();
  final _admitted = HashSet<T>.identity();
  final _awaitingFirstLayout = HashSet<T>.identity();
  final _indices = HashMap<T, int>.identity();
  final _offsets = RowExtentIndex(
    onWork: (operation, count) =>
        debugAncestorRowWindowWorkObserver?.call(operation, count),
  );
  List<T>? _indexedRows;
  bool _duplicateRows = false;
  int _measurementEpoch = 0;
  TextScaler? _lastTextScaler;
  TextTheme? _lastTextTheme;
  TextDirection? _lastDirection;
  List<T> _mountedRows = const [];
  T? _lastInteracted;
  T? _requested;
  ScrollableState? _scrollable;
  ScrollPosition? _position;
  double? _topInContent;
  double _viewportExtent = 0;
  double _screenExtent = 0;
  int _first = 0;
  int _last = -1;
  bool _measurementQueued = false;
  bool _geometryQueued = false;
  bool _rangeQueued = false;
  bool _retentionQueued = false;
  bool _mountScheduled = false;
  bool _shellLaidOut = false;
  int _pendingMountRows = 0;
  Stopwatch? _mountClock;
  double _pendingCorrection = 0;
  int _revealRevision = 0;
  bool _revealing = false;
  bool _presentationActive = true;

  double get _windowViewportExtent => widget.viewportOnly
      ? (_position?.hasViewportDimension == true
            ? _position!.viewportDimension
            : _viewportExtent)
      : math.max(_screenExtent, _viewportExtent);
  bool get _windowed =>
      widget.rows.length >= widget.threshold &&
      _position != null &&
      _offsets.last > _windowViewportExtent;
  bool get _stageNewRows =>
      widget.deferRowMounts &&
      widget.rows.length >= UtenAncestorRowWindow.minimumStagedRows;
  bool get _isMounting =>
      _presentationActive &&
      (_pendingMountRows > 0 ||
          _mountScheduled ||
          _awaitingFirstLayout.isNotEmpty);

  Future<void> _waitForCurrentWindow() async {
    while (mounted && _presentationActive) {
      WidgetsBinding.instance.ensureVisualUpdate();
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || !_presentationActive) return;
      if (!_isMounting &&
          !_measurementQueued &&
          !_geometryQueued &&
          _pendingCorrection.abs() <= .5) {
        return;
      }
    }
  }

  void _scheduleMount() {
    if (_mountScheduled || !_presentationActive) return;
    _mountScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _mountScheduled = false;
      if (!mounted || !_presentationActive) return;
      // Cold host/header layout and cold input Element mounting must not share
      // the initial frame. Only a real laid-out shell opens row admission.
      final shell = context.findRenderObject();
      if (shell is RenderBox && shell.attached && shell.hasSize) {
        _shellLaidOut = true;
      }
      // A keyed render subtree can be reused without performLayout running
      // again. At frame end, attached geometry is also a real mount receipt.
      for (final row in List<T>.of(_awaitingFirstLayout)) {
        final render = _rowKeys[row]?.currentContext?.findRenderObject();
        if (render is RenderBox && render.attached && render.hasSize) {
          _acknowledgeLayout(row);
        }
      }
      if (_pendingMountRows > 0) setState(() {});
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  // The caller provides a geometry estimate. Text scaling does not scale a
  // control's padding/minimum height linearly; multiplying the whole row can
  // overestimate unknown rows and expose spacer holes after a distant jump.
  double get _estimatedExtent => widget.estimatedRowExtent;

  @override
  void initState() {
    super.initState();
    widget.controller._state = this;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scaler = MediaQuery.textScalerOf(context);
    final textTheme = Theme.of(context).textTheme;
    final direction = Directionality.maybeOf(context);
    if ((_lastTextScaler != null && _lastTextScaler != scaler) ||
        (_lastTextTheme != null && _lastTextTheme != textTheme) ||
        (_lastDirection != null && _lastDirection != direction)) {
      _heights.clear();
    }
    _lastTextScaler = scaler;
    _lastTextTheme = textTheme;
    _lastDirection = direction;
    _retireMeasurements();
    _presentationActive =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.of(context)?.isCurrent ?? true);
    // The ancestor may grow within a split pane without rebuilding this child.
    // Budget for one screen even when its initial viewport is shorter, so that
    // growth cannot expose an unmounted blank region before the next scroll.
    _screenExtent = MediaQuery.sizeOf(context).height;
    final scrollable = Scrollable.maybeOf(context, axis: Axis.vertical);
    final next = scrollable?.position;
    if (!identical(next, _position)) {
      _position?.removeListener(_onScroll);
      _position = next;
      _scrollable = scrollable;
      _topInContent = null;
      next?.addListener(_onScroll);
    }
    // Sliver children are built during their ancestor viewport's layout. Use
    // that already known dimension before the first row subtree is mounted;
    // the post-frame geometry receipt must not start from an arbitrary 800px.
    _viewportExtent = next?.hasViewportDimension == true
        ? next!.viewportDimension
        : _screenExtent;
    _reindex();
    _setRange(notify: false);
    _scheduleGeometry();
  }

  @override
  void didUpdateWidget(covariant UtenAncestorRowWindow<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      if (identical(oldWidget.controller._state, this)) {
        oldWidget.controller._state = null;
      }
      widget.controller._state = this;
    }
    final anchor = widget.preserveRowAnchorOnSourceChange
        ? _anchor(rows: oldWidget.rows)
        : null;
    final oldAnchorIndex = anchor == null ? null : _indices[anchor];
    final oldAnchorOffset = oldAnchorIndex == null
        ? null
        : _offsets[oldAnchorIndex];
    _retireMeasurements(); // keyed elements still survive a source update.
    final sameEstimate =
        oldWidget.estimatedRowExtent == widget.estimatedRowExtent;
    if (!sameEstimate) _heights.clear();
    _reindex(allowIncremental: sameEstimate);
    if (anchor != null &&
        oldAnchorOffset != null &&
        _indices.containsKey(anchor)) {
      _pendingCorrection += _offsets[_indices[anchor]!] - oldAnchorOffset;
    }
    _setRange(notify: false);
    _scheduleGeometry();
  }

  void _retireMeasurements() {
    _measurementEpoch++;
    _pendingHeights.clear();
    _children.clear();
  }

  void _reindex({bool allowIncremental = false}) {
    final previous = _indexedRows;
    final prefix = allowIncremental && !_duplicateRows
        ? immutablePagedRowsCommonPrefix(previous, widget.rows)
        : null;
    if (previous != null &&
        prefix != null &&
        _offsets.rowCount == previous.length &&
        previous.length - prefix <= 8) {
      final removed = previous.getRange(prefix, previous.length);
      for (var index = prefix; index < previous.length; index++) {
        final row = previous[index];
        if (_indices[row] == index) _indices.remove(row);
      }
      var index = prefix;
      var duplicate = false;
      for (final row in widget.rows.getRange(prefix, widget.rows.length)) {
        if (_indices.containsKey(row)) {
          duplicate = true;
          break;
        }
        _indices[row] = index++;
      }
      if (!duplicate) {
        debugAncestorRowWindowWorkObserver?.call(
          'indexRows',
          widget.rows.length - prefix,
        );
        _offsets.replaceTail(
          common: prefix,
          count: widget.rows.length,
          deltas: widget.rows
              .getRange(prefix, widget.rows.length)
              .map(
                (row) => (_heights[row] ?? _estimatedExtent) - _estimatedExtent,
              ),
        );
        debugAncestorRowWindowWorkObserver?.call(
          'offsetRows',
          widget.rows.length - prefix,
        );
        for (final row in removed) {
          if (!_indices.containsKey(row)) _forgetRow(row);
        }
        _indexedRows = widget.rows;
        _clearMissingAnchors();
        return;
      }
      // Duplicate presentation objects retain the old last-index behavior.
      // Never partially accept an append whose identities are ambiguous.
    }
    _indices.clear();
    _duplicateRows = false;
    var index = 0;
    for (final row in widget.rows) {
      if (_indices.containsKey(row)) _duplicateRows = true;
      _indices[row] = index++;
    }
    debugAncestorRowWindowWorkObserver?.call('indexRows', widget.rows.length);
    debugAncestorRowWindowWorkObserver?.call(
      'fullReindexRows',
      widget.rows.length,
    );
    _heights.removeWhere((row, _) => !_indices.containsKey(row));
    _rowKeys.removeWhere((row, _) => !_indices.containsKey(row));
    _focused.removeWhere((row) => !_indices.containsKey(row));
    _retained.removeWhere((row) => !_indices.containsKey(row));
    _admitted.removeWhere((row) => !_indices.containsKey(row));
    _awaitingFirstLayout.removeWhere((row) => !_indices.containsKey(row));
    _clearMissingAnchors();
    _indexedRows = widget.rows;
    _rebuildOffsets();
  }

  void _clearMissingAnchors() {
    if (!_indices.containsKey(_lastInteracted)) _lastInteracted = null;
    if (!_indices.containsKey(_requested)) _requested = null;
  }

  void _forgetRow(T row) {
    _heights.remove(row);
    _rowKeys.remove(row);
    _children.remove(row);
    _pendingHeights.remove(row);
    _focused.remove(row);
    _retained.remove(row);
    _admitted.remove(row);
    _awaitingFirstLayout.remove(row);
  }

  void _rebuildOffsets() {
    final estimated = _estimatedExtent;
    _offsets.reset(
      count: widget.rows.length,
      estimate: estimated,
      deltas: widget.rows.map(
        (row) => (_heights[row] ?? estimated) - estimated,
      ),
    );
    debugAncestorRowWindowWorkObserver?.call('offsetRows', widget.rows.length);
  }

  int _rowAt(double offset) => _offsets.rowAt(offset);

  T? _anchor({List<T>? rows}) {
    // An explicit destination owns scrolling until its geometry is settled.
    // Preserving the old visible row while revealing another one fights that
    // destination when the new rows replace their estimated spacers.
    if (_revealing) return null;
    final source = rows ?? widget.rows;
    if (_position == null ||
        source.length < widget.threshold ||
        source.isEmpty ||
        _topInContent == null) {
      return null;
    }
    final local = (_position!.pixels + _pendingCorrection) - _topInContent!;
    if (local < 0 || local >= _offsets.last) return null;
    final index = _rowAt(local);
    return index < source.length ? source[index] : null;
  }

  void _setRange({bool notify = true}) {
    var first = 0;
    var last = widget.rows.length - 1;
    if (_windowed && widget.rows.isNotEmpty) {
      final top = _topInContent == null
          ? 0.0
          : _position!.pixels + _pendingCorrection - _topInContent!;
      final extent = _windowViewportExtent;
      // Keep scrolling headroom bounded in pixels: a whole extra screen of
      // editable controls makes a single frame too expensive on dense forms.
      final overscan = widget.expensiveRows
          ? math.min(64.0, extent * .1)
          : math.min(320.0, extent * .5);
      first = _rowAt(math.max(0, top - overscan));
      last = _rowAt(math.max(0, top + extent + overscan));
    }
    if (first == _first && last == _last) return;
    _first = first;
    _last = last;
    if (notify && mounted) setState(() {});
  }

  void _onScroll() {
    if (!mounted || !_presentationActive) return;
    _scheduleGeometry();
    // Layout can correct a scroll position while widgets are being built.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_rangeQueued) return;
      _rangeQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _rangeQueued = false;
        if (mounted && _presentationActive) _setRange();
      });
    } else {
      _setRange();
    }
  }

  void _scheduleGeometry() {
    if (_geometryQueued || !_presentationActive) return;
    _geometryQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryQueued = false;
      if (!mounted || !_presentationActive) return;
      final box = context.findRenderObject();
      final viewport = _scrollable?.context.findRenderObject();
      final position = _position;
      if (box is! RenderBox ||
          !box.hasSize ||
          viewport is! RenderBox ||
          !viewport.hasSize ||
          position == null ||
          !position.hasPixels) {
        return;
      }
      _topInContent =
          box.localToGlobal(Offset.zero, ancestor: viewport).dy +
          position.pixels;
      _viewportExtent = viewport.size.height;
      final correction = _pendingCorrection;
      _pendingCorrection = 0;
      if (correction.abs() > .5 && position.hasContentDimensions) {
        position.jumpTo(
          (position.pixels + correction).clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
      }
      _setRange();
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  void _acknowledgeLayout(T row) {
    if (_awaitingFirstLayout.remove(row) && _awaitingFirstLayout.isEmpty) {
      final clock = _mountClock;
      _mountClock = null;
      if (clock != null) {
        debugUiWorkSliceObserver?.call(
          'row-window-element-mount',
          clock.elapsed,
        );
      }
    }
  }

  void _measured(T row, double height) {
    _acknowledgeLayout(row);
    if (!height.isFinite ||
        height <= 0 ||
        !_indices.containsKey(row) ||
        ((_heights[row] ?? -1) - height).abs() < .5) {
      return;
    }
    if (!_presentationActive) {
      _heights[row] = height;
      return;
    }
    _pendingHeights[row] = height;
    if (_measurementQueued) return;
    _measurementQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _measurementQueued = false;
      if (!mounted) return;
      if (!_presentationActive) {
        _heights.addAll(_pendingHeights);
        _pendingHeights.clear();
        return;
      }
      final anchor = _anchor();
      final before = anchor == null ? null : _offsets[_indices[anchor]!];
      _pendingHeights.removeWhere((row, _) => !_indices.containsKey(row));
      if (_duplicateRows) {
        _heights.addAll(_pendingHeights);
        _rebuildOffsets();
      } else {
        for (final entry in _pendingHeights.entries) {
          final index = _indices[entry.key];
          if (index != null) _offsets.setHeight(index, entry.value);
          _heights[entry.key] = entry.value;
        }
      }
      _pendingHeights.clear();
      if (anchor != null && before != null && _indices.containsKey(anchor)) {
        _pendingCorrection += _offsets[_indices[anchor]!] - before;
      }
      setState(() => _setRange(notify: false));
      _scheduleGeometry();
      widget.onExtentChanged?.call();
    });
  }

  ValueChanged<double> _heightObserver(T row) {
    final epoch = _measurementEpoch;
    return (height) {
      if (epoch == _measurementEpoch) _measured(row, height);
    };
  }

  void _focusChanged(T row, bool focused) {
    if (!mounted || !_indices.containsKey(row)) return;
    if (!_presentationActive) {
      focused ? _focused.add(row) : _focused.remove(row);
      return;
    }
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focusChanged(row, focused),
      );
      return;
    }
    setState(() {
      if (focused) {
        _focused.add(row);
        _lastInteracted = row;
      } else {
        _focused.remove(row);
      }
    });
  }

  void _retain(T row, bool retain) {
    if (!mounted || !_indices.containsKey(row)) return;
    final changed = retain ? _retained.add(row) : _retained.remove(row);
    if (!changed) return;
    if (!_presentationActive) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_retentionQueued) return;
      _retentionQueued = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _retentionQueued = false;
        if (mounted && _presentationActive) setState(() {});
      });
    } else {
      setState(() {});
    }
  }

  Future<bool> _reveal(
    T row,
    double alignment,
    bool Function()? isCurrent,
    int maxGeometryCorrections,
  ) async {
    if (!mounted ||
        !_presentationActive ||
        !_indices.containsKey(row) ||
        isCurrent?.call() == false) {
      return false;
    }
    final revision = ++_revealRevision;
    bool current() =>
        mounted &&
        _presentationActive &&
        revision == _revealRevision &&
        _indices.containsKey(row) &&
        isCurrent?.call() != false;
    setState(() {
      _pendingCorrection = 0;
      _revealing = true;
      _requested = row;
    });
    try {
      var releasedRequest = false;
      final position = _position;
      if (position != null &&
          position.hasContentDimensions &&
          _topInContent != null) {
        final target =
            _topInContent! +
            _offsets[_indices[row]!] -
            _viewportExtent * alignment;
        position.jumpTo(
          target.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      }
      // Mounting a distant variable-height row changes both the spacers and
      // the ancestor's maxScrollExtent. A two-frame jump can still be clamped
      // to the previous extent near the end. Re-read actual geometry after a
      // bounded number of geometry corrections. Real row admission may take
      // more frames than that under the shared mount budget; waiting for it
      // must not consume those corrections or abandon a valid reveal.
      for (var corrections = 0; corrections < maxGeometryCorrections;) {
        WidgetsBinding.instance.ensureVisualUpdate();
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || !current()) return false;
        if (!_isMounting) corrections++;
        final render = _rowKeys[row]?.currentContext?.findRenderObject();
        if (render is! RenderBox || !render.attached || !render.hasSize) {
          continue;
        }
        final activePosition = _position;
        if (activePosition == null) {
          _lastInteracted = row;
          return true;
        }
        final viewport = _scrollable?.context.findRenderObject();
        if (viewport is! RenderBox ||
            !viewport.hasSize ||
            !activePosition.hasContentDimensions) {
          continue;
        }
        final extent = activePosition.hasViewportDimension
            ? activePosition.viewportDimension
            : viewport.size.height;
        if (extent <= 0) continue;
        // The nearest RenderViewport is horizontal in an editor. Resolve Y
        // against the explicitly selected vertical ancestor instead.
        final top = render.localToGlobal(Offset.zero, ancestor: viewport).dy;
        final tall = render.size.height > extent;
        final desiredTop = tall
            ? extent * alignment.clamp(0.0, .5)
            : math.min(
                extent * alignment.clamp(0.0, 1.0),
                extent - render.size.height,
              );
        final target = (activePosition.pixels + top - desiredTop).clamp(
          activePosition.minScrollExtent,
          activePosition.maxScrollExtent,
        );
        final visible =
            top >= -.5 &&
            (tall
                ? top < extent - .5
                : top + render.size.height <= extent + .5);
        final settled =
            !_isMounting &&
            !_measurementQueued &&
            !_geometryQueued &&
            _pendingCorrection.abs() <= .5;
        if ((target - activePosition.pixels).abs() <= .5 &&
            visible &&
            settled) {
          _lastInteracted = row;
          if (releasedRequest) return true;
          // Removing the temporary neighbour retention may itself change the
          // range/measurements. Verify once more after that final layout, not
          // only while the temporary request is still holding the window open.
          setState(() => _requested = null);
          releasedRequest = true;
          continue;
        }
        if ((target - activePosition.pixels).abs() > .5) {
          activePosition.jumpTo(target);
        }
      }
      return false;
    } finally {
      if (mounted && revision == _revealRevision) {
        void clearRequest() {
          _revealing = false;
          _requested = null;
        }

        if (_presentationActive) {
          setState(clearRequest);
        } else {
          clearRequest();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final indices = <int>{for (var i = _first; i <= _last; i++) i};
    void keep(T? row, {bool neighbours = false}) {
      final index = _indices[row];
      if (index == null) return;
      indices.add(index);
      if (neighbours) {
        if (index > 0) indices.add(index - 1);
        if (index + 1 < widget.rows.length) indices.add(index + 1);
      }
    }

    for (final row in _focused) {
      keep(row, neighbours: true);
    }
    for (final row in _retained) {
      keep(row);
    }
    keep(_lastInteracted);
    keep(_requested, neighbours: true);
    final ordered = indices.toList()..sort();
    final wantedRows = [for (final i in ordered) widget.rows[i]];
    final membership = HashSet<T>.identity()..addAll(wantedRows);
    _children.removeWhere((row, _) => !membership.contains(row));
    _admitted.removeWhere((row) => !membership.contains(row));
    _awaitingFirstLayout.removeWhere((row) => !membership.contains(row));
    if (_awaitingFirstLayout.isEmpty) _mountClock = null;
    final priorities = <T>[];
    void prioritize(T? row) {
      if (row != null && membership.contains(row) && !_admitted.contains(row)) {
        priorities.add(row);
      }
    }

    prioritize(_requested);
    for (final row in _focused) {
      final index = _indices[row]!;
      if (index + 1 < widget.rows.length) prioritize(widget.rows[index + 1]);
      if (index > 0) prioritize(widget.rows[index - 1]);
    }
    priorities.addAll(wantedRows);
    for (final row in priorities) {
      if (_admitted.contains(row)) continue;
      if (!_presentationActive) break;
      if (_stageNewRows &&
          (!_shellLaidOut ||
              !_RowMountBudget.take(expensive: widget.expensiveRows))) {
        break;
      }
      _admitted.add(row);
      _awaitingFirstLayout.add(row);
      if (debugUiWorkSliceObserver != null) {
        _mountClock ??= Stopwatch()..start();
      }
    }
    _mountedRows = [
      for (final row in wantedRows)
        if (_admitted.contains(row)) row,
    ];
    _pendingMountRows = wantedRows.length - _mountedRows.length;
    if (_pendingMountRows > 0 || _awaitingFirstLayout.isNotEmpty) {
      _scheduleMount();
    }
    final children = <Widget>[];
    var previous = 0;
    var announcedPending = false;
    for (final index in ordered) {
      if (index > previous) {
        children.add(SizedBox(height: _offsets[index] - _offsets[previous]));
      }
      final row = widget.rows[index];
      if (!_admitted.contains(row)) {
        final announce = !announcedPending;
        announcedPending = true;
        children.add(
          UtenRowMountPlaceholder(
            key: ValueKey(('pending-row-mount', index)),
            height: _heights[row] ?? _estimatedExtent,
            remaining: announce ? _pendingMountRows : null,
          ),
        );
        previous = index + 1;
        continue;
      }
      final key = _rowKeys.putIfAbsent(row, GlobalKey.new);
      children.add(
        KeyedSubtree(
          key: key,
          child: _children.putIfAbsent(
            row,
            () => _RowExtentObserver(
              onHeight: _heightObserver(row),
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onFocusChange: (focused) => _focusChanged(row, focused),
                child: Listener(
                  behavior: HitTestBehavior.translucent,
                  onPointerDown: (_) {
                    if (!identical(_lastInteracted, row)) {
                      setState(() => _lastInteracted = row);
                    }
                  },
                  child: widget.rowBuilder(context, row, index),
                ),
              ),
            ),
          ),
        ),
      );
      previous = index + 1;
    }
    if (previous < widget.rows.length) {
      children.add(SizedBox(height: _offsets.last - _offsets[previous]));
    }
    return TickerMode(
      enabled: _presentationActive,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  @override
  void dispose() {
    ++_revealRevision;
    _retained.clear();
    _admitted.clear();
    _awaitingFirstLayout.clear();
    _position?.removeListener(_onScroll);
    if (identical(widget.controller._state, this)) {
      widget.controller._state = null;
    }
    super.dispose();
  }
}

/// Explicit loading surface, not an empty or interactive imitation of a row.
/// No business text, field or selection registration exists until admission.
class UtenRowMountPlaceholder extends StatelessWidget {
  const UtenRowMountPlaceholder({
    super.key,
    required this.height,
    this.remaining,
  });
  final double height;
  final int? remaining;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: SelectionContainer.disabled(
      child: Semantics(
        container: true,
        liveRegion: remaining != null,
        label: remaining == null ? null : '正在显示表格行，还剩 $remaining 行',
        child: SizedBox(
          height: height,
          child: ColoredBox(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: remaining == null
                ? null
                : Align(
                    alignment: Alignment.topCenter,
                    child: LinearProgressIndicator(
                      value: MediaQuery.disableAnimationsOf(context) ? 0 : null,
                      minHeight: 2,
                      semanticsLabel: '正在显示表格行',
                    ),
                  ),
          ),
        ),
      ),
    ),
  );
}

class _RowExtentObserver extends SingleChildRenderObjectWidget {
  const _RowExtentObserver({required this.onHeight, required super.child});
  final ValueChanged<double> onHeight;
  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RowExtentRender(onHeight);
  @override
  void updateRenderObject(
    BuildContext context,
    _RowExtentRender renderObject,
  ) => renderObject.onHeight = onHeight;
}

class _RowExtentRender extends RenderProxyBox {
  _RowExtentRender(this.onHeight);
  ValueChanged<double> onHeight;
  @override
  void performLayout() {
    super.performLayout();
    // Admission also needs an acknowledgement for retained/reparented render
    // objects whose height did not change. The owner deduplicates measurements.
    onHeight(size.height);
  }
}
