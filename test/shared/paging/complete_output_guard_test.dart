import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/paging/complete_output_guard.dart';

void main() {
  test(
    'prefixes never qualify, complete acceptance survives a same-query read failure',
    () {
      final guard = CompleteOutputGuard();
      final key = [
        'actor',
        1,
        {'filter': 'A'},
      ];
      final cold = guard.begin<List<int>>(identity: key);
      expect(guard.hasComplete(key), isFalse);
      expect(guard.mayPublishPrefix(cold), isTrue);
      expect(cold.fallback, isNull);
      expect(guard.accept(cold), isTrue);
      final retirement = guard.retirement;
      final repeat = guard.begin<List<int>>(identity: key, previous: [1, 2, 3]);
      expect(guard.hasComplete(key), isTrue);
      expect(guard.mayPublishPrefix(repeat), isFalse);
      expect(repeat.fallback, [1, 2, 3]);
      expect(guard.retirement, retirement);
    },
  );
  test(
    'write retirement cannot revive old actions after replacement acceptance',
    () {
      final guard = CompleteOutputGuard();
      const key = ['actor', 1, 'A'];
      guard.accept(guard.begin<Object>(identity: key));
      final actionRetirement = guard.retirement;
      guard.retireAfterConfirmedWrite();
      expect(guard.hasComplete(key), isFalse);
      final next = guard.begin<List<int>>(
        identity: key,
        previous: [1, 2],
        preserveEditorInput: true,
      );
      expect(next.fallback, [1, 2]);
      expect(guard.mayPublishPrefix(next), isFalse);
      expect(guard.hasComplete(key), isFalse);
      guard.accept(next);
      expect(guard.hasComplete(key), isTrue);
      expect(guard.retirement, isNot(actionRetirement));
    },
  );
  test('query keys freeze collections and stale readers cannot accept', () {
    final guard = CompleteOutputGuard();
    final filters = {'name': 'A'};
    final first = guard.begin<Object>(identity: ['actor', filters]);
    guard.accept(first);
    filters['name'] = 'B';
    expect(guard.hasComplete(['actor', filters]), isFalse);
    final second = guard.begin<Object>(identity: ['actor', filters]);
    expect(guard.accept(first), isFalse);
    guard.accept(second);
    expect(
      guard.hasComplete([
        'actor',
        {'name': 'B'},
      ]),
      isTrue,
    );
    guard.retire();
    expect(guard.accept(second), isFalse);
  });
}
