import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/features/admin/models/server_operations.dart';
import 'package:uten_imp/features/admin/repositories/server_operation_outcome.dart';
import 'package:uten_imp/features/admin/widgets/server_update_overview.dart';

void main() {
  test(
    'legacy job and status retain their receipt without inventing failure',
    () {
      final job = ServerUpdateJob.fromJson(_job()..['message'] = '旧版安全提示');
      expect(job.failure, isNull);
      expect(job.message, '旧版安全提示');
      expect(job.terminal, isTrue);
      expect(job.recoveryRequired, isFalse);
      final status = ServerOperationsStatus.fromJson({
        'available': true,
        'canUpdate': true,
        'latestJob': _job(),
      });
      expect(status.failure, isNull);
      expect(status.latestJob?.id, 'job-123');
      expect(status.latestJob?.failure, isNull);
      expect(status.canUpdate, isTrue);
      expect(status.timerActive, isNull);
    },
  );

  test('unsupported platform is distinct from a host helper failure', () {
    final unsupported = ServerOperationsStatus.fromJson({
      'available': false,
      'canUpdate': true,
      'canCleanup': true,
      'canConfigureSource': true,
      'failure': {'code': 'HOST_PLATFORM_UNSUPPORTED'},
    });
    expect(unsupported.platformUnsupported, isTrue);
    expect(unsupported.canUpdate, isTrue);
    expect(unsupported.canCleanup, isTrue);
    expect(unsupported.canConfigureSource, isTrue);
    for (final code in ['HOST_HELPER_UNAVAILABLE', 'HOST_RESPONSE_INVALID']) {
      expect(
        ServerOperationsStatus.fromJson({
          'available': false,
          'failure': {'code': code},
        }).platformUnsupported,
        isFalse,
      );
    }
    expect(
      ServerOperationsStatus.fromJson({
        'available': true,
        'failure': {'code': 'HOST_PLATFORM_UNSUPPORTED'},
      }).platformUnsupported,
      isFalse,
    );
  });

  test(
    'optional failure ignores non-object legacy values and parses safe data',
    () {
      for (final value in <Object?>[null, 'legacy', 7, false, <Object>[]]) {
        expect(ServerUpdateFailure.fromValue(value), isNull);
        expect(ServerUpdateJob.fromJson(_job(failure: value)).failure, isNull);
      }
      final failure = ServerUpdateFailure.fromValue(_failure())!;
      expect(failure.code, 'HOST_IDENTITY_PERMISSION');
      expect(failure.phase, 'CHECKING');
      expect(failure.title, '主机账号切换权限不足');
      expect(failure.reason, '本阶段未通过身份核对。');
      expect(failure.suggestion, '请联系管理员核对。');
      expect(failure.nextAction, 'CONTACT_ADMIN');
      expect(failure.exitCode, 1);
      final status = ServerOperationsStatus.fromJson({
        'available': false,
        'failure': _failure()..['code'] = 'HOST_HELPER_UNAVAILABLE',
      });
      expect(status.available, isFalse);
      expect(status.failure?.code, 'HOST_HELPER_UNAVAILABLE');
    },
  );

  test(
    'recovery wins over retry and the outer job recovery state is retained',
    () {
      final raw = _failure()
        ..['retrySafe'] = true
        ..['recoveryRequired'] = true
        ..['nextAction'] = 'VERIFY_RECOVERY';
      final job = ServerUpdateJob.fromJson(_job(failure: raw));
      expect(job.failure?.retrySafe, isFalse);
      expect(job.failure?.recoveryRequired, isTrue);
      expect(job.recoveryRequired, isTrue);
      expect(job.failure?.nextAction, 'VERIFY_RECOVERY');
      final legacy = ServerUpdateJob.fromJson(
        _job()..['state'] = 'RECOVERY_REQUIRED',
      );
      expect(legacy.failure, isNull);
      expect(legacy.recoveryRequired, isTrue);
      expect(legacy.terminal, isTrue);
    },
  );

  test(
    'optional flags and actions use typed values and a fixed action allowlist',
    () {
      final malformed = ServerUpdateFailure.fromValue(
        _failure()
          ..['retrySafe'] = 'true'
          ..['originalServicePreserved'] = 'true'
          ..['exitCode'] = '1'
          ..['nextAction'] = 'RUN_UPDATE',
      )!;
      expect(malformed.retrySafe, isFalse);
      expect(malformed.originalServicePreserved, isNull);
      expect(malformed.exitCode, isNull);
      expect(malformed.nextAction, 'CONTACT_ADMIN');
      for (final action in const {
        'CHECK_SOURCE',
        'RETRY_CHECK',
        'REFRESH_STATUS',
        'WAIT_FOR_JOB',
        'CONTACT_ADMIN',
        'VERIFY_RECOVERY',
      }) {
        expect(
          ServerUpdateFailure.fromValue(
            _failure()..['nextAction'] = action,
          )?.nextAction,
          action,
        );
      }
    },
  );

  test(
    'safe codes reject provider documents URLs whitespace and oversized data',
    () {
      expect(safeServerOperationCode('SOURCE_TLS_FAILED'), 'SOURCE_TLS_FAILED');
      for (final value in <Object?>[
        null,
        1,
        '',
        'source_failed',
        '<Error>FORBIDDEN</Error>',
        'https://private.invalid',
        'SOURCE FAILED',
        'A' * 81,
      ]) {
        expect(safeServerOperationCode(value), isNull, reason: '$value');
      }
      final fallback = ServerUpdateFailure.fromValue(
        _failure()
          ..['code'] = '<Error>PRIVATE</Error>'
          ..['phase'] = 'https://private.invalid',
      )!;
      expect(fallback.code, 'UPDATE_FAILED');
      expect(fallback.phase, isNull);
    },
  );

  test(
    'safe text rejects raw XML URLs credentials stack traces and long output',
    () {
      expect(safeServerOperationText('  请核对服务器状态。  '), '请核对服务器状态。');
      expect(safeServerOperationText('数据库备份未通过，请联系管理员。'), isNotNull);
      for (final value in <Object?>[
        null,
        1,
        '',
        '   ',
        '<Error><Code>AccessDenied</Code></Error>',
        '下载失败 https://private.invalid/object',
        'AccessKeySecret=fixture-secret',
        'Authorization: OSS fixture-signature',
        'Bearer fixture-token',
        'LTAIFIXTUREKEY12345',
        'AKIAFIXTUREKEY12345',
        'Stack trace: private diagnostic',
        'at com.example.PrivateFailure.run(PrivateFailure.java:42)',
        '?token=fixture-token',
        '&signature=fixture-signature',
        'x' * 601,
      ]) {
        expect(safeServerOperationText(value), isNull, reason: '$value');
      }
      final failure = ServerUpdateFailure.fromValue(
        _failure()
          ..['title'] = '<Error>PRIVATE_XML</Error>'
          ..['reason'] = 'https://private.invalid'
          ..['suggestion'] = 'Authorization: OSS private',
      )!;
      expect(failure.title, isNull);
      expect(failure.reason, isNull);
      expect(failure.suggestion, isNull);
    },
  );

  test(
    'copy diagnostics contains only safe receipt and curated failure fields',
    () {
      final raw = _job(failure: _failure())
        ..['message'] = 'DO_NOT_COPY_MESSAGE Bearer fixture-token'
        ..['health'] = {'status': 'UP', 'secret': 'DO_NOT_COPY_HEALTH'}
        ..['startedAt'] = '2026-10-17T10:00:00+08:00'
        ..['finishedAt'] = '2026-10-17T10:00:01+08:00';
      final diagnostics = serverUpdateDiagnostics(
        ServerUpdateJob.fromJson(raw),
      );
      expect(diagnostics.split('\n'), [
        'requestId=request-123',
        'jobId=job-123',
        'state=FAILED',
        'phase=CHECKING',
        'code=HOST_IDENTITY_PERMISSION',
        'reason=本阶段未通过身份核对。',
        'recoveryRequired=false',
        'originalServicePreserved=true',
        'nextAction=CONTACT_ADMIN',
        'exitCode=1',
      ]);
      expect(diagnostics, isNot(contains('DO_NOT_COPY')));
      expect(diagnostics, isNot(contains('message=')));
      expect(diagnostics, isNot(contains('health=')));
      expect(diagnostics, isNot(contains('title=')));
      expect(diagnostics, isNot(contains('suggestion=')));
      expect(diagnostics, isNot(contains('startedAt=')));
    },
  );

  test(
    'diagnostics redact unsafe IDs phase and failure reason including legacy',
    () {
      final raw =
          _job(
              failure: _failure()
                ..['code'] = '<Error>PRIVATE_CODE</Error>'
                ..['phase'] = 'bad phase'
                ..['reason'] = 'https://private.invalid/token'
                ..['rawStderr'] = 'DO_NOT_COPY_STDERR',
            )
            ..['id'] = 'https://private.invalid/job'
            ..['requestId'] = 'Bearer fixture-token'
            ..['phase'] = 'bad phase';
      final diagnostics = serverUpdateDiagnostics(
        ServerUpdateJob.fromJson(raw),
      );
      expect(diagnostics, contains('requestId=unavailable'));
      expect(diagnostics, contains('jobId=unavailable'));
      expect(diagnostics, contains('phase=unavailable'));
      expect(diagnostics, contains('code=UPDATE_FAILED'));
      for (final forbidden in [
        'private.invalid',
        'fixture-token',
        'PRIVATE_CODE',
        'DO_NOT_COPY',
        'reason=',
      ]) {
        expect(diagnostics, isNot(contains(forbidden)));
      }
      final legacy = serverUpdateDiagnostics(
        ServerUpdateJob.fromJson(
          _job()..['message'] = '<Error>legacy-secret</Error>',
        ),
      );
      expect(legacy.split('\n'), [
        'requestId=request-123',
        'jobId=job-123',
        'state=FAILED',
        'phase=CHECKING',
      ]);
    },
  );

  test('only a trusted application 4xx body is a definite rejection', () {
    for (final status in [400, 401, 403, 404, 409, 422, 429]) {
      expect(
        serverOperationDefinitelyRejected(
          ApiException(
            'CONFLICT',
            '明确拒绝',
            httpStatus: status,
            hasResponseCode: true,
          ),
        ),
        isTrue,
        reason: '$status',
      );
      expect(
        serverOperationDefinitelyRejected(
          ApiException('CONFLICT', '无可信业务回执', httpStatus: status),
        ),
        isFalse,
        reason: '$status',
      );
    }
  });

  test(
    'gateway timeouts throttling 5xx and malformed receipts remain uncertain',
    () {
      for (final status in [408, 429, 500, 502, 503, 504]) {
        expect(
          serverOperationDefinitelyRejected(
            ApiException('INTERNAL', '网关没有业务回执', httpStatus: status),
          ),
          isFalse,
          reason: '$status',
        );
      }
      for (final status in [200, 302, 500, 503]) {
        expect(
          serverOperationDefinitelyRejected(
            ApiException(
              'CONFLICT',
              '错误响应不能证明未执行',
              httpStatus: status,
              hasResponseCode: true,
            ),
          ),
          isFalse,
        );
      }
      expect(
        serverOperationDefinitelyRejected(
          ApiException('CONFLICT', '没有状态', hasResponseCode: true),
        ),
        isFalse,
      );
      expect(serverOperationDefinitelyRejected(NetworkException()), isFalse);
      expect(
        serverOperationDefinitelyRejected(NetworkTimeoutException()),
        isFalse,
      );
      expect(
        serverOperationDefinitelyRejected(
          const FormatException('Malformed receipt'),
        ),
        isFalse,
      );
    },
  );

  test(
    'both uncertain business codes override even a trusted 4xx response',
    () {
      for (final code in const [
        'OUTCOME_UNCERTAIN',
        'SERVER_OPERATION_OUTCOME_UNCERTAIN',
      ]) {
        for (final status in [400, 409, 422, 429, 503]) {
          expect(
            serverOperationDefinitelyRejected(
              ApiException(
                code,
                '原结果待确认',
                httpStatus: status,
                hasResponseCode: true,
              ),
            ),
            isFalse,
            reason: '$code / $status',
          );
        }
      }
    },
  );
}

Map<String, dynamic> _job({Object? failure}) => {
  'id': 'job-123',
  'requestId': 'request-123',
  'actorId': 'actor-123',
  'state': 'FAILED',
  'phase': 'CHECKING',
  'mode': 'CHECK_ONLY',
  'failure': ?failure,
};

Map<String, dynamic> _failure() => {
  'code': 'HOST_IDENTITY_PERMISSION',
  'phase': 'CHECKING',
  'title': '主机账号切换权限不足',
  'reason': '本阶段未通过身份核对。',
  'suggestion': '请联系管理员核对。',
  'nextAction': 'CONTACT_ADMIN',
  'retrySafe': false,
  'recoveryRequired': false,
  'originalServicePreserved': true,
  'exitCode': 1,
};
