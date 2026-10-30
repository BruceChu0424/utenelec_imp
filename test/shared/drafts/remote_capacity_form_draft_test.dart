import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/drafts/form_draft_store.dart';

// Reuse the real form widget + durable draft harness. Its main() is not called;
// this independently discovered file owns only the new capacity regressions.
import 'form_draft_mixin_test.dart' as harness;

class _CapacityAdapter implements HttpClientAdapter {
  _CapacityAdapter({this.code = 'REMOTE_CAPACITY_REJECTED', this.status = 429});
  final String? code;
  final int status;
  int attempts = 0, accepted = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    expect(options.method, 'POST');
    expect(options.path, '/sales/new');
    attempts++;
    if (attempts == 1) {
      return ResponseBody.fromString(
        jsonEncode({
          if (code != null) 'code': code,
          'message': 'Remote request admission refused',
        }),
        status,
        headers: {
          Headers.contentTypeHeader: [Headers.jsonContentType],
        },
      );
    }
    accepted++;
    return ResponseBody.fromString(
      '{"saved":true}',
      200,
      headers: {
        Headers.contentTypeHeader: [Headers.jsonContentType],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

ApiClient _client(_CapacityAdapter adapter) {
  final dio = Dio(BaseOptions(baseUrl: 'https://test.example/api'))
    ..httpClientAdapter = adapter;
  return ApiClient(dio);
}

void main() {
  testWidgets(
    'typed capacity refusal keeps editing and requires a second human submit',
    (tester) async {
      final adapter = _CapacityAdapter();
      final api = _client(adapter);
      ApiException? refusal;
      final env = await harness.pumpEditor(
        tester,
        harness.MemoryDraftStorage(),
        onSubmit: (editor) async {
          try {
            await editor.runFormDraftSubmission(
              () => api.post('/sales/new', body: {'text': editor.text.text}),
              isDefiniteRejection: (_) => false,
            );
            await editor.completeFormDraft();
          } on ApiException catch (error) {
            refusal = error;
          }
        },
      );
      await tester.enterText(find.byKey(const Key('input')), '原始输入保留');
      await tester.tap(find.byKey(const Key('send-draft')));
      await tester.pumpAndSettle();
      expect(
        adapter.attempts,
        1,
        reason: 'Admission refusal must not trigger an automatic replay',
      );
      expect(adapter.accepted, 0);
      expect(refusal?.code, 'REMOTE_CAPACITY_REJECTED');
      expect(refusal?.httpStatus, 429);
      expect(refusal?.hasResponseCode, isTrue);
      final editor = tester.state<harness.TestEditorState>(
        find.byType(harness.TestEditor),
      );
      expect(editor.formDraftHasUnknownSubmission, isFalse);
      expect(editor.text.text, '原始输入保留');
      expect(
        env.container
            .read(formDraftsProvider)
            .single
            .data['_formDraftSubmissionPending'],
        isNull,
      );
      await tester.enterText(find.byKey(const Key('input')), '人工核查并修改');
      await tester.tap(find.byKey(const Key('send-draft')));
      await tester.pumpAndSettle();
      expect(adapter.attempts, 2);
      expect(adapter.accepted, 1);
      expect(env.container.read(formDraftsProvider), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      env.router.dispose();
      env.container.dispose();
    },
  );

  for (final classifier in [false, true]) {
    testWidgets(
      'typed capacity refusal preserves a prior unknown commit classifier=$classifier',
      (tester) async {
        final adapter = _CapacityAdapter();
        final api = _client(adapter);
        final env = await harness.pumpEditor(
          tester,
          harness.MemoryDraftStorage(),
        );
        final editor = tester.state<harness.TestEditorState>(
          find.byType(harness.TestEditor),
        )..canReplay = true;
        editor.text.text = '此前超时的同一命令';
        await expectLater(
          editor.runFormDraftSubmission(
            () async => throw NetworkTimeoutException(),
          ),
          throwsA(isA<NetworkTimeoutException>()),
        );
        await tester.runAsync(
          () => expectLater(
            editor.runFormDraftSubmission(
              () => api.post('/sales/new'),
              isDefiniteRejection: (_) => classifier,
            ),
            throwsA(isA<ApiException>()),
          ),
        );
        expect(adapter.attempts, 1);
        expect(adapter.accepted, 0);
        expect(editor.formDraftHasUnknownSubmission, isTrue);
        expect(
          env.container
              .read(formDraftsProvider)
              .single
              .data['_formDraftSubmissionPending'],
          isTrue,
        );
        expect(editor.text.text, '此前超时的同一命令');
        await tester.pumpWidget(const SizedBox.shrink());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }

  for (final scenario in <(int, String?)>[
    (429, 'RATE_LIMITED'),
    (429, null),
    (503, 'REMOTE_CAPACITY_REJECTED'),
  ]) {
    testWidgets(
      '${scenario.$1}/${scenario.$2} cannot claim a fresh write was never executed',
      (tester) async {
        final adapter = _CapacityAdapter(
          status: scenario.$1,
          code: scenario.$2,
        );
        final api = _client(adapter);
        final env = await harness.pumpEditor(
          tester,
          harness.MemoryDraftStorage(),
        );
        final editor = tester.state<harness.TestEditorState>(
          find.byType(harness.TestEditor),
        );
        editor.text.text = '保留未知提交证据';
        await tester.runAsync(
          () => expectLater(
            editor.runFormDraftSubmission(() => api.post('/sales/new')),
            throwsA(isA<ApiException>()),
          ),
        );
        await expectLater(
          editor.runFormDraftSubmission(() => api.post('/sales/new')),
          throwsStateError,
        );
        expect(
          adapter.attempts,
          1,
          reason:
              'Ambiguous results remain locked instead of causing a duplicate write',
        );
        expect(adapter.accepted, 0);
        expect(
          env.container
              .read(formDraftsProvider)
              .single
              .data['_formDraftSubmissionPending'],
          isTrue,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        env.router.dispose();
        env.container.dispose();
      },
    );
  }
}
