import fs from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
const sdk = 'D:/Software/Flutter/flutter';
const original = path.join(sdk, 'packages/flutter_tools');
const isolated = path.resolve('tmp/flutter-tools-feedback');
await fs.mkdir(isolated, {recursive:true});
for (const part of ['lib','bin','static','pubspec.yaml']) await fs.cp(path.join(original,part), path.join(isolated,part), {recursive:true});
// Font audit helpers fetch the real application bundle; make that bundle
// available under /assets/ on this isolated test host only.
await fs.cp(path.resolve('build/unit_test_assets'), path.join(isolated,'assets'), {recursive:true});
const configPath = path.join(original,'.dart_tool/package_config.json');
const config = JSON.parse(await fs.readFile(configPath,'utf8'));
const base = pathToFileURL(configPath);
for (const pkg of config.packages) pkg.rootUri = pkg.name === 'flutter_tools'
  ? pathToFileURL(isolated + path.sep).href : new URL(pkg.rootUri,base).href;
await fs.mkdir(path.join(isolated,'.dart_tool'), {recursive:true});
await fs.writeFile(path.join(isolated,'.dart_tool/package_config.json'),JSON.stringify(config,null,2));
const relative = 'lib/src/test/flutter_web_platform.dart';
const originalSource = await fs.readFile(path.join(original,relative),'utf8');
const replacements = [
  ["request.requestedUri.path.contains('host.dart.js')", "request.requestedUri.path == '/static/host.dart.js'"],
  ["final String fullPath = _fileSystem.path.fromUri(request.url);", "final String fullPath = request.url.path;"],
  ["final String path = _fileSystem.path.fromUri(request.url);", "final String path = request.url.path;"],
  ['window.testSelector = "$test";', 'window.testSelector = ${jsonEncode(test)};'],
  ["fileSystem.path.join(Cache.flutterRoot!, 'packages', 'flutter_tools')", JSON.stringify(isolated.replaceAll('\\','/'))],
  ['canvasKitBaseUrl: "/canvaskit/",', 'canvasKitBaseUrl: "/canvaskit/",\n                assetBase: "/",'],
];
let source = originalSource;
for (const [from,to] of replacements) {
  if (source.split(from).length !== 2) throw new Error(`Expected one exact SDK match: ${from}`);
  source = source.replace(from,to);
}
await fs.writeFile(path.join(isolated,relative),source);
const hash = text => createHash('sha256').update(text).digest('hex');
const proof = {sdk,isolated,relative,originalSha256:hash(originalSource),isolatedSha256:hash(source),originalUnchanged:hash(await fs.readFile(path.join(original,relative),'utf8'))===hash(originalSource),replacements};
await fs.writeFile('build-feedback-flutter-tools-isolation.json',JSON.stringify(proof,null,2));
console.log(JSON.stringify(proof));
