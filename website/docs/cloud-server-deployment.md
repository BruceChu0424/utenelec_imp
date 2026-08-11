# Cloud Server Deployment Guide (Website + Admin CMS)

This document is the runbook for production deployment on a Linux cloud instance.

## 1) Target deployment model

- Ubuntu/CentOS x64 server
- Node.js `22.13+` (LTS)
- Nginx reverse proxy + HTTPS
- One process for Next app on loopback interface only
- DB: SQLite target now (`prisma/dev.db`) for this repository baseline
- Storage: persistent mount for `public/uploads`

For long-term multi-instance or team usage, switch data from SQLite to PostgreSQL and object storage.

## 2) Required environment variables

- `DATABASE_URL`
- `AUTH_SECRET` (strong random value only)
- `SITE_URL=https://www.ch-uten.com`
- `INQUIRY_TRUSTED_CLIENT_IP_HEADER=x-real-ip` (or proxy header you actually forward)
- `ADMIN_TRUSTED_CLIENT_IP_HEADER` (optional, for admin audit logs)
- `INQUIRY_RATE_CLIENT_MINUTE=3`
- `INQUIRY_RATE_CLIENT_HOUR=15`
- `INQUIRY_RATE_GLOBAL_MINUTE=30`
- `INQUIRY_RATE_GLOBAL_HOUR=300`
- `NODE_ENV=production`
- `ALLOW_DESTRUCTIVE_SEED=false` for normal startup/operations

## 3) Deployment steps

1. Pull the code and install dependencies:
   - `npm ci`
2. Render and verify environment:
   - `copy .env.example .env` then set real secrets and production values
3. Build in dry environment:
   - `npm run build`
4. Configure process manager:
   - `pm2`, `systemd`, or container process manager with restart policy
5. Start on loopback:
   - `npm run start`
6. Put behind Nginx and only expose 80/443 to the internet

### Smoke checks (minimum)

- `GET /zh`
- `GET /zh/products`
- `GET /zh/products/<family-slug>`
- `GET /zh/news`
- `GET /zh/careers`
- `GET /api/health`

## 4) Nginx example

```nginx
server {
    listen 443 ssl http2;
    server_name www.ch-uten.com ch-uten.com;

    client_max_body_size 128k;

    ssl_certificate /etc/nginx/ssl/site.crt;
    ssl_certificate_key /etc/nginx/ssl/site.key;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}

server {
    listen 80;
    server_name www.ch-uten.com ch-uten.com;
    return 308 https://$host$request_uri;
}
```

## 5) Security checklist

- Force HTTPS + 308 redirect
- Add HSTS at edge and/or app level
- Never expose direct admin login by public CDN/WAF policy bypass
- Do not put `/admin` on public anonymous network paths without auth
- Add upload filtering (size/type controls are already in app, keep it in CI/CD review too)
- Keep `AUTH_SECRET` strong and rotate for production incidents
- Enable proxy timeout/size limits and WAF where available
- Lock IP header trust: do not accept arbitrary forwarding headers from public internet

## 6) Data and media backup

- Backup policy (before each write-run):
  - Database copy of active DB file
  - `public/uploads` full copy or snapshot
- Use separate backup retention for:
  - production snapshot
  - pre-maintenance snapshot
  - post-maintenance snapshot
- Store checksums for both DB and uploads metadata for restore verification

## 7) Rollout sequence for production

1. Backup database + uploads
2. Run tests:
   - `npm run test:*`
3. Dry-run catalog scripts and inspect report
4. Build and start in staging
5. Run smoke checks and error-rate sample for 5–10 minutes
6. Switch traffic gradually (blue/green or canary)
7. Turn on monitoring + alerting for:
   - 5xx rate
   - page latency
   - media 404 rate
   - upload failure rate

## 8) CMS and ERP integration note

Current deployment still runs independent Next auth for admin. If ERP SSO is expected later, integrate with one of two approaches:

- Same-tenant OAuth/OIDC code flow for secure identity federation
- Internal service token exchange through a trusted backend bridge

Either way:

- do not store shared secrets in browser
- keep content-editing APIs server-side authenticated only
- keep write actions auditable by actor + request context
