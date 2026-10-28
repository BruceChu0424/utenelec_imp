import 'package:flutter/material.dart';

import '../../core/theme/uten_anim.dart';
import '../feedback/uten_motion.dart';

/// A clipped reveal that keeps the outgoing content visible until closing ends.
/// Hidden content cannot receive focus, pointer events or accessibility visits.
/// Use [maintainState] for editors; large read-only catalogs can unmount when shut.
class UtenCollapsibleContent extends StatelessWidget {
  const UtenCollapsibleContent({
    super.key,
    required this.expanded,
    required this.child,
    this.maintainState = true,
  });

  final bool expanded;
  final bool maintainState;
  final Widget child;

  @override
  Widget build(BuildContext context) => UtenMotion(
    duration: UtenAnim.normal,
    builder: (context, duration) => _Reveal(
      expanded: expanded,
      maintainState: maintainState,
      duration: duration,
      child: child,
    ),
  );
}

class _Reveal extends StatefulWidget {
  const _Reveal({
    required this.expanded,
    required this.maintainState,
    required this.duration,
    required this.child,
  });

  final bool expanded;
  final bool maintainState;
  final Duration duration;
  final Widget child;

  @override
  State<_Reveal> createState() => _RevealState();
}

class _RevealState extends State<_Reveal> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.expanded ? 1 : 0,
  )..addStatusListener(_onStatus);
  late final _factor = _controller.drive(CurveTween(curve: UtenAnim.standard));

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && !widget.maintainState) {
      setState(() {});
    }
  }

  @override
  void didUpdateWidget(covariant _Reveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (widget.duration == Duration.zero) {
      _controller.value = widget.expanded ? 1 : 0;
    } else if (widget.expanded != oldWidget.expanded) {
      widget.expanded ? _controller.forward() : _controller.reverse();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizeTransition(
    sizeFactor: _factor,
    alignment: Alignment.topCenter,
    child: ExcludeFocus(
      excluding: !widget.expanded,
      child: ExcludeSemantics(
        excluding: !widget.expanded,
        child: IgnorePointer(
          ignoring: !widget.expanded,
          child: TickerMode(
            enabled: widget.expanded,
            child:
                widget.expanded ||
                    widget.maintainState ||
                    !_controller.isDismissed
                ? widget.child
                : const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
}
