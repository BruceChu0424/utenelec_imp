import 'package:dio/dio.dart';

/// 面向中国大陆企业网络（移动网络、园区 Wi-Fi、跨运营商链路）的统一超时策略。
const apiConnectTimeout = Duration(seconds: 15);
const apiSendTimeout = Duration(seconds: 30);
const apiReceiveTimeout = Duration(seconds: 45);
const apiDownloadReceiveTimeout = Duration(minutes: 2);

/// 完整列表 NDJSON 流的帧间空闲上限（2026-11-10 G）：服务端把写响应移出数据事务后，
/// 首帧与栅栏后回放之间是整个内部扫描的静默期，合法扫描最长可到服务端 60 秒完整读取
/// 预算；帧间空闲须高于该预算，让服务端自己的错误帧合同裁决，而不是客户端提前掐断。
const apiSummaryStreamChunkIdleTimeout = Duration(seconds: 75);

BaseOptions buildApiBaseOptions(String baseUrl) => BaseOptions(
  baseUrl: baseUrl,
  connectTimeout: apiConnectTimeout,
  sendTimeout: apiSendTimeout,
  receiveTimeout: apiReceiveTimeout,
  headers: const {'Content-Type': 'application/json'},
);
