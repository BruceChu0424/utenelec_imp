import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

typedef FinanceEntryFilePicker = Future<PlatformFile?> Function();

final financeEntryFilePickerProvider = Provider<FinanceEntryFilePicker>(
  (ref) => () async {
    final selection = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['xlsx', 'xls', 'csv', 'pdf'],
      withData: true,
    );
    return selection?.files.single;
  },
);
