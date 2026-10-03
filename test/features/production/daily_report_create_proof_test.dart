import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/data_write_revision.dart';
import 'package:uten_imp/core/router/permission_by_path.dart';
import 'package:uten_imp/features/production/models/production_daily_report_create_request.dart';
import 'package:uten_imp/features/production/repositories/production_repository.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/drafts/form_draft.dart';

List<Map<String, dynamic>> _vectors() =>
    (jsonDecode(
              File(
                'test/fixtures/daily_report_create_fingerprints.json',
              ).readAsStringSync(),
            )
            as List)
        .map((entry) => Map<String, dynamic>.from(entry as Map))
        .toList();

FrozenDailyReportCreate _command([Map<String, dynamic>? body]) =>
    FrozenDailyReportCreate.capture(
      body: body ?? Map<String, dynamic>.from(_vectors().first['body'] as Map),
      server: 'https://original.invalid/api',
      userId: 'original-user',
      actorId: null,
    );

Map<String, dynamic> _committed(FrozenDailyReportCreate command) => {
  'status': 'COMMITTED',
  'idempotencyKey': command.idempotencyKey,
  'requestHash': command.requestHash,
  'fullPayloadVersion': 1,
  'fullPayloadHash': command.fullPayloadHash,
  'reportId': 'report-1',
  'detail': {
    'id': 'report-1',
    'billNo': 'SR-001',
    'status': 1,
    'items': <Object?>[],
  },
};

class _Api extends ApiClient {
  _Api(this.response) : super(Dio());
  final Map<String, dynamic> response;
  final requests = <({String path, Object? body})>[];
  @override
  Future<Map<String, dynamic>> post(
    String path, {
    Object? body,
    Map<String, dynamic>? headers,
    Map<String, dynamic>? query,
  }) async {
    requests.add((path: path, body: body));
    return response;
  }
}

