import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/server_config.dart';
import 'package:uten_imp/shared/ai/ai_job_models.dart';
import 'package:uten_imp/shared/ai/ai_job_repository.dart';
import 'package:uten_imp/shared/ai/guided/ai_guided_file_plan.dart';
import 'package:uten_imp/shared/auth/permissions.dart';
import 'package:uten_imp/shared/providers/authenticated_scope_provider.dart';

void main() {
  test(
    'document page hint strips values and rejects malformed or overlong paths',
    () {
      expect(
        safeAiGuidedPageRoute('/sales/orders/new?value=secret#total'),
        '/sales/orders/new',
      );
      expect(safeAiGuidedPageRoute('/${'a' * 239}'), '/${'a' * 239}');
      for (final raw in [
        null,
        '/${'a' * 240}',
        '//foreign.invalid/page',
        'https://foreign.invalid/page',
        '/sales/../admin',
        '/sales/%2Fadmin',
        '/sales/orders\nnew',
      ]) {
        expect(safeAiGuidedPageRoute(raw), isNull, reason: '$raw');
      }
    },
  );

  testWidgets(
    'page hint survives fresh validation and local restore without inventing one',
    (tester) async {
      final harness = await _pump(tester);
      for (final route in <String?>['/sales/quotes/new?amount=secret', null]) {
        final plan = harness.plan(pageRoute: route);
        final fresh = await validateAiGuidedFilePlan(harness.ref, plan);
        final restored = AiGuidedFilePlan.restoreLocalDraft(
          fresh.toLocalDraft(),
          fresh.identity,
        )!;
        expect(restored.pageRoute, route == null ? null : '/sales/quotes/new');
        expect(restored.toLocalDraft().containsKey('pageRoute'), route != null);
        final tampered = AiGuidedFilePlan.restoreLocalDraft({
          ...fresh.toLocalDraft(),
          'pageRoute': '/${'a' * 240}',
        }, fresh.identity)!;
        expect(tampered.pageRoute, isNull);
        expect(tampered.file.bytes, fresh.file.bytes);
      }
    },
  );

  test(
    'source binding rejects changed bytes, filename and malformed digest',
    () {
      final file = _file();
      final result = AiGuidedFileResult.fromJson(_result(file));
      expect(result.matchesSource(file), isTrue);
      expect(result.matchesSource(_file(text: 'different bytes')), isFalse);
      expect(result.matchesSource(_file(name: 'another.csv')), isFalse);
      expect(
        result.matchesSource(PlatformFile(name: file.name, size: file.size)),
        isFalse,
      );
      final hash = sha256.convert(file.bytes!).toString();
      for (final invalid in ['', 'g' * 64, '$hash trailing-junk']) {
        final json = _result(file)
          ..['source'] = {'fileName': file.name, 'sha256': invalid};
        expect(
          AiGuidedFileResult.fromJson(json).matchesSource(file),
          isFalse,
          reason: 'A digest must be validated, not truncated into validity',
        );
      }
    },
  );

  test(
    'unknown workflow and non-invoice payload cannot become executable data',
    () {
      final json = _result(_file(), workflow: 'GRANT_SUPER_ADMIN')
        ..['url'] = '/admin/permissions'
        ..['_access'] = {'actor': 'forged'}
        ..['choices'] = [
          {'workflow': 'RUN_SQL', 'title': 'unsafe'},
        ]
        ..['fields'] = {
          'totalAmount': 999.99,
          'invoiceNo': '12345678',
          'url': '/admin/permissions',
        };
      final result = AiGuidedFileResult.fromJson(json);
      expect(result.workflow, AiGuidedWorkflow.none);
      expect(result.choices, isEmpty);
      expect(result.fields, {'invoiceNo': '12345678'});
      expect(result.toJson(), isNot(contains('_access')));
      expect(result.toJson(), isNot(contains('url')));
    },
  );

  testWidgets(
    'local fence blocks new account, server, epoch and read-only identity',
    (tester) async {
      final harness = await _pump(tester);
      final plan = harness.plan();
      expect(plan.matches(harness.ref), isTrue);
      for (final scope in [
        null,
        const AuthenticatedScope(userId: 'another'),
        const AuthenticatedScope(userId: 'owner', epoch: 2),
        const AuthenticatedScope(
          userId: 'owner',
          actorId: 'operator',
          readOnly: true,
        ),
      ]) {
        harness.container.read(harness.scope.notifier).state = scope;
        await tester.pump();
        await expectLater(
          validateAiGuidedFilePlan(harness.ref, plan),
          throwsA(_api('FORBIDDEN')),
        );
      }
      harness.container.read(harness.scope.notifier).state =
          const AuthenticatedScope(userId: 'owner');
      harness.container.read(harness.server.notifier).state =
          'https://another.example.test/api';
      await tester.pump();
      await expectLater(
        validateAiGuidedFilePlan(harness.ref, plan),
        throwsA(_api('FORBIDDEN')),
      );
      expect(harness.jobs.reads, isEmpty);
    },
  );

  testWidgets(
    'removed form permission and unknown selected workflow fail before reading the job',
    (tester) async {
      final harness = await _pump(tester);
      final plan = harness.plan();
      harness.container.read(harness.permissions.notifier).state = const {
        'ai:use',
      };
      await tester.pump();
      await expectLater(
        validateAiGuidedFilePlan(harness.ref, plan),
        throwsA(_api('FORBIDDEN')),
      );
      harness.container.read(harness.permissions.notifier).state = _permissions;
      await tester.pump();
      final unknown = harness.plan(workflow: AiGuidedWorkflow.none);
      await expectLater(
        validateAiGuidedFilePlan(harness.ref, unknown),
        throwsA(_api('FORBIDDEN')),
      );
      expect(harness.jobs.reads, isEmpty);
    },
  );

  testWidgets(
    'fresh owner-scoped server result replaces forged router-extra fields',
    (tester) async {
      final harness = await _pump(tester);
      final file = _file();
      final stale = _result(
        file,
        fields: {'totalAmount': '999999', 'invoiceNo': 'FORGED'},
      );
      final fresh = _result(
        file,
        fields: {'totalAmount': '113.00', 'invoiceNo': '12345678'},
      )..['fieldConfidence'] = {'totalAmount': 'LOW'};
      harness.jobs.response = _snapshot(result: fresh);
      final plan = harness.plan(file: file, result: stale);
      final validated = await validateAiGuidedFilePlan(harness.ref, plan);
      expect(harness.jobs.reads, ['job-1']);
      expect(validated.result.fields, {
        'totalAmount': '113.00',
        'invoiceNo': '12345678',
      });
      expect(validated.result.isHighConfidence('totalAmount'), isFalse);
      expect(identical(validated.result, plan.result), isFalse);
      expect(validated.file.name, file.name);
      expect(validated.file.bytes, file.bytes);
    },
  );

  testWidgets(
    'retained original is immutable and cannot be changed through the picker bytes',
    (tester) async {
      final harness = await _pump(tester);
      final pickerFile = _file();
      final original = Uint8List.fromList(pickerFile.bytes!);
      final plan = harness.plan(file: pickerFile);
      pickerFile.bytes![0] = pickerFile.bytes![0] ^ 1;
      expect(plan.file.bytes, original);
      expect(plan.sourceSha256, sha256.convert(original).toString());
      expect(plan.matches(harness.ref), isTrue);
      expect(() => plan.file.bytes![0] = 9, throwsUnsupportedError);
      harness.jobs.response = _snapshot(result: _result(plan.file));
      final validated = await validateAiGuidedFilePlan(harness.ref, plan);
      expect(validated.file.bytes, original);
      expect(validated.result.matchesSource(validated.file), isTrue);
    },
  );

  testWidgets(
    'identity or permissions changed while GET is pending discard its late result',
    (tester) async {
      final harness = await _pump(tester);
      for (final permissionChange in [false, true]) {
        harness.container.read(harness.scope.notifier).state =
            const AuthenticatedScope(userId: 'owner');
        harness.container.read(harness.permissions.notifier).state =
            _permissions;
        await tester.pump();
        final pending = Completer<AiJobSnapshot>();
        harness.jobs.pending = pending;
        final result = validateAiGuidedFilePlan(harness.ref, harness.plan());
        final rejected = expectLater(result, throwsA(_api('FORBIDDEN')));
        if (permissionChange) {
          harness.container.read(harness.permissions.notifier).state = const {
            'ai:use',
          };
        } else {
          harness.container.read(harness.scope.notifier).state =
              const AuthenticatedScope(userId: 'other');
        }
        await tester.pump();
        pending.complete(_snapshot());
        await rejected;
      }
      expect(harness.jobs.reads, ['job-1', 'job-1']);
    },
  );

  testWidgets('wrong job identity kind status and absent result are rejected', (
    tester,
  ) async {
    final harness = await _pump(tester);
    final plan = harness.plan();
    for (final snapshot in [
      _snapshot(id: 'other-job'),
      _snapshot(kind: 'ERP_CHAT'),
      _snapshot(status: AiJobStatus.running),
      _snapshot(status: AiJobStatus.failed),
      _snapshot(status: AiJobStatus.cancelled),
      const AiJobSnapshot(
        id: 'job-1',
        kind: aiGuidedRouteKind,
        status: AiJobStatus.succeeded,
      ),
    ]) {
      harness.jobs.response = snapshot;
      await expectLater(
        validateAiGuidedFilePlan(harness.ref, plan),
        throwsA(_api('DOCUMENT_ROUTE_INVALID')),
      );
    }
    expect(harness.jobs.reads, hasLength(6));
  });

  testWidgets(
    'withdrawn workflow choice or changed server source cannot reuse old plan',
    (tester) async {
      final harness = await _pump(tester);
      final plan = harness.plan();
      final wrongName = _result(_file(name: 'different.csv'));
      final wrongBytes = _result(_file(text: 'different'));
      for (final json in [
        _result(_file(), workflow: 'NONE', needsChoice: true),
        _result(_file(), workflow: 'UNKNOWN'),
        wrongName,
        wrongBytes,
      ]) {
        harness.jobs.response = _snapshot(result: json);
        await expectLater(
          validateAiGuidedFilePlan(harness.ref, plan),
          throwsA(_api('DOCUMENT_ROUTE_INVALID')),
        );
      }
      harness.jobs.response = _snapshot(
        result: _result(
          _file(),
          workflow: 'NONE',
          needsChoice: true,
          choices: const ['EXPENSE_CLAIM'],
        ),
      );
      final accepted = await validateAiGuidedFilePlan(harness.ref, plan);
      expect(accepted.workflow, AiGuidedWorkflow.expenseClaim);
      expect(accepted.result.needsChoice, isTrue);
    },
  );

  testWidgets(
    'server deletion and revocation errors propagate without returning cached fields',
    (tester) async {
      final harness = await _pump(tester);
      final plan = harness.plan();
      for (final code in ['NOT_FOUND', 'FORBIDDEN']) {
        harness.jobs.failure = ApiException(code, 'Source no longer readable');
        await expectLater(
          validateAiGuidedFilePlan(harness.ref, plan),
          throwsA(_api(code)),
        );
      }
      expect(harness.jobs.reads, ['job-1', 'job-1']);
    },
  );

  test(
    'local draft corruption is discarded and valid draft preserves exact source bytes',
    () {
      final file = _file();
      final identity = _identity();
      final plan = AiGuidedFilePlan(
        jobId: 'job-1',
        file: file,
        result: AiGuidedFileResult.fromJson(_result(file)),
        workflow: AiGuidedWorkflow.expenseClaim,
        identity: identity,
      );
      final draft = plan.toLocalDraft();
      final restored = AiGuidedFilePlan.restoreLocalDraft(draft, identity);
      expect(restored, isNotNull);
      expect(restored!.file.bytes, file.bytes);
      expect(restored.result.matchesSource(restored.file), isTrue);
      expect(AiGuidedFilePlan.restoreLocalDraft(draft, null), isNull);
      expect(
        AiGuidedFilePlan.restoreLocalDraft('not a draft', identity),
        isNull,
      );
      expect(
        AiGuidedFilePlan.restoreLocalDraft({
          ...draft,
          'bytes': '%not-base64%',
        }, identity),
        isNull,
      );
      expect(
        AiGuidedFilePlan.restoreLocalDraft({...draft, 'bytes': ''}, identity),
        isNull,
      );
      expect(
        AiGuidedFilePlan.restoreLocalDraft({
          ...draft,
          'bytes': base64Encode([1, 2, 3]),
        }, identity),
        isNull,
      );
      expect(
        AiGuidedFilePlan.restoreLocalDraft({
          ...draft,
          'fileName': 'renamed.csv',
        }, identity),
        isNull,
      );
      expect(
        AiGuidedFilePlan.restoreLocalDraft({
          ...draft,
          'workflow': 'RUN_SQL',
        }, identity),
        isNull,
      );
    },
  );

  test(
    'local draft bounds reject oversized encoded and decoded input before accepting a plan',
    () {
      final identity = _identity();
      final raw = {
        'jobId': 'job-1',
        'workflow': 'EXPENSE_CLAIM',
        'fileName': 'large.csv',
        'result': _result(_file()),
      };
      expect(
        AiGuidedFilePlan.restoreLocalDraft({
          ...raw,
          'bytes': 'A' * (20 * 1024 * 1024 + 5),
        }, identity),
        isNull,
      );
      final tooLarge = Uint8List(15 * 1024 * 1024 + 1);
      expect(
        AiGuidedFilePlan.restoreLocalDraft({
          ...raw,
          'bytes': base64Encode(tooLarge),
        }, identity),
        isNull,
      );
    },
  );

  test(
    'request messages compress control characters and truncate without splitting emoji',
    () {
      expect(
        aiGuidedRequestMessage('  发票\r\n\t生成\u0000报销\u007f\u0085  '),
        '发票 生成 报销',
      );
      expect(aiGuidedRequestMessage('x' * 600), 'x' * 512);
      expect(aiGuidedRequestMessage('${'x' * 511}🙂tail'), 'x' * 511);
      expect(aiGuidedRequestMessage('${'x' * 510}🙂tail'), '${'x' * 510}🙂');
      expect(aiGuidedRequestMessage('line 1\nline 2').contains('\n'), isFalse);
    },
  );
}

