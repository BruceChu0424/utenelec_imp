# Real Inno VERSIONINFO fixtures

These two 1,412-byte resources were emitted by the real Inno Setup 7.1.0 compiler
from the adjacent public `fixture.iss` and `payload.txt`. The test verifies their
SHA-256 values, wraps the unchanged bytes with the existing bounded synthetic PE
resource header, and exercises the production inspector. The normal product must
pass; the Local Test product must be rejected. The reserved Inno text padding is
retained byte-for-byte. Other tests independently cover malformed PE structures.

Only hex-encoded `RT_VERSION` data is committed. No program code, setup loader,
compressed payload, ERP binary, customer input, private path, or credential is
included. The generated installers stay in an ignored scratch directory and are
never executed. This is not installation, Authenticode, or full-payload acceptance.

To regenerate on Windows with the reviewed compiler:

```powershell
python generate.py --iscc <reviewed-Inno-7.1.0>/ISCC.exe --work <new-ignored-scratch-directory>
```

The compiler SHA-256 is pinned in `generate.py` and `manifest.json`. The manifest
also records the source/payload hashes, both temporary compiled-installer hashes,
and exact extracted-resource sizes and hashes. Review any changed fixture bytes.
The Java test still accepts explicit full-file overrides through
`uten.inno.paddingFixture` and `uten.inno.localFixture`; ordinary Linux CI needs
neither property nor an installed Inno compiler.

Inno Setup is by Jordan Russell and Martijn Laan. Its supplied license is retained
unchanged in text as `INNO-LICENSE.txt`; the compiler itself is not included here.
Vendor: <https://jrsoftware.org/>. The synthetic fixture sources are project test
code; they do not represent an official Inno installer or an ERP release package.
