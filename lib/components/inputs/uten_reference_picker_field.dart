import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/uten_tokens.dart';
import '../../core/ui/app_notification.dart';
import 'uten_input_decoration.dart';

/// A reference lookup keeps typed discovery separate from committing a record.
/// The caller owns both the controller and the actual record identity. Only a
/// chosen candidate or the full picker should change that identity.
class UtenReferencePickerField<T> extends StatefulWidget {
  const UtenReferencePickerField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    required this.loadSuggestions,
    required this.labelOf,
    required this.onSelected,
    required this.onInputChanged,
    required this.onOpenPicker,
    this.optionBuilder,
    this.onClear,
    this.onEditingDismissed,
    this.pickerLabel = '选择',
    this.enabled = true,
    this.debounce = const Duration(milliseconds: 300),
    this.maxSuggestions = 8,
    this.suggestionScope,
    this.isCurrent,
  }) : assert(maxSuggestions > 0);

  final TextEditingController controller;
  final String label;
  final String hint;
  final Future<List<T>> Function(String keyword) loadSuggestions;
  final String Function(T item) labelOf;
  final ValueChanged<T> onSelected;
  final ValueChanged<String> onInputChanged;
  final Future<void> Function(String keyword) onOpenPicker;
  final Widget Function(BuildContext context, T item)? optionBuilder;
  final VoidCallback? onClear;
  final VoidCallback? onEditingDismissed;
  final String pickerLabel;
  final bool enabled;
  final Duration debounce;
  final int maxSuggestions;

  /// The owner includes identity, endpoint and business scope in this token.
  /// It does not grant access. A live guard also fences taps before rebuilding.
  final Object? suggestionScope;
  final bool Function()? isCurrent;

  @override
  State<UtenReferencePickerField<T>> createState() =>
      _UtenReferencePickerFieldState<T>();
}