void main() {
  for (final vector in _vectors()) {
    test('matches exact B17 Java hashes: ${vector['name']}', () {
      final body = Map<String, dynamic>.from(vector['body'] as Map);
      expect(dailyReportCreateRequestHash(body), vector['requestHash']);
      expect(dailyReportCreateFullPayloadHash(body), vector['fullPayloadHash']);
    });
  }

  test(
    'freeze keeps the actual nested request while editor and request copies change',
    () {
      final body = Map<String, dynamic>.from(_vectors().first['body'] as Map);
      final command = _command(body);
      final frozen = command.bodyJson;
      ((body['items'] as List).first as Map)['qty'] = 99;
      final copied = command.requestBody;
      final fields =
          ((copied['items'] as List).first as Map)['platformFields'] as Map;
      (fields['cells'] as List).clear();
      expect(command.bodyJson, frozen);
      expect(((command.requestBody['items'] as List).first as Map)['qty'], 37);
      expect(command.toJson()['bodyHash'], _command().bodyHash);
      expect(
        FrozenDailyReportCreate.restore(command.toJson()).bodyJson,
        frozen,
      );
    },
  );

  test(
    'TEXT 001 and TEXT 1 have distinct full proofs even when native fields match',
    () {
      final vectors = _vectors();
      expect(vectors[0]['requestHash'], vectors[1]['requestHash']);
      expect(
        vectors[0]['fullPayloadHash'],
        isNot(vectors[1]['fullPayloadHash']),
      );
      expect(vectors[0]['fullPayloadHash'], vectors[2]['fullPayloadHash']);
      expect(vectors[3]['fullPayloadHash'], vectors[4]['fullPayloadHash']);
    },
  );

  test(
    'restoring a modified body fails rather than reconstructing current inputs',
    () {
      final command = _command();
      final json = command.toJson();
      final changed = command.requestBody..['remark'] = 'changed after send';
      json['bodyJson'] = jsonEncode(changed);
      expect(
        () => FrozenDailyReportCreate.restore(json),
        throwsFormatException,
      );
      expect(
        command.belongsTo(
          server: command.server,
          userId: command.userId,
          actorId: null,
        ),
        isTrue,
      );
      expect(
        command.belongsTo(
          server: 'https://other.invalid/api',
          userId: command.userId,
          actorId: null,
        ),
        isFalse,
      );
      expect(
        command.belongsTo(
          server: command.server,
          userId: 'other-user',
          actorId: null,
        ),
        isFalse,
      );
      expect(
        command.belongsTo(
          server: command.server,
          userId: command.userId,
          actorId: 'other-actor',
        ),
        isFalse,
      );
    },
  );

  for (final mismatch in [
    'idempotencyKey',
    'requestHash',
    'fullPayloadHash',
    'fullPayloadVersion',
    'reportId',
    'detail',
  ]) {
    test('COMMITTED $mismatch mismatch cannot produce a saved checkpoint', () {
      final command = _command();
      final body = _committed(command);
      body[mismatch] = switch (mismatch) {
        'fullPayloadVersion' => 2,
        'detail' => {'id': 'other-report', 'items': <Object?>[]},
        _ => 'unrelated',
      };
      final receipt = DailyReportCreateResolution.fromJson(body);
      expect(() => receipt.verify(command), throwsFormatException);
      expect(receipt.toCheckpoint, throwsStateError);
    });
  }

  for (final state in ['UNKNOWN', 'LEGACY_UNCONFIRMED']) {
    test(
      '$state never confirms merely matching key, native hash, or current document',
      () {
        final command = _command();
        final receipt = DailyReportCreateResolution.fromJson({
          'status': state,
          'idempotencyKey': command.idempotencyKey,
          'requestHash': command.requestHash,
          if (state == 'LEGACY_UNCONFIRMED') ...{
            'reportId': 'report-1',
            'detail': {'id': 'report-1', 'items': <Object?>[]},
          },
        });
        receipt.verify(command);
        expect(receipt.committed, isFalse);
        expect(receipt.toCheckpoint, throwsStateError);
      },
    );
  }

  test(
    'current detail may have changed after create; the original proof and id are decisive',
    () {
      final command = _command();
      final receipt = DailyReportCreateResolution.fromJson(_committed(command));
      expect(receipt.toCheckpoint, throwsStateError);
      receipt.verify(command);
      expect(receipt.detail!.status, 1);
      expect(receipt.toCheckpoint()['reportId'], 'report-1');
    },
  );

  test(
    'repository performs one readonly POST with the entire frozen body and validates proof',
    () async {
      final command = _command();
      final api = _Api(_committed(command));
      final result = await ProductionDailyReportRepository(
        api,
      ).createReceipt(command);
      expect(result.committed, isTrue);
      expect(api.requests, hasLength(1));
      expect(
        api.requests.single.path,
        '/production/daily-reports/create-receipt',
      );
      expect(api.requests.single.body, command.requestBody);
    },
  );

  test(
    'only exact readonly POST is excluded from business write revisions',
    () {
      for (final path in [
        '/production/daily-reports/create-receipt',
        '/api/production/daily-reports/create-receipt',
      ]) {
        expect(
          isBusinessWrite(RequestOptions(path: path, method: 'POST')),
          isFalse,
        );
        expect(
          isBusinessWrite(RequestOptions(path: path, method: 'PUT')),
          isTrue,
        );
      }
      for (final path in [
        '/production/daily-reports',
        '/production/daily-reports/create-receipt/anything',
        '/other/production/daily-reports/create-receipt',
      ]) {
        expect(
          isBusinessWrite(RequestOptions(path: path, method: 'POST')),
          isTrue,
        );
      }
    },
  );

  test(
    'only original workshop report drafts use the view-only recovery route',
    () {
      FormDraft draft({
        String route = '/production/daily-reports/new',
        String kind = 'productionDailyReport',
      }) => FormDraft(
        id: 'local-1',
        title: '原日报',
        module: BadgeModule.workshop,
        route: route,
        permission: Perm.productionDailyReportCreate,
        draftKind: kind,
        updatedAt: DateTime(2026, 10),
        data: {
          '_formDraftSubmissionPending': true,
          'idempotencyKey': 'legacy-original-key',
        },
      );
      expect(
        draft().resumeLocation,
        '/production/daily-reports/create-recovery?draftId=local-1',
      );
      expect(requiredAnyPermFor(draft().resumeLocation), [
        Perm.productionDailyReportView,
      ]);
      expect(
        isDailyReportCreateRecoveryDraft(draft(route: '/production/plans/new')),
        isFalse,
      );
      expect(isDailyReportCreateRecoveryDraft(draft(kind: 'other')), isFalse);
    },
  );
}
