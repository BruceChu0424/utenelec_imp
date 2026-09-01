import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/shell/widgets/uten_sliding_tab_view.dart';

void main() {
  testWidgets('inactive main tabs stop ticking and keep their State', (
    tester,
  ) async {
    final harnessKey = GlobalKey<_SlidingHarnessState>();
    await tester.pumpWidget(_SlidingHarness(key: harnessKey));
    await tester.pump(const Duration(milliseconds: 100));

    final firstFinder = find.byKey(
      const Key('ticker-probe-first'),
      skipOffstage: false,
    );
    final secondFinder = find.byKey(
      const Key('ticker-probe-second'),
      skipOffstage: false,
    );
    final first = tester.state<_TickerProbeState>(firstFinder);
    final second = tester.state<_TickerProbeState>(secondFinder);

    first.requestProbeFocus();
    await tester.pump();
    expect(first.hasProbeFocus, isTrue);

    first.incrementMarker();
    await tester.pump();
    final firstBefore = first.animationValue;
    final secondBefore = second.animationValue;
    await tester.pump(const Duration(milliseconds: 200));

    expect(first.animationValue, isNot(firstBefore));
    expect(second.animationValue, secondBefore);
    expect(first.marker, 1);

    harnessKey.currentState!.showTab(1);
    await tester.pump();
    await tester.pump();

    expect(tester.state<_TickerProbeState>(firstFinder), same(first));
    expect(tester.state<_TickerProbeState>(secondFinder), same(second));
    expect(first.marker, 1);
    expect(first.hasProbeFocus, isFalse);

    first.requestProbeFocus();
    await tester.pump();
    expect(first.hasProbeFocus, isFalse);
    second.requestProbeFocus();
    await tester.pump();
    expect(second.hasProbeFocus, isTrue);

    final firstHidden = first.animationValue;
    final secondVisible = second.animationValue;
    await tester.pump(const Duration(milliseconds: 200));

    expect(first.animationValue, firstHidden);
    expect(second.animationValue, isNot(secondVisible));
  });

  testWidgets('business page TickerMode pauses and resumes kept-alive tab', (
    tester,
  ) async {
    final harnessKey = GlobalKey<_SlidingHarnessState>();
    await tester.pumpWidget(_SlidingHarness(key: harnessKey));
    await tester.pump(const Duration(milliseconds: 100));

    final firstFinder = find.byKey(
      const Key('ticker-probe-first'),
      skipOffstage: false,
    );
    final secondFinder = find.byKey(
      const Key('ticker-probe-second'),
      skipOffstage: false,
    );
    final first = tester.state<_TickerProbeState>(firstFinder);
    final second = tester.state<_TickerProbeState>(secondFinder);
    final activeBefore = first.animationValue;
    await tester.pump(const Duration(milliseconds: 200));
    expect(first.animationValue, isNot(activeBefore));

    harnessKey.currentState!.setTabsVisible(false);
    await tester.pump();
    final firstPaused = first.animationValue;
    final secondPaused = second.animationValue;
    await tester.pump(const Duration(milliseconds: 300));
    expect(first.animationValue, firstPaused);
    expect(second.animationValue, secondPaused);

    harnessKey.currentState!.setTabsVisible(true);
    await tester.pump();
    final firstResumed = first.animationValue;
    final secondStillHidden = second.animationValue;
    await tester.pump(const Duration(milliseconds: 200));
    expect(first.animationValue, isNot(firstResumed));
    expect(second.animationValue, secondStillHidden);
    expect(tester.state<_TickerProbeState>(firstFinder), same(first));
  });
}

class _SlidingHarness extends StatefulWidget {
  const _SlidingHarness({super.key});

  @override
  State<_SlidingHarness> createState() => _SlidingHarnessState();
}

class _SlidingHarnessState extends State<_SlidingHarness> {
  late final ValueNotifier<double> _position;
  int _index = 0;
  bool _tabsVisible = true;

  @override
  void initState() {
    super.initState();
    _position = ValueNotifier<double>(0);
  }

  @override
  void dispose() {
    _position.dispose();
    super.dispose();
  }

  void showTab(int index) => setState(() => _index = index);

  void setTabsVisible(bool visible) => setState(() => _tabsVisible = visible);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: TickerMode(
          enabled: _tabsVisible,
          child: UtenSlidingTabView(
            index: _index,
            position: _position,
            animated: false,
            swipeEnabled: false,
            children: const [
              _TickerProbe(key: Key('ticker-probe-first'), label: 'first'),
              _TickerProbe(key: Key('ticker-probe-second'), label: 'second'),
            ],
          ),
        ),
      ),
    );
  }
}

class _TickerProbe extends StatefulWidget {
  const _TickerProbe({super.key, required this.label});

  final String label;

  @override
  State<_TickerProbe> createState() => _TickerProbeState();
}

class _TickerProbeState extends State<_TickerProbe>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final FocusNode _focusNode;
  int marker = 0;

  double get animationValue => _controller.value;
  bool get hasProbeFocus => _focusNode.hasFocus;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
    _focusNode = FocusNode(debugLabel: widget.label);
  }

  void incrementMarker() => setState(() => marker++);
  void requestProbeFocus() => _focusNode.requestFocus();

  @override
  void dispose() {
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => Text(
          '${widget.label}:$marker:${_controller.value.toStringAsFixed(3)}',
        ),
      ),
    );
  }
}
