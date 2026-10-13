import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/components/feedback/uten_dialog.dart';

void main() {
  for (final ending in ['confirm', 'cancel', 'error']) {
    testWidgets(
      '$ending releases the owner only after exit and permits reopening',
      (tester) async {
        late BuildContext owner;
        var builders = 0;
        var snapshots = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  owner = context;
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        Future<bool?> open({bool fail = false}) =>
            UtenDialog.showAndWaitForExit<bool>(
              owner,
              onPopped: (_) {
                snapshots++;
                if (fail) throw StateError('snapshot');
              },
              builder: (context) {
                builders++;
                return UtenAlertDialog(
                  title: const Text('确认'),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('取消'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('确定'),
                    ),
                  ],
                );
              },
            );
        Object? error;
        final first = open(fail: ending == 'error').catchError((Object e) {
          error = e;
          return null;
        });
        expect(
          await open(),
          isNull,
          reason: 'The owner is reserved before the first barrier can render.',
        );
        expect(snapshots, 0);
        await tester.pumpAndSettle();
        expect(builders, 1);
        await tester.tap(find.text(ending == 'cancel' ? '取消' : '确定'));
        await tester.pump(const Duration(milliseconds: 16));
        expect(await open(), isNull);
        expect(builders, 1);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
        expect(await first, ending == 'error' ? null : ending == 'confirm');
        expect(error, ending == 'error' ? isA<StateError>() : isNull);
        expect(snapshots, 1);
        final reopened = open();
        await tester.pumpAndSettle();
        expect(builders, 2);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(await reopened, isFalse);
        expect(snapshots, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('different owners keep independent confirmation leases', (
    tester,
  ) async {
    late BuildContext firstOwner;
    late BuildContext secondOwner;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              Builder(
                builder: (context) {
                  firstOwner = context;
                  return const SizedBox();
                },
              ),
              Builder(
                builder: (context) {
                  secondOwner = context;
                  return const SizedBox();
                },
              ),
            ],
          ),
        ),
      ),
    );
    Future<bool?> open(BuildContext owner, String label) =>
        UtenDialog.showAndWaitForExit<bool>(
          owner,
          builder: (context) => UtenAlertDialog(
            title: Text(label),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text('取消$label'),
              ),
            ],
          ),
        );
    final first = open(firstOwner, '甲');
    await tester.pumpAndSettle();
    final second = open(secondOwner, '乙');
    await tester.pumpAndSettle();
    expect(find.text('甲'), findsOneWidget);
    expect(find.text('乙'), findsOneWidget);
    await tester.tap(find.text('取消乙'));
    await tester.pumpAndSettle();
    expect(await second, isFalse);
    await tester.tap(find.text('取消甲'));
    await tester.pumpAndSettle();
    expect(await first, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed dialog construction does not retain its owner', (
    tester,
  ) async {
    late BuildContext owner;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            owner = context;
            return const SizedBox();
          },
        ),
      ),
    );
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(
        UtenDialog.showAndWaitForExit<bool>(
          owner,
          builder: (_) => const SizedBox(),
        ),
        throwsFlutterError,
      );
    }
  });
}
