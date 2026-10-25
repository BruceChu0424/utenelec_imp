import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/core/network/authenticated_request_scope.dart';
import 'package:uten_imp/features/company_files/models/company_file.dart';
import 'package:uten_imp/features/company_files/models/company_file_upload.dart';
import 'package:uten_imp/features/company_files/repositories/company_file_repository.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';

final _api = ApiClient(Dio(BaseOptions(baseUrl: 'https://library.test/api')));
const _entry = CompanyFile(
  id: 'node',
  name: '模板.txt',
  kind: 'FILE',
  version: 1,
  pending: true,
  allowedActions: {'upload', 'view'},
);
const _receipt = Attachment(
  id: 'receipt',
  ownerType: 'COMPANY_FILE',
  ownerId: 'node',
  storageKey: 'private/original',
  originalName: '模板.txt',
  sizeBytes: 3,
  sha256: 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
);

class _Repository extends CompanyFileRepository {
  _Repository() : super(_api);
  int reserveCount = 0, completeCount = 0;
  bool loseReservationResponse = false,
      loseCompleteResponse = false,
      completed = false;
  final requestIds = <String>[];
  @override
  Future<CompanyFile> reserveFile({
    String? parentId,
    required String name,
    required String requestId,
  }) async {
    reserveCount++;
    requestIds.add(requestId);
    if (loseReservationResponse) {
      loseReservationResponse = false;
      throw NetworkTimeoutException();
    }
    return _entry;
  }

  @override
  Future<CompanyFile> get(String id) async => completed
      ? const CompanyFile(
          id: 'node',
          name: '模板.txt',
          kind: 'FILE',
          version: 2,
          attachmentId: 'receipt',
          allowedActions: {'view'},
        )
      : _entry;
  @override
  Future<CompanyFile> complete(CompanyFile file, String attachmentId) async {
    expect(attachmentId, 'receipt');
    completeCount++;
    completed = true;
    if (loseCompleteResponse) {
      loseCompleteResponse = false;
      throw NetworkTimeoutException();
    }
    return get(file.id);
  }
}

class _Attachments extends AttachmentService {
  _Attachments() : super(_api);
  int rawCount = 0, confirmCount = 0, presignCount = 0;
  bool loseConfirmationResponse = false;
  Object? presignFailure;
  List<Attachment> receipts = [];
  @override
  Future<List<Attachment>> listHistory({
    required String ownerType,
    required String ownerId,
  }) async {
    expect(ownerType, 'COMPANY_FILE');
    expect(ownerId, 'node');
    return receipts;
  }

  @override
  Future<PresignResult> presign({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required int sizeBytes,
  }) async {
    presignCount++;
    if (presignFailure != null) throw presignFailure!;
    return const PresignResult(
      storageKey: 'private/original',
      url: '/raw/private',
      method: 'PUT',
      contentType: 'text/plain',
      headers: {},
      formFields: {},
      confirmToken: 'private-token',
    );
  }

  @override
  Future<void> uploadBytes(PresignResult upload, Uint8List bytes) async {
    rawCount++;
    expect(bytes, [97, 98, 99]);
  }

  @override
  Future<Attachment> confirm({
    required String storageKey,
    required String confirmToken,
    required String ownerType,
    required String ownerId,
    required String originalName,
    required String contentType,
    required int sizeBytes,
    String? category,
  }) async {
    confirmCount++;
    receipts = [_receipt];
    if (loseConfirmationResponse) {
      loseConfirmationResponse = false;
      throw NetworkTimeoutException();
    }
    return _receipt;
  }
}

Future<AuthenticatedRequestScope> _scope({bool Function()? current}) =>
    _api.captureRequestScope(isCurrent: current ?? () => true);

