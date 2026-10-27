import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uten_imp/core/network/company_tls.dart';
import 'package:uten_imp/core/network/api_client.dart';
import 'package:uten_imp/core/network/company_tls_io.dart' as native;
import 'package:uten_imp/core/network/company_tls_stub.dart' as browser;
import 'package:uten_imp/core/network/health_probe.dart';
import 'package:uten_imp/core/network/server_selection.dart';
import 'package:uten_imp/shared/providers/shared_providers.dart';

class _RealHttpOverrides extends HttpOverrides {}

Future<String> _openssl() async {
  try {
    if ((await Process.run('openssl', ['version'])).exitCode == 0) {
      return 'openssl';
    }
  } on ProcessException {
    // Git for Windows carries OpenSSL even when its usr/bin is not on PATH.
  }
  final git = await Process.run('git', ['--exec-path']);
  var directory = Directory((git.stdout as String).trim());
  for (var level = 0; level < 5; level++) {
    final candidate = File('${directory.path}/usr/bin/openssl.exe');
    if (await candidate.exists()) return candidate.path;
    directory = directory.parent;
  }
  throw StateError(
    'OpenSSL is required to generate private, test-only TLS fixtures',
  );
}

class _Fixtures {
  _Fixtures(this.directory, this.openssl);

  final Directory directory;
  final String openssl;
  File file(String name) => File('${directory.path}/$name');

  Future<void> run(List<String> arguments) async {
    final result = await Process.run(
      openssl,
      arguments,
      workingDirectory: directory.path,
    );
    if (result.exitCode != 0) {
      throw StateError('Test-only TLS fixture generation failed');
    }
  }

  Future<void> generate() async {
    await file(
      'openssl.cnf',
    ).writeAsString('[req]\ndistinguished_name=dn\n[dn]\nCN=unused\n');
    for (final label in ['a', 'b']) {
      await run([
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-days',
        '3',
        '-config',
        'openssl.cnf',
        '-subj',
        '/CN=UTEN TEST ONLY CA $label',
        '-keyout',
        '$label-ca.key',
        '-out',
        '$label-ca.crt',
        '-addext',
        'basicConstraints=critical,CA:TRUE',
        '-addext',
        'keyUsage=critical,keyCertSign,cRLSign',
      ]);
    }
    for (final label in ['valid', 'wrong-host']) {
      await run([
        'req',
        '-new',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-config',
        'openssl.cnf',
        '-subj',
        '/CN=$label',
        '-keyout',
        '$label.key',
        '-out',
        '$label.csr',
      ]);
      final san = label == 'valid'
          ? 'DNS:imp.utenelec,IP:192.168.1.13,DNS:cloud.example.test'
          : 'DNS:wrong.example.test';
      await file('$label.ext').writeAsString(
        'subjectAltName=$san\nbasicConstraints=critical,CA:FALSE\n'
        'keyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n',
      );
      await run([
        'x509',
        '-req',
        '-in',
        '$label.csr',
        '-CA',
        'a-ca.crt',
        '-CAkey',
        'a-ca.key',
        '-CAcreateserial',
        '-days',
        '3',
        '-extfile',
        '$label.ext',
        '-out',
        '$label.crt',
      ]);
    }
    await run([
      'x509',
      '-req',
      '-in',
      'valid.csr',
      '-CA',
      'b-ca.crt',
      '-CAkey',
      'b-ca.key',
      '-CAcreateserial',
      '-days',
      '3',
      '-extfile',
      'valid.ext',
      '-out',
      'wrong-ca.crt',
    ]);
    await generateLanIntermediateProfiles();
  }

