import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uten_imp/core/l10n/gen/app_localizations.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_endpoints.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/core/router/route_names.dart';
import 'package:uten_imp/core/theme/light_theme.dart';
import 'package:uten_imp/core/ui/app_notification.dart';
import 'package:uten_imp/features/basic_data/widgets/master_data_table_view.dart';
import 'package:uten_imp/features/quality/pages/production_fqc_handling_page.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft_navigation.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';
import '../../support/audit_screenshot_support.dart';

const _id = '10000000-0000-0000-0000-000000000001';
const _id2 = '10000000-0000-0000-0000-000000000002';
const _id3 = '10000000-0000-0000-0000-000000000003';
const _sheetId = '20000000-0000-0000-0000-000000000001';
const _nextSheetId = '20000000-0000-0000-0000-000000000002';
final _scope = StateProvider<AuthenticatedScope?>(
  (ref) => const AuthenticatedScope(userId: 'quality-user'),
);
final _server = StateProvider<String>((ref) => 'https://fqc-test.example/api');

void main() {
  for (final sheet in [false, true]) {
    for (final change in ['account', 'server']) {
      Future<void> aba(WidgetTester tester, ProviderContainer container) async {
        final owner = container.read(_scope);
        final server = container.read(_server);
        if (change == 'account') {
          container.read(_scope.notifier).state = const AuthenticatedScope(
            userId: 'other',
          );
        } else {
          container.read(_server.notifier).state = 'https://other.example/api';
        }
        await tester.pump();
        if (change == 'account') {
          container.read(_scope.notifier).state = owner;
        } else {
          container.read(_server.notifier).state = server;
        }
        await tester.pump();
      }

      testWidgets(
        'ABA FQC sheet=$sheet $change initial read cannot revive the old view',
        (tester) async {
          final gate = Completer<void>();
          final api = _FqcApi()
            ..readGates[sheet ? _sheetId : _id] = gate.future;
          final env = await _mount(tester, api, sheet: sheet, settle: false);
          await aba(tester, env.container);
          gate.complete();
          await tester.pumpAndSettle();
          expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
          expect(
            find.byKey(
              Key(
                sheet
                    ? 'fqc-sheet-submit-report'
                    : 'fqc-inspection-submit-report',
              ),
            ),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
      for (final beforeSend in [false, true]) {
        testWidgets(
          'ABA FQC sheet=$sheet $change beforeSend=$beforeSend keeps original evidence and blocks late publication',
          (tester) async {
            final gate = Completer<void>();
            final storage = _MemoryStorage();
            final api = _FqcApi();
            final env = await _mount(
              tester,
              api,
              sheet: sheet,
              storage: storage,
            );
            if (beforeSend) {
              storage.beforeWrite = (value) async {
                if (((jsonDecode(value) as Map)['data']
                        as Map?)?['_formDraftSubmissionPending'] ==
                      true) {
                  await gate.future;
                }
              };
            } else {
              api.responseGate = gate.future;
            }
            final location = env.router.routerDelegate.currentConfiguration.uri;
            await _startSubmit(tester, sheet: sheet);
            final frozen = beforeSend
                ? null
                : Map<String, String>.of(storage.records);
            await aba(tester, env.container);
            gate.complete();
            await tester.pumpAndSettle();
            expect(api.calls, hasLength(beforeSend ? 0 : 1));
            expect(
              env.container
                  .read(appNotificationProvider)
                  .where(
                    (notice) => notice.kind == AppNotificationKind.success,
                  ),
              isEmpty,
            );
            expect(
              env.router.routerDelegate.currentConfiguration.uri,
              location,
            );
            if (frozen != null) expect(storage.records, frozen);
            expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  for (final sheet in [false, true]) {
    testWidgets(
      'unknown ${sheet ? 'sheet' : 'single'} GET failure preserves frozen disk and permits exit',
      (tester) async {
        final api = _FqcApi()..outcomes.add(NetworkTimeoutException());
        final storage = _MemoryStorage();
        var env = await _mount(tester, api, sheet: sheet, storage: storage);
        await _submit(tester, sheet: sheet);
        final resume = env.container
            .read(formDraftsProvider)
            .single
            .resumeLocation;
        await _unmount(tester, env);
        final before = Map<String, String>.of(storage.records);
        api.failReads = true;
        env = await _mount(
          tester,
          api,
          sheet: sheet,
          storage: storage,
          initial: resume,
        );
        env.router.go('/other');
        await tester.pumpAndSettle();
        expect(find.text('新页面'), findsOneWidget);
        expect(storage.records, before);
        expect(api.calls, hasLength(1));
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      'unknown exit retains legacy ${sheet ? 'sheet' : 'single'} row command without generic marker',
      (tester) async {
        final api = _FqcApi()..outcomes.add(NetworkTimeoutException());
        final storage = _MemoryStorage();
        var env = await _mount(tester, api, sheet: sheet, storage: storage);
        await _submit(tester, sheet: sheet);
        final original = Map<String, dynamic>.from(api.calls.single.body);
        final resume = env.container
            .read(formDraftsProvider)
            .single
            .resumeLocation;
        await _unmount(tester, env);
        for (final key in storage.records.keys.toList()) {
          final saved =
              jsonDecode(storage.records[key]!) as Map<String, dynamic>;
          (saved['data'] as Map).remove('_formDraftSubmissionPending');
          (saved['data'] as Map).remove('_formDraftHasUnknownSubmission');
          storage.records[key] = jsonEncode(saved);
        }
        env = await _mount(
          tester,
          api,
          sheet: sheet,
          storage: storage,
          initial: resume,
        );
        env.router.go('/other');
        await tester.pumpAndSettle();
        expect(find.text('不保存'), findsNothing);
        expect(find.text('继续核对'), findsOneWidget);
        await tester.tap(find.text('保存原提交后离开'));
        await tester.pumpAndSettle();
        expect(find.text('新页面'), findsOneWidget);
        expect(storage.records, hasLength(1));
        await _unmount(tester, env);
        env = await _mount(
          tester,
          api,
          sheet: sheet,
          storage: storage,
          initial: resume,
        );
        await _submit(tester, sheet: sheet, recovery: true);
        expect(api.calls, hasLength(2));
        expect(api.calls.last.body, original);
        expect(api.commits, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
  if (const bool.fromEnvironment('UTEN_CAPTURE_UI')) {
    for (final shot in [
      'single-unknown',
      'sheet-partial',
      'original-confirm',
      'partial-remainder',
    ]) {
      testWidgets('FQC恢复视觉 $shot', (tester) async {
        await loadAuditScreenshotFonts(tester);
        final boundary = GlobalKey();
        final sheet = shot == 'sheet-partial' || shot == 'partial-remainder';
        final api = _FqcApi(ids: sheet ? [_id, _id2, _id3] : [_id]);
        if (shot != 'partial-remainder') {
          api.outcomes.addAll([if (sheet) null, NetworkTimeoutException()]);
        }
        await _mount(
          tester,
          api,
          sheet: sheet,
          boundary: boundary,
          size: sheet ? const Size(1400, 1050) : const Size(390, 950),
          textScale: sheet ? 1 : 1.2,
        );
        if (shot == 'partial-remainder') {
          _rows(tester, sheet: true).first.pass.text = '3';
          await _select(tester, {_id});
        }
        await _submit(tester, sheet: sheet);
        if (shot == 'original-confirm') {
          await tester.tap(
            find.byKey(const Key('fqc-inspection-submit-report')),
          );
          await tester.pumpAndSettle();
        }
        expect(tester.takeException(), isNull);
        await saveAuditScreenshot(tester, boundary, 'fqc-recovery-$shot');
      });
    }
  }
  for (final sheet in [false, true]) {
    testWidgets(
      '${sheet ? 'sheet' : 'single'} partial confirmation and failed refresh waits for fresh remaining quantity',
      (tester) async {
        final api = _FqcApi();
        await _mount(tester, api, sheet: sheet);
        final before = _rows(tester, sheet: sheet).single;
        before.pass.text = '3';
        final originalKey = before.idempotencyKey;
        api.afterPost = () => api.failReads = true;
        await _submit(tester, sheet: sheet);
        expect(api.commits, 1);
        expect(find.textContaining('待检已全部处理完成'), findsNothing);
        expect(
          find.byKey(
            Key(
              sheet
                  ? 'fqc-sheet-submit-report'
                  : 'fqc-inspection-submit-report',
            ),
          ),
          findsNothing,
        );
        api.failReads = false;
        api.afterPost = null;
        await tester.tap(find.byTooltip('刷新').last);
        await tester.pumpAndSettle();
        final remaining = _rows(tester, sheet: sheet).single;
        expect(remaining.inspection.remainingQty, 7);
        expect(remaining.completed, isFalse);
        expect(remaining.idempotencyKey, isNot(originalKey));
        final checkpoint = remaining.toFormDraft();
        expect(checkpoint['confirmedSubmissionCount'], 1);
        expect(
          (checkpoint['lastConfirmedSubmission'] as Map)['idempotencyKey'],
          originalKey,
        );
        expect(checkpoint.containsKey('confirmedSubmissions'), isFalse);
        if (sheet) {
          expect(remaining.selected, isFalse);
          await _select(tester, {_id});
        }
        await _submit(tester, sheet: sheet);
        expect(api.calls.map((call) => call.body['passQty']), [3, 7]);
        expect(
          api.calls.map((call) => call.body['idempotencyKey']).toSet(),
          hasLength(2),
        );
        expect(api.commits, 2);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${sheet ? 'sheet' : 'single'} same route different document preserves ordinary busy onExit',
      (tester) async {
        final gate = Completer<void>();
        final api = _FqcApi()..responseGate = gate.future;
        final env = await _mount(tester, api, sheet: sheet);
        final oldLocation =
            env.router.routerDelegate.currentConfiguration.uri.path;
        await _startSubmit(tester, sheet: sheet);
        env.router.go(
          sheet
              ? RouteName.productionFqcSheetHandling(_nextSheetId)
              : RouteName.productionFqcInspectionHandling(_id2),
        );
        await tester.pump(const Duration(milliseconds: 400));
        expect(
          env.router.routerDelegate.currentConfiguration.uri.path,
          oldLocation,
        );
        gate.complete();
        await tester.pumpAndSettle();
        expect(api.calls, hasLength(1));
      },
    );
    testWidgets(
      '${sheet ? 'sheet' : 'single'} same route different document after saved unknown keeps separate draft owners',
      (tester) async {
        final api = _FqcApi()..outcomes.add(NetworkTimeoutException());
        final env = await _mount(tester, api, sheet: sheet);
        final page = find.byType(
          sheet ? ProductionFqcSheetHandlingPage : ProductionFqcInspectionPage,
        );
        final oldState = tester.state(page);
        await _submit(tester, sheet: sheet);
        final oldDraft = env.container.read(formDraftsProvider).single;
        final nextLocation = sheet
            ? RouteName.productionFqcSheetHandling(_nextSheetId)
            : RouteName.productionFqcInspectionHandling(_id2);
        env.router.go(nextLocation);
        await tester.pumpAndSettle();
        await tester.tap(find.text('保存原提交后离开'));
        await tester.pumpAndSettle();
        expect(identical(oldState, tester.state(page)), isFalse);
        final nextRows = _rows(tester, sheet: sheet);
        expect(nextRows.single.inspection.id, sheet ? _id3 : _id2);
        nextRows.single.pass.text = '5';
        await tester.pumpAndSettle();
        final drafts = env.container.read(formDraftsProvider);
        final old = drafts.singleWhere((draft) => draft.id == oldDraft.id);
        expect(old.route, oldDraft.route);
        expect(old.data, oldDraft.data);
        final next = drafts.singleWhere(
          (draft) => Uri.parse(draft.route).path == nextLocation,
        );
        final nextRow =
            (sheet ? (next.data['rows'] as List).first : next.data['row'])
                as Map;
        expect(nextRow['inspectionId'], sheet ? _id3 : _id2);
        expect(nextRow['submission'], isNull);
        expect(api.calls, hasLength(1));
      },
    );
    testWidgets(
      '${sheet ? 'sheet' : 'single'} same route different document ignores initial delayed GET',
      (tester) async {
        final gate = Completer<void>();
        final api = _FqcApi();
        api.readGates[sheet ? _sheetId : _id] = gate.future;
        final env = await _mount(tester, api, sheet: sheet, settle: false);
        final nextLocation = sheet
            ? RouteName.productionFqcSheetHandling(_nextSheetId)
            : RouteName.productionFqcInspectionHandling(_id2);
        env.router.go(nextLocation);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pump(const Duration(milliseconds: 400));
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          _rows(tester, sheet: sheet).single.inspection.id,
          sheet ? _id3 : _id2,
        );
        expect(api.calls, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${sheet ? 'sheet' : 'single'} same route different document after identity switch preserves old draft during pending write',
      (tester) async {
        final gate = Completer<void>();
        final api = _FqcApi(ids: [_id, _id2])..responseGate = gate.future;
        final env = await _mount(tester, api, sheet: sheet);
        final pageFinder = find.byType(
          sheet ? ProductionFqcSheetHandlingPage : ProductionFqcInspectionPage,
        );
        final oldState = tester.state(pageFinder);
        await _startSubmit(tester, sheet: sheet);
        final oldDraft = env.container.read(formDraftsProvider).single;
        final nextLocation = sheet
            ? RouteName.productionFqcSheetHandling(_nextSheetId)
            : RouteName.productionFqcInspectionHandling(_id2);
        final nextInspection = sheet ? _id3 : _id2;
        // The real onExit guard allows leaving the previous identity. A normal
        // same-identity in-flight exit remains blocked by that existing guard.
        env.container.read(_scope.notifier).state = const AuthenticatedScope(
          userId: 'next-quality-user',
        );
        await tester.pump(const Duration(milliseconds: 400));
        env.router.go(nextLocation);
        // The old request is deliberately still running while the route changes.
        await tester.pumpAndSettle();
        final stateWasReused = identical(oldState, tester.state(pageFinder));
        final displayedIds = <String>[];
        if (!stateWasReused) {
          final newRows = _rows(tester, sheet: sheet);
          displayedIds.addAll(newRows.map((row) => row.inspection.id));
          newRows.first.pass.text = '5';
        }
        await tester.pump(const Duration(milliseconds: 400));
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          stateWasReused,
          isFalse,
          reason:
              'A route-pattern pageKey does not separate document draft owners',
        );
        expect(displayedIds, [nextInspection]);
        expect(api.calls.map((call) => call.id), [_id]);
        expect(
          env.router.routeInformationProvider.value.uri.path,
          nextLocation,
        );
        expect(
          env.container
              .read(appNotificationProvider)
              .where((notice) => notice.kind == AppNotificationKind.success),
          isEmpty,
        );
        final drafts = env.container.read(formDraftsProvider);
        final preserved = env.storage.records.values
            .map((value) => jsonDecode(value) as Map)
            .singleWhere((record) => record['id'] == oldDraft.id);
        expect(preserved['route'], oldDraft.route);
        expect(preserved['data'], oldDraft.data);
        expect(
          drafts.map((draft) => Uri.parse(draft.route).path),
          contains(nextLocation),
        );
        final current = drafts.singleWhere(
          (draft) => Uri.parse(draft.route).path == nextLocation,
        );
        final currentRow =
            (sheet ? (current.data['rows'] as List).first : current.data['row'])
                as Map;
        expect(currentRow['inspectionId'], nextInspection);
        expect(currentRow['pass'], '5');
        expect(current.id, isNot(oldDraft.id));
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${sheet ? 'sheet' : 'single'} route change during pre-send draft write sends zero requests',
      (tester) async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final storage = _MemoryStorage();
        final api = _FqcApi();
        final env = await _mount(tester, api, sheet: sheet, storage: storage);
        storage.beforeWrite = (value) async {
          final data = (jsonDecode(value) as Map)['data'] as Map;
          if (data['_formDraftSubmissionPending'] == true &&
              !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        await _startSubmit(tester, sheet: sheet);
        expect(entered.isCompleted, isTrue);
        unawaited(env.router.push('/other'));
        await tester.pump(const Duration(milliseconds: 400));
        release.complete();
        await tester.pumpAndSettle();
        expect(api.calls, isEmpty);
        expect(find.text('新页面'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${sheet ? 'sheet' : 'single'} pre-stocked cancelled replay reports original confirmation without new warehouse promise',
      (tester) async {
        final api = _FqcApi()
          ..preStocked = true
          ..outcomes.add('commit-timeout');
        final env = await _mount(tester, api, sheet: sheet);
        await _submit(tester, sheet: sheet);
        api.statusOverride = 'CANCELLED';
        await _submit(tester, sheet: sheet, recovery: true);
        expect(api.commits, 1);
        expect(api.calls, hasLength(2));
        expect(
          env.container
              .read(appNotificationProvider)
              .map((notice) => notice.message),
          contains(contains('原提交已确认')),
        );
        expect(
          env.container
              .read(appNotificationProvider)
              .map((notice) => notice.message),
          isNot(contains(contains('已转仓库待最终点收'))),
        );
        expect(find.textContaining('已转仓库待最终点收'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
    for (final change in ['identity', 'server', 'route']) {
      testWidgets(
        '${sheet ? 'sheet' : 'single'} late success cannot publish into changed $change',
        (tester) async {
          final responseGate = Completer<void>();
          final api = _FqcApi()..responseGate = responseGate.future;
          final env = await _mount(tester, api, sheet: sheet);
          final button = find.byKey(
            Key(
              sheet
                  ? 'fqc-sheet-submit-report'
                  : 'fqc-inspection-submit-report',
            ),
          );
          await tester.ensureVisible(button);
          await tester.tap(button);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const Key('inspection-report-confirm-submit')),
          );
          await tester.pump(const Duration(milliseconds: 400));
          expect(api.calls, hasLength(1));
          switch (change) {
            case 'identity':
              env.container.read(_scope.notifier).state =
                  const AuthenticatedScope(userId: 'another-user');
            case 'server':
              env.container.read(_server.notifier).state =
                  'https://another.example/api';
            case 'route':
              unawaited(env.router.push('/other'));
          }
          await tester.pump(const Duration(milliseconds: 400));
          responseGate.complete();
          await tester.pumpAndSettle();
          expect(api.commits, 1);
          expect(find.textContaining('质检决定已确认保存'), findsNothing);
          expect(find.textContaining('检验报告已确认'), findsNothing);
          expect(
            env.container
                .read(appNotificationProvider)
                .where((notice) => notice.kind == AppNotificationKind.success),
            isEmpty,
          );
          if (change == 'route') {
            expect(find.text('新页面'), findsOneWidget);
            expect(env.router.canPop(), isTrue);
          } else {
            expect(find.textContaining('登录身份或服务器已变化'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
        },
      );
    }
    for (final status in [400, 422]) {
      testWidgets(
        '${sheet ? 'sheet' : 'single'} uncertain attempt then $status never unlocks original body',
        (tester) async {
          final api = _FqcApi()..outcomes.add(NetworkTimeoutException());
          final env = await _mount(tester, api, sheet: sheet);
          await _submit(tester, sheet: sheet);
          final original = Map<String, dynamic>.from(api.calls.single.body);
          api.outcomes.add(
            ApiException(
              status == 400 ? 'BUSINESS' : 'VALIDATION_FAILED',
              '本次请求被拒绝',
              httpStatus: status,
            ),
          );
          await _submit(tester, sheet: sheet, recovery: true);
          expect(api.calls.last.body, original);
          expect(
            _rows(tester, sheet: sheet).single.submission,
            isNotNull,
            reason:
                'A later rejected attempt cannot disprove the earlier unknown commit',
          );
          expect(_savedRow(env)['submission'], isNotNull);
          expect(
            env.container
                .read(formDraftsProvider)
                .single
                .data['_formDraftSubmissionPending'],
            isTrue,
          );
        },
      );
    }
    testWidgets(
      '${sheet ? 'sheet' : 'single'} bare 400 without application rejection evidence remains uncertain',
      (tester) async {
        final api = _FqcApi()
          ..outcomes.add(ApiException('UNKNOWN', '代理请求失败', httpStatus: 400));
        await _mount(tester, api, sheet: sheet);
        await _submit(tester, sheet: sheet);
        expect(_rows(tester, sheet: sheet).single.submission, isNotNull);
        expect(find.textContaining('待核对 1 行'), findsOneWidget);
      },
    );
    for (final status in [400, 422]) {
      testWidgets(
        '${sheet ? 'sheet' : 'single'} first $status rejects and permits correction',
        (tester) async {
          final api = _FqcApi()
            ..outcomes.add(
              ApiException(
                status == 400 ? 'BUSINESS' : 'VALIDATION_FAILED',
                '数量校验未通过',
                httpStatus: status,
              ),
            );
          final env = await _mount(tester, api, sheet: sheet);
          await _submit(tester, sheet: sheet);
          final row = _rows(tester, sheet: sheet).single;
          expect(row.submission, isNull);
          expect(find.textContaining('明确拒绝 1 行'), findsOneWidget);
          expect(_savedRow(env).containsKey('submissionState'), isTrue);
          expect(
            env.container
                .read(formDraftsProvider)
                .single
                .data['_formDraftSubmissionPending'],
            isNull,
          );
          row.pass.text = '8';
          await _submit(tester, sheet: sheet);
          expect(api.calls, hasLength(2));
          expect(api.calls.last.body['passQty'], 8);
          expect(api.commits, 1);
          expect(tester.takeException(), isNull);
        },
      );
    }
    for (final error in [
      NetworkTimeoutException(),
      ApiException('INTERNAL', '服务器繁忙', httpStatus: 500),
    ]) {
      testWidgets(
        '${sheet ? 'sheet' : 'single'} ${error.code} stays unknown across pending GET and later 422',
        (tester) async {
          final api = _FqcApi()..outcomes.add(error);
          final env = await _mount(tester, api, sheet: sheet);
          api.beforePost = () {
            final draft = env.container.read(formDraftsProvider).single;
            expect(draft.data['_formDraftSubmissionPending'], isTrue);
            expect(_savedRow(env)['submissionState'], 'unknown');
            expect(_savedRow(env)['submission'], isNotNull);
          };
          await _submit(tester, sheet: sheet);
          expect(find.textContaining('待核对 1 行'), findsOneWidget);
          final original = Map<String, dynamic>.from(api.calls.single.body);
          api.outcomes.add(
            ApiException('VALIDATION_FAILED', '后续请求被拒绝', httpStatus: 422),
          );
          await _submit(tester, sheet: sheet, recovery: true);
          expect(api.calls.last.body, original);
          expect(_savedRow(env)['submission'], isNotNull);
          expect(
            env.container
                .read(formDraftsProvider)
                .single
                .data['_formDraftSubmissionPending'],
            isTrue,
          );
          expect(find.textContaining('待核对 1 行'), findsOneWidget);
          expect(find.textContaining('登记被拒'), findsNothing);
          expect(tester.takeException(), isNull);
        },
      );
    }
    testWidgets(
      '${sheet ? 'sheet' : 'single'} committed response loss and failed reads replay one command after restart',
      (tester) async {
        final api = _FqcApi()..outcomes.add('commit-timeout');
        final storage = _MemoryStorage();
        var env = await _mount(tester, api, sheet: sheet, storage: storage);
        final row = _rows(tester, sheet: sheet).single;
        row.pass.text = '8';
        row.fail.text = '2';
        row.disposition = 'SCRAP';
        api.afterPost = () => api.failReads = true;
        await _submit(tester, sheet: sheet, reason: '表面划痕');
        final original = Map<String, dynamic>.from(api.calls.single.body);
        expect(api.commits, 1);
        expect(find.textContaining('待核对 1 行'), findsOneWidget);
        final resume = env.container
            .read(formDraftsProvider)
            .single
            .resumeLocation;
        // Exercise legacy compatibility: the previous version had no outcome fields.
        for (final key in storage.records.keys.toList()) {
          final record =
              jsonDecode(storage.records[key]!) as Map<String, dynamic>;
          final data = record['data'] as Map<String, dynamic>;
          final savedRows = sheet ? data['rows'] as List : [data['row']];
          for (final saved in savedRows.cast<Map<String, dynamic>>()) {
            saved.remove('submissionState');
            saved.remove('submissionMessage');
            saved.remove('decisionEventId');
          }
          storage.records[key] = jsonEncode(record);
        }
        await _unmount(tester, env);
        api.failReads = false;
        api.afterPost = null;
        env = await _mount(
          tester,
          api,
          sheet: sheet,
          storage: storage,
          initial: resume,
        );
        expect(find.textContaining('待核对 1 行'), findsOneWidget);
        await _submit(tester, sheet: sheet, recovery: true);
        expect(api.calls.last.body, original);
        expect(api.commits, 1);
        expect(api.calls, hasLength(2));
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${sheet ? 'sheet' : 'single'} missing durable checkpoint sends nothing',
      (tester) async {
        final storage = _MemoryStorage();
        final api = _FqcApi();
        await _mount(tester, api, sheet: sheet, storage: storage);
        storage.failWrites = true;
        await _submit(tester, sheet: sheet);
        expect(api.calls, isEmpty);
        expect(find.textContaining('本行未发送'), findsOneWidget);
        expect(find.textContaining('待核对 1 行'), findsNothing);
        storage.failWrites = false;
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets(
      '${sheet ? 'sheet' : 'single'} confirmed response survives failed local save and refresh',
      (tester) async {
        final storage = _MemoryStorage();
        final api = _FqcApi();
        await _mount(tester, api, sheet: sheet, storage: storage);
        api.afterPost = () {
          storage.failWrites = true;
          api.failReads = true;
        };
        await _submit(tester, sheet: sheet);
        expect(api.commits, 1);
        expect(api.calls, hasLength(1));
        expect(find.textContaining('已确认 1 次提交'), findsOneWidget);
        expect(
          find.byKey(
            Key(
              sheet
                  ? 'fqc-sheet-submit-report'
                  : 'fqc-inspection-submit-report',
            ),
          ),
          findsNothing,
        );
        expect(find.textContaining('登记被拒'), findsNothing);
        expect(tester.takeException(), isNull);
        storage.failWrites = false;
      },
    );
    testWidgets(
      '${sheet ? 'sheet' : 'single'} permission withdrawal retains uncertain original',
      (tester) async {
        final api = _FqcApi()..outcomes.add(NetworkTimeoutException());
        final env = await _mount(tester, api, sheet: sheet);
        await _submit(tester, sheet: sheet);
        final original = Map<String, dynamic>.from(_savedRow(env));
        api.outcomes.add(ApiException('FORBIDDEN', '审批权限已撤回', httpStatus: 403));
        api.afterPost = () => api.canDecide = false;
        await _submit(tester, sheet: sheet, recovery: true);
        expect(find.textContaining('当前无办理权限'), findsOneWidget);
        expect(_savedRow(env)['submission'], original['submission']);
        expect(_savedRow(env)['idempotencyKey'], original['idempotencyKey']);
        expect(
          env.container
              .read(formDraftsProvider)
              .single
              .data['_formDraftSubmissionPending'],
          isTrue,
        );
        expect(
          find.byKey(
            Key(
              sheet
                  ? 'fqc-sheet-submit-report'
                  : 'fqc-inspection-submit-report',
            ),
          ),
          findsNothing,
        );
        api.canDecide = true;
        api.afterPost = null;
        await tester.tap(find.byTooltip('刷新').last);
        await tester.pumpAndSettle();
        await _submit(tester, sheet: sheet, recovery: true);
        expect(
          api.calls.last.body['idempotencyKey'],
          original['idempotencyKey'],
        );
        expect(api.calls.last.body, api.calls.first.body);
        expect(api.commits, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'sheet stops at uncertain second line; confirmed first is never resent; third stays unsent',
    (tester) async {
      final api = _FqcApi(ids: [_id, _id2, _id3])
        ..outcomes.addAll([null, NetworkTimeoutException()]);
      final env = await _mount(tester, api, sheet: true);
      await _submit(tester, sheet: true);
      expect(api.calls.map((call) => call.id), [_id, _id2]);
      expect(
        find.textContaining('已确认 1 次提交 · 明确拒绝 0 行 · 待核对 1 行 · 未提交 1 行'),
        findsOneWidget,
      );
      final original = api.calls.last.body;
      final resume = env.container
          .read(formDraftsProvider)
          .single
          .resumeLocation;
      await _unmount(tester, env);
      await _mount(
        tester,
        api,
        sheet: true,
        storage: env.storage,
        initial: resume,
      );
      await _submit(tester, sheet: true, recovery: true);
      expect(api.calls.map((call) => call.id), [_id, _id2, _id2]);
      expect(api.calls.last.body, original);
      await _submit(tester, sheet: true);
      expect(api.calls.map((call) => call.id), [_id, _id2, _id2, _id3]);
      expect(api.commits, 3);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'sheet partial confirmation exposes remainder without overwriting unselected input',
    (tester) async {
      final api = _FqcApi(ids: [_id, _id2]);
      await _mount(tester, api, sheet: true);
      final original = _rows(tester, sheet: true);
      original.first.pass.text = '3';
      original.last.pass.text = '4';
      original.last.fail.text = '1';
      original.last.disposition = 'SCRAP';
      final otherKey = original.last.idempotencyKey;
      final originalKey = original.first.idempotencyKey;
      await _select(tester, {_id});
      await _submit(tester, sheet: true);
      final rows = _rows(tester, sheet: true);
      final remainder = rows.singleWhere((row) => row.inspection.id == _id);
      final other = rows.singleWhere((row) => row.inspection.id == _id2);
      expect(remainder.pass.text, '7');
      expect(remainder.selected, isFalse);
      expect(remainder.completed, isFalse);
      expect(remainder.idempotencyKey, isNot(originalKey));
      expect(other.pass.text, '4');
      expect(other.fail.text, '1');
      expect(other.disposition, 'SCRAP');
      expect(other.idempotencyKey, otherKey);
      expect(other.selected, isFalse);
      expect(api.calls, hasLength(1));
      await _select(tester, {_id});
      await _submit(tester, sheet: true);
      expect(api.calls.map((call) => call.body['passQty']), [3, 7]);
      expect(api.calls.every((call) => call.id == _id), isTrue);
      expect(_rows(tester, sheet: true).single.pass.text, '4');
    },
  );
  testWidgets(
    'sheet partial confirmation keeps other unknown body while remainder waits unselected',
    (tester) async {
      final api = _FqcApi(ids: [_id, _id2])
        ..outcomes.addAll([null, NetworkTimeoutException()]);
      await _mount(tester, api, sheet: true);
      _rows(tester, sheet: true).first.pass.text = '3';
      await _submit(tester, sheet: true);
      final unknownBody = Map<String, dynamic>.from(api.calls.last.body);
      final remainder = _rows(
        tester,
        sheet: true,
      ).singleWhere((row) => row.inspection.id == _id);
      expect(remainder.pass.text, '7');
      expect(remainder.selected, isFalse);
      await _submit(tester, sheet: true, recovery: true);
      expect(api.calls.map((call) => call.id), [_id, _id2, _id2]);
      expect(api.calls.last.body, unknownBody);
      await _select(tester, {_id});
      await _submit(tester, sheet: true);
      expect(api.calls.map((call) => call.body['passQty']), [3, 10, 10, 7]);
      expect(api.commits, 3);
      expect(
        api.calls.first.body['idempotencyKey'],
        isNot(api.calls.last.body['idempotencyKey']),
      );
    },
  );
  testWidgets(
    'sheet route change during confirmed checkpoint stops before second request',
    (tester) async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final storage = _MemoryStorage();
      final api = _FqcApi(ids: [_id, _id2]);
      final env = await _mount(tester, api, sheet: true, storage: storage);
      storage.beforeWrite = (value) async {
        final data = (jsonDecode(value) as Map)['data'] as Map;
        if (((data['rows'] as List?)?.first as Map?)?['completed'] == true &&
            !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      await _startSubmit(tester, sheet: true);
      expect(entered.isCompleted, isTrue);
      expect(api.calls.map((call) => call.id), [_id]);
      unawaited(env.router.push('/other'));
      await tester.pump(const Duration(milliseconds: 400));
      release.complete();
      await tester.pumpAndSettle();
      expect(api.calls.map((call) => call.id), [_id]);
      expect(find.text('新页面'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}

typedef _Env = ({
  GoRouter router,
  ProviderContainer container,
  _MemoryStorage storage,
  bool sheet,
});

Future<_Env> _mount(
  WidgetTester tester,
  _FqcApi api, {
  bool sheet = false,
  _MemoryStorage? storage,
  String? initial,
  GlobalKey? boundary,
  Size size = const Size(1500, 1300),
  double textScale = 1,
  bool settle = true,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  SharedPreferences.setMockInitialValues({});
  final preferences = await SharedPreferences.getInstance();
  final store = storage ?? _MemoryStorage();
  final container = ProviderContainer(
    overrides: [
      apiClientProvider.overrideWithValue(api),
      authenticatedScopeProvider.overrideWith((ref) => ref.watch(_scope)),
      apiBaseUrlProvider.overrideWith((ref) => ref.watch(_server)),
      currentPermissionsProvider.overrideWithValue({
        Perm.productionQualityInspectionView,
        Perm.productionQualityInspectionApprove,
      }),
      isSuperAdminProvider.overrideWithValue(false),
      sharedPreferencesProvider.overrideWithValue(preferences),
      formDraftStorageProvider.overrideWithValue(store),
    ],
  );
  final router = GoRouter(
    initialLocation:
        initial ??
        (sheet
            ? RouteName.productionFqcSheetHandling(_sheetId)
            : RouteName.productionFqcInspectionHandling(_id)),
    routes: [
      GoRoute(
        path: '/other',
        builder: (_, _) => const Scaffold(body: Text('新页面')),
      ),
      DraftAwareGoRoute(
        path: '${RouteName.productionFqcSheetHandlingBase}/:sheetId',
        builder: const bool.fromEnvironment('UTEN_FQC_LEGACY_ROUTE_KEY')
            ? (_, state) => ProductionFqcSheetHandlingPage(
                sheetId: state.pathParameters['sheetId']!,
              )
            : ProductionFqcSheetHandlingPage.route,
      ),
      DraftAwareGoRoute(
        path: '${RouteName.productionFqcInspectionHandlingBase}/:inspectionId',
        builder: const bool.fromEnvironment('UTEN_FQC_LEGACY_ROUTE_KEY')
            ? (_, state) => ProductionFqcInspectionPage(
                inspectionId: state.pathParameters['inspectionId']!,
                extra: state.extra,
              )
            : ProductionFqcInspectionPage.route,
      ),
    ],
  );
  await tester.pumpWidget(
    _OwnedHarness(
      key: UniqueKey(),
      container: container,
      router: router,
      boundary: boundary,
      textScale: textScale,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump(const Duration(milliseconds: 400));
  }
  return (router: router, container: container, storage: store, sheet: sheet);
}

class _OwnedHarness extends StatefulWidget {
  const _OwnedHarness({
    super.key,
    required this.container,
    required this.router,
    this.boundary,
    this.textScale = 1,
  });
  final ProviderContainer container;
  final GoRouter router;
  final GlobalKey? boundary;
  final double textScale;
  @override
  State<_OwnedHarness> createState() => _OwnedHarnessState();
}

class _OwnedHarnessState extends State<_OwnedHarness> {
  @override
  void dispose() {
    widget.router.dispose();
    widget.container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: widget.boundary,
    child: UncontrolledProviderScope(
      container: widget.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: widget.boundary == null ? null : _screenshotTheme(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(widget.textScale)),
          child: child!,
        ),
        routerConfig: widget.router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
      ),
    ),
  );
}

ThemeData _screenshotTheme() {
  final theme = auditScreenshotTheme(buildLightTheme());
  return theme.copyWith(
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: theme.textTheme.headlineSmall,
      contentTextStyle: theme.textTheme.bodyMedium,
    ),
  );
}

Future<void> _unmount(WidgetTester tester, _Env env) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

List<FqcReportRow> _rows(WidgetTester tester, {required bool sheet}) => tester
    .widget<MasterDataTableView<FqcReportRow>>(
      find.byKey(
        Key(sheet ? 'fqc-sheet-report-table' : 'fqc-inspection-decision-table'),
      ),
    )
    .items;

Map<String, dynamic> _savedRow(_Env env) {
  final data = env.container.read(formDraftsProvider).single.data;
  return Map<String, dynamic>.from(
    (env.sheet ? (data['rows'] as List).first : data['row']) as Map,
  );
}

Future<void> _submit(
  WidgetTester tester, {
  required bool sheet,
  bool recovery = false,
  String? reason,
}) async {
  final button = find.byKey(
    Key(sheet ? 'fqc-sheet-submit-report' : 'fqc-inspection-submit-report'),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
  if (reason != null) {
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      reason,
    );
  }
  // The fallback also runs the same regression against the exact former page.
  await tester.tap(
    recovery && find.text('继续原提交').evaluate().isNotEmpty
        ? find.text('继续原提交')
        : find.byKey(const Key('inspection-report-confirm-submit')),
  );
  await tester.pumpAndSettle();
}

Future<void> _startSubmit(WidgetTester tester, {required bool sheet}) async {
  final button = find.byKey(
    Key(sheet ? 'fqc-sheet-submit-report' : 'fqc-inspection-submit-report'),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const Key('inspection-report-confirm-submit')));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _select(WidgetTester tester, Set<String> ids) async {
  tester
      .widget<MasterDataTableView<FqcReportRow>>(
        find.byKey(const Key('fqc-sheet-report-table')),
      )
      .onSelectedIdsChanged!(ids);
  await tester.pumpAndSettle();
}

class _MemoryStorage implements FormDraftStorage {
  final records = <String, String>{};
  bool failWrites = false;
  Future<void> Function(String value)? beforeWrite;
  @override
  Future<Map<String, String>> readAll(String prefix) async => {
    for (final e in records.entries)
      if (e.key.startsWith(prefix)) e.key: e.value,
  };
  @override
  Future<String?> read(String key) async => records[key];
  @override
  Future<void> write(String key, String value) async {
    records[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    records.remove(key);
  }

  @override
  Future<bool> compareAndSet(
    String key, {
    required String? expectedValue,
    required String? value,
  }) async {
    if (value != null) await beforeWrite?.call(value);
    if (failWrites) throw StateError('storage full');
    if (records[key] != expectedValue) return false;
    if (value == null) {
      records.remove(key);
    } else {
      records[key] = value;
    }
    return true;
  }
}

class _FqcApi extends ApiClient {
  _FqcApi({this.ids = const [_id]}) : super(Dio());
  final List<String> ids;
  final outcomes = <Object?>[];
  final calls = <({String id, Map<String, dynamic> body})>[];
  final events = <String, Map<String, dynamic>>{};
  final decisions = <String, Map<String, dynamic>>{};
  int commits = 0;
  bool failReads = false;
  bool canDecide = true;
  bool preStocked = false;
  String? statusOverride;
  VoidCallback? beforePost;
  VoidCallback? afterPost;
  Future<void>? responseGate;
  final readGates = <String, Future<void>>{};
  Map<String, dynamic> inspection(String id) => {
    'id': id,
    'sourceReportId': 'report-$id',
    'sourceReportItemId': 'item-$id',
    'reportNo': 'RB-${ids.indexOf(id) + 1}',
    'goodsName': '测试货品',
    'reportedQty': 10,
    'passedQty': events.containsKey(id) ? events[id]!['passQty'] ?? 0 : 0,
    'failedQty': events.containsKey(id) ? events[id]!['failQty'] ?? 0 : 0,
    'remainingQty': events.containsKey(id)
        ? 10 -
              ((events[id]!['passQty'] as num?) ?? 0) -
              ((events[id]!['failQty'] as num?) ?? 0)
        : 10,
    'status':
        statusOverride ??
        (!events.containsKey(id)
            ? 'PENDING'
            : ((events[id]!['passQty'] as num) +
                          (events[id]!['failQty'] as num) >=
                      10
                  ? 'PASSED'
                  : 'PARTIAL')),
    if (preStocked)
      'preStocked': {
        'warehouseId': 'warehouse-1',
        'warehouseName': '成品仓',
        'place': 'A-01',
      },
    'authorizedInboundQty': 0,
    'createdAt': '2026-09-30T01:00:00Z',
    'updatedAt': '2026-09-30T01:00:00Z',
    'unitName': '个',
  };
  @override
  Future<Map<String, dynamic>> get(
    String path, {
    Map<String, dynamic>? query,
  }) async {
    if (path == ApiEndpoints.productionQualityInspectionCapability) {
      return {'canDecide': canDecide};
    }
    if (path.startsWith('${ApiEndpoints.productionQualityInspectionSheets}/')) {
      if (failReads) throw NetworkException();
      final sheetId = path.split('/').last;
      await readGates[sheetId];
      final sheetRows = sheetId == _sheetId ? ids : [_id3];
      return {
        'sheet': {
          'id': sheetId,
          'sheetNo': 'FQC-1',
          'itemCount': sheetRows.length,
          'activeCount': sheetRows
              .where((id) => !events.containsKey(id))
              .length,
          'status': 'ACTIVE',
        },
        'inspections': [for (final id in sheetRows) inspection(id)],
      };
    }
    if (path.startsWith('${ApiEndpoints.productionQualityInspections}/')) {
      if (failReads) throw NetworkException();
      await readGates[path.split('/').last];
      return inspection(path.split('/').last);
    }
    return {'items': <Object>[], 'total': 0, 'totalPages': 0};
  }

  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? query,
    Map<String, dynamic>? headers,
  }) async {
    expect(path.endsWith('/decisions'), isTrue);
    beforePost?.call();
    final id = path.split('/')[3];
    final command = Map<String, dynamic>.from(body! as Map);
    calls.add((id: id, body: command));
    await responseGate;
    final outcome = outcomes.isEmpty ? null : outcomes.removeAt(0);
    if (outcome is Exception) {
      afterPost?.call();
      throw outcome;
    }
    final key = '$id/${command['idempotencyKey']}';
    final replay = decisions.containsKey(key);
    if (replay) {
      expect(command, decisions[key]);
    } else {
      decisions[key] = command;
      final previous = events[id];
      events[id] = {
        'passQty':
            ((previous?['passQty'] as num?) ?? 0) +
            ((command['passQty'] as num?) ?? 0),
        'failQty':
            ((previous?['failQty'] as num?) ?? 0) +
            ((command['failQty'] as num?) ?? 0),
      };
      commits++;
    }
    afterPost?.call();
    if (outcome == 'commit-timeout') throw NetworkTimeoutException();
    return {
      'decisionEventId': 'decision-$id',
      'inspection': inspection(id),
      'replay': replay,
    };
  }
}
