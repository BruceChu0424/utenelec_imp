import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/request_reload_semantics.dart';

void main() {
  const id = '10000000-0000-0000-0000-000000000001';
  test('only audited original preview and proof verification are reads', () {
    expect(
      isReadOnlyPost(
        '/api/production/material-analyses/$id/aggregate-orders/preview',
      ),
      isTrue,
    );
    expect(
      isReadOnlyPost('/finance/material-statements/operations/$id/verify'),
      isTrue,
    );
    for (final path in [
      '/production/material-analyses/$id/aggregate-orders/submit',
      '/production/material-analyses/$id/aggregate-orders/actions/$id/cancel',
      '/finance/material-statements/operations/$id/cancel-unwritten',
      '/finance/material-statements/operations/$id/verify/more',
      '/production/material-analyses/not-an-id/aggregate-orders/preview',
      '/unknown/preview',
    ]) {
      expect(isReadOnlyPost(path), isFalse, reason: path);
    }
  });
}
