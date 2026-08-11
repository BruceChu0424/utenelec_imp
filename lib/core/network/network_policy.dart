import 'package:dio/dio.dart';

/// 面向中国大陆企业网络（移动网络、园区 Wi-Fi、跨运营商链路）的统一超时策略。
const apiConnectTimeout = Duration(seconds: 15);
const apiSendTimeout = Duration(seconds: 30);
const apiReceiveTimeout = Duration(seconds: 45);
const apiDownloadReceiveTimeout = Duration(minutes: 2);

BaseOptions buildApiBaseOptions(String baseUrl) => BaseOptions(
  baseUrl: baseUrl,
  connectTimeout: apiConnectTimeout,
  sendTimeout: apiSendTimeout,
  receiveTimeout: apiReceiveTimeout,
  headers: const {'Content-Type': 'application/json'},
);
