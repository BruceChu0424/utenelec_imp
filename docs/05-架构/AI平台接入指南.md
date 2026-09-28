# AI 平台接入指南

> 适用: 任何想用大模型的新功能(第一个接入方是销售客户文件识别, ADR-134)。设计与安全决定见
> [ADR-133 公共 AI 平台与服务商可配置](../99-决策记录-ADR/ADR-133-公共AI平台与服务商可配置.md)。
> 本文只讲「怎么接」; 新行一律用半角括号。

## 一、先选接入方式

| 场景 | 用什么 | 说明 |
| --- | --- | --- |
| 上传文件后识别、要几十秒、要进度与取消 | 异步任务: 实现 `AiJobHandler` | 平台负责上传、排队、后台线程、进度、取消、租约、清理与「只给本人看」; 前端用公共进度弹窗 |
| 已经在服务端手里的一小段文字, 几秒内出结果 | 同步调用: 注入 `AiCompletionPort` | 必须在**事务外**、非请求高峰的路径上调用; 超过 5 秒的请改用异步任务 |

两条路都经同一个网关: 同一个默认服务商、同一套出网/境外开关、同一个并发名额与每日额度、同一张调用技术记录。
业务 feature 只依赖 `com.uten.imp.application.port` 下的接口, **不得** import `features.ai`
(ArchitectureBoundaryTest 锁 feature 依赖图); 报销模块(`features.expenseclaim`)**不得**接入 AI 平台
(ADR-094, 由 ArchitectureBoundaryTest 单独一条规则锁住)。

## 二、同步调用 `AiCompletionPort`

```java
@Slf4j
@Service
@RequiredArgsConstructor
class SupplierNoteSummarizer {
    private final AiCompletionPort ai;
    private final ObjectMapper objectMapper;

    /** 不要加 @Transactional: 网关发现事务会直接拒绝。 */
    Optional<String> summarize(String supplierNote) throws JsonProcessingException {
        if (!ai.availability().available()) {
            return Optional.empty();                      // AI 没配置/被关: 走不用 AI 的老路
        }
        var request = new AiCompletionPort.AiCompletionRequest(
                "SUPPLIER_NOTE_SUMMARY",                  // 用途代码: 大写下划线, 进调用技术记录
                "Summarize the supplier note in Chinese in at most 40 characters. "
                        + "Return {\"summary\": string}.",   // 英文系统提示词, 写清 JSON 形状
                List.of(new AiCompletionPort.AiText(supplierNote, true)),   // 外部内容一律 untrusted = true
                null, null,                               // 服务商支持 JSON_SCHEMA 时可给 schema 名称与 schema
                256,                                      // 本次最大输出 token(再与服务商上限取小)
                null);                                    // 非任务调用 jobId 为空
        try {
            String json = ai.completeJson(request).json(); // 已去掉代码块、取出首个完整 JSON 对象
            return Optional.of(objectMapper.readTree(json).path("summary").asText());
        } catch (AiCompletionPort.AiCallException e) {
            // e.getMessage() 面向管理员(可能带服务商原文与状态码); 给业务人员的界面按 e.category() 换成通俗说法
            log.info("supplier note summary failed: category={}, status={}", e.category(), e.httpStatus());
            throw new ApiException(ErrorCode.BUSINESS, "AI 暂时用不了, 请稍后再试");
        }
    }
}
```

要点:

- **绝不在事务里调用**(会占住数据库连接几十秒); 需要读写库就在调用前后各开一个短事务。
- 网关已经做了: 取默认且启用的服务商、解密密钥、出网/境外/图片能力检查、每日 token 额度、并发名额(最多等 30 秒)、
  系统提示词追加 `Respond with a single JSON object.`、不可信文本加随机编号的隔离标记、网络/服务端/返回无法解析时重试一次、
  每次尝试写 `ai_call_logs`。调用方不要自己重试。
