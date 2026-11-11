import 'dart:io';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import '../test/support/windows_acceptance_preferences.dart';

/// Keeps preferences, encrypted plugin storage, drafts and exports inside this
/// test run. The real Windows storage implementation and DPAPI remain enabled.
Future<void> prepareAcceptanceRuntime({String? rootPath}) async {
  final root = Directory(
    rootPath ?? 'build/finance-closeout-20261104/native-runtime',
  ).absolute;
  isolateRealWindowsPreferences(root);
  PathProviderPlatform.instance = _AcceptancePaths(root);
}

class _AcceptancePaths extends PathProviderPlatform {
  _AcceptancePaths(this.root);
  final Directory root;
  Future<String> _directory(String name) async {
    final directory = Directory('${root.path}/$name');
    await directory.create(recursive: true);
    return directory.path;
  }

  @override
  Future<String?> getApplicationSupportPath() => _directory('UTEN Local Test');
  @override
  Future<String?> getApplicationCachePath() => _directory('cache');
  @override
  Future<String?> getTemporaryPath() => _directory('temporary');
  @override
  Future<String?> getApplicationDocumentsPath() => _directory('exports');
}
