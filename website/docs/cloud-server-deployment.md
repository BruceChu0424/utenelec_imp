# 单台云服务器部署手册

当前版本适合先部署到一台长期运行的 Linux 云服务器：Nginx 负责 HTTPS 与反向代理，Next.js 只监听内网端口，SQLite 数据库和 `public/uploads/` 使用持久磁盘。多实例、Serverless 或自动扩缩容上线前，必须先迁移到共享数据库、对象存储和共享限流服务。

## 发布前门禁

1. 使用 Node.js 22.13 或更新的受支持版本，并锁定 `package-lock.json`。
2. 将 `.env` 放在服务器受限目录，不进入 Git；生成至少 43 字符的随机 `AUTH_SECRET`，设置唯一强管理员密码和正式 `SITE_URL=https://www.ch-uten.com`。使用下方 Nginx 配置时还必须设置 `INQUIRY_TRUSTED_CLIENT_IP_HEADER=x-real-ip`；若后台登录继续开放，同步设置 `ADMIN_TRUSTED_CLIENT_IP_HEADER=x-real-ip`。
3. 备份目标数据库与上传目录。先在数据库副本上检查 Prisma schema diff；确认后才对目标库执行受控 schema 更新。不要在已有正式数据上运行 `npm run db:seed`。
4. 当前询盘与登录限流只适用于单个长期运行的 Node 进程。多实例部署必须使用 Redis/数据库原子限流或在可信边缘实现等价规则。
5. 人工确认公司电话、完整地址、招聘开放状态、案例授权、认证有效期、产品颜色/尺寸与八种待补产品翻译后，才能对外宣称这些内容完整。

## 构建与启动

在新的版本目录中执行：

```bash
npm ci
npm run lint
npm run test:admin-guardrails
npm run test:inquiry-security
npm run test:publication-guards
npm run build
npm run start
```

SQLite 文件和 `public/uploads/` 不应随版本目录一起替换。使用固定持久目录并通过受控软链接或部署挂载接入；切换版本前验证实际路径仍指向该持久目录。

建议使用 systemd 以非 root 账号运行单实例：

```ini
[Unit]
Description=UTEN corporate website
After=network.target

[Service]
Type=simple
User=uten-web
WorkingDirectory=/srv/uten/current/website
EnvironmentFile=/etc/uten-website.env
Environment=NODE_ENV=production
ExecStart=/usr/bin/npm run start
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

## Nginx 与 HTTPS

只开放 80/443，拒绝公网直接访问 Next.js 端口。Nginx 代理时覆盖可信来源头：

```nginx
server {
    listen 443 ssl http2;
    server_name www.ch-uten.com ch-uten.com;

    # Public forms are small. Keep the broad request-body limit low so an
    # anonymous request cannot consume the Server Action 10 MB ceiling.
    client_max_body_size 128k;
    client_body_timeout 10s;

    # Temporary standalone CMS upload path. Keep this private/VPN-restricted
    # until company-platform SSO and the media service replace it.
    location /admin/ {
        client_max_body_size 10m;
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}

server {
    listen 80;
    server_name www.ch-uten.com ch-uten.com;
    return 308 https://$host$request_uri;
}
```

证书由受信任的 ACME 客户端自动续期。应用生产响应已包含 HSTS，但仍必须实测 HTTP 到 HTTPS 的 308、证书链、管理后台 Secure Cookie 和源站不可直连。生产 Nginx 还应在 `http` 级配置按客户端 IP 的 `limit_req_zone`，并分别给公开询盘和后台设置速率、并发与超时上限；不能只依赖单进程内存限流。

## 验收与回滚

- 验证 `/zh`、`/en`、产品目录、产品详情、Studio、新闻、联系表单、品牌 404 和 `/admin/login`。
- 用真实手机检查 375px 宽度、阿拉伯语 RTL、浏览器语言自动跳转和上传图片。
- 提交一条真实测试询盘并在后台确认 locale、source 与 consent 审计字段，再删除测试数据。
- 检查响应头、sitemap、robots、图片加载、备份可读性与日志中是否存在秘密。
- 让外部监控定期请求 `/api/health`；它必须在数据库不可读或持久媒体目录丢失时返回 503，并对首页、证书到期和备份新鲜度另设告警。
- 回滚时切回上一只读版本目录；数据库只有在已验证备份和明确迁移回退方案下才允许恢复，不能用 seed 或覆盖文件代替回滚。
