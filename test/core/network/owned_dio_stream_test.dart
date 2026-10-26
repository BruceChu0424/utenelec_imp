@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/owned_dio.dart';

void main() {
  test(
    'graceful release preserves a response that is still streaming',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final finish = Completer<void>();
      addTearDown(() async {
        if (!finish.isCompleted) finish.complete();
        await server.close(force: true);
      });
      server.listen((request) async {
        request.response.write('first');
        await request.response.flush();
        await finish.future;
        request.response.write('last');
        await request.response.close();
      });

      final response = await withOwnedDio(
        () => Dio(),
        (dio) => dio.get<ResponseBody>(
          'http://127.0.0.1:${server.port}/stream',
          options: Options(responseType: ResponseType.stream),
        ),
      );
      final stream = response.data!.stream.toList();
      finish.complete();
      final bytes = (await stream).expand((part) => part).toList();
      expect(String.fromCharCodes(bytes), 'firstlast');
    },
  );
}
