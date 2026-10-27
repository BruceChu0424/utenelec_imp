import 'dart:typed_data';

import 'package:dio/dio.dart';

Future<void> initializeCompanyTls(
  Future<ByteData> Function(String key) loadAsset,
) async {}

Dio createCompanyDio(BaseOptions options) => Dio(options);
