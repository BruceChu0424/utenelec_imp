import 'dart:typed_data';

bool hasPdfSignature(Uint8List bytes) =>
    bytes.length >= 5 &&
    bytes[0] == 0x25 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x44 &&
    bytes[3] == 0x46 &&
    bytes[4] == 0x2D;

String payrollPdfFilename({
  required String period,
  required String employeeCode,
}) {
  final safePeriod = _safeFilenamePart(period, fallback: '未知期间');
  final safeEmployeeCode = _safeFilenamePart(employeeCode, fallback: '未知员工');
  return '工资条_${safePeriod}_$safeEmployeeCode.pdf';
}

String _safeFilenamePart(String value, {required String fallback}) {
  var safe = value
      .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\.{2,}'), '_')
      .trim()
      .replaceAll(RegExp(r'_+'), '_')
      .replaceAll(RegExp(r'^[_ .]+|[_ .]+$'), '');
  if (safe.isEmpty) safe = fallback;
  if (safe.length > 64) safe = safe.substring(0, 64);
  return safe;
}
