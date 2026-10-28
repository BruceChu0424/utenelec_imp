import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/uten_tokens.dart';
import '../inputs/uten_field_message.dart';
import '../inputs/uten_input_decoration.dart';

/// Compact page navigation shared by tables, grids and picker footers.
///
/// [totalPages] is null when a cursor protocol does not provide a total. In
/// that case [maxPage] limits jumps to the known cursor horizon without
/// presenting that horizon as an exact total.
class UtenPagination extends StatefulWidget {
  const UtenPagination({
    super.key,
    required this.currentPage,
    required this.totalPages,
    this.onPageChanged,
    this.onPrevious,
    this.onNext,
    this.busy = false,
    this.maxPage,
    this.previousKey = const ValueKey('master-table-page-previous'),
    this.nextKey = const ValueKey('master-table-page-next'),
    this.inputOutlineKey,
    this.controller,
    this.focusNode,
  });

  final int currentPage;
  final int? totalPages;
  final ValueChanged<int>? onPageChanged;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final bool busy;
  final int? maxPage;
  final Key? previousKey;
  final Key? nextKey;
  final Key? inputOutlineKey;

  /// Optional page-owned state, used when a table spans a fullscreen route.
  final TextEditingController? controller;
  final FocusNode? focusNode;

  @override
  State<UtenPagination> createState() => _UtenPaginationState();
}

class _UtenPaginationState extends State<UtenPagination> {
  late final _ownedText = TextEditingController(text: '${widget.currentPage}');
  final _ownedFocus = FocusNode();
  TextEditingController get _text => widget.controller ?? _ownedText;
  FocusNode get _focus => widget.focusNode ?? _ownedFocus;
  bool _keepSubmittedOnBlur = false;

  int? get _lastPage => switch (widget.totalPages ?? widget.maxPage) {
    final int pages => math.max(1, pages),
    null => null,
  };

  @override
  void initState() {
    super.initState();
    _focus.addListener(_focusChanged);
  }

  void _focusChanged() {
    if (_focus.hasFocus) {
      _keepSubmittedOnBlur = false;
    } else if (_keepSubmittedOnBlur) {
      _keepSubmittedOnBlur = false;
    } else {
      _syncText();
    }
  }

  void _syncText() {
    final current = '${widget.currentPage}';
    if (_text.text != current) _text.text = current;
  }