- 返回的 JSON 仍然是**不可信数据**: 调用方必须按自己的规则校验(字段类型、取值范围、引用的 id 是否在服务端给出的候选里)。
- 错误类别: AUTH / NOT_FOUND / BAD_REQUEST / RATE_LIMIT / QUOTA / TIMEOUT / NETWORK / SERVER / INVALID_RESPONSE /
  BLOCKED(被规则或次数拦截) / UNAVAILABLE(没配置或被关)。`e.getMessage()` 不含密钥, 但为了让管理员排错会带
  「密钥无效」「服务商返回 503」「服务商不接受这个请求: <服务商原文>」这类技术说法, **不要直接显示给业务人员**;
  面向业务人员时按类别换成通俗说法(与异步任务的规则相同, 见 §三.5)。
- **JSON Schema**(服务商的 JSON 方式为 `JSON_SCHEMA` 时才会发送 schema, 目前 OpenAI 与 Claude 预设默认如此):
  按「严格模式」写 schema —— 每一层对象都写 `"additionalProperties": false`; `required` 列出 `properties` 的**每一个**键;
  「没有就填 null」的字段写成类型联合, 例如 `"type": ["string", "null"]`, 而不是从 `required` 里去掉。
  满足这两条时 OpenAI 客户端发 `strict: true`(输出保证符合 schema); 不满足时自动改发 `strict: false`
  (schema 只作指引, 输出仍要自己校验) —— 否则 OpenAI 会以 400 拒绝整个请求(类别 BAD_REQUEST)。
- 只发**完成任务所必需**的内容: 不发银行账号、证件号、私人联系方式、价格、成本等; 需要发送的字段写进你的 ADR,
  并登记到《中国大陆部署与兼容性》。
- 日志只记用途、耗时与错误类别, 不记提示词、文件内容与回复。

## 三、写一个异步任务处理器 `AiJobHandler`

实现接口并注册为 Spring Bean 即自动接入(`AiJobHandlerRegistry` 按 `kind()` 查找, 大写下划线、全局唯一)。

```java
@Component
@RequiredArgsConstructor
class PurchaseInvoiceMatchHandler implements AiJobHandler {
    static final String KIND = "PURCHASE_DOCUMENT_MATCH";

    @Override public String kind() { return KIND; }

    /** 读上传内容之前: 校验权限与参数(403/400)。只做便宜的检查。 */
    @Override public void authorizeSubmit(Map<String, String> params) {
        boolean allowed = currentUser.get()                // SecurityContextCurrentUser
                .map(user -> user.getPermissions().contains("purchase_order:create")).orElse(false);
        if (!allowed) throw new ApiException(ErrorCode.FORBIDDEN);
    }

    /** 有界读取与嗅探之后: 校验文件类型/大小/参数引用的主档是否可见。 */
    @Override public void validateInput(Map<String, String> params, AiJobInput input) { }

    @Override public long maxInputBytes() { return 10L * 1024 * 1024; }   // 与平台 15 MiB 取小
    @Override public Set<String> acceptedKinds() { return Set.of("XLSX", "XLS", "CSV", "PDF"); }

    /** 每次查询结果都会重新调用: 提交人后来失去权限就读不到。 */
    @Override public void authorizeRead(Map<String, String> params) { authorizeSubmit(params); }

    /** 按当前读者权限过滤(不得修改入参)。 */
    @Override public Map<String, Object> filterResultForReader(Map<String, Object> result) { return result; }

    /** 后台线程、无事务、SecurityContext 是提交人重建出的主体。 */
    @Override public Map<String, Object> process(AiJobContext ctx) throws Exception {
        ctx.progress("READING", 5);                       // 阶段键: 大写下划线; 见下方「阶段约定」
        var grid = readGrid(ctx.input().bytes());          // 先把文件完整解析完, 再调用 AI
        ctx.progress("LAYOUT", 20);
        if (ctx.cancelled()) return Map.of();              // 用户取消或系统正在清库: 尽快返回
        Map<String, Object> result = rules(grid);          // 固定规则先做
        if (ctx.aiAllowed() && needsAi(result)) {          // 提交人持有 ai:use 且 AI 可用
            ctx.progress("AI_EXTRACTING", 50);
            var reply = ctx.completeJson(request(grid));   // 计入本任务 AI 次数(默认最多 12 次), jobId 自动带上
            merge(result, reply.json());
        }
        ctx.progress("MATCHING", 80);
        return result;                                     // 存为任务结果(JSON 对象, 不超过 8 MB)
    }
}
```