const _permissions = {
  'ai:use',
  Perm.expenseApply,
  Perm.salesOrderView,
  Perm.salesOrderCreate,
  Perm.salesQuoteView,
  Perm.salesQuoteCreate,
};
AiGuidedFileIdentity _identity() {
  final permissions = _permissions.toList()..sort();
  return (
    scope: const AuthenticatedScope(userId: 'owner'),
    server: 'https://erp.example.test/api',
    permissions: permissions.join('\n'),
  );
}

PlatformFile _file({
  String name = 'invoice.csv',
  String text = 'original invoice bytes',
}) {
  final bytes = Uint8List.fromList(utf8.encode(text));
  return PlatformFile(name: name, size: bytes.length, bytes: bytes);
}

Map<String, dynamic> _result(
  PlatformFile file, {
  String workflow = 'EXPENSE_CLAIM',
  bool needsChoice = false,
  List<String> choices = const [],
  Map<String, String> fields = const {'totalAmount': '100.00'},
}) => {
  'workflow': workflow,
  'documentType': 'INVOICE',
  'title': 'Invoice',
  'summary': 'Review before saving',
  'needsChoice': needsChoice,
  'requiresReview': true,
  'fields': fields,
  'fieldConfidence': {'totalAmount': 'HIGH'},
  'choices': [
    for (final value in choices) {'workflow': value, 'title': value},
  ],
  'source': {
    'fileName': file.name,
    'sha256': sha256.convert(file.bytes!).toString(),
  },
};
AiJobSnapshot _snapshot({
  String id = 'job-1',
  String kind = aiGuidedRouteKind,
  AiJobStatus status = AiJobStatus.succeeded,
  Map<String, dynamic>? result,
}) => AiJobSnapshot(
  id: id,
  kind: kind,
  status: status,
  result: result ?? _result(_file()),
);
Matcher _api(String code) =>
    isA<ApiException>().having((error) => error.code, 'code', code);

