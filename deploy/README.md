# Uten IMP 稳定运行与原子发布基线

公司员工使用的 Web 入口不得由开发调试进程提供。生产入口必须由 Nginx 持续提供版本化的
Flutter Web Release，并把同域 /api 反向代理到受系统服务或编排器监督的 Spring Boot。

## 一、构建不可变制品

~~~powershell
flutter build web --release --no-pub --no-web-resources-cdn `
  --dart-define=APP_VERSION=<release-version>
mvn -f server/pom.xml --batch-mode --no-transfer-progress clean package
~~~

CI 必须为每个发布生成不可变版本号和 SHA256SUMS；manifest 应来自受信、最好已签名的 CI 制品，
不能在目标机复制完成后临时生成来“证明自身”。推荐目录：

~~~text
/opt/uten-imp/
  releases/
    <version>/
      SHA256SUMS
      server/uten-imp-server.jar
      web/index.html
      web/...
  current -> releases/<version>
~~~

生产秘密只放在仅服务账号可读的 /etc/uten-imp/server.env，不进入版本目录、仓库或命令历史。
新制品必须先完整写入一个从未运行过的新版本目录，再执行：

~~~bash
cd /opt/uten-imp/releases/<version>
sha256sum -c SHA256SUMS

test "$(stat -c %d /opt/uten-imp)" = \
  "$(stat -c %d /opt/uten-imp/releases/<version>)"

cd /opt/uten-imp
ln -s "releases/<version>" ".current-<version>"
mv -Tf ".current-<version>" current
~~~

临时 symlink 与 current 必须位于同一目录、同一文件系统，mv 才能使用同文件系统 rename 原子替换。
systemd 和 Nginx 都只读取 /opt/uten-imp/current；严禁把新 JAR、index.html 或 Web 资源复制到
current 指向的目录中原位覆盖。运行中的旧版本目录在回滚窗口结束且确认无进程引用前不得删除。

单机正式切换顺序是：后台预置并校验新目录 → 关闭入口 → 排空请求并停止旧服务 → 按第三节清退会话
→ 原子切换 current → 启动并验证新服务 → 重开入口。回滚也必须指向一个已校验、仍不可变的旧版本
目录，不能从备份散文件覆盖 current。

systemd 起点见 systemd/uten-imp.service.example。示例已要求 current 是 symlink，并从
current/server/uten-imp-server.jar 启动。Nginx 示例从 current/web 提供静态文件，并在 127.0.0.1:8081
提供只读 index.html 探针。同机部署把 upstream 改为 127.0.0.1:8080；容器部署改为真实服务 DNS，
并以防火墙保证应用端口只允许受信代理访问。后端与静态入口分别由 JVM 外 watchdog 监督；Nginx
systemd drop-in 负责异常进程退出时自动拉起。

~~~bash
sudo install -m 0644 deploy/systemd/uten-imp.service.example /etc/systemd/system/uten-imp.service
sudo install -d -m 0755 /etc/systemd/system/nginx.service.d
sudo install -m 0644 deploy/systemd/nginx-uten-imp-override.conf.example \
  /etc/systemd/system/nginx.service.d/uten-imp.conf
sudo install -m 0644 deploy/systemd/uten-imp-watchdog.service.example /etc/systemd/system/uten-imp-watchdog.service
sudo install -m 0644 deploy/systemd/uten-imp-watchdog.timer.example /etc/systemd/system/uten-imp-watchdog.timer
sudo install -m 0644 deploy/systemd/uten-imp-entry-watchdog.service.example \
  /etc/systemd/system/uten-imp-entry-watchdog.service
sudo install -m 0644 deploy/systemd/uten-imp-entry-watchdog.timer.example \
  /etc/systemd/system/uten-imp-entry-watchdog.timer
sudo systemctl daemon-reload
sudo nginx -t
sudo systemctl reload nginx
sudo systemctl enable --now uten-imp.service
sudo systemctl enable --now uten-imp-watchdog.timer uten-imp-entry-watchdog.timer
~~~

每次维护、切换或回滚前必须先执行：

~~~bash
sudo systemctl stop uten-imp-watchdog.timer uten-imp-entry-watchdog.timer
sudo systemctl stop uten-imp-watchdog.service uten-imp-entry-watchdog.service
~~~

完成原子切换、严格健康检查和真实账号冒烟后再重新启动两个 timer。否则 watchdog 可能把维护中
故意停止的旧服务提前拉起。

## 二、监督、健康与容量

Restart=always 只能发现 JVM 退出，无法处理“PID 仍在但事件循环卡死、健康端点超时”的故障。
本目录提供两个运行在目标进程之外的独立监督链：

- `uten-imp-watchdog` 开机宽限 120 秒后，每 15 秒直连
  `127.0.0.1:8080/actuator/health/liveness`，5 秒超时；必须同时满足 HTTP 2xx 与 JSON
  `status=UP`，连续 4 次失败才重启 Spring，单次抖动只记日志；
- `uten-imp-entry-watchdog` 每 15 秒读取仅回环开放的 `127.0.0.1:8081/index.html`，同时要求 HTTP
  成功和 `flutter_bootstrap.js` 制品标记；连续 4 次失败才重启 Nginx。Nginx master 异常退出则由
  `nginx.service.d/uten-imp.conf` 的 `Restart=on-failure` 更快拉起；
- 两条链的计数文件都以同文件系统 rename 原子写入 `/run`，`flock` 保证探测/重启单飞；脚本绝不
  读取 token 或业务数据，StartLimit 继续限制重启风暴；
- readiness 失败只负责摘流和告警，不触发 Spring watchdog 重启；外部负载均衡/监控仍须单独探测；
- 外部域名的 health/readiness、静态首页和真实业务可用性持续 60 秒失败必须告警，即使本地探针
  正常；systemd 进入 failed/StartLimit 状态也必须立即告警；
- 修复后按具体 unit 执行 `systemctl reset-failed <unit> && systemctl start <unit>`，不得盲目循环重启。

Kubernetes 等编排环境应分别配置 startupProbe、livenessProbe、readinessProbe：startup probe 保护
冷启动，liveness 连续失败才替换容器，readiness 只摘流；仍需全局不可用告警与工作负载重启退避。

Nginx 的 IP 桶只是有限洪泛保护，不能承担账号策略。模板针对同一 NAT 下约 1,000 个恢复客户端分离为：

- health：独立 1000 r/s、burst 5000，不再与普通 API 的 3000 r/m 桶争抢；
- auth：300 r/s、burst 2000，容纳早班登录及故障后的集中 refresh；
- 普通 API：继续使用独立有限桶；账号、手机号等低阈值仍由应用层实施。

这些是容量起点，不是所有现场通用值。必须从真实办公 NAT、运营商 CGNAT、WAF/CDN 路径压测
2/5/10/15 秒恢复波次和登录/刷新峰值，再调整；计划恢复波不得大量 429，明显超出批准容量的持续洪泛
仍必须被 429 限制。

Nginx 只代理根 health、liveness 和 readiness。普通 location /actuator/ 明确返回 404，且没有 ^~，
因此三个允许的 exact/regex location 仍优先，而 /actuator/info 等路径不会落入 SPA index.html 冒充 200。
后端 SecurityConfig 继续保护非 health Actuator 端点。

## 三、最小 staff JWT 的发布与回滚边界

最小 staff access token 不再携带 emp/acc/roles/perms/mcp，只保留主体、类型和授权版本。旧 token 可由
新 JAR 读取；新最小 token 到旧 JAR 可能以 403“无权限”结束且不会自动刷新。因此：

- 禁止新旧 JAR 直接滚动混跑，也禁止携带新最小 token 直接回滚旧 JAR；
- 单机必须维护窗口全停、排空、原子切换版本，并通过受控 issuer/签名密钥轮换及 refresh 撤销或等价
  机制清退既有会话，强制重新登录；回滚旧 JAR 前必须再次清退已签发的最小 token；
- 当前源码没有“继续签发旧兼容 claim”的 writer 开关，因此本候选**不支持集群滚动升级**；
  只能全停、排空、清退会话后切为同一版本。若未来实现并验证兼容 writer，才可采用 reader-first、
  minimal-writer-second 的两阶段滚动发布；
- 发布记录保存版本、SHA256 校验结果、current 前后目标、issuer/密钥版本、会话清退时间、节点清单及
  验证结果；不得记录真实密钥或 token。

## 四、连接与有限包络

- Spring Boot 的请求行加全部请求头预算为 16 KiB；Nginx 使用两个 8 KiB 大缓冲与 8 KiB 单字段
  上限。两者计数语义不同，代理还会追加转发头，因此这是测量后的有限包络，不是逐字节相等。
- access token 只携带最小身份及授权版本；X-Uten-Audit-Context 客户端编码上限为 1536 字符。
  禁止在请求头携带正文、查询值或令牌副本。
- 普通 API 读取超时为 45 秒；只有 /api/**/export 使用 120 秒。写请求不得自动重放。

## 五、目标环境验证

健康验证必须检查 JSON；单纯 curl --fail 不能防止 SPA index.html 冒充 200：

~~~bash
systemctl is-enabled uten-imp.service
systemctl is-active uten-imp.service
systemctl is-failed uten-imp.service && exit 1 || true
test -L /opt/uten-imp/current
readlink -f /opt/uten-imp/current

for endpoint in health health/liveness health/readiness; do
  curl --fail --silent "https://<production-host>/actuator/$endpoint" \
    | jq -e '.status == "UP"' >/dev/null
done

test "$(curl --silent --output /dev/null --write-out '%{http_code}' \
  https://<production-host>/actuator/info)" = "404"
~~~

还必须完成：

- 对版本目录执行 SHA256SUMS 校验，证明 current 只经原子 symlink rename 切换；检查运行 JAR/Web 从未
  原位覆盖，并演练保留目录间的原子回滚；
- 不能只 kill JVM：在保持 Java PID 存活时，用测试故障注入令 liveness 持续超时/失败，验证 watchdog
  达到连续失败阈值后通过 systemd/编排器替换实例，同时产生不可用告警且不突破启动限速；
- 单独令 readiness 失败，验证摘流和告警但不会形成无意义 JVM 重启循环；
- 主动终止一次 JVM，验证 Restart=always 拉起；再连续触发失败验证 StartLimit 与 failed 告警；
- 主动终止 Nginx master，验证 drop-in 自动拉起；再让进程存活但回环 index 探针超时/缺标记，
  验证静态入口 watchdog 达连续阈值后重启，并确认维护期间两个 timer 已停止、不误拉旧版本；
- 从同一源 NAT 压测 1,000 客户端的 health 恢复波及集中 login/refresh，确认批准容量内不大量 429，
  超过洪泛边界仍返回 429；
- 验证根 health、liveness、readiness 到达 Spring 且为 JSON；停止后端时均不得由 SPA 返回 200，
  /actuator/info 等非公开路径在网关固定 404；
- 验证优雅停止期间的在途请求，确认 90 秒 systemd 总窗口不会提前 SIGKILL；
- 验证普通 API 45 秒与仅 export 120 秒边界、请求头正反例、断网读恢复与写请求不重复；
- 按单机全停或集群两阶段方案验证新旧 token 矩阵、会话清退和受控回滚。

源码与本地测试通过不等于目标环境的 checksum、原子切换、真实网关容量、外部 watchdog、告警或会话
清退演练已经完成。