生命周期与约定:

1. **提交**(`POST /api/ai/jobs?kind=...&<参数>`, 原始字节流): 找处理器 → `authorizeSubmit` → 每人进行中 <= 2、每天 <= 60、
   全局排队 <= 100 → 有界读取 → 嗅探(XLSX/XLS/CSV/PDF/PNG/JPEG/WEBP, 按魔数与扩展名) → `validateInput` → 同一人同一文件
   同一参数 10 分钟内直接复用(已请求取消、已被单据采用的不复用) → 入队 → 202。参数是查询串(键 `^[A-Za-z][A-Za-z0-9_]{0,47}$`, 值 <= 512 字符, 最多 16 个)。
2. **处理**: 后台线程认领后先按提交时的授权戳重建提交人主体(账号或权限有变化即失败「账号权限已变化, 请重新识别」),
   再调用 `process`。`process` 里需要读写数据库时自己开**短**事务; AI 调用在事务外。
3. **阶段约定**: `READING` / `PARSING` / `LAYOUT` 是「解析文件」阶段 —— 处理线程在这些阶段死掉(租约过期)时平台判定是坏文件,
   直接失败「文件无法解析」不再重试; 其后的阶段第一次过期会重新排队一次(AI 次数归零、从头处理), 第二次判失败;
   用户已点取消的任务租约过期时直接按取消结束; 处理中发现 `cancelled()` 时直接返回空结果即可, 平台按「已取消」结束、不保存结果。所以: **先把文件完整解析完, 再调用 AI**,
   并且解析阶段一定要报告这三个阶段键之一。平台认领任务时把阶段置为 `STARTING`(重建主体中, 不算解析阶段), 重新排队的任务从头处理。其他阶段键自取(前端进度弹窗按阶段键分组显示)。
4. **进度、租约与取消**: 处理中的任务有租约(`uten.ai.job-lease-seconds`, 默认 600 秒), 过期视为处理线程已死。
   `progress(stage, percent)` 写一个短事务并续租; `completeJson` 调用期间平台每隔租约的 1/4(最长 60 秒)自动续租,
   调用结束再续一次 —— 所以等名额、服务商超时加重试一次都不会让任务被误判中断。处理器**自己的**耗时工作(解析、匹配)
   平台不续租: 超过几分钟的循环里要定期 `progress(...)`。任务被取消/清理/清库, 或租约过期后已被重新认领时,
   `progress` 静默返回、`cancelled()` 变成 true, 之后任何结果都不会写入 —— 在阶段之间检查 `cancelled()` 并尽快返回。
5. **失败**(`errorMessage` 会显示给提交人, 一律是业务人员能看懂的话):
   - 抛 `ApiException`: 它的中文消息原样显示(处理器自己负责写成通俗说法); 需要前端按原因给出不同的下一步时,
     在 `fieldErrors` 里放 `field = "errorCode"`、`message = 业务码`(大写下划线, 不超过 48 字符, 例如销售识别的
     `AI_REQUIRED`、`AI_VISION_UNAVAILABLE`), 平台写进任务的 `errorCode`; 没有时 `errorCode` 为 `ApiException` 的错误类别名;
   - 没接住的 `AiCallException`: 错误码记 `AI_<类别>`(给管理员与日志), 显示的消息按类别换成通俗说法 ——
     RATE_LIMIT / QUOTA →「AI 服务暂时繁忙或今日额度已用完, 请稍后再试」; AUTH / NOT_FOUND / BAD_REQUEST / UNAVAILABLE /
     BLOCKED →「AI 服务暂时不可用, 请联系管理员」; TIMEOUT / NETWORK / SERVER / INVALID_RESPONSE →「识别失败, 请稍后重试」。
     平台自己抛出的 BLOCKED 提示原样保留:「识别已取消」「没有使用 AI 识别的权限」「这次识别调用 AI 的次数已达上限」
     「系统正在重置数据, 请稍后重试」「当前 AI 服务不支持识别图片, 请上传 Excel 或文字版 PDF」。类别与 HTTP 状态只记服务端日志;
   - 其他异常一律「识别失败, 请稍后重试」(服务端日志只留异常类型与调用栈, 不留消息)。
