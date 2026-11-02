import 'dart:typed_data';

abstract class DiagnosticStore {
  String? get directory;
  Future<void> append(String lines);
  Future<Uint8List> readRecent();
  Future<void> openDirectory();
}
