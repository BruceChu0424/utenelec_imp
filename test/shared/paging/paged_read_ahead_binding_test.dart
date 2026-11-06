// Only reader ownership survives the retired read-ahead/window protocol.
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/paged_result.dart';
import 'package:uten_imp/shared/paging/paged_read_window_binding.dart';

PagedResult<int> _result(List<int> rows) => PagedResult(
  items: rows,
  page: 1,
  size: rows.length,
  total: rows.length,
  totalPages: rows.isEmpty ? 0 : 1,
);
void main() {
  test(
    'a Base owner proof remains attached when the same response rows are viewed through their Child type',
    () {
      final session = PagedReadWindowSession<num>(isCurrent: () => true);
      final List<int> rows = [1, 2];
      session.bindResult(
        PagedResult<num>(
          items: rows,
          page: 1,
          size: 2,
          total: 2,
          totalPages: 1,
        ),
      );
      final proof = readWindowBindingOf<int>(rows);
      expect(proof, isNotNull);
      expect(proof!.isCurrent, isTrue);
      session.invalidate();
      expect(proof.isCurrent, isFalse);
    },
  );

  test(
    'business projection retains live ownership without fetching or maintaining replacement pages',
    () {
      var current = true;
      final session = PagedReadWindowSession<int>(isCurrent: () => current);
      final raw = <int>[1, 2];
      session.bindResult(_result(raw));
      final view = raw.map((row) => 'row-$row').toList();
      projectReadWindowBinding(
        raw,
        view,
        project: (rows) => rows.map((row) => 'row-$row').toList(),
        projectionKey: 'labels',
      );
      final proof = readWindowBindingOf(view)!;
      expect(proof.isCurrent, isTrue);
      current = false;
      expect(proof.isCurrent, isFalse);
      expect(view, ['row-1', 'row-2']);
    },
  );
  test(
    'pending and ordinary failure retain ownership while access rejection retires every projection',
    () {
      final session = PagedReadWindowSession<int>(isCurrent: () => true);
      final raw = <int>[1];
      session.bindResult(_result(raw));
      final view = <String>['one'];
      projectReadWindowBinding(
        raw,
        view,
        project: (rows) => ['one'],
        projectionKey: 'labels',
      );
      final proof = readWindowBindingOf(view)!;
      session.bindResult(_result(raw), pending: true);
      expect(proof.pending, isTrue);
      session.fail();
      expect(proof.pending, isFalse);
      expect(proof.failed, isTrue);
      expect(proof.isCurrent, isTrue);
      session.fail(accessDenied: true);
      expect(proof.isCurrent, isFalse);
    },
  );
  test(
    'an empty result clears the existing owner session without binding a shared const empty list',
    () {
      final session = PagedReadWindowSession<int>(isCurrent: () => true);
      final rows = <int>[1];
      session.bindResult(_result(rows));
      final proof = readWindowBindingOf(rows)!;
      final empty = session.bindResult(_result(const []));
      expect(proof.empty, isTrue);
      expect(session.empty, isTrue);
      expect(readWindowBindingOf(const <int>[]), isNull);
      expect(readWindowBindingOf(empty.items)!.isCurrent, isTrue);
      final other = PagedReadWindowSession<int>(isCurrent: () => true);
      final otherEmpty = other.bindResult(_result(const []));
      expect(identical(empty.items, otherEmpty.items), isFalse);
      session.invalidate();
      expect(readWindowBindingOf(empty.items)!.isCurrent, isFalse);
      expect(readWindowBindingOf(otherEmpty.items)!.isCurrent, isTrue);
      final projected = projectReadWindowBinding(
        otherEmpty.items,
        const <String>[],
        project: (_) => const <String>[],
        projectionKey: 'empty labels',
      );
      expect(readWindowBindingOf(projected)!.isCurrent, isTrue);
      expect(readWindowBindingOf(const <String>[]), isNull);
    },
  );
  test('sameSession includes an immutable structural projection identity', () {
    final session = PagedReadWindowSession<int>(isCurrent: () => true);
    final raw = <int>[1];
    session.bindResult(_result(raw));
    final key = {
      'kind': <int>[1],
    };
    final a = <String>['a'];
    projectReadWindowBinding(
      raw,
      a,
      project: (rows) => ['a'],
      projectionKey: key,
    );
    key['kind']!.add(2);
    final b = <String>['b'];
    projectReadWindowBinding(
      raw,
      b,
      project: (rows) => ['b'],
      projectionKey: {
        'kind': [1],
      },
    );
    expect(readWindowBindingOf(a)!.sameSession(readWindowBindingOf(b)), isTrue);
    final other = PagedReadWindowSession<int>(isCurrent: () => true);
    final otherRows = <int>[1];
    other.bindResult(_result(otherRows));
    expect(
      readWindowBindingOf(raw)!.sameSession(readWindowBindingOf(otherRows)),
      isFalse,
    );
  });
}
