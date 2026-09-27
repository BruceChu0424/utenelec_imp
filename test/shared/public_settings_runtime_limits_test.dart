// 公共运行时设置是前端规则的唯一来源 (ADR-110)：附件单文件上限、
// 徽章轮询间隔都按服务端下发的值走；拉取失败时回到与服务端出厂默认一致的兜底值。
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/security/input_validators.dart';
import 'package:uten_imp/shared/attachments/attachment_file_rules.dart';
import 'package:uten_imp/shared/attachments/pending_attachment_controller.dart';
import 'package:uten_imp/shared/repositories/public_settings_repository.dart';

void main() {
  tearDown(AttachmentLimits.reset);

  test('解析新增的公共设置字段，缺省时回到出厂默认', () {
    final parsed = PublicSettings.fromJson(const {
      'idleTimeoutMinutes': 20,
      'auditReceiptRetentionMonths': 36,
      'attachmentMaxBytes': 10485760,
      'badgePollSeconds': 90,
    });
    expect(parsed.attachmentMaxBytes, 10485760);
    expect(parsed.badgePollSeconds, 90);

    final fallback = PublicSettings.fromJson(const {});
    expect(fallback.attachmentMaxBytes, kAttachmentMaxFileBytes);
    expect(fallback.badgePollSeconds, 60);
  });

  test('拉到公共设置后，新建单据的附件暂存按服务端上限预检', () async {
    final dio = Dio(BaseOptions(baseUrl: 'http://localhost:8080/api'));
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (request, handler) => handler.resolve(
          Response<dynamic>(
            requestOptions: request,
            statusCode: 200,
            data: const {'attachmentMaxBytes': 10},
          ),
        ),
      ),
    );

    await DioPublicSettingsRepository(ApiClient(dio)).fetch();

    final controller = PendingAttachmentController();
    expect(controller.maxFileBytes, 10);
    final tooBig = PlatformFile(
      name: '合同.pdf',
      size: 11,
      bytes: Uint8List.fromList(List.filled(11, 1)),
    );
    expect(controller.add(tooBig), contains('超过单文件'));
  });

  test('非正数的上限视为无效，保持原值', () {
    AttachmentLimits.apply(0);
    expect(AttachmentLimits.maxFileBytes, kAttachmentMaxFileBytes);
  });

  test('密码只要求非空，不限制长度或字符组合', () {
    for (final password in ['1', 'a', '密', '!', 'x' * 129, ' 1 ']) {
      expect(InputValidators.password(password), isNull);
    }
    for (final password in [null, '', ' \t\n']) {
      expect(InputValidators.password(password), '密码不能为空');
    }
  });
}
