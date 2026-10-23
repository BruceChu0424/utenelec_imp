# 独立运行与灾备控制面

本目录提供可独立运行的控制服务、救援 Web、SQLite 作业队列和独立身份存储，不依赖公司业务数据库或 ERP JWT。当前支持真实登记受限目标、接受密文备份状态、创建 / 查询 / 原子领取隔离恢复演练，以及带 Ed25519 签名门禁的提升状态机。**现役云归档节点尚未配置可信强隔离、成套恢复验证和备用业务执行器，所以当前真实提升必须拒绝**；源代码的签名回归不能当成目标机隔离或恢复证据。

现场运维流程已确定为：**先到现场关机并隔离旧主 → 核验独立恢复证据 → 超级管理员人工启用备用服务**。网络断开不会自动切换。现场人工步骤仍须由另行验收的独立适配器形成绑定本次作业的可信签名回执；普通确认框、手填布尔值和旧主自报不能作为隔离证据。当前缺少备用 BUSINESS 运行环境和已验收适配器，保持未 commissioned / NO_GO；本轮不把此后续现场适配器混入主站最小发布。

## 部署边界

- 程序：`/opt/uten-dr-control/control_plane.py`、`promotion_receipts.py`、`rescue.html` 及独立 `venv`，root 拥有，运行账号只读。签名校验使用锁定的 cryptography50.0.2，缺少或低于安全基线时提升禁用。
- 服务：`uten-dr-control.service`，独立 `uten-dr-control` 无登录用户，仅监听 `127.0.0.1:9087`；不接受 API 传入的 URL、路径、shell 或 SQL。
- 配置：`/etc/uten-dr-control/control.json`，`root:uten-dr-control`，目录0750、文件0640。初始化程序 `provision.py` 只创建保护文件，不创建救援管理员。
- 身份及作业：`/var/lib/uten-dr-control/state.sqlite3`，服务账号私有，目录0700、文件0600。内含独立口令哈希和 TOTP 派生 reference(无明文seed)，实际256位 master 通过 systemd LoadCredential 独立加载，须按独立秘密保护与密文备份，不送入普通日志、业务导出或公开备份目录。
- TOTP master：`/etc/uten-dr-control/totp-master.key`，root0600，通过 `LoadCredential=totp-master:...` 只提供给此服务。使用域分离 HMAC-SHA256派生用户TOTP seed；SQLite记录master指纹，错配直接拒绝启动。绑定前须将master独立离线加密托管并核验可取回，不能丢失后生成新master冒充恢复。服务重启撤销旧会话，作业和TOTP防重放状态继续保留。
- systemd255可能用0440 ACL mask提供凭据：仅root拥有的`totp-master`、精确`CREDENTIALS_DIRECTORY`、无写和other权限的root父目录、实际只读credential挂载同时满足时接受。普通0440文件仍拒绝，不放宽原始`/etc`密钥权限。
- 备份发布 token：`/etc/uten-dr-control/backup-publisher.token`，root0600；配置只保存 SHA-256。演练执行器使用不同 token，并只在完成隔离运行验收后将该执行器登记为 `canDrill:true`。
- 登记 broker token：cloud 侧 root 私有文件；公司侧安全分发到 `/run/credentials/uten-imp.service/dr-enrollment-broker.token`，systemd LoadCredential 私有凭据。用途仅为短期、内网、重新认证后的身份登记，不得用作控制面管理员会话。

公网 TLS、管理网 / 设备白名单、限流由独立网关配置；正式入口为预先批准的 `https://admin.justplayit.cn`，不复用员工业务 stream 的证书或 ERP 身份。网关只代理控制面 API，不向用户发布 broker 接口。绑定 broker 由公司固定受控转发连接 cloud loopback9087，SSH 账号必须无 shell、仅允许固定 `permitopen`；不允许 ERP 配置任意外部地址。