  Future<void> generateLanIntermediateProfiles() async {
    await run([
      'req',
      '-new',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-config',
      'openssl.cnf',
      '-subj',
      '/CN=UTEN TEST ONLY LAN Issuer',
      '-keyout',
      'lan-issuer.key',
      '-out',
      'lan-issuer.csr',
    ]);
    await run([
      'req',
      '-new',
      '-key',
      'valid.key',
      '-config',
      'openssl.cnf',
      '-subj',
      '/C=CN/O=UtenElec/CN=imp.utenelec',
      '-out',
      'lan-leaf.csr',
    ]);
    // Mirror the deployed LAN leaf, including the IP SAN even when connecting
    // by DNS. Both profiles are valid under OpenSSL; Dart must test its own
    // certificate verifier, which rejects an issuer's IP name constraint.
    const dnsConstraints =
        'permitted;DNS:imp.utenelec,permitted;DNS:erp.utenelec.lan,'
        'permitted;DNS:utenelec-imp-server';
    await file('lan-leaf.ext').writeAsString(
      'basicConstraints=critical,CA:FALSE\n'
      'keyUsage=critical,digitalSignature,keyEncipherment\n'
      'extendedKeyUsage=serverAuth\n'
      'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
      'subjectAltName=DNS:imp.utenelec,DNS:erp.utenelec.lan,'
      'DNS:utenelec-imp-server,IP:192.168.1.13\n',
    );
    for (final profile in ['lan-dns', 'lan-ip']) {
      final ipConstraint = profile == 'lan-ip'
          ? ',permitted;IP:192.168.1.13/255.255.255.255'
          : '';
      await file('$profile-issuer.ext').writeAsString(
        'basicConstraints=critical,CA:TRUE,pathlen:0\n'
        'keyUsage=critical,keyCertSign,cRLSign\n'
        'subjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid,issuer\n'
        'nameConstraints=critical,$dnsConstraints$ipConstraint\n',
      );
      await run([
        'x509',
        '-req',
        '-in',
        'lan-issuer.csr',
        '-CA',
        'a-ca.crt',
        '-CAkey',
        'a-ca.key',
        '-CAcreateserial',
        '-days',
        '3',
        '-extfile',
        '$profile-issuer.ext',
        '-out',
        '$profile-issuer.crt',
      ]);
      await run([
        'x509',
        '-req',
        '-in',
        'lan-leaf.csr',
        '-CA',
        '$profile-issuer.crt',
        '-CAkey',
        'lan-issuer.key',
        '-CAcreateserial',
        '-days',
        '3',
        '-extfile',
        'lan-leaf.ext',
        '-out',
        '$profile-leaf.crt',
      ]);
      for (final identity in [
        ['-verify_ip', '192.168.1.13'],
        ['-verify_hostname', 'imp.utenelec'],
      ]) {
        await run([
          'verify',
          '-CAfile',
          'a-ca.crt',
          '-untrusted',
          '$profile-issuer.crt',
          '-purpose',
          'sslserver',
          ...identity,
          '$profile-leaf.crt',
        ]);
      }
      await file('$profile.crt').writeAsString(
        '${await file('$profile-leaf.crt').readAsString()}'
        '${await file('$profile-issuer.crt').readAsString()}',
      );
    }
  }

