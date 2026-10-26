import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/widgets/read_owned_dialog.dart';

void main() {
  testWidgets(
    'scope retirement removes only the owned read-only evidence and keeps the local input',
    (tester) async {
      final text = TextEditingController(text: '保留原始查询');
      addTearDown(text.dispose);
      Object? result = 'pending';
      late WidgetRef holder;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            apiBaseUrlProvider.overrideWithValue(
              'https://read-dialog.fixture/api',
            ),
            authenticatedScopeProvider.overrideWithValue(
              const AuthenticatedScope(userId: 'reader'),
            ),
            currentPermissionsProvider.overrideWithValue({'goods:view'}),
          ],
          child: MaterialApp(
            home: Consumer(
              builder: (context, ref, child) {
                holder = ref;
                return Scaffold(
                  body: Column(
                    children: [
                      TextField(controller: text),
                      TextButton(
                        onPressed: () async {
                          result = await showReadOwnedDialog<String>(
                            ref: ref,
                            context: context,
                            builder: (dialog) => AlertDialog(
                              title: const Text('原范围私有证据'),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(dialog, 'old'),
                                  child: const Text('继续'),
                                ),
                              ],
                            ),
                          );
                        },
                        child: const Text('查看证据'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('查看证据'));
      await tester.pumpAndSettle();
      expect(find.text('原范围私有证据'), findsOneWidget);
      holder.read(readScopeRevisionProvider.notifier).state++;
      await tester.pumpAndSettle();
      expect(find.text('原范围私有证据'), findsNothing);
      expect(result, isNull);
      expect(text.text, '保留原始查询');
      expect(tester.takeException(), isNull);
    },
  );
}
