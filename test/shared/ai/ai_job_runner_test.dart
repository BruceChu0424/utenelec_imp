import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';
import 'package:uten_imp/shared/ai/ai_job_runner.dart';

const _request = AiJobRequest(
  kind: 'SALES_DOCUMENT_INTAKE',
  params: {'docType': 'order'},
  bytes: [1, 2, 3],
  fileName: 'UJ23 quotation.xlsx',
  contentType: 'application/octet-stream',
);

AiJobSnapshot _snap(
  AiJobStatus status, {
  String? stage,
  int progress = 0,
  Map<String, dynamic>? result,
  String? errorCode,
  String? errorMessage,
}) => AiJobSnapshot(
  id: 'job-1',
  kind: 'SALES_DOCUMENT_INTAKE',
  status: status,
  stage: stage,
  progress: progress,
  result: result,
  errorCode: errorCode,
  errorMessage: errorMessage,
);

/// 虚拟时钟: sleep 只推进时间不真等, 记录每一次等待。
class _VirtualTime {
  DateTime now = DateTime.utc(2026, 9, 27, 9);
  final List<Duration> sleeps = [];
  void Function()? onSleep;

  Future<void> sleep(Duration duration) async {
    sleeps.add(duration);
    now = now.add(duration);
    onSleep?.call();
  }
}

class _FakeRepository implements AiJobRepository {
  _FakeRepository({this.submitResult, List<Object>? polls})
    : polls = polls ?? [];

  AiJobSnapshot? submitResult;
  Object? submitError;

  /// 每次 get 依次取一项: AiJobSnapshot 返回, 其它当异常抛出; 取完后重复最后一项。
  final List<Object> polls;
  final List<String> gets = [];
  final List<String> cancels = [];
  int submits = 0;

  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) async {
    submits++;
    if (submitError != null) throw submitError!;
    return submitResult ?? _snap(AiJobStatus.pending);
  }

  @override
  Future<AiJobSnapshot> get(String jobId) async {
    gets.add(jobId);
    final next = polls.length > 1 ? polls.removeAt(0) : polls.first;
    if (next is AiJobSnapshot) return next;
    throw next;
  }

  @override
  Future<void> cancel(String jobId) async => cancels.add(jobId);
}

AiJobRunner _runner(_FakeRepository repository, _VirtualTime time) =>
    AiJobRunner(repository, sleep: time.sleep, now: () => time.now);

