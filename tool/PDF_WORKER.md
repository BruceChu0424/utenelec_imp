# Isolated print generation

`lib/core/print/print_pdf_document.dart` is the single pure-Dart document renderer.
It preserves A4 landscape, 28-point margins, full supplied font bytes, original
strings, table column weights and natural PDF pagination. It has no Flutter,
account, API, storage, or UI dependencies.

Native platforms run the complete renderer in an owned `Isolate.spawn` worker. Web uses a
dedicated worker compiled from `tool/pdf_worker.dart`, bundled as a Flutter
asset. The page loads it from its own origin and base path. The compiler uses
`--csp`; neither `blob:` workers, runtime code generation, remote code nor a
relaxed CSP is needed. Input carries only the already-authorised document and
font. Output is transferred as PDF bytes. One generator permits one task at a
time. Web closes the worker after success/failure/timeout or owner disposal;
native disposal kills the isolate and closes its ports. A disposal during spawn
kills the worker as soon as its handle arrives, without delivering a print job.

After changing the renderer, worker entry, work-budget helper or dependency lock:

```powershell
python tool/build_pdf_worker.py
python tool/build_pdf_worker.py --check
```

Commit the generated `assets/workers/uten_pdf_worker.js` and its build receipt
with the source change. The receipt binds SHA-256 of the inputs and output,
compiler version and flags. Input text hashes normalize CRLF to LF so Windows
and Linux checkouts agree; the compiled worker hash covers exact file bytes.
`--check` performs no generation or network access.
The checked-in asset makes `flutter run` and `flutter build web` work without a
manual preprocessing step. Existing `pubspec.lock` supplies the pinned pure-Dart
`pdf` package and transitive dependencies; no new dependency is introduced.

The old balanced `MultiPage` test remains useful as a diagnostic: balancing
`Document.save` alone does not isolate a spanning table's synchronous layout or
painting. Actual UI responsiveness is tested through `IsolatedPrintPdfGenerator`.
