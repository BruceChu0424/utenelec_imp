# Inquiry Security and Data Policy

This page explains the inquiry submission flow and how to keep it production-safe.

## 1) Validation rules

Required at submit:

- `name`
- `company`
- `market`
- `needType`
- `message`
- At least one of `phone` or `email`

Stored fields:

- `locale`
- `source`
- `projectStage`
- `products`
- `estimatedQuantity`
- `targetMarket`
- `consentAt`
- `consentPolicyVersion`

Validation principles:

- Empty or malformed phone/email is rejected
- Whitespace-only text is trimmed and blocked
- Message length and field size limits are enforced
- Internal error returns do not expose raw exceptions

## 2) Abuse limits

Current default limits:

- 3 requests per minute per client
- 15 requests per hour per client
- 30 requests per minute global
- 300 requests per hour global

The limiter is in-memory by default.

- For single-instance deployments this is accepted for release-stage guard
- For multi-instance deployments migrate to shared limiter (Redis / cache store)
- Keep strict proxy IP trust rules to avoid header spoofing

## 3) Production configuration

- `INQUIRY_TRUSTED_CLIENT_IP_HEADER` (example: `x-real-ip`)
- `INQUIRY_RATE_CLIENT_MINUTE`
- `INQUIRY_RATE_CLIENT_HOUR`
- `INQUIRY_RATE_GLOBAL_MINUTE`
- `INQUIRY_RATE_GLOBAL_HOUR`

If the trusted header is missing or not in allowlist, inquiry limiter uses shared fallback bucket (`unidentified-client`).

## 4) API behavior

- Missing contact fields returns structured `code: contact-required`
- Rejected requests return consistent `code` values for client handling
- Consent must be explicit and persisted (`consent=true`)
- Locale is sourced from page locale (front-end and API both)

## 5) Operational rollout checklist

1. Run schema + security tests:
   - `npm run test:inquiry-security`
2. Configure `INQUIRY_TRUSTED_CLIENT_IP_HEADER` in reverse proxy and app env
3. Confirm proxy truly sets trusted header (not just passes through client headers)
4. Simulate production checks:
   - valid submit
   - duplicate rapid submits
   - missing contact fallback
   - header spoofing attempts
5. Verify one successful inquiry appears in admin query and can be archived after follow-up

## 6) Planned upgrades

- Replace in-memory limiter with shared limiter for multi-instance
- Add audit export/retention policy for inquiry handling
- Add optional webhook/CRM handoff with masked customer info