6. **结果**: 只有提交人本人能查(其他人 404), 每次查询都重新 `authorizeRead` 并经 `filterResultForReader`。上传文件在终态清空,
   结果被单据采用时立即清空(没被采用的 48 小时后清空), 任务行 7 天后删除。
7. **没有 `ai:use` 或 AI 不可用**: `aiAllowed()` 为 false, `completeJson` 抛 BLOCKED —— 处理器必须有「只用固定规则」的退路。

### 保存单据时使用识别结果(`AiJobUsagePort`)

```java
// 先读: 以服务端保存的结果为准, 不信任请求体里回传的识别内容
Map<String, Object> result = aiJobUsage.resultFor(jobId, currentUserId).orElse(Map.of());
...
// 后标记: 记下去向并在同一条语句里清空结果
aiJobUsage.markUsed(jobId, currentUserId, "quote", quoteId);
```

- `resultFor` 只对提交人本人、成功、**从未被单据采用**且未清空的任务返回完整(未过滤)结果, 其余一律为空。
- 一个结果只能被一张单据采用: `markUsed` 第一张单据生效并立即清空结果; 之后别的单据再标记不生效、去向不变,
  也读不到结果(同一识别结果不会喂给第二张单据的学习); 同一张单据重复标记无害。
- 所以需要结果的一方必须**先读后标记**: 在保存事务里读好, 或像主档学习那样在提交后回调里先读、最后一步再标记
  (主档学习回调顺序 `LOWEST_PRECEDENCE`); 其他需要同一结果的提交后回调要排在它前面(版式学习 `SalesIntakeLayoutLearner`
  就是 `HIGHEST_PRECEDENCE` 的提交后回调), 或在保存事务里先读好。

### 前端(`lib/shared/ai/`)

```dart
final runner = ref.read(aiJobRunnerProvider);
final snapshot = await showAiProgressDialog(
  context,
  title: l10n.salesIntakeProgressTitle,
  stages: const [
    AiProgressStage(key: 'upload', label: '上传文件', serverStages: [AiJobSnapshot.uploadingStage]),
    AiProgressStage(key: 'read', label: '读取表格', serverStages: ['READING', 'PARSING', 'LAYOUT']),
    AiProgressStage(key: 'match', label: '对应货品', serverStages: ['MATCHING']),
  ],
  task: (onProgress, cancelToken) => runner.run(
    AiJobRequest(kind: 'PURCHASE_DOCUMENT_MATCH', params: {'supplierId': id},
        bytes: bytes, fileName: name, contentType: type),
    onProgress: onProgress,
    cancelToken: cancelToken,
  ),
);
if (snapshot == null) return;              // 用户取消
final result = snapshot.result;            // 失败时抛 AiJobFailure(message 可直接展示)
```

- 只需「提交 + 进度弹窗」时直接用 `runAiJob(context, runner:, request:, title:, stages:)`(内部就是上面的 `showAiProgressDialog(..., task:)`)。
- 第一步要覆盖上传阶段 `AiJobSnapshot.uploadingStage`(`UPLOADING`); 服务端认领后先报 `STARTING`(重建提交人主体), 可并入第一个服务端阶段。
  `AiProgressStage.serverStages` 列出该步骤对应的服务端阶段键, 阶段只进不退。
- 用户取消(含服务端已取消)返回 null; 作业失败抛 `AiJobFailure{message, code, snapshot, clientMessage}`(`code` 为服务端 `errorCode`
  或客户端的 `CANCELLED` / `CLIENT_TIMEOUT` / `JOB_GONE` / `FAILED`); 提交被服务端拒绝(403/422/429)时原样抛 `ApiException`。

- 状态接口 `GET /api/ai/status` → `aiStatusProvider`: `available`(管理员已配置可用的 AI)、`aiAllowedForMe`(持有 `ai:use`)、
  `supportsVision`。AI 不可用时只提示「AI 未开启, 只能识别常见格式的文件」, 不要显示服务商或模型名称。
