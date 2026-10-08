part of 'production_daily_report_exact_segment_test.dart';

void registerDailyReportSessionBoundaryTests() {
  for (final change in [
    'intent',
    'account',
    'confirmation-intent',
    'same-session',
  ]) {
    testWidgets(
      'report session fence preserves supplement acknowledgements: $change',
      (tester) async {
        late _ExactSegmentSession session;
        final submitted = <Map<String, dynamic>>[];
        final api = _api(
          previewResult: (body) => {
            'requiresSupplements': true,
            'lines': [
              for (final entry
                  in ((body['report'] as Map)['items'] as List).indexed)
                {
                  'inputLineIndex': entry.$1,
                  'sourceExecutionSegmentId':
                      (entry.$2 as Map)['executionSegmentId'],
                  'sourceSalesAllocationId':
                      (entry.$2 as Map)['executionSegmentSalesAllocationId'],
                  'actualQty': (entry.$2 as Map)['qty'],
                  'originalReportQty': 1,
                  'supplementQty': 1,
                  'requiresSupplement': true,
                  'fingerprint': 'frozen-${entry.$1}',
                },
            ],
          },
          responseOverride: (request) {
            if (request.path.endsWith('/cancelled-supplement')) {
              return {'id': 'cancelled-supplement', 'status': 'CANCELLED'};
            }
            if (request.method == 'POST' &&
                request.path.endsWith('/actual-output-supplements')) {
              submitted.add(Map<String, dynamic>.from(request.data as Map));
              if (submitted.length == 1) {
                if (change == 'intent') session.intentEpoch++;
                if (change == 'account') session.switchAccount();
              }
              return {
                'id': 'accepted-${submitted.length}',
                'status': 'PENDING',
              };
            }
            return null;
          },
        );
        await _pumpNewReport(
          tester,
          api,
          followSessionIdentity: true,
          extraPermissions: {
            Perm.productionExecutionView,
            productionSupplementRequestPermission,
          },
        );
        final container = ProviderScope.containerOf(
          tester.element(find.byType(ProductionDailyReportEditPage)),
        );
        session =
            container.read(sessionProvider.notifier) as _ExactSegmentSession;
        final grid = tester
            .widget<UtenEditableGrid<DailyGridRow>>(
              find.byType(UtenEditableGrid<DailyGridRow>),
            )
            .controller;
        final first = grid.rows.firstWhere((row) => !row.isSubRow);
        first.qty.text = '2';
        first.supplementRequestId = 'cancelled-supplement';
        final second = first.clone()
          ..planItemId = 'plan-item-2'
          ..executionSegmentId = 'segment-2'
          ..supplementRequestId = null;
        grid.addRow(second);
        grid.setSelected([second], true);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
        await tester.pumpAndSettle();
        expect(find.text('提交 2 份追加计划审批'), findsOneWidget);
        if (change == 'confirmation-intent') session.intentEpoch++;
        await tester.tap(find.text('提交 2 份追加计划审批'));
        await tester.pumpAndSettle();
        expect(
          submitted,
          hasLength(
            change == 'confirmation-intent'
                ? 0
                : change == 'same-session'
                ? 2
                : 1,
          ),
        );
        expect(
          first.supplementRequestId,
          change == 'confirmation-intent' ? isNull : 'accepted-1',
        );
        expect(
          second.supplementRequestId,
          change == 'same-session' ? 'accepted-2' : isNull,
        );
        expect(first.qty.text, '2');
        expect(second.qty.text, '2');
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'report session fence retains original create proof when intent changes before receipt read',
    (tester) async {
      late _ExactSegmentSession session;
      Map<String, dynamic>? acceptedBody;
      var receiptReads = 0;
      final api = _api(
        responseOverride: (request) {
          if (request.method == 'POST' &&
              request.path.endsWith('/daily-reports')) {
            acceptedBody = Map<String, dynamic>.from(request.data as Map);
            session.intentEpoch++;
            return {'id': 'accepted-report', 'status': 0, 'items': <dynamic>[]};
          }
          if (request.path.endsWith('/daily-reports/create-receipt')) {
            receiptReads++;
            return _createProofBody(
              Map<String, dynamic>.from(request.data as Map),
              'accepted-report',
            );
          }
          return null;
        },
      );
      await _pumpNewReport(tester, api);
      final page = tester.element(find.byType(ProductionDailyReportEditPage));
      final container = ProviderScope.containerOf(page);
      session =
          container.read(sessionProvider.notifier) as _ExactSegmentSession;
      _productRows(tester).first.qty.text = '2';
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('uten-edit-save')));
      await tester.pumpAndSettle();
      expect(acceptedBody, isNotNull);
      expect(receiptReads, 0);
      final draft = container.read(formDraftsProvider).single;
      expect(draft.hasUnknownSubmission, isTrue);
      expect(draft.data['idempotencyKey'], acceptedBody!['idempotencyKey']);
      expect(tester.takeException(), isNull);
    },
  );
}