首次安装先创建独立账号、上述保护目录，按审核后的摘要安装程序及 unit，并在独立venv安装随包锁定的依赖。由 root 执行 `provision.py --config ... --origin https://admin.justplayit.cn --broker-token-file ... --broker-group root --agent-token-file ... --master-key-file /etc/uten-dr-control/totp-master.key`，不会向终端输出 token；首次配置默认 `enrollmentEnabledUntil:0`，绑定关闭。初始化四文件作为一套提交，配置最后落地；失败只回收本次新文件，既有秘密不覆盖；同参数重复初始化仅核验原文件。随后启用独立 systemd 服务，检查 `/healthz`，初始必须返回 `setupRequired:true` 和 `businessReady:false`。

不能以自动生成一份 root 凭据宣称用户已经拥有救援能力。真正登记流程是：运维将 root 配置的 `enrollmentEnabledUntil` 开放不超过15分钟并重启控制服务 → 公司内网当前超管本人在主站重新认证 → `/api/admin/disaster-recovery/enrollment` 以固定本机 broker 转发交换五分钟一次性登记能力 → 用户在独立页面绑定自己的验证器、独立口令并确认验证码。一次性能力只放 URL fragment，页面立即清除地址栏；不得打印、分享或收集到审计正文。新控制面用户尚未完成绑定之前，不声称远程救援已经就绪。

撤销救援身份必须在独立身份库立即设置 `users.revoked=1` 并清除相应会话，保留审计；该权限不随业务数据库恢复而复活。生产执行应由保护的管理流程以控制服务身份完成，禁止把可修改 SQLite 的路径暴露给 API。业务侧超管撤销与独立身份撤销需要运维成套核对，当前不会通过业务库可达性推断独立授权。

## 精确 API 契约

所有修改使用 JSON、有明确 Content-Length、受信 Origin；管理员 API 还要求独立 Bearer 与 `X-CSRF-Token`，写操作要求五分钟内重新验证的 MFA 会话。会话30分钟绝对超时、10分钟空闲超时，TOTP 原子单次消费；错误不透露口令、seed、token、文件路径或异常正文。

| API | 身份和行为 |
|---|---|
| `GET /healthz` | 仅返回控制服务存活、是否尚需登记；永不报告业务已恢复 |
| `POST /v1/broker/enrollments` | 保护的 ERP broker，仅在短期窗口接受绑定当前 `subject/account` 的内网超管 step-up；不对公网开放 |
| `POST /v1/enrollments/claim`、`/complete` | 五分钟一次性登记能力，绑定独立口令与用户验证器，不签发免 MFA 会话 |
| `POST /v1/auth/login`、`/logout` | 独立口令 + TOTP；不会接受业务 JWT |
| `GET /v1/state`、`GET /v1/jobs/{requestId}` | 登录后脱敏目标、恢复点及原作业回执；过期 lease 显示 UNKNOWN，不自动重试 |
| `PUT /v1/targets/{id}` | `label,agentId,kind,expectedRevision`；kind为ARCHIVE / DRILL / BUSINESS，ID及能力必须在执行器root配置中预登记 |
| `POST /v1/jobs` | `requestId(UUID),kind:DRILL,targetId,recoveryPointId,expectedRevision`；请求 ID 幂等，全局仅一个排队 / 执行 / 未知作业 |
| `POST /v1/promotions/prepare` | 建立PREPARING挑战作业，绑定旧主 / 目标 / 恢复点 / 下一代次；需要已commission的权威状态与BUSINESS执行器 |
| `POST /v1/promotions` | 同事务校验并消费本次FENCE+RESTORE独立签名后，预留单调epoch、记录旧主FENCED并入受限提升队列；条件缺失409，不接受手填bool |
| `POST /v1/promotions/{id}/refresh-proofs` | 仅未领取的QUEUED作业可更新过期签名，不重复提升 |
| `POST /v1/promotions/{id}/reconcile` | UNKNOWN只能用新的FENCE与实际ACTIVATION签名核对原结果，不重跑命令 |
| `POST /v1/promotions/{id}/cancel` | 仅取消尚未授权的PREPARING作业，绝不自动解除实际隔离 |

