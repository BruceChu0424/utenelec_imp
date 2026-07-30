import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/latest_request_guard.dart';

void main() {
  test('slow stale response cannot overwrite the latest request', () async {
    final guard = LatestRequestGuard();
    final slowResponse = Completer<String>();
    final fastResponse = Completer<String>();
    String? visibleValue;
    var loading = false;

    Future<void> load(Completer<String> response) async {
      final generation = guard.begin();
      loading = true;
      final value = await response.future;
      if (!guard.isCurrent(generation)) return;
      visibleValue = value;
      loading = false;
    }

    final slow = load(slowResponse);
    final fast = load(fastResponse);

    fastResponse.complete('latest filter');
    await fast;
    expect(visibleValue, 'latest filter');
    expect(loading, isFalse);

    slowResponse.complete('stale filter');
    await slow;
    expect(visibleValue, 'latest filter');
    expect(loading, isFalse);
  });

  test('stale error cannot overwrite latest page, error, or loading', () async {
    final guard = LatestRequestGuard();
    final slowResponse = Completer<String>();
    final latestResponse = Completer<String>();
    String? visibleValue;
    String? error;
    var pageNumber = 0;
    var loading = false;

    Future<void> load(int page, Completer<String> response) async {
      final generation = guard.begin();
      pageNumber = page;
      loading = true;
      error = null;
      try {
        final value = await response.future;
        if (!guard.isCurrent(generation)) return;
        visibleValue = value;
        loading = false;
      } catch (_) {
        if (!guard.isCurrent(generation)) return;
        error = 'failed';
        loading = false;
      }
    }

    final stale = load(1, slowResponse);
    final latest = load(2, latestResponse);

    slowResponse.completeError(StateError('weak network timeout'));
    await stale;
    expect(pageNumber, 2);
    expect(error, isNull);
    expect(loading, isTrue);

    latestResponse.complete('page 2');
    await latest;
    expect(visibleValue, 'page 2');
    expect(pageNumber, 2);
    expect(error, isNull);
    expect(loading, isFalse);
  });
}
