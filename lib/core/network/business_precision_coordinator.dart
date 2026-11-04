import 'dart:async';
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
  Future<void> _tail = Future.value();
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
    _tail = Future.value();
  }

  Future<BusinessPrecisionChoice?> ask(
    BusinessPrecisionRequirement requirement, {
    required bool Function() isCurrent,
  }) {
    final result = Completer<BusinessPrecisionChoice?>(),
        generation = _generation,
        prompter = _prompter;
    _pending.add(result);
    _tail = _tail.catchError((_) {}).then((_) async {
      if (generation != _generation || prompter == null || !isCurrent()) {
        if (!result.isCompleted) {
          result.complete(null);
        }
        _pending.remove(result);
        return;
      }
      try {
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
    });
    return result.future;
  }
}
