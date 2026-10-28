import 'package:intl/intl.dart';

/// Parse the standard GMT date used by host Date and Retry-After headers.
/// Kept Web-compatible so all readers share the same strict parser.
DateTime? parseHttpResponseDate(String? value) {
  if (value == null || !value.endsWith(' GMT')) return null;
  try {
    return DateFormat(
      'EEE, dd MMM yyyy HH:mm:ss',
      'en_US',
    ).parseStrict(value.substring(0, value.length - 4), true);
  } on FormatException {
    return null;
  }
}
