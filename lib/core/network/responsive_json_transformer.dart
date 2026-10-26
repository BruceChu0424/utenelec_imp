import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'responsive_json_decoder.dart';
import 'streaming_download_contract.dart';
import '../performance/ui_work_budget.dart';

/// Keeps UTF-8 and JSON decoding for large responses off the UI executor.
/// Custom response decoders and non-JSON/stream/binary contracts stay with Dio.
class ResponsiveJsonTransformer extends BackgroundTransformer {
  ResponsiveJsonTransformer(this.decoder);

  final ResponsiveJsonDecoder decoder;

  @override
  Future<dynamic> transformResponse(
    RequestOptions options,
    ResponseBody responseBody,
  ) async {
    if (options.extra[streamingDownloadRequestKey] == true &&
        options.responseType == ResponseType.stream &&
        responseBody.statusCode >= 400) {
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in responseBody.stream) {
        if (bytes.length + chunk.length > maxDownloadErrorBytes) {
          return <String, dynamic>{'message': '文件下载失败，请核查原任务后重试'};
        }
        bytes.add(chunk);
      }
      // Auth/MFA/step-up interceptors must receive the same small JSON refusal
      // as ordinary requests, while successful file bodies remain untouched.
      try {
        return await decoder.decodeBytes(
          bytes.takeBytes(),
          isCurrent: () => options.cancelToken?.isCancelled != true,
        );
      } catch (_) {
        if (options.cancelToken?.isCancelled == true) {
          throw options.cancelToken!.cancelError!;
        }
        return <String, dynamic>{'message': '文件下载失败，请核查原任务后重试'};
      }
    }
    if (options.responseType != ResponseType.json ||
        options.responseDecoder != null ||
        !Transformer.isJsonMimeType(
          responseBody.headers[Headers.contentTypeHeader]?.first,
        )) {
      return super.transformResponse(options, responseBody);
    }
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in responseBody.stream) {
      if (options.cancelToken?.isCancelled == true) {
        throw options.cancelToken!.cancelError!;
      }
      bytes.add(chunk);
    }
    final Object? result;
    try {
      result = await decoder.decodeBytes(
        bytes.takeBytes(),
        isCurrent: () => options.cancelToken?.isCancelled != true,
      );
    } on UiWorkCancelled {
      if (options.cancelToken?.isCancelled == true) {
        throw options.cancelToken!.cancelError!;
      }
      rethrow;
    }
    if (options.cancelToken?.isCancelled == true) {
      throw options.cancelToken!.cancelError!;
    }
    return result;
  }
}
