import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/features/basic_data/repositories/account_repository.dart';

void main() {
  test(
    'account posting choices read the authoritative cash scope without loading the general category tree',
    () async {
      final paths = <String>[];
      final api = ApiClient(
        Dio(BaseOptions(baseUrl: 'https://account.invalid/api'))
          ..interceptors.add(
            InterceptorsWrapper(
              onRequest: (request, handler) {
                paths.add(request.path);
                handler.resolve(
                  Response<dynamic>(
                    requestOptions: request,
                    data: [
                      {'id': 'cash-leaf', 'code': '100101', 'name': '库存现金'},
                    ],
                  ),
                );
              },
            ),
          ),
      );
      final container = ProviderContainer(
        overrides: [apiClientProvider.overrideWithValue(api)],
      );
      addTearDown(container.dispose);
      final choices = await container.read(
        accountPostingStylesReaderProvider,
      )();
      expect(paths, ['/master/accounts/posting-styles']);
      expect(choices.single.id, 'cash-leaf');
      expect(choices.single.code, '100101');
      expect(choices.single.name, '库存现金');
    },
  );
}
