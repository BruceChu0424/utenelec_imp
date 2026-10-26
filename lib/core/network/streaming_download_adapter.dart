import 'package:dio/dio.dart';
import 'streaming_download_adapter_stub.dart'
    if (dart.library.js_interop) 'streaming_download_adapter_web.dart'
    as platform;

/// Preserve the standard transport for all other API/JSON/upload requests.
void installStreamingDownloadAdapter(Dio dio) {
  dio.httpClientAdapter = platform.wrapStreamingDownloads(
    dio.httpClientAdapter,
  );
}
