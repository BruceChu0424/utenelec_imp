import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/layout/uten_picker_confirm_bar.dart';
import 'package:uten_imp/features/basic_data/models/client_node.dart';
import 'package:uten_imp/features/basic_data/models/client_ship_address.dart';
import 'package:uten_imp/features/basic_data/repositories/client_repository.dart';
import 'package:uten_imp/features/basic_data/repositories/client_ship_address_repository.dart';
import 'package:uten_imp/features/basic_data/widgets/client_ship_address_sheet.dart';
import 'package:uten_imp/shared/auth/permissions.dart';

void main() {
  testWidgets('shared customer address book is selectable but not writable', (
    tester,
  ) async {
    ClientShipAddress? selected;
    await _pumpAddressBook(tester, (value) => selected = value);

    await tester.tap(find.text('打开地址簿'));
    await tester.pumpAndSettle();

    expect(find.textContaining('当前客户只能查看'), findsOneWidget);
    expect(find.text('已有地址一号'), findsOneWidget);
    expect(find.text('新增地址'), findsNothing);
    expect(find.byTooltip('删除该地址'), findsNothing);
    expect(
      tester
          .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
          .confirmEnabled,
      isFalse,
    );

    await tester.tap(find.text('已有地址一号'));
    await tester.pumpAndSettle();
    expect(selected, isNull);
    expect(find.text('收货地址 · 共享客户'), findsOneWidget);
    await tester.tap(find.byKey(const Key('client-ship-address-confirm')));
    await tester.pumpAndSettle();
    expect(selected?.id, 'address-1');
    expect(find.text('已有地址一号'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('address selection stays local on repeated taps and cancel', (
    tester,
  ) async {
    final returned = <ClientShipAddress?>[];
    await _pumpAddressBook(tester, returned.add);
    await tester.tap(find.text('打开地址簿'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('已有地址一号'));
    await tester.tap(find.text('已有地址一号'));
    await tester.pumpAndSettle();
    expect(returned, isEmpty);
    expect(find.text('已选择：已有地址一号'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(returned, [null]);
    await tester.tap(find.text('打开地址簿'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UtenPickerConfirmBar>(find.byType(UtenPickerConfirmBar))
          .selectedCount,
      0,
    );
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpAddressBook(
  WidgetTester tester,
  ValueChanged<ClientShipAddress?> onResult,
) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        clientRepositoryProvider.overrideWithValue(_ReadOnlyClientRepository()),
        clientShipAddressRepositoryProvider.overrideWithValue(
          _AddressRepositoryFake(),
        ),
        currentPermissionsProvider.overrideWithValue({
          Perm.clientAddressCreate,
          Perm.clientAddressDelete,
        }),
        isSuperAdminProvider.overrideWithValue(false),
      ],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: FilledButton(
              onPressed: () async => onResult(
                await showClientShipAddressSheet(
                  context,
                  ref,
                  clientId: 'client-1',
                  clientName: '共享客户',
                ),
              ),
              child: const Text('打开地址簿'),
            ),
          ),
        ),
      ),
    ),
  );
}

class _ReadOnlyClientRepository implements ClientRepository {
  @override
  Future<ClientDetail> detail(String id) async =>
      const ClientDetail(id: 'client-1', name: '共享客户');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _AddressRepositoryFake implements ClientShipAddressRepository {
  @override
  Future<List<ClientShipAddress>> list(String clientId) async => const [
    ClientShipAddress(id: 'address-1', clientId: 'client-1', address: '已有地址一号'),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