Future<_Harness> _pump(WidgetTester tester) async {
  final scope = StateProvider<AuthenticatedScope?>(
    (ref) => const AuthenticatedScope(userId: 'owner'),
  );
  final permissions = StateProvider<Set<String>>((ref) => _permissions);
  final server = StateProvider<String>((ref) => 'https://erp.example.test/api');
  final jobs = _Jobs();
  late WidgetRef widgetRef;
  late ProviderContainer container;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authenticatedScopeProvider.overrideWith((ref) => ref.watch(scope)),
        currentPermissionsProvider.overrideWith(
          (ref) => ref.watch(permissions),
        ),
        apiBaseUrlProvider.overrideWith((ref) => ref.watch(server)),
        aiJobRepositoryProvider.overrideWithValue(jobs),
      ],
      child: Consumer(
        builder: (context, ref, child) {
          widgetRef = ref;
          container = ProviderScope.containerOf(context, listen: false);
          return const SizedBox();
        },
      ),
    ),
  );
  return _Harness(widgetRef, container, scope, permissions, server, jobs);
}

class _Harness {
  _Harness(
    this.ref,
    this.container,
    this.scope,
    this.permissions,
    this.server,
    this.jobs,
  );
  final WidgetRef ref;
  final ProviderContainer container;
  final StateProvider<AuthenticatedScope?> scope;
  final StateProvider<Set<String>> permissions;
  final StateProvider<String> server;
  final _Jobs jobs;
  AiGuidedFilePlan plan({
    PlatformFile? file,
    Map<String, dynamic>? result,
    AiGuidedWorkflow workflow = AiGuidedWorkflow.expenseClaim,
    String? pageRoute,
  }) {
    final source = file ?? _file();
    return AiGuidedFilePlan(
      jobId: 'job-1',
      file: source,
      result: AiGuidedFileResult.fromJson(result ?? _result(source)),
      workflow: workflow,
      identity: container.read(aiGuidedFileIdentityProvider)!,
      pageRoute: pageRoute,
    );
  }
}

class _Jobs implements AiJobRepository {
  final reads = <String>[];
  AiJobSnapshot? response;
  Completer<AiJobSnapshot>? pending;
  Object? failure;
  @override
  Future<AiJobSnapshot> get(String jobId) async {
    reads.add(jobId);
    if (failure case final error?) throw error;
    if (pending case final value?) return value.future;
    return response ?? _snapshot();
  }

  @override
  Future<AiJobSnapshot> submit(AiJobRequest request) =>
      throw StateError('Validation must not upload a new job');
  @override
  Future<void> cancel(String jobId) =>
      throw StateError('Validation must not mutate a source job');
}
