# Public enquiry security

The public enquiry action keeps the honeypot, validates the submitted locale
against `i18n/routing.ts`, and returns the same `{ ok: false }` shape for input,
rate-limit, and database failures. Successful records store the server-owned
`consentAt`, `consentPolicyVersion`, `locale`, and allowlisted `source` values.

## Trusted client address

Set `INQUIRY_TRUSTED_CLIENT_IP_HEADER` to the header that the production reverse
proxy **overwrites** with the connecting client address. Accepted values are:

- `cf-connecting-ip`
- `fly-client-ip`
- `true-client-ip`
- `x-forwarded-for`
- `x-real-ip`
- `x-vercel-forwarded-for`

The application origin must reject direct public traffic. If the setting is
missing, unsupported, or contains an invalid address, all such requests share
the conservative `unidentified-client` bucket. Do not enable a forwarded header
unless the last trusted proxy overwrites it; an append-only or client-controlled
header does not provide a trustworthy identity.

## Limits

Every valid write attempt must pass all four server-side limits:

| Scope | Window | Default | Environment override |
| --- | ---: | ---: | --- |
| Client IP | 1 minute | 3 | `INQUIRY_RATE_CLIENT_MINUTE` |
| Client IP | 1 hour | 15 | `INQUIRY_RATE_CLIENT_HOUR` |
| All clients | 1 minute | 30 | `INQUIRY_RATE_GLOBAL_MINUTE` |
| All clients | 1 hour | 300 | `INQUIRY_RATE_GLOBAL_HOUR` |

The current limiter is deliberately a **single-process in-memory guard**. It is
appropriate only for one long-lived application instance. Before production on
multiple instances, serverless workers, or autoscaling infrastructure, replace
it with one shared atomic limiter (for example Redis) or enforce equivalent
per-client and global minute/hour limits at the edge. Keeping the in-memory
limiter alone in those deployments is a release blocker.

## Schema rollout

The three new enquiry audit columns are nullable so pre-existing records are not
given invented consent or locale facts. New submissions always populate them.
Back up the target database, review the schema diff, apply it through the
approved migration process, and verify a real enquiry before deployment. Do not
run `prisma db push` against an existing database without that checkpoint.
