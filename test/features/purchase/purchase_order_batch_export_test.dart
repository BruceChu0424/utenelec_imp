// 采购任务工作台「进行中」段批量导出单据的实现级测试：
// 单份直存 PDF、多份打包 zip、部分失败不打断其余单据并汇总提示、进度回调。
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/purchase/widgets/purchase_order_batch_export.dart';
import 'package:uten_imp/core/print/isolated_print_pdf.dart';
import 'package:uten_imp/core/network/read_scope_revision.dart';

Map<String, dynamic> _fixture({
  required String id,
  required String billNo,
  int lines = 1,
}) => {
  'id': id,
  'contentDigest': 'a' * 64,
  'billNo': billNo,
  'billDate': '2026-10-19',
  'deliverDate': '2026-11-01',
  'companyName': '测试电器有限公司(虚构)',
  'companyPhone': '0760-12345678',
  'supplierName': '测试金属配件供应商(虚构)',
  'supplierContact': '测试联系人',
  'supplierPhone': '13800000000',
  'deliveryPlace': '五金仓库 A区',
  'currencyName': '人民币',
  'currencyCode': 'CNY',
  'settlementMethod': '月结',
  'totalOriginal': '1000.00',
  'priceMasked': false,
  'remark': '批量导出测试',
  'makerName': '测试制单员',
  'reviewerName': '',
  'statusLabel': '财务已通过',
  'lines': [
    for (var i = 0; i < lines; i++)
      {
        'id': 'line-$i',
        'goodsCode': 'MAT-$i',
        'goodsName': '测试货品 $i',
        'model': '45A',
        'spec': 'φ20',
        'colorName': '本色',
        'unitName': '个',
        'physicalQty': '100',
        'chargedQty': '100',
        'giftQty': '0',
        'material': '紫铜',
        'remark': '',
        'deliverDate': '2026-11-01',
      },
  ],
};

class _FakeApi extends ApiClient {
  _FakeApi(
    this.failIds, {
    this.pendingIds = const {},
    this.rejectedIds = const {},
    this.missingProof = false,
    this.proofFailure = false,
  }) : super(Dio());

  final Set<String> failIds;
  final Set<String> pendingIds;
  final Set<String> rejectedIds;
  final bool missingProof, proofFailure;
  final List<String> paths = [];
  final List<Object?> authorizations = [];

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    expectSync(path, '/purchase/orders/print-authorization');
    authorizations.add(body);
    if (proofFailure) throw ApiException('CONFLICT', '采购单已修改，请重新导出');
    return {};
  }

  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    paths.add(path);
    final id = path.split('/')[3];
    if (failIds.contains(id)) throw StateError('boom');
    if (rejectedIds.contains(id)) {
      throw ApiException('FINANCE_APPROVAL_REQUIRED', '采购单须财务审核通过后才能导出或打印');
    }
    final fixture = _fixture(
      id: id,
      billNo: 'CD20261019${(id.split('-').last).padLeft(6, '0')}',
    )..['statusLabel'] = pendingIds.contains(id) ? '改量待财务复核' : '财务已通过';
    if (missingProof) fixture.remove('contentDigest');
    return fixture;
  }
}

Future<void> _run(
  WidgetTester tester, {
  required ApiClient api,
  required List<({String id, String number})> documents,
  required Future<String> Function(
    Uint8List bytes,
    String filename, {
    bool Function()? stillCurrent,
  })
  saver,
  void Function(int done, int total)? onProgress,
  bool confirm = true,
  bool dismiss = false,
  bool Function()? stillCurrent,
  VoidCallback? beforeConfirm,
  VoidCallback? duringGenerate,
  ThemeData? theme,
  double textScale = 1,
}) async {
  late BuildContext captured;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [apiClientProvider.overrideWithValue(api)],
      child: MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) {
            captured = context;
            return const Scaffold(body: SizedBox.shrink());
          },
        ),
      ),
    ),
  );
  await tester.pump();
  final export = exportPurchaseOrderDocumentsBatch(
    captured,
    apiClient: api,
    documents: documents,
    onProgress: onProgress,
    saver: saver,
    stillCurrent: stillCurrent,
    // Business/caller regressions use the pure worker handler; a separate test
    // exercises the real isolate/worker lifecycle and responsiveness.
    generate: (PrintPdfRequest request) {
      duringGenerate?.call();
      return request.binaryRenderer!(request.binaryPayload!, request.fontBytes);
    },
  );
  await tester.pumpAndSettle();
  expect(find.text('确认导出采购单'), findsOneWidget);
  if (api is _FakeApi) expect(api.paths, isEmpty);
  beforeConfirm?.call();
  if (dismiss) {
    await tester.binding.handlePopRoute();
  } else {
    final button = find.text(confirm ? '确认导出' : '取消');
    await tester.ensureVisible(button);
    await tester.tap(button);
  }
  await tester.pumpAndSettle();
  expect(find.text('确认导出采购单'), findsNothing);
  await export;
}

