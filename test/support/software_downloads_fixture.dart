import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:uten_imp/core/network/api_client.dart';

/// Only the transport is synthetic: ApiClient performs its real JSON parsing,
/// relative-package path validation, request scopes, and streamed response path.
class SoftwareDownloadsTransport implements HttpClientAdapter {
  SoftwareDownloadsTransport({int byteCount = 8192})
    : bytes = Uint8List.fromList(
        List<int>.generate(byteCount, (index) => index % 251),
      ) {
    releases = [installer()];
    dio = Dio(BaseOptions(baseUrl: 'https://fixture.test/api'))
      ..httpClientAdapter = this;
    api = ApiClient(dio);
  }

  static const x64Id = '466b8f2a-9822-4ada-b362-c239b4a089c1';
  static const arm64Id = '67ba471c-c646-4be3-8599-4c836100d048';
  final Uint8List bytes;
  late final Dio dio;
  late final ApiClient api;
  late List<Map<String, dynamic>> releases;
  final requests = <RequestOptions>[];
  int listStatus = 200;
  int packageStatus = 200;
  Completer<ResponseBody>? delayedList;
  Stream<Uint8List> Function()? streamFactory;
  bool cancellationObserved = false;
  final packageRequested = Completer<void>();

  Map<String, dynamic> installer({
    String id = x64Id,
    String architecture = 'x64',
    String version = '2.5.32',
    String platform = 'windows',
    String kind = 'installer',
    String mode = 'windows_setup',
    String state = 'PUBLISHED',
  }) => {
    'id': id,
    'platform': platform,
    'architecture': architecture,
    'version': version,
    'buildNumber': 2532,
    'releaseNotes': '演示版本：优化工作台与表格体验，保留已保存的设置和草稿。',
    'installMode': mode,
    'packageKind': kind,
    'state': state,
    'fileName': 'uten-imp-$version-windows-$architecture-setup.exe',
    'sizeBytes': bytes.length,
    'sha256': sha256.convert(bytes).toString(),
  };

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    if (options.path == '/client-updates/downloads') {
      if (delayedList != null) return delayedList!.future;
      return ResponseBody.fromString(
        jsonEncode(listStatus == 200 ? releases : {'code': 'UNAVAILABLE'}),
        listStatus,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    if (options.path.endsWith('/download')) {
      if (!packageRequested.isCompleted) packageRequested.complete();
      unawaited(
        cancelFuture?.then((_) {
          cancellationObserved = true;
        }),
      );
      return ResponseBody(
        streamFactory?.call() ??
            Stream.fromIterable([
              Uint8List.sublistView(bytes, 0, bytes.length ~/ 2),
              Uint8List.sublistView(bytes, bytes.length ~/ 2),
            ]),
        packageStatus,
        headers: {
          Headers.contentTypeHeader: ['application/octet-stream'],
          Headers.contentLengthHeader: [bytes.length.toString()],
        },
      );
    }
    if (options.path == '/admin/client-releases') {
      return ResponseBody.fromString(
        '[]',
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    }
    throw StateError('Unexpected fixture request: ${options.path}');
  }

  @override
  void close({bool force = false}) {}
}

/// Models the atomic save boundary, never a real user download directory.
/// Bytes are published only after the verified stream and final scope succeed.
class SoftwarePackageSaveFixture {
  final published = <Uint8List>[];
  final filenames = <String>[];
  int attempts = 0;
  Object? failure;

  Future<String> save(
    Stream<Uint8List> chunks,
    String filename, {
    required bool Function() stillCurrent,
    required Future<void> Function() verifyScope,
    required int maxBytes,
  }) async {
    attempts++;
    final builder = BytesBuilder(copy: false);
    await for (final chunk in chunks) {
      if (!stillCurrent()) throw StateError('Fixture owner retired');
      builder.add(chunk);
      if (builder.length > maxBytes) throw StateError('Fixture limit exceeded');
    }
    await verifyScope();
    if (!stillCurrent()) throw StateError('Fixture owner retired');
    if (failure != null) throw failure!;
    published.add(builder.takeBytes());
    filenames.add(filename);
    return 'fixture-downloads/$filename';
  }
}
