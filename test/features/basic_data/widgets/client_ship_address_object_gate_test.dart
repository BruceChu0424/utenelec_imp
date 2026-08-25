import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          clientRepositoryProvider.overrideWithValue(
            _ReadOnlyClientRepository(),
          ),
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
                onPressed: () => showClientShipAddressSheet(
                  context,
                  ref,
                  clientId: 'client-1',
                  clientName: '共享客户',
                ),
                child: const Text('打开地址簿'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开地址簿'));
    await tester.pumpAndSettle();

    expect(find.textContaining('当前客户为只读范围'), findsOneWidget);
    expect(find.text('已有地址一号'), findsOneWidget);
    expect(find.text('新增地址'), findsNothing);
    expect(find.byTooltip('删除该地址'), findsNothing);

    await tester.tap(find.text('已有地址一号'));
    await tester.pumpAndSettle();
    expect(find.text('已有地址一号'), findsNothing);
  });
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
