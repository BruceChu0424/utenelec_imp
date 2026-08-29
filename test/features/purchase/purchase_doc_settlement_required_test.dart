import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/inputs/uten_dropdown_field.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/purchase/models/purchase_doc.dart';
import 'package:uten_imp/features/purchase/pages/purchase_doc_edit_page.dart';
import 'package:uten_imp/shared/providers/session_provider.dart';

void main() {
  testWidgets('新建采购订货单的结账方式为空时立即显示必填红框', (tester) async {
    await tester.binding.setSurfaceSize(const Size(375, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          apiClientProvider.overrideWithValue(_EmptyApi()),
          sessionProvider.overrideWith(_EmptySessionNotifier.new),
        ],
        child: const MaterialApp(
          home: PurchaseDocEditPage(docType: PurchaseDocType.order),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final fieldFinder = find.byWidgetPredicate(
      (widget) => widget is UtenDropdownField && widget.label == '结账方式',
    );
    expect(fieldFinder, findsOneWidget);
    final field = tester.widget<UtenDropdownField>(fieldFinder);
    expect(field.required, isTrue);
    expect(field.allowClear, isFalse);
    expect(field.value, isNull);

    final decoratorFinder = find.descendant(
      of: fieldFinder,
      matching: find.byType(InputDecorator),
    );
    final decorator = tester.widget<InputDecorator>(decoratorFinder);
    final border = decorator.decoration.enabledBorder! as OutlineInputBorder;
    expect(
      border.borderSide.color,
      Theme.of(tester.element(fieldFinder)).colorScheme.error,
    );
  });
}

class _EmptySessionNotifier extends SessionNotifier {
  @override
  SessionState build() => const SessionState();
}

class _EmptyApi extends ApiClient {
  _EmptyApi() : super(Dio());

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async => const {
    'items': <Map<String, dynamic>>[],
    'page': 1,
    'size': 1,
    'total': 0,
    'totalPages': 0,
  };

  @override
  Future<List<Map<String, dynamic>>> getList(
    String path, {
    Map<String, dynamic>? query,
  }) async => const [];
}
