import 'dart:async';
import '../async/serial_task_queue.dart';
import 'business_precision.dart';

typedef BusinessPrecisionPrompter =
    Future<BusinessPrecisionChoice?> Function(
      BusinessPrecisionRequirement requirement,
    );

/// Serializes visible dialogs, never shares a choice across different operations.
class BusinessPrecisionCoordinator {
  static final instance = BusinessPrecisionCoordinator();
  BusinessPrecisionPrompter? _prompter;
  int _generation = 0;
  var _operations = SerialTaskQueue();
  final _pending = <Completer<BusinessPrecisionChoice?>>{};
  void Function() register(BusinessPrecisionPrompter prompter) {
    clear();
    _prompter = prompter;
    return () {
      if (identical(_prompter, prompter)) {
        _prompter = null;
        clear();
      }
    };
  }

  void clear() {
    _generation++;
    for (final pending in _pending) {
      if (!pending.isCompleted) {
        pending.complete(null);
      }
    }
    _pending.clear();
    // A retired dialog may still be closing. New owners use a fresh queue and
    // never inherit a completed/retired caller's execution zone.
    _operations = SerialTaskQueue();
  }

  Future<BusinessPrecisionChoice?> ask(
    BusinessPrecisionRequirement requirement, {
    required bool Function() isCurrent,
  }) {
    final result = Completer<BusinessPrecisionChoice?>(),
        generation = _generation,
        prompter = _prompter;
    _pending.add(result);
    unawaited(
      _operations.run(() async {
        try {
          if (generation != _generation || prompter == null || !isCurrent()) {
            if (!result.isCompleted) result.complete(null);
            return;
          }
          final choice = await prompter(requirement);
          if (!result.isCompleted) {
            result.complete(
              generation == _generation &&
                      identical(prompter, _prompter) &&
                      isCurrent()
                  ? choice
                  : null,
            );
          }
        } catch (error, stack) {
          if (!result.isCompleted) {
            result.completeError(error, stack);
          }
        } finally {
          _pending.remove(result);
        }
      }),
    );
    return result.future;
  }
}