- 模拟身份期间提交被服务端只读守卫拦截, 界面应隐藏入口。
- 组件说明见 [AI 任务进度弹窗](../02-组件库/AI任务进度弹窗.md)。

## 四、新增服务商预设或协议

- **新预设**: 在 `AiProviderPreset` 加一项(显示名称、区域、协议、默认接口地址、建议模型、JSON 方式、关闭思考方式、
  温度、图片、是否必须密钥、**登记域名**)。境内预设必须同时把域名、发送字段与留存登记到
  《中国大陆部署与兼容性》的外部服务清单; 境外预设默认被 `uten.ai.allow-overseas-providers=false` 挡住。
  数据库 `ai_providers.preset` 的 CHECK 需要同一个迁移补上新值。
- **新协议**: 实现 `AiProtocolClient`(`protocol()` / `chat` / `listModels`), 注册为 Bean; 所有 HTTP 经 `AiHttpTransport`
  (防 SSRF、禁止跳转、超时、4 MiB 上限、错误映射与脱敏), 不要自己 new HttpClient。`ai_providers.protocol` 的 CHECK 同步扩展。
- 不要为某个服务商在业务代码里写分支: 差异放进能力开关。

## 五、安全规则(接入方自查)

- [ ] 端口调用在事务外; 没有在请求线程上同步等一个可能超过 45 秒的 AI 调用。
- [ ] 外部内容全部 `AiText(..., untrusted = true)`; AI 返回的 id/金额/状态都在服务端校验, 从不直接落库。
- [ ] 发送字段最少必要, 已写进 ADR 并登记; 没有发送价格、成本、账号、证件号、私人联系方式。
- [ ] 没有记录提示词、文件内容、回复与密钥。
- [ ] 异步任务: `authorizeSubmit` 与 `authorizeRead` 都做了权限校验; `filterResultForReader` 去掉当前读者不该看的字段;
      处理器有「只用固定规则」的退路; 解析阶段报告 READING/PARSING/LAYOUT。
- [ ] 保存单据时只用 `AiJobUsagePort.resultFor` 读服务端结果, 不信任请求体里的识别内容。
- [ ] 报销、工资等敏感模块不接入(ADR-094 与 ArchitectureBoundaryTest)。

## 六、测试

- **假服务商** `com.uten.imp.features.ai.support.FakeAiProviderServer`(测试源码): JDK `HttpServer`, 只监听 127.0.0.1 随机端口,
  OpenAI 与 Anthropic 两种形状。
  ```java
  try (FakeAiProviderServer fake = FakeAiProviderServer.start()) {
      fake.enqueue(FakeAiProviderServer.openAiContent("{\"clientName\": \"SUNAS\"}"));
      fake.enqueue(FakeAiProviderServer.openAiError(429, "rate limited"));
      AiProviderRuntime runtime = AiTestRuntimes.openAi(fake, "sk-test-key-0123456789");  // 本机部署 + 字面回环
      ...
      assertThat(fake.lastChatRequest().body()).contains("UNTRUSTED_DOCUMENT");
  }
  ```
  还有 `anthropicContent`、`anthropicError`、`redirect`、`raw`、`withDelay(毫秒)`(模拟超时)、`models(...)`、`modelsStatus(404)`。
- **处理器单元测试**: 直接 new 处理器, 用一个假的 `AiJobContext`(记录 `progress`、按脚本返回 `completeJson`、可切换 `aiAllowed`)。
- **真库端到端**: 继承 `com.uten.imp.features.ai.AiPlatformPostgresTestSupport`(真实 PostgreSQL + 全部迁移 + 完整安全链 +
  真实后台线程), 用 `resetToFakeDefaultProvider(adminToken())` 建一个指向假服务商的默认服务商, `aiUser()` 开一个持有
  `ai:use` 的员工, 再经 `POST /api/ai/jobs` 提交并轮询 `GET /api/ai/jobs/{id}`。需要 `UTEN_RUN_DB_TESTS=true` 与 Docker。
- 平台自身的测试清单见 ADR-133「验证」。

## 七、运维

