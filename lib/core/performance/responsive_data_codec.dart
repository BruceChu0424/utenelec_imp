import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';

import 'json_value_snapshot.dart';
import 'responsive_data_codec_native.dart'
    if (dart.library.js_interop) 'responsive_data_codec_web.dart'
    as platform;
import 'ui_work_budget.dart';

final Object _deferredJsonCapture = Object();

/// Only changes attachment representation during an immediate local snapshot.
/// The public attachment exporters retain their legacy string representation.
T captureDeferredJsonValues<T>(T Function() capture) =>
    runZoned(capture, zoneValues: {_deferredJsonCapture: true});

/// Owns original bytes independently of a picker/controller's mutable buffer.
/// Identity remains stable across snapshots and the encoded result is cached.
class DraftByteValue {
  DraftByteValue(Uint8List bytes) : this._(bytes, null);

  /// Used only after the restore decoder verified the original encoding.
  factory DraftByteValue.decoded(Uint8List bytes, String encoded) =>
      DraftByteValue._(bytes, encoded);

  DraftByteValue._(Uint8List bytes, this._encoded)
    : _bytes = Uint8List.fromList(bytes).asUnmodifiableView();
  final Uint8List _bytes;
  String? _encoded;
  Future<String>? _encoding;
  Uint8List get bytes => _bytes;
  bool get isEncoded => _encoded != null;
  String get encodedSync => _encoded ??= base64Encode(_bytes);
  Object get jsonValue =>
      Zone.current[_deferredJsonCapture] == true ? this : encodedSync;
  Future<String> encode() {
    if (_encoded case final value?) return Future.value(value);
    return _encoding ??= platform
        .executeDataCodec('base64-encode', _bytes)
        .then((value) => _encoded = value as String)
        .whenComplete(() => _encoding = null);
  }
}

/// Resolve only a detached snapshot. No partial result is published; unchanged
/// strings (including existing base64) are retained without scanning them.
Future<Object?> materializeJsonResponsive(
  Object? value, {
  bool Function()? isCurrent,
}) async {
  final snapshot = snapshotJsonValue(value);
  if (isCurrent?.call() == false) throw const UiWorkCancelled();
  if (_canMaterializeInline(snapshot)) return _materializeInline(snapshot);
  final work = UiWorkBudget(
    maxItems: 2048,
    isCurrent: isCurrent,
    debugLabel: 'draft-materialise',
  );
  Future<Object?> visit(Object? value) async {
    work.ensureCurrent();
    if (value is DraftByteValue) {
      final result = await value.encode();
      work.ensureCurrent();
      return result;
    }
    if (value is Map<String, dynamic>) {
      final result = <String, dynamic>{};
      for (final entry in value.entries) {
        result[entry.key] = await visit(entry.value);
        await work.checkpoint();
      }
      return result;
    }
    if (value is List) {
      final result = <Object?>[];
      for (final item in value) {
        result.add(await visit(item));
        await work.checkpoint();
      }
      return result;
    }
    return value;
  }

  final result = await visit(snapshot);
  work.ensureCurrent();
  return result;
}

bool _canMaterializeInline(Object? value) {
  var nodes = 0, bytes = 0;
  final stack = <Object?>[value];
  while (stack.isNotEmpty) {
    if (++nodes > 512) return false;
    final item = stack.removeLast();
    if (item is DraftByteValue && !item.isEncoded) {
      bytes += item.bytes.length;
      if (bytes > 32768) return false;
    } else if (item is Map<String, dynamic>) {
      if (nodes + item.length > 512) return false;
      stack.addAll(item.values);
    } else if (item is List) {
      if (nodes + item.length > 512) return false;
      stack.addAll(item);
    }
  }
  return true;
}

Object? _materializeInline(Object? value) {
  if (value is DraftByteValue) return value.encodedSync;
  if (value is Map<String, dynamic>) {
    return <String, dynamic>{
      for (final entry in value.entries)
        entry.key: _materializeInline(entry.value),
    };
  }
  if (value is List) {
    return [for (final item in value) _materializeInline(item)];
  }
  return value;
}

Future<String> encodeJsonResponsive(
  Object? value, {
  bool Function()? isCurrent,
}) async {
  final materialized = await materializeJsonResponsive(
    value,
    isCurrent: isCurrent,
  );
  return await platform.executeDataCodec(
        'json-encode',
        materialized,
        isCurrent: isCurrent,
      )
      as String;
}

Future<Object?> decodeJsonResponsive(
  String value, {
  bool Function()? isCurrent,
}) => platform.executeDataCodec('json-decode', value, isCurrent: isCurrent);

Future<String> encodeBase64Responsive(
  Uint8List bytes, {
  bool Function()? isCurrent,
}) async =>
    await platform.executeDataCodec(
          'base64-encode',
          Uint8List.fromList(bytes),
          isCurrent: isCurrent,
        )
        as String;

Future<Uint8List> decodeBase64Responsive(
  String value, {
  bool Function()? isCurrent,
}) async =>
    await platform.executeDataCodec(
          'base64-decode',
          value,
          isCurrent: isCurrent,
        )
        as Uint8List;

Future<Uint8List> encodeUtf8Responsive(
  String value, {
  bool Function()? isCurrent,
}) async =>
    await platform.executeDataCodec('utf8-encode', value, isCurrent: isCurrent)
        as Uint8List;

Future<String> decodeUtf8Responsive(
  Uint8List bytes, {
  bool Function()? isCurrent,
  bool allowMalformed = false,
}) async =>
    await platform.executeDataCodec(
          allowMalformed ? 'utf8-decode-lossy' : 'utf8-decode',
          Uint8List.fromList(bytes),
          isCurrent: isCurrent,
        )
        as String;

/// Incremental hashing preserves the existing file identity without a large
/// uninterrupted main-isolate digest (including on non-secure Web origins).
Future<String> sha256HexResponsive(
  Uint8List bytes, {
  bool Function()? isCurrent,
}) async {
  final owned = Uint8List.fromList(bytes);
  final result = _DigestResult();
  final sink = sha256.startChunkedConversion(result);
  final work = UiWorkBudget(
    maxItems: 8,
    isCurrent: isCurrent,
    debugLabel: 'file-sha256',
  );
  for (var offset = 0; offset < owned.length; offset += 32768) {
    work.ensureCurrent();
    final end = (offset + 32768).clamp(0, owned.length);
    sink.add(Uint8List.sublistView(owned, offset, end));
    await work.checkpoint();
  }
  sink.close();
  work.ensureCurrent();
  return result.digest!.toString();
}

class _DigestResult implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) => digest = value;
  @override
  void close() {}
}
