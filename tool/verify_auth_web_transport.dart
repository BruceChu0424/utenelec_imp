// Run with the project Dart SDK. Exercises the real browser Fetch adapter.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final output = Directory(
    args.isNotEmpty ? args.first : 'output/auth-web-transport',
  );
  await output.create(recursive: true);
  final chrome =
      Platform.environment['CHROME_EXECUTABLE'] ??
      r'C:\Program Files\Google\Chrome\Application\chrome.exe';
  if (!File(chrome).existsSync()) {
    throw StateError(
      'Set CHROME_EXECUTABLE to a Chrome or Chromium executable',
    );
  }
  final js = File('${output.path}/probe.js');
  final compile = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'js',
    '-O1',
    '--packages=.dart_tool/package_config.json',
    'test/browser/auth_web_transport_probe.dart',
    '-o',
    js.path,
  ]);
  await File(
    '${output.path}/compile.log',
  ).writeAsString('${compile.stdout}${compile.stderr}');
  if (compile.exitCode != 0) {
    throw StateError('Browser probe compile failed: ${compile.stderr}');
  }

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final report = Completer<String>();
  final barriers = <String, Completer<void>>{};
  var outsideRequests = 0;
  server.listen((request) async {
    try {
      final path = request.uri.path;
      if (path == '/') {
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><html><body>Running browser transport checks<script src="/probe.js"></script></body></html>',
        );
      } else if (path == '/probe.js') {
        request.response.headers.contentType = ContentType(
          'application',
          'javascript',
        );
        request.response.add(await js.readAsBytes());
      } else if (path == '/report') {
        final body = await utf8.decoder.bind(request).join();
        if (!report.isCompleted) report.complete(body);
        request.response.write('ok');
      } else if (path.startsWith('/api/redirect/')) {
        await request.drain<void>();
        request.response.statusCode = int.parse(path.split('/').last);
        request.response.headers.set(HttpHeaders.locationHeader, '/outside');
      } else if (path == '/outside') {
        outsideRequests++;
        request.response.write('unexpected redirect recipient');
      } else if (path == '/api/echo') {
        final bytes = await request.fold<List<int>>(
          [],
          (all, chunk) => all..addAll(chunk),
        );
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'utf8': utf8.decode(bytes, allowMalformed: true),
            'base64': base64Encode(bytes),
            'contentType': request.headers.contentType.toString(),
          }),
        );
      } else if (path.startsWith('/api/wait/')) {
        await request.drain<void>();
        final key = path.split('/').last;
        final started = barriers.putIfAbsent(key, Completer<void>.new);
        if (!started.isCompleted) started.complete();
        await report.future;
      } else if (path.startsWith('/api/barrier/')) {
        await barriers
            .putIfAbsent(path.split('/').last, Completer<void>.new)
            .future;
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"started":true}');
      } else if (path == '/api/slow-body') {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"unfinished":');
        await request.response.flush();
        await report.future;
      } else if (path == '/api/stats') {
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({'outsideRequests': outsideRequests}),
        );
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    } on Object {
      // Timeout/cancellation probes intentionally close their network stream.
      request.response.close().ignore();
    }
  });
  final browser = await Process.start(chrome, [
    '--headless=new',
    '--disable-gpu',
    '--no-first-run',
    '--disable-background-networking',
    '--user-data-dir=${output.absolute.path}/chrome-${DateTime.now().microsecondsSinceEpoch}',
    'http://127.0.0.1:${server.port}/',
  ]);
  final stdoutLog = File('${output.path}/chrome.stdout.log').openWrite();
  final stderrLog = File('${output.path}/chrome.stderr.log').openWrite();
  final stdoutDrain = stdoutLog.addStream(browser.stdout);
  final stderrDrain = stderrLog.addStream(browser.stderr);
  try {
    final raw = await report.future.timeout(const Duration(seconds: 45));
    await File('${output.path}/results.json').writeAsString(raw);
    final result = jsonDecode(raw) as Map<String, dynamic>;
    final rows = (result['results'] as List).cast<Map<String, dynamic>>();
    final failures = rows.where((row) => row['passed'] != true).toList();
    stdout.writeln(
      'Real Chrome browser: ${rows.length - failures.length}/${rows.length} passed; outside API requests=$outsideRequests',
    );
    for (final failure in failures) {
      stdout.writeln(jsonEncode(failure));
    }
    if (failures.isNotEmpty || outsideRequests != 0) exitCode = 1;
  } finally {
    if (!report.isCompleted) report.complete('{}');
    browser.kill();
    await server.close(force: true);
    await Future.wait([stdoutDrain, stderrDrain]);
    await stdoutLog.close();
    await stderrLog.close();
  }
}