- **服务商配置**: 系统设置 → AI 服务(超管, 写入要再次输入登录密码)。
- **环境开关**(`server.env`):
  | 变量 | 默认 | 说明 |
  | --- | --- | --- |
  | `UTEN_SECRET_CIPHER_KEY` / `UTEN_SECRET_CIPHER_KEY_VERSION` | 空(由 `UTEN_HMAC_KEY` 派生) / 1 | 服务商密钥的专用加密密钥, 至少 32 字节; 新装机模板自动生成。**云端实例必须与本地生产完全相同**(和 JWT/PGP/HMAC 密钥一样), 否则云端解不开已保存的密钥, 状态接口报 AI 不可用、设置页显示「密钥无法解密」 |
  | `UTEN_CRYPTO_SECRETCIPHERLEGACYKEYS_<旧版本号>` | 无 | 轮换用: 旧密钥按版本号放这里(即 `uten.crypto.secret-cipher-legacy-keys.<旧版本号>` 的环境变量写法, 例如 `UTEN_CRYPTO_SECRETCIPHERLEGACYKEYS_1=<旧值>`), 新值写进 `UTEN_SECRET_CIPHER_KEY` 且版本号加一; 重启后启动任务把全部密文改用新密钥重新加密, 确认设置页不再有「密钥无法解密」后删掉旧值。云端与本地同步修改 |
  | `UTEN_AI_OUTBOUND_ENABLED` | true | false 时只能用本机部署; internal-test 强制 false |
  | `UTEN_AI_ALLOW_OVERSEAS` | false | 境外服务商; 开启前必须完成数据出境评估 |
  | `UTEN_AI_ALLOW_LAN_HTTP` | false | 本机部署可否用明文 http 访问内网地址 |
  | `UTEN_AI_DAILY_TOKEN_BUDGET` | 3000000 | 每天全公司 token 总额度, 0 为不限 |
  | `UTEN_AI_MAX_CONCURRENT_CALLS` / `UTEN_AI_JOB_WORKERS` | 4 / 2 | 并发调用名额 / 后台线程数 |
  | `UTEN_AI_MAX_CALLS_PER_JOB` / `UTEN_AI_MAX_JOBS_PER_USER_PER_DAY` | 12 / 60 | 每个任务 AI 次数 / 每人每天任务数 |
  | `UTEN_AI_RESULT_RETENTION_HOURS` / `UTEN_AI_JOB_RETENTION_DAYS` / `UTEN_AI_CALL_LOG_RETENTION_DAYS` | 48 / 7 / 180 | 留存 |
- **nginx**: 每个模板都有精确 location `= /api/ai/jobs`(16 MiB、独立限流区 12 次/分钟 + 突发 4、每 IP 并发 2 超出回 429、
  不缓冲请求体、读超时 60 秒); 查询与取消走普通 `/api/`。
- **跨源网页(CORS)**: 上传要带请求头 `X-Uten-File-Name` / `X-Uten-File-Type`(`AiJobController.HEADER_FILE_NAME` / `HEADER_FILE_TYPE`)。
  网页与接口不同源时(本机 Flutter Web 开发端口 53764、办公网页访问云端接口), 这两个头必须在 `SecurityConfig.corsConfigurationSource`
  的允许请求头里, 否则浏览器预检失败、文件传不上来; 同源部署与桌面端不受影响。文件名故意放请求头而不是查询串:
  文件名常含客户名称, 查询串会进 nginx 访问日志。
- **租约**: `uten.ai.job-lease-seconds`(默认 600)一般不用改; AI 调用期间自动续租, 与服务商超时设置无关。
- **后台任务**(服务器状态页可见): 「AI 识别任务」每 5 秒接手排队任务并回收过期租约; 「AI 数据清理」每 10 分钟清理。
  两者只在本地实例运行, 业务数据清空期间自动跳过。
- **用量**: 设置页的用量卡片(`GET /api/admin/ai/usage?days=30`)按服务商汇总调用次数、成功率、token 与平均耗时, 并显示今日用量与每日额度;
  明细在 `ai_call_logs`(不含提示词与回复)。
- **服务器迁移/恢复到别的环境**: AAD 绑定 JWT 签发者, 换环境后已保存的密钥会显示「密钥无法解密, 请重新填写」, 在设置页重新填写即可。
