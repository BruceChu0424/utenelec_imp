import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'responsive_json_decoder.dart';
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
