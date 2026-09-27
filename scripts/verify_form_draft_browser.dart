// Renderer-free browser check for the production IndexedDB implementation.
// Compile with dart compile js, then run run_form_draft_browser_check.mjs.
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'package:uten_imp/shared/drafts/form_draft_storage_api.dart';
import 'package:uten_imp/shared/drafts/form_draft_storage_web.dart';

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main() async {
  final query = Uri.parse(web.window.location.href).queryParameters;
  final phase = query['phase']!;
  final prefix = '${query['namespace']!}_';
  final checks = <String>[];
  Future<void> progress(String checkpoint) async {
    await web.window
        .fetch(
          '/progress'.toJS,
          web.RequestInit(
            method: 'POST',
            body: jsonEncode({'phase': phase, 'checkpoint': checkpoint}).toJS,
          ),
        )
        .toDart;
  }

  final payload = '原始附件-${''.padRight(8 * 1024 * 1024, 'x')}-完整';
  Map<String, Object> result;
  try {
    await progress('started');
    final first = createFormDraftStorage();
    if (phase == 'write') {
      await first.write('${prefix}attachment', payload);
      await (first as ClosableFormDraftStorage).close();
      checks.add('strict transaction committed 8 MiB and closed connection');
    } else {
      final second = createFormDraftStorage();
      final restored = await first.read('${prefix}attachment');
      await progress('attachment read');
      require(
        restored == payload,
        '8 MiB payload changed after browser restart',
      );
      checks.add('new Chrome process recovered full 8 MiB attachment');

      await first.write('${prefix}zzzz', 'prefix upper bound');
      require(
        (await second.readAll(prefix))['${prefix}zzzz'] == 'prefix upper bound',
        'prefix range omitted high-character suffix',
      );
      checks.add('prefix upper bound includes zzzz');
      await progress('prefix read');

      final key = '${prefix}race';
      await first.write(key, 'original');
      final outcomes = await Future.wait([
        first.compareAndSet(key, expectedValue: 'original', value: 'first'),
        second.compareAndSet(key, expectedValue: 'original', value: 'second'),
      ]);
      require(
        outcomes.where((value) => value).length == 1,
        'CAS had multiple winners',
      );
      final winner = await second.read(key);
      require(winner == 'first' || winner == 'second', 'CAS winner missing');
      checks.add('two IndexedDB transactions produced one CAS winner');
      await progress('CAS race complete');

      const tombstone = '{"completed":true,"revision":"done"}';
      require(
        await first.compareAndSet(key, expectedValue: winner, value: tombstone),
        'completion marker failed',
      );
      require(
        !await second.compareAndSet(key, expectedValue: winner, value: 'stale'),
        'stale update resurrected completed form',
      );
      require(
        !await second.compareAndSet(key, expectedValue: null, value: 'new'),
        'new creation resurrected completed form',
      );
      await (first as ClosableFormDraftStorage).close();
      require(
        await first.read(key) == tombstone,
        'completion marker did not survive reopen',
      );
      checks.add(
        'durable completion marker blocked stale and new resurrection',
      );

      await second.remove(key);
      await progress('tombstone checked');
      await (second as ClosableFormDraftStorage).close();
      require(
        await second.read(key) == null,
        'removed record returned after reopen',
      );
      checks.add('record removal survived connection reopen');
      for (final key in (await first.readAll(prefix)).keys) {
        await first.remove(key);
      }
      await (first as ClosableFormDraftStorage).close();
      await (second as ClosableFormDraftStorage).close();
    }
    result = {
      'status': 'passed',
      'phase': phase,
      'payloadCharacters': payload.length,
      'checks': checks,
    };
  } catch (error, stack) {
    result = {
      'status': 'failed',
      'phase': phase,
      'error': '$error',
      'stack': '$stack',
      'checks': checks,
    };
  }
  final json = jsonEncode(result);
  web.document.body!.textContent = json;
  await web.window
      .fetch('/result'.toJS, web.RequestInit(method: 'POST', body: json.toJS))
      .toDart;
}