class _UtenReferencePickerFieldState<T>
    extends State<UtenReferencePickerField<T>> {
  final _link = LayerLink();
  final _fieldKey = GlobalKey();
  final _focus = FocusNode();
  final _tapGroup = Object();
  Timer? _timer;
  OverlayEntry? _overlay;
  List<T> _options = [];
  late TextEditingValue _lastValue;
  int _version = 0;
  int _acceptedVersion = -1;
  int _highlighted = -1;
  bool _loading = false;
  bool _failed = false;
  bool _edited = false;
  bool _selecting = false;
  bool _pickerOpen = false;
  Object? _acceptedScope;

  bool get _allowed => widget.enabled && (widget.isCurrent?.call() ?? true);

  bool _composing(TextEditingValue value) =>
      value.composing.isValid && !value.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    _lastValue = widget.controller.value;
    widget.controller.addListener(_textChanged);
    _focus.addListener(_focusChanged);
  }

  @override
  void didUpdateWidget(covariant UtenReferencePickerField<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_textChanged);
      _lastValue = widget.controller.value;
      widget.controller.addListener(_textChanged);
      _cancel();
    }
    if (!widget.enabled ||
        oldWidget.suggestionScope != widget.suggestionScope) {
      _cancel();
    }
  }

  void _cancel() {
    _version++;
    _timer?.cancel();
    _options = [];
    _loading = false;
    _failed = false;
    _highlighted = -1;
    _closeOverlay();
  }

  void _textChanged() {
    final value = widget.controller.value;
    final textChanged = value.text != _lastValue.text;
    final compositionEnded = _composing(_lastValue) && !_composing(value);
    final composing = _composing(value);
    _lastValue = value;
    if (_selecting || _pickerOpen || !_allowed) return;
    if (!textChanged && !compositionEnded) return;
    _cancel();
    if (textChanged) {
      _edited = true;
      widget.onInputChanged(value.text);
    }
    if (mounted) setState(() {});
    if (!composing) _schedule();
  }

  void _focusChanged() {
    if (_focus.hasFocus) {
      if (_edited) _schedule();
    } else {
      _cancel();
      if (!_pickerOpen && !_selecting) _finishEditing();
    }
  }

  void _finishEditing() {
    _selecting = true;
    widget.onEditingDismissed?.call();
    _lastValue = widget.controller.value;
    _edited = false;
    _selecting = false;
  }

  void _schedule() {
    if (!_focus.hasFocus || !_allowed || _pickerOpen) return;
    final value = widget.controller.value;
    final query = value.text.trim();
    if (query.isEmpty || _composing(value)) return;
    _timer?.cancel();
    final version = ++_version;
    _timer = Timer(widget.debounce, () => _load(query, version));
  }

  Future<void> _load(String query, int version) async {
    if (!mounted || version != _version || !_focus.hasFocus || !_allowed) {
      return;
    }
    final scope = widget.suggestionScope;
    setState(() => _loading = true);
    _showOverlay();
    try {
      final options = await widget.loadSuggestions(query);
      if (!mounted ||
          version != _version ||
          !_focus.hasFocus ||
          !_allowed ||
          scope != widget.suggestionScope) {
        return;
      }
      setState(() {
        _options = options.take(widget.maxSuggestions).toList();
        _acceptedVersion = version;
        _acceptedScope = scope;
        _loading = false;
      });
    } catch (_) {
      if (!mounted ||
          version != _version ||
          !_focus.hasFocus ||
          !_allowed ||
          scope != widget.suggestionScope) {
        return;
      }
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
    _showOverlay();
  }

  void _choose(T item, int version) {
    if (!mounted ||
        !_allowed ||
        _loading ||
        version != _version ||
        _acceptedVersion != version ||
        _acceptedScope != widget.suggestionScope ||
        _composing(widget.controller.value)) {
      return;
    }
    _selecting = true;
    _cancel();
    final label = widget.labelOf(item);
    widget.controller.value = TextEditingValue(
      text: label,
      selection: TextSelection.collapsed(offset: label.length),
    );
    widget.onSelected(item);
    _edited = false;
    _focus.unfocus();
    _selecting = false;
    if (mounted) setState(() {});
  }

  Future<void> _openPicker() async {
    if (!mounted ||
        !_allowed ||
        _pickerOpen ||
        _composing(widget.controller.value)) {
      return;
    }
    final query = widget.controller.text.trim();
    _pickerOpen = true;
    _cancel();
    _focus.unfocus();
    if (mounted) setState(() {});
    try {
      await widget.onOpenPicker(query);
    } catch (_) {
      if (mounted) context.appError('打开选择窗口失败，请重试');
    } finally {
      if (mounted) {
        _pickerOpen = false;
        _edited = false;
        _finishEditing();
        setState(() {});
      }
    }
  }

  void _submit() {
    if (_highlighted >= 0 && _highlighted < _options.length) {
      _choose(_options[_highlighted], _acceptedVersion);
    } else {
      unawaited(_openPicker());
    }
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent || _composing(widget.controller.value)) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape && _overlay != null) {
      _cancel();
      return KeyEventResult.handled;
    }
    if (_options.isNotEmpty &&
        !_loading &&
        (event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowUp)) {
      final delta = event.logicalKey == LogicalKeyboardKey.arrowDown ? 1 : -1;
      _highlighted = (_highlighted + delta) % _options.length;
      _overlay?.markNeedsBuild();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _submit();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _showOverlay() {
    if (!mounted || !_focus.hasFocus || !_allowed) return;
    if (_overlay == null) {
      _overlay = OverlayEntry(builder: _buildOverlay);
      Overlay.of(context, rootOverlay: true).insert(_overlay!);
    } else {
      _overlay!.markNeedsBuild();
    }
  }

  void _closeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }

  Widget _buildOverlay(BuildContext overlayContext) {
    final box = _fieldKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return const SizedBox.shrink();
    final media = MediaQuery.of(overlayContext);
    final position = box.localToGlobal(Offset.zero);
    final width = math.min(
      box.size.width,
      math.max(160.0, media.size.width - 16),
    );
    final left = position.dx.clamp(
      8.0,
      math.max(8.0, media.size.width - width - 8),
    );
    final below =
        media.size.height -
        media.viewInsets.bottom -
        position.dy -
        box.size.height -
        8;
    final above = position.dy - 8;
    final openAbove = below < 160 && above > below;
    final height = math.min(360.0, math.max(96.0, openAbove ? above : below));
    final version = _acceptedVersion;
    final theme = Theme.of(overlayContext);
    return Positioned(
      left: 0,
      top: 0,
      width: width,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: openAbove ? Alignment.topLeft : Alignment.bottomLeft,
        followerAnchor: openAbove ? Alignment.bottomLeft : Alignment.topLeft,
        offset: Offset(left - position.dx, openAbove ? -4 : 4),
        child: Align(
          alignment: Alignment.topLeft,
          widthFactor: 1,
          heightFactor: 1,
          child: TapRegion(
            groupId: _tapGroup,
            child: Material(
              elevation: 6,
              color: theme.colorScheme.surfaceContainerHigh,
              borderRadius: UtenRadius.mdAll,
              clipBehavior: Clip.antiAlias,
              child: SizedBox(
                width: width,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: height),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: _loading || _options.isEmpty
                            ? SingleChildScrollView(
                                child: Padding(
                                  padding: const EdgeInsets.all(
                                    UtenSpacing.s12,
                                  ),
                                  child: Text(
                                    _loading
                                        ? '正在查找…'
                                        : _failed
                                        ? '近似候选加载失败，可点击选择继续查找'
                                        : '没有近似候选，可点击选择继续查找',
                                  ),
                                ),
                              )
                            : ListView.builder(
                                shrinkWrap: true,
                                padding: EdgeInsets.zero,
                                itemCount: _options.length,
                                itemBuilder: (context, index) {
                                  final option = _options[index];
                                  return Semantics(
                                    selected: index == _highlighted,
                                    button: true,
                                    child: InkWell(
                                      onTap: () => _choose(option, version),
                                      child: ColoredBox(
                                        color: index == _highlighted
                                            ? theme.colorScheme.primaryContainer
                                            : Colors.transparent,
                                        child:
                                            widget.optionBuilder?.call(
                                              context,
                                              _options[index],
                                            ) ??
                                            Padding(
                                              padding: const EdgeInsets.all(
                                                UtenSpacing.s12,
                                              ),
                                              child: Text(
                                                widget.labelOf(_options[index]),
                                              ),
                                            ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                      const Divider(height: 1),
                      TextButton(
                        onPressed: () => unawaited(_openPicker()),
                        child: const Text('展开分类和筛选'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: _tapGroup,
    onTapOutside: (_) => _focus.unfocus(),
    child: CompositedTransformTarget(
      key: _fieldKey,
      link: _link,
      child: Focus(
        onKeyEvent: _key,
        child: TextField(
          controller: widget.controller,
          focusNode: _focus,
          enabled: _allowed && !_pickerOpen,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _submit(),
          onTapOutside: (_) {},
          decoration: UtenInputDecoration(
            InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
              suffixIcon: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (widget.controller.text.isNotEmpty)
                    IconButton(
                      tooltip: '清除${widget.label}',
                      onPressed: _allowed && !_pickerOpen
                          ? () {
                              if (!mounted || !_allowed) return;
                              _selecting = true;
                              _cancel();
                              widget.controller.clear();
                              if (widget.onClear != null) {
                                widget.onClear!();
                              } else {
                                widget.onInputChanged('');
                              }
                              _edited = false;
                              _selecting = false;
                              setState(() {});
                            }
                          : null,
                      icon: const Icon(Icons.close_rounded, size: 18),
                    ),
                  TextButton(
                    onPressed: _allowed && !_pickerOpen
                        ? () => unawaited(_openPicker())
                        : null,
                    child: Text(widget.pickerLabel),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  @override
  void dispose() {
    widget.controller.removeListener(_textChanged);
    _timer?.cancel();
    _closeOverlay();
    _focus.removeListener(_focusChanged);
    _focus.dispose();
    super.dispose();
  }
}
