# Finance flow/monthly read-only acceptance SQL regression

Run the offline unit tests from `server/legacy_migration`:

```text
python -B -m unittest test_verify_finance_flow_monthly
```

The native verifier fixture accepts an explicit saved schema-only baseline; it
does not inspect a local database or rely on a private drive/freeze directory:

```text
python -B tests/finance_flow_monthly/run_verifier_sql_smoke.py --schema-baseline /absolute/saved-schema.sql --output /absolute/new-receipt-directory
```

The baseline supplies the existing V626 cash projection, financial precision /
snapshot functions, V408 monthly table, rebuild and integrity definitions. Use a
reviewed PostgreSQL16 schema-only dump containing those objects. No connection
string, password, `.env`, administrator snapshot or original source CSV is read.

Before any payload/container operation, the tool rejects DOCKER_HOST overrides
and remote Docker contexts, then pins all Docker commands to the resolved local
context. `postgres:16.15-alpine` must already be available; no pull, published
port or network is used. Only the tool's uniquely named containers are removed.

The baseline ledger is built by the **original V626 projection**, and its cache
by the **original V408 rebuild**, independently of the verifier's source formula.
Synthetic cases cover positive/negative/NULL values, an offshore account, a
UTC-to-Shanghai month boundary, a missing original account (archive-only), an
unresolved original header, and exact proof/UUID bindings.

Fourteen attacks include changing original amounts, clamping signed history,
resigning proofs and rebuilding a matching cache, changing month amounts/counts/
posting bounds, omitting rebuild, forged row/file SHA, resigned archive rows,
origin/issued-tx changes, extra business columns, dangling document UUID and a
wrong real account/currency. The acceptance SELECT runs in a read-only snapshot;
mutations occur only inside the tool's synthetic fixture transaction and roll
back. Reports contain counts, booleans and SHA, not amounts or source rows.

This is **verifier SQL coverage**, not a substitute for V916's full-schema
bootstrap/source-guard/terminal-context tests. The synthetic fixture creates no
business write guards and disables none. It cannot establish actual import,
cutover, server restore, user login or deployment success.