bool _isPdf(Uint8List bytes) => String.fromCharCodes(bytes.take(5)) == '%PDF-';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('a single order saves one purchase-order PDF directly', (
    tester,
  ) async {
    final api = _FakeApi(const {});
    final saved = <String, Uint8List>{};
    await _run(
      tester,
      api: api,
      documents: const [(id: 'order-1', number: 'CD-1')],
      saver: (bytes, name, {stillCurrent}) async {
        saved[name] = bytes;
        return name;
      },
    );
    expect(api.paths, ['/purchase/orders/order-1/print-data']);
    expect(saved.keys, ['采购单-CD20261019000001.pdf']);
    expect(_isPdf(saved.values.single), isTrue);
    expect(api.authorizations, [
      {
        'documents': [
          {'id': 'order-1', 'contentDigest': 'a' * 64},
        ],
      },
    ]);
  });

  testWidgets('multiple orders are packed into one zip of PDFs', (
    tester,
  ) async {
    final api = _FakeApi(const {});
    final saved = <String, Uint8List>{};
    final progress = <String>[];
    await _run(
      tester,
      api: api,
      documents: const [
        (id: 'order-1', number: 'CD-1'),
        (id: 'order-2', number: 'CD-2'),
      ],
      saver: (bytes, name, {stillCurrent}) async {
        saved[name] = bytes;
        return name;
      },
      onProgress: (done, total) => progress.add('$done/$total'),
    );
    expect(api.paths.toSet(), {
      '/purchase/orders/order-1/print-data',
      '/purchase/orders/order-2/print-data',
    });
    expect(progress, ['1/2', '2/2']);
    expect((api.authorizations.single as Map)['documents'], hasLength(2));
    expect(saved.keys, ['采购单批量导出(2份).zip']);
    final entries = ZipDecoder().decodeBytes(saved.values.single).files;
    expect(entries.map((file) => file.name).toSet(), {
      '采购单-CD20261019000001.pdf',
      '采购单-CD20261019000002.pdf',
    });
    for (final file in entries) {
      expect(_isPdf(Uint8List.fromList(file.content)), isTrue);
    }
  });

  testWidgets('a failing order never blocks the rest and reports its number', (
    tester,
  ) async {
    final api = _FakeApi({'order-2'});
    final saved = <String, Uint8List>{};
    await _run(
      tester,
      api: api,
      documents: const [
        (id: 'order-1', number: 'CD-1'),
        (id: 'order-2', number: 'CD-2'),
        (id: 'order-3', number: 'CD-3'),
      ],
      saver: (bytes, name, {stillCurrent}) async {
        saved[name] = bytes;
        return name;
      },
    );
    expect(saved.keys, ['采购单批量导出(2份).zip']);
    expect(ZipDecoder().decodeBytes(saved.values.single).files, hasLength(2));
  });

  testWidgets('all failures surface one error and save nothing', (
    tester,
  ) async {
    final api = _FakeApi({'order-1', 'order-2'});
    var saves = 0;
    await _run(
      tester,
      api: api,
      documents: const [
        (id: 'order-1', number: 'CD-1'),
        (id: 'order-2', number: 'CD-2'),
      ],
      saver: (bytes, name, {stillCurrent}) async {
        saves++;
        return name;
      },
    );
    expect(saves, 0);
  });

  for (final missingProof in [true, false]) {
    testWidgets(
      'missing old-server proof or final changed document never saves ($missingProof)',
      (tester) async {
        final api = _FakeApi(
          const {},
          missingProof: missingProof,
          proofFailure: !missingProof,
        );
        var saves = 0;
        await _run(
          tester,
          api: api,
          documents: const [(id: 'order-1', number: 'CD-1')],
          saver: (bytes, name, {stillCurrent}) async {
            saves++;
            return name;
          },
        );
        expect(saves, 0);
        expect(api.authorizations, hasLength(missingProof ? 0 : 1));
      },
    );
  }

  testWidgets(
    'scope ABA while formatting retires the original bundle and never authorizes or saves it',
    (tester) async {
      final api = _FakeApi(const {});
      var saves = 0;
      late ProviderContainer container;
      await _run(
        tester,
        api: api,
        documents: const [(id: 'order-1', number: 'CD-1')],
        beforeConfirm: () => container = ProviderScope.containerOf(
          tester.element(find.byType(Scaffold)),
          listen: false,
        ),
        duringGenerate: () {
          container.read(readScopeRevisionProvider.notifier).state++;
          container.read(readScopeRevisionProvider.notifier).state++;
        },
        saver: (bytes, name, {stillCurrent}) async {
          saves++;
          return name;
        },
      );
      expect(saves, 0);
      expect(api.authorizations, isEmpty);
    },
  );

  for (final dismiss in [false, true]) {
    testWidgets(
      'cancel or back from confirmation makes no request ($dismiss)',
      (tester) async {
        final api = _FakeApi(const {});
        var saves = 0;
        await _run(
          tester,
          api: api,
          documents: const [(id: 'order-1', number: 'CD-1')],
          confirm: false,
          dismiss: dismiss,
          saver: (bytes, name, {stillCurrent}) async {
            saves++;
            return name;
          },
        );
        expect(api.paths, isEmpty);
        expect(saves, 0);
      },
    );
  }

  testWidgets('one order selected through multiple lines exports one PDF', (
    tester,
  ) async {
    final api = _FakeApi(const {});
    final saved = <String>[];
    await _run(
      tester,
      api: api,
      documents: const [
        (id: 'order-1', number: 'CD-1'),
        (id: 'order-1', number: 'CD-1'),
      ],
      beforeConfirm: () =>
          expect(find.textContaining('将导出 1 份采购单'), findsOneWidget),
      saver: (bytes, name, {stillCurrent}) async {
        saved.add(name);
        return name;
      },
    );
    expect(api.paths, hasLength(1));
    expect(saved.single, endsWith('.pdf'));
  });

  testWidgets('pending finance response never generates an output', (
    tester,
  ) async {
    final api = _FakeApi(const {}, pendingIds: {'order-1'});
    var saves = 0;
    await _run(
      tester,
      api: api,
      documents: const [(id: 'order-1', number: 'CD-1')],
      saver: (bytes, name, {stillCurrent}) async {
        saves++;
        return name;
      },
    );
    expect(saves, 0);
  });

  testWidgets(
    'a stale approved selection rejected by the server saves nothing',
    (tester) async {
      final api = _FakeApi(const {}, rejectedIds: {'order-1'});
      var saves = 0;
      await _run(
        tester,
        api: api,
        documents: const [(id: 'order-1', number: 'CD-1')],
        saver: (bytes, name, {stillCurrent}) async {
          saves++;
          return name;
        },
      );
      expect(api.paths, hasLength(1));
      expect(saves, 0);
    },
  );

  testWidgets('identity change while confirming prevents requests and saves', (
    tester,
  ) async {
    final api = _FakeApi(const {});
    var current = true;
    var saves = 0;
    await _run(
      tester,
      api: api,
      documents: const [(id: 'order-1', number: 'CD-1')],
      stillCurrent: () => current,
      beforeConfirm: () => current = false,
      saver: (bytes, name, {stillCurrent}) async {
        saves++;
        return name;
      },
    );
    expect(api.paths, isEmpty);
    expect(saves, 0);
  });

  testWidgets('confirmation fits a narrow dark window with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final api = _FakeApi(const {});
    var saves = 0;
    await _run(
      tester,
      api: api,
      documents: const [
        (id: 'order-1', number: 'CD20261020000001'),
        (id: 'order-2', number: 'CD20261020000002'),
      ],
      theme: ThemeData.dark(),
      textScale: 2,
      confirm: false,
      beforeConfirm: () => expect(tester.takeException(), isNull),
      saver: (bytes, name, {stillCurrent}) async {
        saves++;
        return name;
      },
    );
    expect(tester.takeException(), isNull);
    expect(api.paths, isEmpty);
    expect(saves, 0);
  });
}
