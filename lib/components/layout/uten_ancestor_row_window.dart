import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../core/performance/ui_work_budget.dart';

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
  Future<bool> reveal(
    T row, {
    double alignment = .15,
    bool Function()? isCurrent,
  }) async => await _state?._reveal(row, alignment, isCurrent) ?? false;
}

/// Limits real new row subtrees across all windows in a frame. Constructing a
/// row Widget is cheap; the expensive Element/input/theme mount happens later
/// in that frame, so a construction-time stopwatch cannot bound that work.
abstract final class _RowMountBudget {
  static bool _resetScheduled = false;
  static int _used = 0;

  static bool take() {
    if (!_resetScheduled) {
      _resetScheduled = true;
      // Reset in the next frame's transient phase, before any widget builds.
      // Distinct frames may share a timestamp (notably WidgetTester.pump()).
      SchedulerBinding.instance.scheduleFrameCallback((_) {
        _used = 0;
        _resetScheduled = false;
      });
    }
    // A light row cannot predict the next row's input/layout cost. Admit one
    // actual business subtree globally per frame, without restoring a larger
    // allowance after a cheap frame. Existing rows do not consume admission.
    if (_used >= 1) return false;
    _used++;
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
    this.onExtentMeasured,
  });
  final UtenDeferredRowMountController controller;
  final WidgetBuilder builder;
  final double estimatedExtent;
  final bool deferNewMounts;
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
        (!widget.deferNewMounts || (_shellLaidOut && _RowMountBudget.take()))) {
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
  List<double> _offsets = const [0];
  List<T> _mountedRows = const [];
  T? _lastInteracted;
  T? _requested;
  ScrollableState? _scrollable;
  ScrollPosition? _position;
  double? _topInContent;
  double _viewportExtent = 800;
  double _screenExtent = 800;
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
    final oldAnchorOffset = anchor == null ? null : _offsets[_indices[anchor]!];
    _children.clear(); // layout/columns changed; keyed elements still survive.
    _reindex();
    if (anchor != null &&
        oldAnchorOffset != null &&
        _indices.containsKey(anchor)) {
      _pendingCorrection += _offsets[_indices[anchor]!] - oldAnchorOffset;
    }
    _setRange(notify: false);
    _scheduleGeometry();
  }

  void _reindex() {
    _indices.clear();
    for (var i = 0; i < widget.rows.length; i++) {
      _indices[widget.rows[i]] = i;
    }
    _heights.removeWhere((row, _) => !_indices.containsKey(row));
    _rowKeys.removeWhere((row, _) => !_indices.containsKey(row));
    _focused.removeWhere((row) => !_indices.containsKey(row));
    _retained.removeWhere((row) => !_indices.containsKey(row));
    _admitted.removeWhere((row) => !_indices.containsKey(row));
    _awaitingFirstLayout.removeWhere((row) => !_indices.containsKey(row));
    if (!_indices.containsKey(_lastInteracted)) _lastInteracted = null;
    if (!_indices.containsKey(_requested)) _requested = null;
    _rebuildOffsets();
  }

  void _rebuildOffsets() {
    final estimated = _estimatedExtent;
    final offsets = List<double>.filled(widget.rows.length + 1, 0);
    for (var i = 0; i < widget.rows.length; i++) {
      offsets[i + 1] = offsets[i] + (_heights[widget.rows[i]] ?? estimated);
    }
    _offsets = offsets;
  }

  int _rowAt(double offset) {
    var low = 0;
    final count = _offsets.length - 1;
    var high = count;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_offsets[middle + 1] <= offset) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low.clamp(0, math.max(0, count - 1));
  }

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
    return source[_rowAt(local)];
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
      final overscan = math.min(64.0, extent * .1);
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
      _heights.addAll(_pendingHeights);
      _pendingHeights.clear();
      _rebuildOffsets();
      if (anchor != null && before != null && _indices.containsKey(anchor)) {
        _pendingCorrection += _offsets[_indices[anchor]!] - before;
      }
      setState(() => _setRange(notify: false));
      _scheduleGeometry();
      widget.onExtentChanged?.call();
    });
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
      for (var corrections = 0; corrections < 16;) {
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
      if (_stageNewRows && (!_shellLaidOut || !_RowMountBudget.take())) {
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
              onHeight: (height) => _measured(row, height),
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
