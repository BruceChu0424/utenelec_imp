import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Checks emitted incremental payloads rather than only the final framework
/// tree. A child must have been emitted in this or a previous batch. Root
/// reachability is a separate conservative diagnostic: native traversal
/// parents and the web engine's detachments do not prune identically.
class SemanticsWireTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() => _Builder();
}

class SemanticsWireGraph {
  static final nodes = <int, List<int>>{};
  static final labels = <int, String>{};
  static final missing = <String>[];
  static final reachabilityCandidates = <String>[];
  static int frames = 0;

  static void reset() {
    nodes.clear();
    labels.clear();
    missing.clear();
    reachabilityCandidates.clear();
    frames = 0;
  }
}

class _Builder extends Fake implements ui.SemanticsUpdateBuilder {
  final _inner = ui.SemanticsUpdateBuilder();
  final _updates = <int, List<int>>{};
  final _labels = <int, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #updateNode) {
      final args = invocation.namedArguments;
      _updates[args[#id] as int] =
          (args[#childrenInTraversalOrder] as List<int>).toList();
      _labels[args[#id] as int] = '${args[#label]} | ${args[#tooltip]}';
      return Function.apply(
        _inner.updateNode,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
    }
    if (invocation.memberName == #updateCustomAction) {
      return Function.apply(
        _inner.updateCustomAction,
        invocation.positionalArguments,
        invocation.namedArguments,
      );
    }
    return super.noSuchMethod(invocation);
  }

  @override
  ui.SemanticsUpdate build() {
    final nodes = SemanticsWireGraph.nodes;
    SemanticsWireGraph.frames++;
    nodes.addAll(_updates);
    SemanticsWireGraph.labels.addAll(_labels);
    for (final entry in _updates.entries) {
      for (final child in entry.value) {
        if (!nodes.containsKey(child)) {
          final record =
              'frame=${SemanticsWireGraph.frames} parent=${entry.key} '
              'label=${SemanticsWireGraph.labels[entry.key]} child=$child '
              'lastLabel=${SemanticsWireGraph.labels[child]}';
          if (SemanticsWireGraph.labels.containsKey(child)) {
            SemanticsWireGraph.reachabilityCandidates.add(record);
          } else {
            SemanticsWireGraph.missing.add(record);
          }
        }
      }
    }
    final reachable = <int>{};
    void visit(int id) {
      if (!reachable.add(id)) return;
      for (final child in nodes[id] ?? const <int>[]) {
        visit(child);
      }
    }

    visit(0);
    nodes.removeWhere((id, _) => !reachable.contains(id));
    return _inner.build();
  }
}