  Future<HttpServer> serve(
    String certificate, {
    bool redirect = false,
    void Function()? onRequest,
  }) async {
    final context = SecurityContext()
      ..useCertificateChain(file('$certificate.crt').path)
      ..usePrivateKey(
        file(certificate == 'wrong-host' ? 'wrong-host.key' : 'valid.key').path,
      );
    final server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
    );
    server.listen((request) async {
      onRequest?.call();
      if (redirect && request.uri.path == '/redirect') {
        request.response.statusCode = HttpStatus.found;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          'https://cloud.example.test/final',
        );
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{"status":"UP"}');
      }
      await request.response.close();
    }, onError: (Object _) {});
    return server;
  }

  HttpClient client(
    SecurityContext context,
    int port, {
    void Function(HandshakeException error)? onHandshakeError,
  }) => _RealHttpOverrides().createHttpClient(context)
    ..findProxy = (_) {
      return 'DIRECT';
    }
    ..connectionFactory = (uri, proxyHost, proxyPort) async {
      final pending = await Socket.startConnect(
        InternetAddress.loopbackIPv4,
        port,
      );
      final secure = pending.socket.then((socket) async {
        try {
          return await SecureSocket.secure(
            socket,
            host: uri.host,
            context: context,
          );
        } on HandshakeException catch (error) {
          onHandshakeError?.call(error);
          rethrow;
        }
      });
      return ConnectionTask.fromSocket(secure, pending.cancel);
    };

  Future<Dio> dio(
    HttpServer server, {
    BaseOptions? options,
    void Function(HandshakeException error)? onHandshakeError,
  }) async {
    final ca = await file('a-ca.crt').readAsBytes();
    final trust = native.CompanyTlsTrust.forTesting(
      ca,
      expectedSha256: sha256.convert(ca).toString(),
      createHttpClient: (context) =>
          client(context, server.port, onHandshakeError: onHandshakeError),
    );
    final dio = Dio(options ?? BaseOptions());
    dio.httpClientAdapter = trust.wrapForTesting(
      IOHttpClientAdapter(
        createHttpClient: () =>
            client(SecurityContext(withTrustedRoots: true), server.port),
      ),
    );
    return dio;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Fixtures fixtures;
  late String resolvedFixturePath;

  setUpAll(() async {
    final directory = await Directory.systemTemp.createTemp(
      'uten-company-tls-',
    );
    resolvedFixturePath = await directory.resolveSymbolicLinks();
    fixtures = _Fixtures(directory, await _openssl());
    await fixtures.generate();
  });
  tearDownAll(() async {
    final temp = await Directory.systemTemp.resolveSymbolicLinks();
    final current = await fixtures.directory.resolveSymbolicLinks();
    if (current != resolvedFixturePath ||
        !current.startsWith('$temp${Platform.pathSeparator}') ||
        !fixtures.directory.uri.pathSegments
            .where((part) => part.isNotEmpty)
            .last
            .startsWith('uten-company-tls-')) {
      throw StateError(
        'Refusing to clean a fixture path outside its original temporary directory',
      );
    }
    await fixtures.directory.delete(recursive: true);
  });

  test(
    'the actual packaged company asset has the reviewed exact PEM hash and loads once',
    () async {
      final asset = await rootBundle.load(companyCaAsset);
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      expect(sha256.convert(bytes).toString(), companyCaPemSha256);
      var loads = 0;
      Future<ByteData> load(String key) async {
        expect(key, companyCaAsset);
        loads++;
        return asset;
      }

      await Future.wait([
        initializeCompanyTls(loadAsset: load),
        initializeCompanyTls(loadAsset: load),
      ]);
      expect(loads, 1);
    },
  );

  test(
    'only the two exact approved HTTPS origins receive application CA trust',
    () {
      for (final value in [
        'https://192.168.1.13/api',
        'https://imp.utenelec:443/actuator/health',
      ]) {
        expect(isApprovedCompanyTlsOrigin(Uri.parse(value)), isTrue);
      }
      for (final value in [
        'http://192.168.1.13',
        'https://imp.utenelec:8443',
        'https://cloud.example.test',
        'https://imp.utenelec.evil',
        'https://user@imp.utenelec',
      ]) {
        expect(isApprovedCompanyTlsOrigin(Uri.parse(value)), isFalse);
      }
    },
  );

  for (final host in ['imp.utenelec', '192.168.1.13']) {
    test(
      'approved $host accepts the owned CA and still checks its hostname',
      () async {
        final server = await fixtures.serve('valid');
        final dio = await fixtures.dio(server);
        try {
          final response = await dio.get<Object?>(
            'https://$host/actuator/health',
          );
          expect(response.statusCode, 200);
        } finally {
          dio.close(force: true);
          await server.close(force: true);
        }
      },
    );
  }

  for (final certificate in ['wrong-ca', 'wrong-host']) {
    test(
      '$certificate is rejected rather than accepting every certificate',
      () async {
        final server = await fixtures.serve(certificate);
        final dio = await fixtures.dio(server);
        try {
          await expectLater(
            dio.get<Object?>('https://imp.utenelec/actuator/health'),
            throwsA(
              isA<DioException>().having(
                companyTlsFailure,
                'company TLS failure',
                isNotNull,
              ),
            ),
          );
        } finally {
          dio.close(force: true);
          await server.close(force: true);
        }
      },
    );
  }

  for (final host in ['imp.utenelec', '192.168.1.13']) {
    test(
      'Dart accepts the DNS-constrained LAN intermediate and four-SAN leaf for $host',
      () async {
        var requests = 0;
        final server = await fixtures.serve(
          'lan-dns',
          onRequest: () => requests++,
        );
        final dio = await fixtures.dio(server);
        try {
          final response = await dio.get<Object?>(
            'https://$host/actuator/health',
          );
          expect(response.statusCode, 200);
          expect(response.data, {'status': 'UP'});
          expect(requests, 1);
        } finally {
          dio.close(force: true);
          await server.close(force: true);
        }
      },
    );

    test(
      'Dart rejects the IP-constrained LAN intermediate before sending HTTP to $host',
      () async {
        var requests = 0;
        final handshakeErrors = <HandshakeException>[];
        final server = await fixtures.serve(
          'lan-ip',
          onRequest: () => requests++,
        );
        final dio = await fixtures.dio(
          server,
          onHandshakeError: handshakeErrors.add,
        );
        try {
          await expectLater(
            dio.get<Object?>('https://$host/actuator/health'),
            throwsA(
              isA<DioException>().having(
                companyTlsFailure,
                'company TLS failure',
                isNotNull,
              ),
            ),
          );
          expect(handshakeErrors, isNotEmpty);
          expect(
            handshakeErrors.first.toString().toLowerCase(),
            contains('unsupported name constraint type'),
          );
          expect(requests, 0);
        } finally {
          dio.close(force: true);
          await server.close(force: true);
        }
      },
    );
  }

  test(
    'replacing the approved CA bytes fails the pinned fingerprint check',
    () async {
      final first = await fixtures.file('a-ca.crt').readAsBytes();
      final replacement = await fixtures.file('b-ca.crt').readAsBytes();
      expect(
        () => native.CompanyTlsTrust.forTesting(
          replacement,
          expectedSha256: sha256.convert(first).toString(),
        ),
        throwsA(isA<CompanyTlsException>()),
      );
    },
  );

  test(
    'API callers receive the specific certificate error instead of a cloud fallback hint',
    () async {
      final server = await fixtures.serve('wrong-ca');
      final dio = await fixtures.dio(
        server,
        options: BaseOptions(baseUrl: 'https://imp.utenelec'),
      );
      try {
        await expectLater(
          ApiClient(dio).get('/actuator/health'),
          throwsA(
            isA<CompanyTlsException>().having(
              (error) => error.message,
              'message',
              contains('内网证书验证失败'),
            ),
          ),
        );
      } finally {
        dio.close(force: true);
        await server.close(force: true);
      }
    },
  );

  for (final target in [
    'https://cloud.example.test/actuator/health',
    'https://imp.utenelec:8443/actuator/health',
  ]) {
    test(
      '$target does not inherit the company CA from a company base URL',
      () async {
        final server = await fixtures.serve('valid');
        final dio = await fixtures.dio(
          server,
          options: BaseOptions(baseUrl: 'https://imp.utenelec'),
        );
        try {
          await expectLater(
            dio.get<Object?>(target),
            throwsA(isA<DioException>()),
          );
        } finally {
          dio.close(force: true);
          await server.close(force: true);
        }
      },
    );
  }

  test(
    'company credentials never follow a native redirect to another origin',
    () async {
      var requests = 0;
      final server = await fixtures.serve(
        'valid',
        redirect: true,
        onRequest: () => requests++,
      );
      final dio = await fixtures.dio(
        server,
        options: BaseOptions(validateStatus: (status) => status == 302),
      );
      try {
        final response = await dio.get<Object?>(
          'https://imp.utenelec/redirect',
          options: Options(headers: {'Authorization': 'Bearer TEST-ONLY'}),
        );
        expect(response.statusCode, 302);
        expect(requests, 1);
      } finally {
        dio.close(force: true);
        await server.close(force: true);
      }
    },
  );

  test(
    'the same TLS transport supports the anonymous local health probe',
    () async {
      final server = await fixtures.serve('valid');
      final ca = await fixtures.file('a-ca.crt').readAsBytes();
      final trust = native.CompanyTlsTrust.forTesting(
        ca,
        expectedSha256: sha256.convert(ca).toString(),
        createHttpClient: (context) => fixtures.client(context, server.port),
      );
      try {
        expect(
          await probeHealth(
            'https://imp.utenelec',
            dioFactory: (options) => Dio(options)
              ..httpClientAdapter = trust.wrapForTesting(IOHttpClientAdapter()),
          ),
          isTrue,
        );
      } finally {
        await server.close(force: true);
      }
    },
  );

  test(
    'certificate errors are surfaced without changing routing to the cloud',
    () async {
      final preferences = InMemorySharedPreferences();
      await preferences.setBool('uten.local_server_reachable', true);
      final notifier = LocalServerReachabilityNotifier(
        preferences,
        web: false,
        healthProbe: () async => throw CompanyTlsException(),
      );
      try {
        await expectLater(
          notifier.probe(),
          throwsA(isA<CompanyTlsException>()),
        );
        expect(notifier.state, isTrue);
        expect(preferences.getBool('uten.local_server_reachable'), isTrue);
      } finally {
        notifier.dispose();
      }
    },
  );

  test(
    'Web keeps browser certificate handling and never loads the private-company CA',
    () async {
      var loads = 0;
      await browser.initializeCompanyTls((_) async {
        loads++;
        throw StateError('Browser must not load an application CA');
      });
      expect(loads, 0);
      final dio = browser.createCompanyDio(
        BaseOptions(baseUrl: 'https://web.example.test/api'),
      );
      expect(dio.options.baseUrl, 'https://web.example.test/api');
      dio.close(force: true);
    },
  );
}
