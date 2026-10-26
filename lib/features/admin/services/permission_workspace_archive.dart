import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../../../core/performance/ui_work_budget.dart';
import '../models/permission_configuration.dart';
import '../models/permission_template.dart';
import '../models/permission_template_archive.dart';
import 'permission_archive_files.dart';

const permissionWorkspaceArchiveFilename = '权限-全部设置.zip';
const permissionWorkspaceArchiveMaxBytes = 32 * 1024 * 1024;

/// Preserve each existing import contract inside one complete download. Template
/// names are portable across case-insensitive filesystems and never overwrite
/// another template after filename sanitization.
Future<Uint8List> buildPermissionWorkspaceArchive({
  required PermissionConfiguration configuration,
  required List<PermissionTemplate> templates,
  required bool Function() stillCurrent,
  int maximumBytes = permissionWorkspaceArchiveMaxBytes,
}) async {
  if (maximumBytes <= 0 || maximumBytes > permissionWorkspaceArchiveMaxBytes) {
    throw ArgumentError.value(maximumBytes, 'maximumBytes');
  }
  if (configuration.exportScope != null) {
    throw const FormatException('全部权限导出需要完整的权限设置');
  }
  final rows = List<PermissionTemplate>.of(templates, growable: false);
  final work = UiWorkBudget(
    isCurrent: stillCurrent,
    debugLabel: 'permission-workspace-archive',
  );
  work.ensureCurrent();
  final output = OutputMemoryStream();
  final encoder = ZipEncoder()..startEncode(output);
  var retainedBytes = 22; // End-of-central-directory record.
  void add(String name, Uint8List bytes) {
    work.ensureCurrent();
    if (bytes.length > permissionConfigurationMaxBytes) {
      throw const FormatException('权限文件不能超过 16 MB');
    }
    // Stored entries avoid a second compression heap. Reserve both UTF-8 name
    // copies and conservative local/central headers before growing the buffer.
    final entryBytes = bytes.length + utf8.encode(name).length * 2 + 256;
    if (entryBytes > maximumBytes - retainedBytes) {
      throw const FormatException('完整权限包超过 32 MB，请分项导出权限和模板；未生成部分文件');
    }
    retainedBytes += entryBytes;
    encoder.add(
      ArchiveFile.bytes(name, bytes)..compression = CompressionType.none,
    );
  }

  add(permissionArchiveFilename('全部设置'), configuration.encode());
  await work.checkpoint();
  final names = <String>{};
  for (final template in rows) {
    final requested = permissionArchiveFilename('模板', template.name);
    var filename = requested;
    var index = 2;
    while (!names.add(filename.toLowerCase())) {
      final suffix = '-${index++}';
      final base = requested.substring(0, requested.length - '.json'.length);
      final maximum = 175 - suffix.length;
      filename =
          '${base.length > maximum ? base.substring(0, maximum) : base}$suffix.json';
    }
    add(
      '模板/$filename',
      PermissionTemplateArchive.fromTemplate(template).encode(),
    );
    await work.checkpoint();
  }
  add(
    '导入说明.txt',
    Uint8List.fromList(
      utf8.encode(
        '本文件包含全部已保存的权限设置及全部权限模板。\n\n'
        '请先解压 ZIP：\n'
        '1. 使用右上角「导入权限设置」选择「权限-全部设置.json」，'
        '核对部门、员工与数据范围映射，并预览确认。\n'
        '2. 在「按模板」中点击右下角「导入模板」，'
        '选择「模板」目录中的 JSON 文件。每个文件会创建一个可继续编辑的模板。\n\n'
        '模板不会直接授予员工权限；应用到员工时仍需按现有流程预览及确认。\n',
      ),
    ),
  );
  encoder.endEncode();
  work.ensureCurrent();
  return output.getBytes();
}
