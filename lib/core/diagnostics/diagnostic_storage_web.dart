import 'dart:convert';
import 'dart:typed_data';
import 'diagnostic_store.dart';

Future<DiagnosticStore> createDiagnosticStore(String version) async =>
    _MemoryStore();
String diagnosticArchitecture() => 'browser';

class _MemoryStore implements DiagnosticStore {
  final _lines = <String>[];
  int _bytes = 0;
  @override
  String? get directory => null;
  @override
  Future<void> append(String lines) async {
    _lines.add(lines);
    _bytes += lines.length;
    while (_bytes > 512 * 1024 && _lines.length > 1) {
      _bytes -= _lines.removeAt(0).length;
    }
  }

  @override
  Future<Uint8List> readRecent() async =>
      Uint8List.fromList(utf8.encode(_lines.join()));
  @override
  Future<void> openDirectory() async {}
}
