import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/api_exception.dart';
import 'package:uten_imp/shared/attachments/attachment.dart';
import 'package:uten_imp/shared/attachments/attachment_service.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';

/// 记录每次 upload 的 (ownerId, 文件名)，可按文件名或 owner 制造失败。
class _Uploads extends AttachmentService {
  _Uploads() : super(ApiClient(Dio()));
  final calls = <(String owner, String name)>[];
  final failNames = <String>{};
  final failOwners = <String>{};

  @override
  Future<Attachment> upload({
    required String ownerType,
    required String ownerId,
    required String fileName,
    required String contentType,
    required Uint8List bytes,
    String? category,
  }) async {
    calls.add((ownerId, fileName));
    if (failNames.contains(fileName) || failOwners.contains(ownerId)) {
      throw ApiException('CONFLICT', '扫描服务不可用');
    }
    return Attachment(
      id: '$ownerId/$fileName',
      ownerType: ownerType,
      ownerId: ownerId,
      storageKey: 'k/$fileName',
      originalName: fileName,
      contentType: contentType,
      sizeBytes: bytes.length,
      category: category,
    );
  }
}

PlatformFile _file(String name, [int size = 3]) => PlatformFile(
  name: name,
  size: size,
  bytes: Uint8List.fromList(List.filled(size, 7)),
);

void main() {
  test('add validates type, single-file limit and the in-memory total cap', () {
    final c = PendingAttachmentController(maxFileBytes: 10, maxTotalBytes: 15);
    var notified = 0;
    c.addListener(() => notified++);

    expect(c.add(_file('病毒.exe')), contains('类型不支持'));
    expect(c.add(PlatformFile(name: '空.pdf', size: 0)), contains('无法读取'));
    expect(c.add(_file('太大.pdf', 11)), contains('超过单文件'));
    expect(c.add(_file('合同.pdf', 8), category: '合同'), isNull);
    expect(c.add(_file('确认.png', 8)), contains('合计超过'));
    expect(c.items.map((i) => i.name), ['合同.pdf']);
    expect(c.items.single.contentType, 'application/pdf');
    expect(c.items.single.category, '合同');
    expect(c.totalBytes, 8);
    expect(notified, 1);

    c.removeAt(0);
    expect(c.isEmpty, isTrue);
    expect(notified, 2);
  });

  test(
    'flush uploads to the saved owner and keeps only failed items',
    () async {
      final c = PendingAttachmentController();
      final service = _Uploads()..failNames.add('坏.xlsx');
      expect(c.add(_file('合同.pdf')), isNull);
      expect(c.add(_file('坏.xlsx')), isNull);
      expect(c.add(_file('图.png')), isNull);

      final first = await c.flush(
        service,
        ownerType: 'SALES_ORDER',
        ownerId: 'order-1',
      );
      expect(first.allSucceeded, isFalse);
      expect(first.uploadedCount, 2);
      expect(first.failed.map((f) => f.name), ['坏.xlsx']);
      expect(c.items.map((i) => i.name), ['坏.xlsx']);
      expect(c.items.single.lastError, '扫描服务不可用');
      expect(c.isFlushing, isFalse);
      expect(service.calls, [
        ('order-1', '合同.pdf'),
        ('order-1', '坏.xlsx'),
        ('order-1', '图.png'),
      ]);

      // 重试只传失败项；成功后暂存清空。
      service.failNames.clear();
      final second = await c.flush(
        service,
        ownerType: 'SALES_ORDER',
        ownerId: 'order-1',
      );
      expect(second.allSucceeded, isTrue);
      expect(second.uploadedCount, 1);
      expect(c.isEmpty, isTrue);
      expect(service.calls.length, 4);
    },
  );

  test(
    'split batch attaches each file to every order and retries only the missing owners',
    () async {
      final c = PendingAttachmentController();
      final service = _Uploads()..failOwners.add('po-2');
      expect(c.add(_file('合同.pdf')), isNull);

      final first = await c.flushToOwners(
        service,
        ownerType: 'PURCHASE_ORDER',
        ownerIds: ['po-1', 'po-2', 'po-3'],
      );
      expect(first.allSucceeded, isFalse);
      expect(c.items.single.uploadedTo, {'po-1'});
      expect(service.calls, [('po-1', '合同.pdf'), ('po-2', '合同.pdf')]);

      service.failOwners.clear();
      final second = await c.flushToOwners(
        service,
        ownerType: 'PURCHASE_ORDER',
        ownerIds: ['po-1', 'po-2', 'po-3'],
      );
      expect(second.allSucceeded, isTrue);
      expect(c.isEmpty, isTrue);
      // po-1 不重复上传。
      expect(service.calls.skip(2), [('po-2', '合同.pdf'), ('po-3', '合同.pdf')]);
    },
  );

  test('flush with nothing pending is a no-op', () async {
    final c = PendingAttachmentController();
    final service = _Uploads();
    final report = await c.flush(
      service,
      ownerType: 'SALES_ORDER',
      ownerId: 'order-1',
    );
    expect(report.allSucceeded, isTrue);
    expect(service.calls, isEmpty);
  });
}
