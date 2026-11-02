import 'dart:io';

Future<void> writeStabilityReceipt(String path, String json) =>
    File(path).writeAsString(json);