  @override
  void didUpdateWidget(covariant UtenPagination oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedFocus).removeListener(_focusChanged);
      _focus.addListener(_focusChanged);
    }
    if (!_focus.hasFocus &&
        (oldWidget.currentPage != widget.currentPage ||
            oldWidget.busy != widget.busy ||
            oldWidget.totalPages != widget.totalPages ||
            oldWidget.maxPage != widget.maxPage)) {
      _syncText();
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_focusChanged);
    _ownedFocus.dispose();
    _ownedText.dispose();
    super.dispose();
  }

  void _submit(String value) {
    if (widget.busy || widget.onPageChanged == null) return;
    final parsed = int.tryParse(value.trim()) ?? widget.currentPage;
    final last = _lastPage;
    final target = last == null ? math.max(1, parsed) : parsed.clamp(1, last);
    _keepSubmittedOnBlur = true;
    _text.text = '$target';
    _focus.unfocus();
    if (target != widget.currentPage) widget.onPageChanged!(target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final touch = UtenControlMetrics.usesTouchTargets(context);
    final hitExtent = UtenControlMetrics.minimumHitExtent(context, desktop: 32);
    final textScaler = MediaQuery.textScalerOf(context);
    final pageStyle = theme.textTheme.bodyMedium?.copyWith(
      fontSize: 15,
      fontWeight: FontWeight.w600,
    );
    final inputHeight = math.max(
      touch ? hitExtent : 28.0,
      textScaler.scale(15) * 1.2 + 6,
    );
    final baseInputWidth = touch ? math.max(48.0, hitExtent) : 40.0;
    final totalText = '/ ${widget.totalPages ?? '?'}';
    final counterText = '${widget.currentPage} $totalText';
    final last = _lastPage;
    final canPrevious = !widget.busy && widget.currentPage > 1;
    final canNext = !widget.busy && (last == null || widget.currentPage < last);

    double widthOf(String text) {
      final painter = TextPainter(
        text: TextSpan(text: text, style: pageStyle),
        textScaler: textScaler,
        textDirection: Directionality.of(context),
      )..layout();
      final width = painter.width;
      painter.dispose();
      return width;
    }

    Widget chevron(bool forward) => IconButton(
      key: forward ? widget.nextKey : widget.previousKey,
      constraints: BoxConstraints.tightFor(width: hitExtent, height: hitExtent),
      padding: EdgeInsets.zero,
      style: IconButton.styleFrom(
        minimumSize: Size.square(hitExtent),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      tooltip: forward ? '下一页' : '上一页',
      onPressed: (forward ? canNext : canPrevious)
          ? (forward ? widget.onNext : widget.onPrevious) ??
                (widget.onPageChanged == null
                    ? null
                    : () => widget.onPageChanged!(
                        widget.currentPage + (forward ? 1 : -1),
                      ))
          : null,
      icon: Icon(
        forward ? Icons.chevron_right_rounded : Icons.chevron_left_rounded,
        size: 24,
      ),
    );

    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _text,
      builder: (context, value, _) {
        final inputWidth = math.min(
          math.max(baseInputWidth, widthOf(value.text) + 16),
          baseInputWidth + 64,
        );
        Widget pageField() => SizedBox(
          key: widget.inputOutlineKey,
          width: inputWidth,
          height: inputHeight,
          child: ListenableBuilder(
            listenable: _focus,
            builder: (context, _) => DecoratedBox(
              decoration: BoxDecoration(
                color: widget.busy
                    ? theme.colorScheme.surfaceContainerHigh
                    : theme.colorScheme.surface,
                borderRadius: UtenRadius.controlAll,
                border: Border.all(
                  color: _focus.hasFocus
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outline,
                  width: _focus.hasFocus ? 2 : 1,
                ),
              ),
              child: Center(
                child: TextFormField(
                  errorBuilder: utenTextFieldErrorBuilder,
                  controller: _text,
                  focusNode: _focus,
                  enabled: !widget.busy && widget.onPageChanged != null,
                  keyboardType: TextInputType.number,
                  textInputAction: TextInputAction.done,
                  textAlign: TextAlign.center,
                  textAlignVertical: TextAlignVertical.center,
                  style: pageStyle,
                  decoration: const UtenInputDecoration(
                    InputDecoration(
                      isCollapsed: true,
                      constraints: BoxConstraints(),
                      filled: false,
                      visualDensity: VisualDensity.standard,
                      hintText: '页码',
                      contentPadding: EdgeInsets.symmetric(horizontal: 4),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      disabledBorder: InputBorder.none,
                    ),
                  ),
                  onFieldSubmitted: _submit,
                ),
              ),
            ),
          ),
        );

        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            if (!width.isFinite ||
                width >=
                    2 * hitExtent +
                        inputWidth +
                        widthOf(totalText) +
                        3 * UtenSpacing.s4) {
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  chevron(false),
                  const SizedBox(width: UtenSpacing.s4),
                  pageField(),
                  const SizedBox(width: UtenSpacing.s4),
                  Text(
                    totalText,
                    style: pageStyle?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s4),
                  chevron(true),
                ],
              );
            }
            if (width >=
                2 * hitExtent + 2 * UtenSpacing.s8 + widthOf(counterText)) {
              return Row(
                children: [
                  chevron(false),
                  Expanded(
                    child: Text(
                      counterText,
                      textAlign: TextAlign.center,
                      style: pageStyle,
                    ),
                  ),
                  chevron(true),
                ],
              );
            }
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  counterText,
                  textAlign: TextAlign.center,
                  style: pageStyle,
                ),
                const SizedBox(height: UtenSpacing.s4),
                if (width >= 2 * hitExtent + UtenSpacing.s8)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [chevron(false), chevron(true)],
                  )
                else
                  Column(
                    children: [
                      chevron(false),
                      const SizedBox(height: UtenSpacing.s4),
                      chevron(true),
                    ],
                  ),
              ],
            );
          },
        );
      },
    );
  }
}
