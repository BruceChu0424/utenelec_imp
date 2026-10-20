import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/shared/auth/session_snapshot_provider.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_layout.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_binding.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_controller.dart';
import 'package:uten_imp/shared/platform_tables/platform_table_models.dart';
import 'package:uten_imp/shared/providers/editable_grid_column_prefs.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/widgets/procurement_document_layout.dart';

const _oldOrder = [
  'goods',
  'qty',
  'extra:freight',
  'price',
  'platform:note',
  'allowedOverReceiptPct',
  'amount',
];
const _newOrder = [
  'goods',
  'qty',
  'allowedOverReceiptPct',
  'extra:freight',
  'price',
  'platform:note',
  'amount',
];

void main() {
  for (final pinned in [
    ['goods', 'qty'],
    ['goods', 'allowedOverReceiptPct'],
  ]) {
    test(
      'legacy purchase host layout migrates and preserves other modes $pinned',
      () {
        final notifier = PurchaseOrderGridColumnPrefsNotifier();
        final decoded = notifier.decode({
          'order': {
            'order': _oldOrder,
            'hidden': ['platform:note'],
            'pinned': pinned,
          },
          'anotherMode': {
            'order': _oldOrder,
            'hidden': ['price'],
            'pinned': pinned,
          },
        })!;
        final order = decoded['order']!;
        expect(order.order, _newOrder);
        expect(order.hidden, {'platform:note'});
        expect(
          order.pinned,
          pinned.contains('qty')
              ? {'goods', 'qty', 'allowedOverReceiptPct'}
              : {'goods'},
        );
        expect(order.layoutVersion, purchaseOrderColumnLayoutVersion);
        expect(decoded['anotherMode']!.order, _oldOrder);
        expect(decoded['anotherMode']!.pinned, pinned.toSet());
        expect(
          notifier.decode(notifier.encode(decoded))!['order']!.order,
          _newOrder,
        );
      },
    );

    test(
      'legacy platform layout migrates without dropping user fields $pinned',
      () {
        final notifier = PlatformTableLayoutNotifier(
          purchaseOrderItemsTableKey,
        );
        final seed = PlatformTableLayout(
          order: _oldOrder,
          hidden: const {'platform:note'},
          pinned: pinned.toSet(),
          widths: const {'qty': 175, 'platform:note': 310},
          added: const [
            PlatformColumnDefinition(id: 'note', scope: '', name: '备注'),
          ],
          filters: const {'price': '高价'},
          sortColumn: 'amount',
          sortAscending: false,
          hasQueryPreferences: true,
        );
        final decoded = notifier.decode(seed.toJson())!;
        expect(decoded.order, _newOrder);
        expect(
          decoded.pinned,
          pinned.contains('qty')
              ? {'goods', 'qty', 'allowedOverReceiptPct'}
              : {'goods'},
        );
        expect(decoded.hidden, seed.hidden);
        expect(decoded.widths, seed.widths);
        expect(decoded.added.single.toJson(), seed.added.single.toJson());
        expect(decoded.filters, seed.filters);
        expect(decoded.sortColumn, seed.sortColumn);
        expect(decoded.sortAscending, isFalse);
        expect(decoded.hasQueryPreferences, isTrue);
        expect(decoded.layoutVersion, purchaseOrderColumnLayoutVersion);
        expect(
          notifier.decode(notifier.encode(decoded))!.toJson(),
          decoded.toJson(),
        );
        expect(
          PlatformTableLayoutNotifier(
            'purchase.receipt.items',
          ).decode(seed.toJson())!.order,
          _oldOrder,
        );
      },
    );
  }

  for (final order in <List<String>>[
    ['goods', 'qty', 'price'],
    ['goods', 'allowedOverReceiptPct', 'price'],
    ['allowedOverReceiptPct'],
    ['goods', 'qty', 'qty', 'allowedOverReceiptPct', 'allowedOverReceiptPct'],
  ]) {
    test(
      'old partial or duplicate layout keeps quantity and tolerance adjacent $order',
      () {
        final host = PurchaseOrderGridColumnPrefsNotifier().decode({
          'order': {'order': order},
        })!['order']!;
        final platform = PlatformTableLayoutNotifier(
          purchaseOrderItemsTableKey,
        ).decode({'order': order})!;
        for (final restored in [host.order, platform.order]) {
          expect(
            restored.indexOf('allowedOverReceiptPct'),
            restored.indexOf('qty') + 1,
          );
          expect(restored.where((key) => key == 'qty'), hasLength(1));
          expect(
            restored.where((key) => key == 'allowedOverReceiptPct'),
            hasLength(1),
          );
        }
      },
    );
  }

  test('empty saved layouts continue to use the complete default schema', () {
    final host = PurchaseOrderGridColumnPrefsNotifier().decode({
      'order': <String, dynamic>{},
    })!['order']!;
    final platform = PlatformTableLayoutNotifier(
      purchaseOrderItemsTableKey,
    ).decode(<String, dynamic>{})!;
    expect(host.order, isEmpty);
    expect(platform.order, isEmpty);
    expect(platform.layoutVersion, purchaseOrderColumnLayoutVersion);
  });

  test(
    'new and future layout versions preserve subsequent custom orders and pins',
    () {
      for (final version in [purchaseOrderColumnLayoutVersion, 2]) {
        final hostNotifier = PurchaseOrderGridColumnPrefsNotifier();
        final host = hostNotifier.decode({
          'order': {
            'order': _oldOrder,
            'pinned': ['allowedOverReceiptPct'],
            'layoutVersion': version,
          },
        })!;
        expect(host['order']!.order, _oldOrder);
        expect(host['order']!.pinned, {'allowedOverReceiptPct'});
        expect(
          hostNotifier
              .decode(hostNotifier.encode(host))!['order']!
              .layoutVersion,
          version,
        );
        final platformNotifier = PlatformTableLayoutNotifier(
          purchaseOrderItemsTableKey,
        );
        final platform = platformNotifier.decode({
          'order': _oldOrder,
          'pinned': ['allowedOverReceiptPct'],
          'layoutVersion': version,
        })!;
        expect(platform.order, _oldOrder);
        expect(platform.pinned, {'allowedOverReceiptPct'});
        expect(platform.copyWith(widths: {'qty': 200}).layoutVersion, version);
        expect(
          platformNotifier
              .decode(platformNotifier.encode(platform))!
              .layoutVersion,
          version,
        );
      }
    },
  );

  test('first user custom order is saved as the current layout version', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final host = container.read(purchaseOrderGridColumnPrefsProvider.notifier);
    host.updateFor('order', _oldOrder, {}, {'allowedOverReceiptPct'});
    final saved = host.encode(
      container.read(purchaseOrderGridColumnPrefsProvider),
    );
    final restored = host.decode(saved)!['order']!;
    expect(restored.order, _oldOrder);
    expect(restored.pinned, {'allowedOverReceiptPct'});
    expect(restored.layoutVersion, purchaseOrderColumnLayoutVersion);
    final platform = PlatformTableLayoutNotifier(purchaseOrderItemsTableKey);
    final custom = platform.defaultValue.copyWith(order: _oldOrder);
    expect(platform.decode(platform.encode(custom))!.order, _oldOrder);
  });

  for (final changeOwner in [false, true]) {
    testWidgets(
      'reset then customize retains the migration version: owner=$changeOwner',
      (tester) async {
        final controller = PlatformTableController<Object>();
        final owner = StateProvider<AuthenticatedScope?>((_) => null);
        late ProviderContainer container;
        addTearDown(controller.dispose);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              authenticatedScopeProvider.overrideWith(
                (ref) => ref.watch(owner),
              ),
              // owner=true 会把身份切到已登录，Riverpod 3 的同步挂链随之唤醒
              // sessionSnapshot 真拉一次 /auth/me：真实 Dio 在假时钟下留下
              // 永不完成的超时定时器。给一份不发请求的空快照即可。
              sessionSnapshotProvider.overrideWith(_NoSession.new),
            ],
            child: MaterialApp(
              home: Builder(
                builder: (context) {
                  container = ProviderScope.containerOf(context);
                  controller.configure(
                    context,
                    descriptor: const PlatformTableDescriptor<Object>(
                      kind: 'editable',
                      tableKey: purchaseOrderItemsTableKey,
                      columnKeys: _oldOrder,
                      rows: [],
                    ),
                  );
                  return const SizedBox();
                },
              ),
            ),
          ),
        );
        if (changeOwner) {
          container.read(owner.notifier).state = const AuthenticatedScope(
            userId: 'next-user',
          );
          await tester.pump();
        } else {
          controller.resetLayout();
        }
        controller.saveLayout(
          knownKeys: _oldOrder,
          order: _oldOrder,
          hidden: {'platform:note'},
          pinned: {'allowedOverReceiptPct'},
          widths: {'qty': 200},
        );
        final restored = PlatformTableLayoutNotifier(
          purchaseOrderItemsTableKey,
        ).decode(controller.layout.toJson())!;
        expect(restored.layoutVersion, purchaseOrderColumnLayoutVersion);
        expect(restored.order, _oldOrder);
        expect(restored.pinned, {'allowedOverReceiptPct'});
        expect(restored.hidden, {'platform:note'});
        expect(restored.widths, {'qty': 200});
      },
    );
  }
}

class _NoSession extends SessionSnapshotNotifier {
  @override
  Future<SessionSnapshot?> build() async => null;
}
