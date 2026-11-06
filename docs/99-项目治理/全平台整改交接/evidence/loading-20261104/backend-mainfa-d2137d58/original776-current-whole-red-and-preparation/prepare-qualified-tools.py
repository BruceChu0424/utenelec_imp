from pathlib import Path
base=Path(__file__).resolve().parent;qualified=base.parent/'main-fa-gift-qualified';assert qualified.is_dir()
text=(base/'verify-source.py').read_text(encoding='utf-8-sig').replace("base/'complete-source-input.json'","base/'source-input.json'")
(qualified/'verify-source.py').write_bytes(text.encode('utf-8'))
text=(base/'run-suite.ps1').read_text(encoding='utf-8-sig').replace('build/loading-validation/main-fa-final','build/loading-validation/main-fa-gift-qualified').replace('complete-source-input.json','source-input.json')
(qualified/'run-suite.ps1').write_bytes(text.encode('utf-8'))
print('Prepared current-source verifier and whole-class runner; original target/source/log/XML retained')
