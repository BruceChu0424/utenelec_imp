import 'dart:io';
import 'package:path_provider/path_provider.dart' as paths;
import '../runtime/client_runtime_profile.dart';

export 'package:path_provider/path_provider.dart'
    hide getTemporaryDirectory, getApplicationDocumentsDirectory;

Future<Directory> getTemporaryDirectory() async {
  final base = await paths.getTemporaryDirectory();
  if (!ClientRuntimeProfile.isLocalTest) return base;
  return Directory('${base.path}/${ClientRuntimeProfile.current.applicationId}')
    ..createSync(recursive: true);
}

Future<Directory> getApplicationDocumentsDirectory() async {
  if (!ClientRuntimeProfile.isLocalTest) {
    return paths.getApplicationDocumentsDirectory();
  }
  final support = await paths.getApplicationSupportDirectory();
  return Directory('${support.path}/exports')..createSync(recursive: true);
}