void main() {
  test(
    'progress snapshots flow from upload through server stages to success',
    () async {
      final time = _VirtualTime();
      final repository = _FakeRepository(
        polls: [
          _snap(AiJobStatus.running, stage: 'READING', progress: 10),
          _snap(AiJobStatus.running, stage: 'MATCHING_GOODS', progress: 60),
          _snap(
            AiJobStatus.succeeded,
            stage: 'DONE',
            progress: 100,
            result: {'schemaVersion': 2},
          ),
        ],
      );
      final seen = <AiJobSnapshot>[];

      final result = await _runner(
        repository,
        time,
      ).run(_request, onProgress: seen.add);

      expect(result.status, AiJobStatus.succeeded);
      expect(result.result, {'schemaVersion': 2});
      expect(repository.submits, 1);
      expect(seen.first.stage, AiJobSnapshot.uploadingStage);
      expect(seen.first.id, isEmpty);
      expect(seen[1].id, 'job-1');
      expect(seen.skip(2).map((s) => s.stage), [
        'READING',
        'MATCHING_GOODS',
        'DONE',
      ]);
      expect(repository.cancels, isEmpty);
    },
  );

  test(
    'polls every second for the first ten seconds, then every two',
    () async {
      final time = _VirtualTime();
      final repository = _FakeRepository(
        polls: [
          ...List.generate(13, (_) => _snap(AiJobStatus.running, stage: 'AI')),
          _snap(AiJobStatus.succeeded, result: const {}),
        ],
      );

      await _runner(repository, time).run(_request);

      expect(time.sleeps.take(10), everyElement(const Duration(seconds: 1)));
      expect(time.sleeps.skip(10), everyElement(const Duration(seconds: 2)));
      expect(repository.gets, hasLength(14));
    },
  );

  test('a failed job throws the plain server reason with its code', () async {
    final time = _VirtualTime();
    final repository = _FakeRepository(
      polls: [
        _snap(
          AiJobStatus.failed,
          errorCode: 'FILE_UNREADABLE',
          errorMessage: '文件无法解析',
        ),
      ],
    );

    final failure = await _runner(repository, time)
        .run(_request)
        .then<AiJobFailure?>(
          (_) => null,
          onError: (Object e) => e as AiJobFailure,
        );

    expect(failure!.message, '文件无法解析');
    expect(failure.code, 'FILE_UNREADABLE');
    expect(failure.snapshot?.status, AiJobStatus.failed);
    expect(failure.isCancelled, isFalse);
    // 服务端原话不会被进度弹窗替换。
    expect(failure.clientMessage, isFalse);
  });

  test('a failed job without a reason still gets a readable message', () async {
    final time = _VirtualTime();
    final repository = _FakeRepository(polls: [_snap(AiJobStatus.failed)]);
    await expectLater(
      _runner(repository, time).run(_request),
      throwsA(
        isA<AiJobFailure>()
            .having((f) => f.code, 'code', AiJobFailure.codeFailed)
            .having((f) => f.message, 'message', isNotEmpty)
            // 兜底文案标成客户端文案, 进度弹窗会换成当前语言。
            .having((f) => f.clientMessage, 'clientMessage', isTrue),
      ),
    );
  });

  test(
    'cancelling while waiting stops polling and asks the server to cancel',
    () async {
      final time = _VirtualTime();
      final repository = _FakeRepository(
        polls: [_snap(AiJobStatus.running, stage: 'AI')],
      );
      final token = AiJobCancelToken();
      time.onSleep = () {
        if (time.sleeps.length == 3) token.cancel();
      };

      await expectLater(
        _runner(repository, time).run(_request, cancelToken: token),
        throwsA(
          isA<AiJobFailure>().having((f) => f.isCancelled, 'cancelled', isTrue),
        ),
      );
      expect(repository.cancels, ['job-1']);
      expect(repository.gets, hasLength(2));
    },
  );

  test(
    'cancel wakes the runner immediately instead of after the interval',
    () async {
      final repository = _FakeRepository(
        polls: [_snap(AiJobStatus.running, stage: 'AI')],
      );
      final never = Completer<void>();
      final token = AiJobCancelToken();
      final runner = AiJobRunner(
        repository,
        // 永远不醒的等待: 只有取消能让它继续。
        sleep: (_) => never.future,
      );
      final future = runner.run(_request, cancelToken: token);
      await Future<void>.delayed(Duration.zero);
      token.cancel();
      await expectLater(future, throwsA(isA<AiJobFailure>()));
      expect(repository.cancels, ['job-1']);
    },
  );

  test('a token cancelled before submit never uploads', () async {
    final repository = _FakeRepository();
    final token = AiJobCancelToken()..cancel();
    await expectLater(
      _runner(repository, _VirtualTime()).run(_request, cancelToken: token),
      throwsA(isA<AiJobFailure>()),
    );
    expect(repository.submits, 0);
  });

  test('gives up after five minutes and cancels the server job', () async {
    final time = _VirtualTime();
    final repository = _FakeRepository(
      polls: [_snap(AiJobStatus.running, stage: 'AI')],
    );

    await expectLater(
      _runner(repository, time).run(_request),
      throwsA(
        isA<AiJobFailure>().having(
          (f) => f.code,
          'code',
          AiJobFailure.codeClientTimeout,
        ),
      ),
    );
    final waited = time.sleeps.fold(Duration.zero, (a, b) => a + b);
    expect(waited, const Duration(minutes: 5));
    expect(repository.cancels, ['job-1']);
  });

  test(
    'a single failed poll is skipped, three in a row surface the error',
    () async {
      final time = _VirtualTime();
      final flaky = _FakeRepository(
        polls: [
          NetworkException(),
          _snap(AiJobStatus.running, stage: 'AI'),
          NetworkException(),
          NetworkException(),
          _snap(AiJobStatus.succeeded, result: const {}),
        ],
      );
      final ok = await _runner(flaky, time).run(_request);
      expect(ok.status, AiJobStatus.succeeded);

      final broken = _FakeRepository(polls: [NetworkException()]);
      await expectLater(
        _runner(broken, _VirtualTime()).run(_request),
        throwsA(isA<NetworkException>()),
      );
      expect(broken.gets, hasLength(3));
    },
  );

  test('a vanished job asks the user to start over', () async {
    final repository = _FakeRepository(
      polls: [ApiException('NOT_FOUND', '资源不存在', httpStatus: 404)],
    );
    await expectLater(
      _runner(repository, _VirtualTime()).run(_request),
      throwsA(
        isA<AiJobFailure>().having(
          (f) => f.code,
          'code',
          AiJobFailure.codeJobGone,
        ),
      ),
    );
  });

  test(
    'a rejected submit surfaces the server ApiException unchanged',
    () async {
      final repository = _FakeRepository()
        ..submitError = ApiException(
          'RATE_LIMITED',
          '你已有识别任务在进行, 请稍等',
          httpStatus: 429,
        );
      await expectLater(
        _runner(repository, _VirtualTime()).run(_request),
        throwsA(
          isA<ApiException>().having(
            (e) => e.message,
            'message',
            '你已有识别任务在进行, 请稍等',
          ),
        ),
      );
      expect(repository.gets, isEmpty);
    },
  );

  test(
    'an idempotent submit that is already finished fetches the result at once',
    () async {
      final time = _VirtualTime();
      final repository = _FakeRepository(
        submitResult: _snap(AiJobStatus.succeeded),
        polls: [
          _snap(AiJobStatus.succeeded, result: {'schemaVersion': 2}),
        ],
      );
      final result = await _runner(repository, time).run(_request);
      expect(result.result, {'schemaVersion': 2});
      expect(time.sleeps, isEmpty);
      expect(repository.gets, ['job-1']);
    },
  );

  test('resume polls an existing job without uploading again', () async {
    final time = _VirtualTime();
    final repository = _FakeRepository(
      polls: [
        _snap(AiJobStatus.running, stage: 'AI'),
        _snap(AiJobStatus.succeeded, result: const {'ok': true}),
      ],
    );
    final seen = <AiJobSnapshot>[];
    final result = await _runner(
      repository,
      time,
    ).resume('job-1', onProgress: seen.add);
    expect(result.result, {'ok': true});
    expect(repository.submits, 0);
    // 第一拍立即查询, 不先等一秒。
    expect(time.sleeps, [const Duration(seconds: 1)]);
    expect(seen.map((s) => s.status), [
      AiJobStatus.running,
      AiJobStatus.succeeded,
    ]);
  });

  test('a server-side cancelled job reads as cancelled', () async {
    final repository = _FakeRepository(polls: [_snap(AiJobStatus.cancelled)]);
    await expectLater(
      _runner(repository, _VirtualTime()).run(_request),
      throwsA(
        isA<AiJobFailure>().having((f) => f.isCancelled, 'cancelled', isTrue),
      ),
    );
  });

  test('the cancel token completes its signal once', () async {
    final token = AiJobCancelToken();
    expect(token.isCancelled, isFalse);
    token
      ..cancel()
      ..cancel();
    await token.whenCancelled;
    expect(token.isCancelled, isTrue);
  });
}