void main() {
  CompanyFileUpload attempt() => CompanyFileUpload(
    name: '模板.txt',
    bytes: Uint8List.fromList([97, 98, 99]),
    contentType: 'text/plain',
  );

  test(
    'original bytes use the standard quarantine and confirmation protocol',
    () async {
      final repository = _Repository(),
          attachments = _Attachments(),
          file = attempt();
      final phases = <CompanyFileUploadState>[];
      await file.send(
        repository: repository,
        attachments: attachments,
        scope: await _scope(),
        parentId: 'folder',
        onChanged: () => phases.add(file.state),
      );
      expect(file.state, CompanyFileUploadState.done);
      expect(repository.reserveCount, 1);
      expect(repository.completeCount, 1);
      expect(attachments.rawCount, 1);
      expect(attachments.confirmCount, 1);
      expect(phases, contains(CompanyFileUploadState.verifying));
    },
  );

  test(
    'a lost reservation response reuses the same request identity',
    () async {
      final repository = _Repository()..loseReservationResponse = true;
      final attachments = _Attachments(),
          file = attempt(),
          scope = await _scope();
      await file.send(
        repository: repository,
        attachments: attachments,
        scope: scope,
        parentId: null,
        onChanged: () {},
      );
      expect(file.state, CompanyFileUploadState.unknown);
      expect(attachments.rawCount, 0);
      await file.send(
        repository: repository,
        attachments: attachments,
        scope: scope,
        parentId: null,
        onChanged: () {},
      );
      expect(file.complete, isTrue);
      expect(repository.requestIds.toSet(), hasLength(1));
      expect(attachments.rawCount, 1);
    },
  );

  test(
    'a lost confirm response reconciles the original receipt without reupload',
    () async {
      final repository = _Repository(),
          attachments = _Attachments()..loseConfirmationResponse = true;
      final file = attempt(), scope = await _scope();
      await file.send(
        repository: repository,
        attachments: attachments,
        scope: scope,
        parentId: null,
        onChanged: () {},
      );
      expect(file.state, CompanyFileUploadState.unknown);
      await file.send(
        repository: repository,
        attachments: attachments,
        scope: scope,
        parentId: null,
        onChanged: () {},
      );
      expect(file.complete, isTrue);
      expect(attachments.rawCount, 1);
      expect(attachments.confirmCount, 1);
      expect(repository.reserveCount, 1);
    },
  );

  test(
    'lost publication receipt checks the same node rather than republishing',
    () async {
      final repository = _Repository()..loseCompleteResponse = true;
      final attachments = _Attachments(),
          file = attempt(),
          scope = await _scope();
      await file.send(
        repository: repository,
        attachments: attachments,
        scope: scope,
        parentId: null,
        onChanged: () {},
      );
      expect(file.state, CompanyFileUploadState.unknown);
      await file.send(
        repository: repository,
        attachments: attachments,
        scope: scope,
        parentId: null,
        onChanged: () {},
      );
      expect(file.complete, isTrue);
      expect(repository.completeCount, 1);
      expect(attachments.rawCount, 1);
    },
  );

  test(
    'session fencing stops the next phase and does not adopt a fresh identity',
    () async {
      final repository = _Repository(),
          attachments = _Attachments(),
          file = attempt();
      var current = true;
      final scope = await _scope(current: () => current);
      current = false;
      await expectLater(
        file.send(
          repository: repository,
          attachments: attachments,
          scope: scope,
          parentId: null,
          onChanged: () {},
        ),
        throwsA(isA<ApiException>()),
      );
      expect(repository.reserveCount, 0);
      expect(attachments.rawCount, 0);
    },
  );

  test('missing capabilities fail closed and preserve an immutable UUID', () {
    final file = CompanyFile.fromJson({
      'id': 'uuid',
      'name': '公开模板.docx',
      'kind': 'FILE',
      'version': 3,
    });
    expect(file.allows('download'), isFalse);
    expect(file.id, 'uuid');
    final listing = CompanyFileListing.fromJson({
      'entries': <Object?>[],
      'total': 0,
    });
    expect(listing.allows('upload'), isFalse);
    expect(listing.canReorder, isFalse);
  });

  test(
    'a scanner outage stops the remaining queue before reserving another file',
    () async {
      final repository = _Repository();
      final attachments = _Attachments()
        ..presignFailure = ApiException(
          'SCANNER_UNAVAILABLE',
          'Scanner unavailable',
          httpStatus: 503,
          hasResponseCode: true,
        );
      final first = attempt(), second = attempt();
      await sendCompanyFileUploadQueue(
        attempts: [first, second],
        repository: repository,
        attachments: attachments,
        scope: await _scope(),
        parentIdOf: (_) => null,
        shouldStop: () => false,
        onChanged: () {},
      );
      expect(first.state, CompanyFileUploadState.unknown);
      expect(second.state, CompanyFileUploadState.stopped);
      expect(repository.reserveCount, 1);
      expect(attachments.rawCount, 0);
    },
  );

  test(
    'stopping after the current file retains its acknowledged upload',
    () async {
      final repository = _Repository(), attachments = _Attachments();
      final first = attempt(), second = attempt();
      await sendCompanyFileUploadQueue(
        attempts: [first, second],
        repository: repository,
        attachments: attachments,
        scope: await _scope(),
        parentIdOf: (_) => null,
        shouldStop: () => first.complete,
        onChanged: () {},
      );
      expect(first.complete, isTrue);
      expect(second.state, CompanyFileUploadState.stopped);
      expect(repository.reserveCount, 1);
      expect(repository.completeCount, 1);
    },
  );
}