执行器 token 不能登记用户、管理目标或授权提升；root 配置仅允许固定 `tokenSha256,targetIds,canDrill,canPromote`，未知字段及 endpoint / command 一律拒绝。云归档发布者默认两项执行能力均为false。

`POST /v1/agent/snapshot`：`agentId,sequence(持久递增整数),observedAt(带时区),health:HEALTHY|DEGRADED,recoveryPoints:[{id,storageTargetId,recoverableUntil,manifestSha256,cipherSha256,complete,cipherVerified,keysCovered,verified}]`。5分钟内的观测才接受，sequence不能重放，点ID与清单不可变。只存档的发布者只能证明密文接收，服务端强制其 `keysCovered/verified` 为false。在线状态每次读取按新鲜度计算。

`POST /v1/agent/jobs/claim`：请求 `{agentId}`，无作业返回 `{job:null}`；成功返回 `{job:{id,kind:DRILL,targetId,recoveryPointId,manifestSha256},leaseToken,leaseExpiresAt}`，同一作业只领取一次。

`POST /v1/agent/jobs/{id}/complete`：`{leaseToken,success,evidence:{databaseRestored,attachmentsVerified,keysVerified,isolated,sideEffectsDisabled,reportSha256}}`。成功必须五项为true并附报告SHA-256；token必须属于原执行器与原有效lease，过期结果不能认成功。排队前只要求成套、校验通过的密文，未知密钥覆盖由隔离演练实测，缺项只能失败。执行器必须使用固定恢复根目录和已审核的隔离工具；控制面自己不执行恢复命令。

PROMOTE领取会额外返回`sourceId,desiredEpoch,signedReceipts`，领取前重新检查两签名TTL，lease不超过证据有效期。完成必须提交`activationReceipt`，由独立预登记ACTIVATION signer签名并绑定原leaseSHA、新数据库system identifier、原恢复LSN；缺少实际启用事实不能成功。失败或超时不回退epoch、不重开旧主。root抬高`promotion.minimumEpoch`后，旧controlDB中的低代次排队 / 执行作业一律UNKNOWN，不可绕过floor继续领取或回报。

签名格式见`promotion_receipts.py`：canonical JSON只排除`signature`字段，字段完整、签名scope固定，receiptId唯一账本；绑定operationId、sourceId、targetId、recoveryPointId、manifestSHA、epoch、签发 / 过期时间(最长300秒)、purpose及对应checks。root公钥登记还限制purpose、sourceIds和targetIds，三类签名身份独立。实际fencer必须位于旧主与云控制面之外，证明数据库 / 存储写入和旧writer lease被强制阻断；停HTTP、WAN断线和旧主自报均不算。目标执行器也须独立验证签名与本机单调epoch，再执行固定受控动作，不能仅相信控制面HTTP回复。

## Flutter 和主站集成

Flutter Release 使用可信构建参数 `DR_CONTROL_PLANE_URL=https://admin.justplayit.cn`。设置中的“运行与灾备”、登录页与连接失败横幅进入同一个公开路由 `/operations/recovery`；独立页面不依赖 ERP 获取 URL，不复用业务登录态。正常公司内网超管可以调用新登记 broker；未发布该 broker 的旧 JAR 只具有独立救援直达能力，不能假称完成绑定。

主站配置 `uten.disaster-recovery.enrollment-token-file` 指向上述保护 token 文件；broker URL默认 `http://127.0.0.1:9087`。源集成最小修改为五个现有Flutter文件和两个新增功能文件；原始 preimage、SHA 和本轮单独 patch 保存在本机审核目录，不将整个 dirty checkout 视为发布权威。

验证使用 `python3 -m unittest discover -s deploy/disaster-recovery -p test_control_plane.py -v`，测试覆盖独立登记、TOTP防重放、CSRF、会话撤销、快照作用域、CAS、并发排队、lease未知态和提升拒绝。真实备份接收、管理机解密 / PostgreSQL恢复 / 原件及历史密钥核验须另有目标机证据；测试fixture不能作为某个正式恢复点的成功回执。
