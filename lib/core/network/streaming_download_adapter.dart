import 'package:dio/dio.dart';
import 'streaming_download_adapter_stub.dart'
    if (dart.library.js_interop) 'streaming_download_adapter_web.dart'
    as platform;

/// Use Fetch for streaming downloads and redirect-fenced browser API requests.
/// The browser's XHR adapter cannot honor Dio's followRedirects=false contract.
void installStreamingDownloadAdapter(Dio dio) {
  dio.httpClientAdapter = platform.wrapStreamingDownloads(
    dio.httpClientAdapter,
  );
}
