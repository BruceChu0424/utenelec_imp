import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'diagnostic_store.dart';

const _channel = MethodChannel('com.uten.imp/diagnostics');
String diagnosticArchitecture() {
  final abi = Abi.current().toString().toLowerCase();
  if (abi.contains('arm64')) return 'arm64';
  if (abi.contains('x64')) return 'x64';
  if (abi.contains('ia32') || abi.contains('x86')) return 'x86';
  if (abi.contains('arm')) return 'arm';
  return 'unknown';
}

Future<DiagnosticStore> createDiagnosticStore(String version) async {
  String? nativeDirectory;
  if (Platform.isWindows) {
    try {
      nativeDirectory = await _channel.invokeMethod<String>('getLogDirectory');
    } on MissingPluginException {
      /* An old runner can still export Dart logs. */
    } on PlatformException {
      /* Fall back to the application-private directory. */
    }
  }
  final root =
      nativeDirectory ??
      '${(await getApplicationSupportDirectory()).path}/client-logs/${Platform.operatingSystem}/${kReleaseMode
          ? 'Release'
          : kProfileMode
          ? 'Profile'
          : 'Debug'}';
  final directory = Directory(root);
  final store = await FileDiagnosticStore.open(directory, version);
  if (Platform.isWindows) {
    // The trusted, already installed updater keeps a bounded snapshot here too,
    // so users can copy one log directory after a failed in-place upgrade.
    final local = Platform.environment['LOCALAPPDATA'];
    if (local != null) {
      final previous = File(
        '$local/com.uten.uten_imp/client-updates/last-update.log',
      );
      try {
        if (await FileSystemEntity.type(previous.path, followLinks: false) ==
            FileSystemEntityType.file) {
          final input = await previous.open();
          try {
            final length = await input.length();
            await input.setPosition((length - 65536).clamp(0, length));
            var tail = await input.read(65536);
            if (length > 65536) {
              final newline = tail.indexOf(10);
              tail = newline < 0
                  ? Uint8List(0)
                  : Uint8List.sublistView(tail, newline + 1);
            }
            await File(
              '$root/update-previous.log',
            ).writeAsBytes(tail, flush: true);
          } finally {
            await input.close();
          }
        }
      } on FileSystemException {
        /* An in-flight updater may own the file. */
      }
    }
  }
  return store;
}

/// One writer per process; only exact owned filenames are eligible for expiry.
class FileDiagnosticStore implements DiagnosticStore {
  FileDiagnosticStore._(this.root, this.file);
  final Directory root;
  File file;
  int _size = 0;
  int _part = 0;
  static final ownedName = RegExp(
    r'^(app|native|fatal|update)-[a-zA-Z0-9_.+\-]+\.log$',
  );
  static const maxFileBytes = 2 * 1024 * 1024;
  @override
  String get directory => root.path;

  static Future<FileDiagnosticStore> open(
    Directory root,
    String version,
  ) async {
    await root.create(recursive: true);
    final safeVersion = version.replaceAll(RegExp(r'[^a-zA-Z0-9_.+\-]'), '_');
    final name =
        'app-$safeVersion-${DateTime.now().toUtc().microsecondsSinceEpoch}-$pid';
    final store = FileDiagnosticStore._(root, File('${root.path}/$name.log'));
    await store.file.writeAsString('', mode: FileMode.writeOnly);
    await store._expire();
    return store;
  }

  Future<List<File>> _owned() async {
    final files = <File>[];
    await for (final entry in root.list(followLinks: false)) {
      final leaf = entry.uri.pathSegments.last;
      if (entry is File && ownedName.hasMatch(leaf)) files.add(entry);
    }
    final dated = <(File, DateTime)>[];
    for (final entry in files) {
      dated.add((entry, (await entry.stat()).modified));
    }
    dated.sort((a, b) => b.$2.compareTo(a.$2));
    return dated.map((x) => x.$1).toList();
  }

  Future<void> _expire() async {
    final owned = await _owned();
    for (final old in owned.skip(16)) {
      if (old.path == file.path) continue;
      // Non-recursive deletion of a proven leaf inside this private directory.
      try {
        await old.delete();
      } on FileSystemException {
        /* Active native log. */
      }
    }
  }

  @override
  Future<void> append(String lines) async {
    final bytes = utf8.encode(lines);
    if (_size + bytes.length > maxFileBytes && _size > 0) {
      final stem = file.path.replaceFirst(RegExp(r'(?:-part\d+)?\.log$'), '');
      file = File('$stem-part${++_part}.log');
      _size = 0;
      await file.writeAsString('', mode: FileMode.writeOnly);
      await _expire();
    }
    await file.writeAsBytes(bytes, mode: FileMode.append, flush: true);
    _size += bytes.length;
  }

  @override
  Future<Uint8List> readRecent() async {
    final bytes = BytesBuilder(copy: false);
    for (final current in (await _owned()).take(8)) {
      final reader = await current.open();
      try {
        final length = await reader.length();
        final start = (length - 128 * 1024).clamp(0, length);
        await reader.setPosition(start);
        var tail = await reader.read(length - start);
        if (start > 0) {
          final newline = tail.indexOf(10);
          tail = newline < 0
              ? Uint8List(0)
              : Uint8List.sublistView(tail, newline + 1);
        }
        bytes.add(tail);
        bytes.addByte(10);
      } finally {
        await reader.close();
      }
    }
    return bytes.takeBytes();
  }

  @override
  Future<void> openDirectory() async {
    if (Platform.isWindows) {
      try {
        await _channel.invokeMethod<void>('openLogDirectory');
        return;
      } on MissingPluginException {
        /* Older runner. */
      }
    }
    await launchUrl(
      Uri.directory(root.path),
      mode: LaunchMode.externalApplication,
    );
  }
}
