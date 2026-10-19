import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/models/retained_async_page.dart';

// Riverpod 3 将 copyWithPrevious 标记为 @internal；跨 family 实例手动保页/保旧值是既有架构，等上游公开等价 API 后再迁移。
// ignore_for_file: invalid_use_of_internal_member

void main() {
  test('keeps the successful page through loading and a failed next page', () {
    final cache = RetainedAsyncPage<List<String>>();
    const first = AsyncData(['first']);
    cache.resolve(('query', 'account'), first);

    final loading = cache.resolve(('query', 'account'), const AsyncLoading());
    expect(loading.isLoading, isTrue);
    expect(loading.value, ['first']);

    final failure = cache.resolve((
      'query',
      'account',
    ), AsyncError(StateError('offline'), StackTrace.current));
    expect(failure.hasError, isTrue);
    expect(failure.value, ['first']);

    final retry = cache.resolve((
      'query',
      'account',
    ), const AsyncData(['next']));
    expect(retry.value, ['next']);
    expect(retry.hasError, isFalse);
  });

  test('query or account changes discard even provider-retained old data', () {
    final cache = RetainedAsyncPage<List<String>>();
    const old = AsyncData(['private old rows']);
    cache.resolve(('first query', 'first account'), old);
    final staleLoading = const AsyncLoading<List<String>>().copyWithPrevious(
      old,
    );

    final changedQuery = cache.resolve((
      'new query',
      'first account',
    ), staleLoading);
    expect(changedQuery.isLoading, isTrue);
    expect(changedQuery.hasValue, isFalse);
    expect(
      cache.resolve(('new query', 'first account'), staleLoading).hasValue,
      isFalse,
    );

    cache.resolve(('new query', 'first account'), old);
    final changedAccount = cache.resolve(
      ('new query', 'second account'),
      AsyncError<List<String>>(
        StateError('offline'),
        StackTrace.current,
      ).copyWithPrevious(old),
    );
    expect(changedAccount.hasError, isTrue);
    expect(changedAccount.hasValue, isFalse);
  });
}
