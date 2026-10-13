import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/features/basic_data/models/payment_style_node.dart';
import 'package:uten_imp/features/basic_data/pages/payment_style_page.dart';
import 'package:uten_imp/features/basic_data/repositories/payment_style_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import '../../support/filter_segment_tap.dart';

class _Categories extends Fake implements PaymentStyleRepository {
  final requests = <String?>[];
  @override
  Future<List<PaymentStyleNode>> tree({String? category}) async {
    requests.add(category);
    return const [];
  }
}

void main() {
  testWidgets(
    'payment category keeps its exact server value and does not clear on re-tap',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = _Categories();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            paymentStyleRepositoryProvider.overrideWithValue(repository),
            currentPermissionsProvider.overrideWithValue(const {
              Perm.paymentStyleView,
            }),
          ],
          child: const MaterialApp(home: PaymentStylePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(repository.requests, ['EXPENSE']);
      await selectFilterSegment(tester, '收入');
      await tester.pumpAndSettle();
      expect(repository.requests, ['EXPENSE', 'INCOME']);
      await selectFilterSegment(tester, '收入');
      await tester.pumpAndSettle();
      expect(repository.requests, ['EXPENSE', 'INCOME']);
      await selectFilterSegment(tester, '结算方式');
      await tester.pumpAndSettle();
      expect(repository.requests.last, 'METHOD');
      expect(find.byTooltip('添加顶级类别'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
