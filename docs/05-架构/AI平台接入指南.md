# AI 平台接入指南

AI 助手(ERP_CHAT)接入见 [第八章](#八ai-助手页面上下文有据作答与确认卡契约adr-150--adr-152--adr-153--adr-158--adr-159) 与 [ADR-150](../99-决策记录-ADR/ADR-150-AI助手页面上下文有据作答与确认后执行.md): 前端随问题发送有界的页面快照, 模型基于服务端发出的来源组织完整回答, 回答经事实守卫, 不通过时按页面内容确定性整理; AI 提出的操作只来自页面登记的动作集, 先生成一次性确认卡, 用户确认后才由页面原按钮路径或原业务端点执行。业务工具仍实现 AiChatToolPort, 成本等敏感结果默认不外送(ADR-140 的权限与历史复核规则不变); 功能目录、「我的权限」与单据进度工具见 [8.12](#812-有据作答功能目录与单据工具adr-159)(ADR-159)。

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
- 只发**完成任务所必需**的内容: 不发银行账号、证件号、私人联系方式、成本、工资、密码与凭证等; 需要发送的字段写进你的 ADR,
  并登记到《中国大陆部署与兼容性》。AI 助手的页面快照(第八章)是用户拍板的例外: 会发送屏幕上可见的业务值(含销售价格),
  但同一组敏感类别仍只发标签(8.2 敏感兜底), 工资/人事/个人资料页面整页不读。
- 日志只记用途、耗时与错误类别, 不记提示词、文件内容与回复。
- **思考程度 `reasoningEffort`**(ADR-152): `AiCompletionRequest` 的第 8 个字段, 取 `DEFAULT / OFF / LOW / MEDIUM / HIGH`
  (7 参构造器默认 `DEFAULT`)。`DEFAULT` = 不要求, 保持服务商配置的原有行为(识别、抽取类用途都用它: DeepSeek/通义/OpenAI 写法关思考,
  智谱与 Anthropic 写法不发参数); 其余档由网关按服务商的「思考参数写法」(`ai_providers.thinking_control`)映射, 唯一映射表是
  `AiReasoningParams`。「能否调整」只有一个判定 `AiReasoningParams.supported(runtime)`: 写法 + 生效协议 + 模型三者都接受才算;
  不能调整时**一律按 `DEFAULT` 写请求体**, 所以账号里存的任何档位都不会让请求被服务商拒绝:

  | 写法(协议) | OFF | LOW | MEDIUM | HIGH |
  | --- | --- | --- | --- | --- |
  | DEEPSEEK | `thinking:{type:disabled}` | `thinking:{type:enabled}` + `reasoning_effort:low` | 同左 + `high` | 同左 + `max` |
  | ZHIPU(OpenAI 兼容 `/api/paas/v4`) | `thinking:{type:enabled}` + `reasoning_effort:low`(GLM-5.3 关不掉思考) | 同左 `low` | `high` | `max` |
  | ZHIPU(Anthropic 兼容 `/api/anthropic`) | `output_config.effort:low` | `low` | `high` | `max` |
  | DASHSCOPE(不可调整) | `enable_thinking:false` | 同左 | 同左 | 同左 |
  | OPENAI_REASONING | `reasoning_effort:none` | `low` | `medium` | `high` |
  | ANTHROPIC_EFFORT(Opus 4.5 / Sonnet 4.6 及以上) | `output_config.effort:low` | `low` | `medium` | `high` |
  | ANTHROPIC_EFFORT + 不认 effort 的模型(Claude 3、Haiku 4.x、Sonnet 4/4.5、Opus 4/4.1, 含云厂商前缀) | 不发 | 不发 | 不发 | 不发 |
  | NONE、写法与生效协议不匹配 | 不发 | 不发 | 不发 | 不发 |

  - 通义千问的思考模式只支持流式输出、且不能和 JSON 模式同用(百炼错误码: 非流式调用 `enable_thinking` 必须为 false; 开思考时不支持
    JSON 模式), 本平台是非流式 JSON 调用, 所以通义写法只用来关掉思考, `reasoningEffortSupported=false`。
  - OpenAI 推理模型只在 `reasoning_effort:none` 时接受 `temperature`: 管理员打开「固定输出(温度 0)」时, 带了 low/medium/high 的请求
    不发 `temperature`(`AiReasoningParams.allowsTemperature`); DeepSeek 开思考时 temperature 不生效, 同样不发。

  支持调整时网关在回答上限之外另给思考额度(LOW +2048、MEDIUM +4096、HIGH +16384 输出 token), 但**单次输出永远不超过管理员配置的
  「最大输出长度」**(那是单次输出含思考的硬上限, 往往就是模型本身的上限, 也是成本上限; 想给「深入」更多思考空间由管理员调大); 并调整超时
  (OFF ≤60 秒, HIGH 为配置的 1.5 倍且 ≤240 秒), 写一行 `AI call reasoning: purpose=…, effort=…, params=[…]` 日志(只有参数名与档位,
  不能调整时 `params=[none]`)。调用方只给回答需要的上限, 不要按思考档自己缩放(对话固定 8192, 详略决定长短)。
  `availability().supportsReasoningEffort()` 告诉调用方当前默认服务商能否调整; 不能时请求照常成功, 只是不发思考参数、额度和超时都不变。
  不发 `budget_tokens`(GLM 忽略、新 Claude 模型直接 400)。
  「测试连接」在能调整时多一步「思考程度」(`THINKING`): 按对话默认档「标准」(MEDIUM)用同一套写法再发一次小对话, 服务商 400/404
  = 这个模型不认思考参数, 判失败并提示把写法改为「不发送」或换模型; 超时、限流只提示。

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
     平台(`AiJobWorker.errorCodeOf`)把它存进 `ai_jobs.error_code`, 查询接口原样返回 `errorCode`, 前端 `AiJobFailure.code` 就是它。
     业务码必须匹配 `^[A-Z][A-Z0-9_]{0,47}$`, 不匹配(小写、带空格、超长)时静默退回错误类别名(如 `BUSINESS`), 前端就分不出原因 ——
     建议像销售识别那样写一个小工具方法统一构造:
     `new ApiException(ErrorCode.BUSINESS, message, List.of(new ApiError.FieldError("errorCode", code)))`
     (`SalesIntakePipeline.fail(message, code)`; 销售识别现有 `UNSUPPORTED_FILE` / `NO_TABLE` / `NO_LINES` / `AI_REQUIRED` /
     `AI_VISION_UNAVAILABLE` / `AI_FAILED`)。业务码不要与平台自己的 `AI_<类别>`(如 `AI_TIMEOUT`、`AI_RATE_LIMIT`)或平台保留码
     (`INTERNAL`、`RESETTING`、`RESULT_TOO_LARGE`、`UNKNOWN_KIND`、`PRINCIPAL_CHANGED`、`UNPARSABLE`、`INTERRUPTED`、`QUEUE_TIMEOUT`)重名;
   - 没接住的 `AiCallException`: 错误码记 `AI_<类别>`(给管理员与日志), 显示的消息按类别换成通俗说法 ——
     RATE_LIMIT / QUOTA →「AI 服务暂时繁忙或今日额度已用完, 请稍后再试」; AUTH / NOT_FOUND / BAD_REQUEST / UNAVAILABLE /
     BLOCKED →「AI 服务暂时不可用, 请联系管理员」; TIMEOUT / NETWORK / SERVER / INVALID_RESPONSE →「识别失败, 请稍后重试」。
     平台自己抛出的 BLOCKED 提示原样保留:「识别已取消」「没有使用 AI 识别的权限」「这次识别调用 AI 的次数已达上限」
     「系统正在重置数据, 请稍后重试」「当前 AI 服务不支持识别图片, 请上传 Excel 或文字版 PDF」。类别与 HTTP 状态只记服务端日志;
   - 其他异常一律「识别失败, 请稍后重试」(服务端日志只留异常类型与调用栈, 不留消息)。
6. **结果**: 只有提交人本人能查(其他人 404), 每次查询都重新 `authorizeRead` 并经 `filterResultForReader`。上传文件在终态清空。
   普通未保留任务沿用未采用结果 48 小时、任务行 7 天的清理规则；V751 为销售确认学习增加 `learning_retry_until`，
   保存单据时在同事务内把可信来源固定到唯一单据，学习回执可重试期间最长保留 30 天。不能用普通清理提前删除其结果或模板候选。
   销售学习的所有必要步骤成功或明确跳过后才消费结果；失败保留回执和必要证据，过期后按保留规则清理。
7. **没有 `ai:use` 或 AI 不可用**: `aiAllowed()` 为 false, `completeJson` 抛 BLOCKED —— 处理器必须有「只用固定规则」的退路。

### 保存单据时使用识别结果(`AiJobUsagePort`)

销售链统一经过 `SalesIntakeSaveHooks` 与 `SalesLearningReceiptPort`：

1. 保存事务校验人工确认的选择，登记学习回执，并用 `reserveLearningForSave` 核实服务端来源行、操作人及单据归属；此时只保留证据，不提前清空结果。
2. 单据提交成功后，在独立短事务执行 MASTER、各来源的 LAYOUT/TEMPLATE 等步骤；步骤状态、次数及必要证据持久化。任一步失败不回滚已保存单据，也不吞掉失败状态。
3. 所有必要步骤成功或明确跳过后，CONSUME 才调用 `markUsed`，写 `used_at` 并清空识别结果。单据保留关系与结果消费是不同状态，不再靠回调先后顺序保障证据完整。
4. 详情页读取 `/sales/{quotes|orders}/{docId}/learning`；原保存人可以在租约内调用重试入口。重试重新检查身份、单据范围、当前字段编辑权限和服务端来源，不接受请求体伪造识别内容，也不覆盖后来人工确认的资料。

`resultFor` 仍是仅供内部学习使用的本人成功任务结果读取口，不直接向页面暴露未过滤内容。新的销售接入不得在保存回调中自行提前调用 `markUsed`，应复用回执协调。一个来源结果只归属一张单据，同单据重复请求幂等，跨单据重用被拒绝。批量识别通过 `additionalJobIds` 保存各份真实来源，不能只学习最后一份文件。

界面只展示步骤、计数、可重试状态和通俗提示；识别原文、客户资料载荷与内部异常不进入状态面板。相关规则与迁移见 [ADR-137](../99-决策记录-ADR/ADR-137-全平台可扩展表格与统一投影.md) 和 [V751](../数据迁移/264-V750至V752全平台扩展列与学习回执.md)。

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

- **新预设**: 在 `AiProviderPreset` 加一项(显示名称、区域、协议、默认接口地址、建议模型、JSON 方式、思考参数写法
  (ADR-152, `AiThinkingControl`; 新写法要在 `AiReasoningParams` 补映射并同步 `ai_providers.thinking_control` 的 CHECK)、
  温度、图片、是否必须密钥、**登记域名**)。境内预设必须同时把域名、发送字段与留存登记到
  《中国大陆部署与兼容性》的外部服务清单; 境外预设默认被 `uten.ai.allow-overseas-providers=false` 挡住。
  数据库 `ai_providers.preset` 的 CHECK 需要同一个迁移补上新值。
- **新协议**: 实现 `AiProtocolClient`(`protocol()` / `chat` / `listModels`), 注册为 Bean; 所有 HTTP 经 `AiHttpTransport`
  (防 SSRF、禁止跳转、超时、4 MiB 上限、错误映射与脱敏), 不要自己 new HttpClient。`ai_providers.protocol` 的 CHECK 同步扩展。
- 不要为某个服务商在业务代码里写分支: 差异放进能力开关。

## 五、安全规则(接入方自查)

- [ ] 端口调用在事务外; 没有在请求线程上同步等一个可能超过 45 秒的 AI 调用。
- [ ] 外部内容全部 `AiText(..., untrusted = true)`; AI 返回的 id/金额/状态都在服务端校验, 从不直接落库。
- [ ] 发送字段最少必要, 已写进 ADR 并登记; 没有发送成本、工资、信用额度、账号、证件号、私人联系方式(AI 助手的页面快照按 ADR-150 只含屏幕可见内容, 敏感数值默认不发送)。
- [ ] 没有记录提示词、文件内容、回复与密钥。
- [ ] 异步任务: `authorizeSubmit` 与 `authorizeRead` 都做了权限校验; `filterResultForReader` 去掉当前读者不该看的字段;
      处理器有「只用固定规则」的退路; 解析阶段报告 READING/PARSING/LAYOUT。
- [ ] 保存单据时只用 `AiJobUsagePort.resultFor` 读服务端结果, 不信任请求体里的识别内容。
- [ ] 报销、工资等敏感模块不接入(ADR-094 与 ArchitectureBoundaryTest)。
- [ ] 处理用户上传的文件时先用本地确定性规则; 只有规则认不出才可把**结构**交给模型(表名、表头列名、值形状、行数, 数字与像人名的名称打码),
      不发任何数据行的值、文件名与文件本身; 模型只回固定枚举, 不决定卡片、页面或权限; 外送字段登记进 ADR 与《中国大陆部署与兼容性》2.3.1(ADR-158)。
- [ ] 给用户的去处(可填的单据、可去的页面)来自写死的固定目录, 按读者**当前**权限在每次读取时重算; 缺权限的写成中文原因(不出现权限码);
      页面路由与前端路由守卫用契约测试对齐(ADR-158 的 `ai_document_destinations_contract_test.dart`)。
- [ ] AI 对话的只读工具(`AiChatToolPort`): 放在业务自己的 feature 里; 查看范围与对应详情页**同一判断**, 先判后读, 看不到与不存在回同一句话、同一证据摘要;
      `modelFacts` 只放阶段、状态、日期、编码名称、数量与单号, 不放人名、客户供应商名称、金额与原因原文, 并在 `AiChatOutboundFactsContractTest` 登记、写进《中国大陆部署与兼容性》2.3.1;
      `authorizeResultRead` 按读者当前范围重读复核; 工具只在 `AiChatDialogueSupport.toolEligible` 认可的问法下执行(ADR-159, 见 8.12)。
- [ ] 给模型或用户的页面名称、菜单路径只来自功能目录 `ai-feature-map.json`(测试生成并逐字比对), 路由与权限码不外送、不显示; 缺权限只写中文权限名并以「请联系管理员开通」结尾, 不点名管理员。

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
- **AI 助手检索评测** `AiKnowledgeGoldenQuestionsEvalTest`(不连库、不调模型, 约 5 秒): 76 道员工口吻问题, 按单一部门读者测前 1/3/5 命中与实际下发命中,
  报告写到构建目录的 `ai-knowledge-golden-eval.txt`; 下限等于当前实测值(68/68/68, 无文档问题不发无关内容 ≥3), 改文档让命中变少就红:
  先看报告里这一题的排序, 是文档写法的问题就改文档; 新文档也能答这一题时, 核对后把它加进这一题的期望清单。
- **假模型端到端** `AiChatQuestionHandlingTest`: 换话题、追问、答非所问、工具执行条件、诚实没找到、跨部门页面、系统提示不含身份等作答链路规则。
- **功能目录** `test/shared/ai/ai_feature_map_test.dart`(Flutter): 生成结果与 `server/src/main/resources/ai-feature-map.json` 逐字比对; 改了路由、守卫、工作台卡片、
  中文界面文字或页面说明的 `路由：` / `> 别名：` 行之后, 运行 `UPDATE_AI_FEATURE_MAP=1 flutter test test/shared/ai/ai_feature_map_test.dart` 重新生成并提交。

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

## 八、AI 助手页面上下文、有据作答与确认卡契约(ADR-150 / ADR-152 / ADR-153 / ADR-158 / ADR-159)

> 设计与取舍见 [ADR-150](../99-决策记录-ADR/ADR-150-AI助手页面上下文有据作答与确认后执行.md)、
> [ADR-152 对话设置与连续对话](../99-决策记录-ADR/ADR-152-AI对话设置与连续对话.md) 与
> [ADR-153 范围闸门与平台知识检索](../99-决策记录-ADR/ADR-153-AI助手范围闸门与平台知识检索.md)、
> [ADR-158 AI 文件理解：一次作答与按权限给出去处](../99-决策记录-ADR/ADR-158-AI文件理解一次作答与按权限给出去处.md)、
> [ADR-159 AI 助手有据作答：检索门槛、功能目录与单据进度工具](../99-决策记录-ADR/ADR-159-AI助手有据作答-检索门槛目录与单据进度工具.md)。本章是前后端共同遵守的**请求/响应契约**:
> 前端工程师照本章实现快照登记、确认卡和执行回执; 后端以本章为准做校验。字段名区分大小写, 未列出的字段服务端忽略。

### 8.1 发消息

`POST /api/ai/chat/messages`(需要 `ai:use`), 返回 202 + 任务视图(`jobId`), 再轮询 `GET /api/ai/jobs/{jobId}`。

```json
{
  "message": "不同的状态分别是什么颜色",
  "conversationId": "当前对话 UUID(ADR-152); 省略时服务端新开一个并在结果里返回",
  "locale": "zh | en | ko(界面语言; 回答语言设为「跟随界面」时按它回答), 可省略",
  "intentHint": "PAGE_HELP(只在点「这个页面怎么填写」快捷入口时带, 其它时候省略)",
  "pageContext": {
    "route": "/production/workshop-tasks",
    "fieldKey": "可省略; 已审核页面说明里的字段键",
    "snapshot": { "...": "见 8.2; 页面感知关闭时整个 pageContext 不发" }
  }
}
```

- `message` 1..2000 字, 不能含控制字符(换行/制表除外)。`route` 只能是 `/[A-Za-z0-9/_-]*` 的路径, 不带查询串和 `#`。
  路由只在服务端用于页面权限与页面说明; 发给模型的是页面形状, 含数字或长十六进制的段一律换成 `:id`(`/expense/:id/edit`), 记录 UUID 不外送。
- 内容不读的页面: `/payroll`、`/hr`、`/employee`、`/profile`、`/change-password`、`/admin/permissions`、`/admin/audit-logs`
  及其子路径(工资、人事、员工档案、个人资料、凭证、权限与审计)。前端不采集快照, 对话框写「这个页面含工资或个人信息, 不读取页面内容, 只发送问题」;
  服务端即使收到也直接丢弃(`AiChatPageSnapshot.contentWithheld`)。两边是同一张清单, 改动要一起改并更新本节。
- 旧字段 `attachmentJobId`、`previousJobId` 已删除(服务端忽略); 文件一律走 `ERP_DOCUMENT_ROUTE` 任务(8.7)。
- 账号的对话设置(ADR-152)在提交时由服务端读取并写进任务输入, 客户端不能在请求里带设置; 「读取当前页面」关闭时服务端丢弃
  `pageContext`(即使客户端发了)。
- 整个任务输入(问题 + 快照 + 授权戳)上限 64 KB; 快照本身上限 24 KB(按服务端 JSON 序列化后字节数)。
- 快照只保存在任务的临时输入里, 任务结束即清空(沿用 `ai_jobs.input_bytes` 清理); 结果和审计摘要里都不保存快照。
- 页面受已审核目录保护时(例如车间任务、销售订货), 服务端照旧校验页面权限, 没权限时快照不会被读取: 带 `intentHint=PAGE_HELP`(明确问这个页面怎么填)时 403;
  其它问题(2026-10-06 起, ADR-159)不再 403, 服务端丢弃整个 `pageContext`, 返回 202 照常作答, 页面内容不读、不存、不外送。前端不用改。

### 8.2 页面快照 `snapshot`

快照是「当前顶层页面上你看得见的东西」, 由 `AiPageContextController` 在**发送时**从登记的提供器计算(不在每帧重建)。
所有文本都是不可信数据: 服务端只把它当资料放进模型的不可信段, 绝不当指令。

```json
{
  "version": 1,
  "title": "我的车间任务",
  "tables": [{
    "title": "车间任务",
    "totalRows": 24, "visibleRows": 24, "selectedRows": 0,
    "columns": [{"label": "货品编号"}, {"label": "状态", "info": "按物料齐套和领料进度显示"}, {"label": "成本单价", "sensitive": true}],
    "rows": [{"no": 1, "cells": ["V50001", "可开工", ""], "selected": false, "flagged": false}],
    "legend": [{"column": "状态", "value": "可开工", "color": "绿", "tone": "success", "meaning": "材料齐了, 可以开工", "count": 6}],
    "flaggedCells": [{"rowNo": 3, "rowLabel": "V50003 V5二开右按钮", "column": "单价", "value": "0",
                      "state": "REVIEW", "reason": "标价为0, 要先做报价单交给财务定价"}],
    "truncated": false
  }],
  "fields": [{"label": "客户", "value": "", "state": "REQUIRED_EMPTY", "required": true, "message": "", "info": "选对客户, 核对结账条件"}],
  "badges": [{"label": "待领料", "tone": "danger", "color": "红", "count": 3}],
  "notices": [{"kind": "BANNER", "title": "AI 识别结果", "text": "已按客户文件填入 5 行, 其中 4 行需要核对"}],
  "pageActions": [{"name": "setLineField", "title": "修改明细行", "kind": "FORM", "risk": "LOW", "params": {"...": "见 8.3"}}],
  "focusField": "数量",
  "withheld": ["成本单价"]
}
```

| 部分 | 字段 | 规则(超限一律 422, 不截断) |
| --- | --- | --- |
| 顶层 | `version` | 省略或 1 |
| | `title` | 页面标题, ≤80 字 |
| | `focusField` | 当前焦点字段的标签, ≤40 字 |
| | `withheld` | 前端因敏感未发送数值的列/字段标签, ≤30 个 |
| `tables[]` | 最多 4 张 | 只取顶层当前路由里的表; 一个页面多张表按屏幕顺序 |
| | `title` | ≤80 字 |
| | `totalRows`/`visibleRows`/`selectedRows` | 0..10000000 的整数, 服务端算的总数优先 |
| | `columns[]` | 最多 12 列(可见列, 按屏幕顺序); `label` ≤40 字, `info` 列头说明 ≤200 字, `sensitive` 见下 |
| | `rows[]` | 最多 30 行(屏幕上靠前的行); `no` 为 1 起的屏幕行号(用户说「第3行」就是 3); `cells` 与 `columns` 一一对应, 不得多于列数, 单值 ≤80 字, 用单元格最终**显示文本**; `selected`/`flagged`(标红行) 可选 |
| | `legend[]` | 最多 40 条, 按最终单元格底色 + 状态组件聚合: `column` 列标签, `value` 状态文字(必填), `color` 中文颜色名(≤8 字, 如 灰/蓝/绿/黄/红/品红/紫/青绿/琥珀), `tone` 共享色调名(neutral/info/success/warning/danger/fuchsia/violet/accent), `meaning` 含义(≤120 字, 来自列定义的 legend 或组件说明; 没有就省略, 不要编), `count` 本表该值的行数 |
| | `flaggedCells[]` | 最多 80 条: `rowNo`、`rowLabel`(行的识别文字 ≤80 字, 取该行前两个非空且**非敏感**列, 如「货品编号 品名」; 服务端对样本里的行按清空敏感格后的单元格重算, 样本外的行只在表里没有敏感列时保留)、`column`、`value` 当前显示值、`state` 取 REVIEW(黄框待核对)/REQUIRED_EMPTY(红框必填空)/WARNING/ERROR/FLAGGED(整行标红, 无列)、`reason` 原因 ≤200 字(例如销售识别的 aiReview/warnings 文案); 敏感列的 `value` 与 `reason` 都不发 |
| `fields[]` | 最多 60 个 | 输入组件(UtenInput/UtenDropdownField/UtenDateField/选择器/工具栏筛选字段): `label`(必填 ≤40 字)、`value` 显示值 ≤80 字、`state` 取 NORMAL/REQUIRED_EMPTY/AUTOFILLED(黄框预填)/WARNING/ERROR、`required`、`message` 黄框/错误提示 ≤200 字、`info` ⓘ 说明 ≤200 字。只读信息行(UtenInfoRow)不登记。**密码/obscure 字段与凭证类标签一律不登记**; 敏感字段只发 `label`、`state`、`required` 与 `sensitive: true` |
| `badges[]` | 最多 30 个 | 状态胶囊、分段徽章、模块红黄徽章: `label`(≤40 字, 前端按同口径截断, 空标签/编号/网址整条不发)、`tone`(只认 8 个共享色调名, 其它不发)、`color`(≤8 字)、`count` |
| `notices[]` | 最多 10 条 | `kind` 取 BANNER(顶部横幅)/INLINE(行内提示)/DIALOG(当前弹窗正文); `title` ≤80 字, `text` 必填 ≤600 字(可含换行) |
| `pageActions[]` | 最多 16 个 | 见 8.3 |

服务端校验与清理(前端不要依赖, 但要知道):

- 标签(列名、字段名、颜色名、动作标题、参数标题)不能是 UUID 或网址, 不能含控制字符, 否则 422。
- 值里出现的 UUID 换成 `[编号]`, 网址换成 `[链接]`; Unicode 格式控制字符(如方向覆盖)被删除。
- **敏感数值默认不发送**: 页面作者对成本、工资、信用额度、个人信息等列/字段写 `aiSensitive: true`(MasterColumnDef / EditableGridColumn / 输入组件);
  前端与服务端还按同一张标签词表兜底(`aiSensitiveLabel` / `AiChatPageSnapshot.SENSITIVE_LABEL`):
  成本/毛利/利润、工资/薪/奖金/年终奖/提成/佣金/社保/公积金/应发/实发/扣减/扣款/扣除合计/个税/所得税/加班费/津贴/补贴/绩效、
  信用额度/信用余额/授信、身份证/证件号/护照/银行卡/银行账号/开户账号/卡号/手机/电话/联系方式/邮箱/住址/户籍, 以及对应英文。
  命中的列: 单元格留空、列说明不发、图例不发、待核对的值与原因不发、标签写进 `withheld`; 命中的字段: 只发标签与状态, 值、`message`、`info` 都不发。
  词表管不到的通用标签(例如成本报表里的「单价」「金额」)必须由页面写 `aiSensitive: true`。
- **凭证整条不发**: 标签像密码/口令/验证码/校验码/动态码/密钥/私钥/令牌/password/secret/api key/access token 的字段整条丢弃, 列的值按敏感处理。
- 清理是幂等的: 清理结果再清理一次不变(`withheld` 输出封顶 30 个)。
- 快照为空(没有表、字段、徽章、提示、动作且没有标题)时按「没带快照」处理。

### 8.3 页面动作描述符 `pageActions[]`

AI 能提出的操作**只来自当前页面登记的闭合动作集**; 模型提出不在集合里的名字一律回「这个页面没有登记这项操作」。

```json
{
  "name": "setLineField",
  "title": "修改明细行",
  "kind": "FORM",
  "risk": "LOW",
  "params": {
    "type": "object", "additionalProperties": false,
    "properties": {
      "row":   {"type": "integer", "title": "行号", "minimum": 1, "maximum": 500},
      "field": {"type": "string",  "title": "字段", "enum": ["数量", "单价"]},
      "value": {"type": "string",  "title": "新值", "maxLength": 40}
    },
    "required": ["row", "field", "value"]
  }
}
```

| 字段 | 规则 |
| --- | --- |
| `name` | `[a-z][A-Za-z0-9_]{1,47}`, 页面内唯一; 就是前端执行时查表用的 handler 名 |
| `title` | 卡片上的操作名, ≤40 字 |
| `kind` | VIEW(筛选/搜索/勾选/打开行, 只改显示)、FORM(只改本页输入并标黄)、SAVE(按页面保存按钮保存草稿)、SUBMIT(按页面提交按钮提交) |
| `risk` | 可省略; 服务端按 kind 定下限: VIEW/FORM=LOW, SAVE=MEDIUM, SUBMIT=HIGH, 页面只能调高 |
| `params` | 封闭对象: 最多 6 个参数、可选参数最多 3 个; 参数类型只允许 string/integer/number/boolean; 每个参数必须有 `title`(≤20 字, 卡片上显示); string 的 `maxLength` 1..200(默认 80); 可选 `enum`(≤60 项)、`minimum`/`maximum`、`description`(≤120 字)。参数名 `row`/`rowNo` 为整数时, 卡片会附上该行的识别文字(只从 `table` 那张表取; 没写 `table` 且多张表都有这一行就不附) |
| `table` | 可选; 行参数数的是快照里第几张表(1 起)。前端按动作的 `rowTable` 自动填 |

**只有用户要求才出卡(确定性闸门)**: 模型选了 ACTION 后, 服务端还要看用户自己的原话是否要求了该类操作:
VIEW 要有筛选/过滤/只看/搜索/勾选/打开等, FORM 要有改/设为/填/录入/换成/确认/标记等, SAVE 要有保存, SUBMIT 要有提交/送审;
只是提问(含「什么/哪些/吗/是否」且没有「帮我/请/把」)不算。闸门不通过就不出卡, 按页面内容确定性作答。
准备授权卡的工具同理: 只在超管原话是授权请求时运行(`AiChatToolPort.requestedBy`)。页面里的提示、弹窗、单元格、客户文件写了什么都不算用户要求。

**卡片绑定提问时的页面实例与行(前端)**: 每次发问, `AiPageContextController.capture` 同时生成「绑定」: 当前页面实例(导航器 overlay 条目 + 页面级 `AiPageInfoSource` 登记)
与行动作所属表在那一刻的记录身份。确认后 `AiPageContextController.run` 只在同一页面实例上执行; 行参数(`AiActionParam(rowRef: true)`, 动作写 `rowTable`)
必须仍指向提问时那条记录(删除/插入/排序/筛选后行变了就拒绝, 提示「第N行已经不是提问时那一行了」), handler 通过 `AiActionCall.row/rows` 直接拿到记录,
不要再按下标去取行。表格提供 `AiTableSource(owner, records, recordKey)`: MasterDataTableView 的 owner 是它自己、记录身份按 `idOf`; UtenEditableGrid 的 owner 是它的 controller、记录身份是行对象。

第一批登记(由前端步骤实现): MasterDataTableView 通用(筛选/搜索/勾选/打开行)、通用输入组件(按标签设值)、销售订货/报价编辑页(改行字段、确认待核对行、保存草稿)。

### 8.4 回答结果(`GET /api/ai/jobs/{id}` 的 `result`)

| 字段 | 说明 |
| --- | --- |
| `reply` | 给人看的回答(纯文本, 有换行与「1. 」编号, 无链接/HTML)。先直接回答再分条给依据; 颜色问题每条「颜色 = 状态 = 含义 (N 行)」; 待检查问题每条「第N行 行标识 / 列: 当前值; 原因; 建议」; 超过 12 条写「还有 N 项」 |
| `intent` | PAGE_STATE / PAGE_HELP / KNOWLEDGE / TOOL / ACTION / CLARIFY / UNSUPPORTED / OUT_OF_SCOPE / NON_WORK / SMALL_TALK / AI_UNAVAILABLE |
| `mode` | 确定性渲染用的呈现方式: OVERVIEW / SUMMARY / EXAMPLE / STEPS |
| `detail` | 这一句实际用的详略档 COMPREHENSIVE / STANDARD / CONCISE: 账号设置为默认, 用户这句话里明说「简单点/详细点/展开说」时只对这一句改档 |
| `conversationId` | 这一轮所属对话(ADR-152); 前端用它继续同一对话 |
| `pageTitle` | 提问时所在页面的标题(快照标题或页面说明标题, ≤80 字), 恢复对话时显示用 |
| `sources` | `[{"id","label"}]` 回答依据, 如 `{"id":"page.legend","label":"当前页面状态颜色"}`、`guide.sales_order`、`knowledge.UI_CONVENTIONS`、`tool.inventory_lookup`、平台设计文档片段 `knowledge.doc-<12 位十六进制>`(label「平台说明: 文档标题 / 章节」, ADR-153); 前端可显示为「依据: 当前页面状态颜色」 |
| `fallback` | true 表示模型没用上(不可用、失败或回答没通过事实守卫), 这是服务端按页面内容的确定性整理; 前端可加一行小字「AI 暂时没回上来, 以下按页面内容整理」 |
| `replyShareable` | 服务端内部用于对话记忆(这一轮回答能否带进后续轮次; 敏感工具结果为 false, 后续只带问题), 前端忽略 |
| `actions` | 确认卡列表(8.5); 每次读取都按数据库刷新状态, 已删除/别人的提案不会出现 |
| `question` / `knowledgeId` / `helpContext` / `queryContext` | 同 ADR-140, 供追问与历史展示 |

### 8.5 确认卡(`actions[]` 元素)

```json
{
  "type": "CONFIRM_ACTION",
  "proposalId": "39a3c832-b0e5-4fe2-8040-7cb4247741b9",
  "actionType": "PAGE_ACTION",
  "handler": "setLineField",
  "execution": "CLIENT",
  "title": "修改明细行",
  "summaryLines": ["页面: 新建销售订货单", "操作: 修改明细行", "行号: 3 (V50003 V5二开右按钮)", "字段: 数量", "新值: 100",
                   "只改本页输入，改动处会标黄「AI 填入，请核对」；保存仍由你点保存。"],
  "risk": "LOW",
  "riskNote": "MEDIUM/HIGH 时才有",
  "requiresStepUp": false,
  "route": "/sales/orders/new",
  "args": {"row": 3, "field": "数量", "value": "100"},
  "issuedAt": "2026-10-04T22:29:10Z",
  "expiresAt": "2026-10-04T22:39:10Z",
  "status": "PROPOSED",
  "outcome": "SUCCEEDED(有回执后才有)",
  "outcomeMessage": "可选"
}
```

| 字段 | 说明 |
| --- | --- |
| `actionType` | PAGE_ACTION(页面登记的动作) / OPEN_GUIDED_FORM(文件识别后打开表单, 一个文件最多一张, 8.7) / PERMISSION_GRANT(超管单项授权) |
| `execution` | CLIENT: 确认后由前端调用页面登记的 handler(与页面按钮同一代码路径); SERVER: 确认即调用对应业务端点, 由服务端执行 |
| `summaryLines` | **服务端渲染**的卡片正文(1..16 行), 模型文字不会出现在这里; 前端逐行原样显示 |
| `risk` / `riskNote` | LOW/MEDIUM/HIGH; MEDIUM/HIGH 时卡片显示风险提示 |
| `requiresStepUp` | 只有 SERVER 动作可能为 true: 确认前弹出「输入登录密码」, 拿到再认证凭证后再调用端点 |
| `route` | CLIENT 动作所属页面; 前端执行前必须确认当前顶层页面就是它, 否则卡片显示「请回到原页面再确认」 |
| `args` | 只有 CLIENT 动作有; 仅供展示, **执行一律用确认接口返回的 args** |
| `status` | 有效状态: PROPOSED(可确认) / CONFIRMED / CANCELLED / EXPIRED / FAILED; 已过 `expiresAt` 或身份变化的 PROPOSED 在读取时直接显示 EXPIRED 或 CANCELLED(outcome=AUTH_CHANGED) |
| `outcome` | SUCCEEDED / FAILED(执行回执) / AUTH_CHANGED(身份变化作废) |

卡片 UI 要求: 标题、逐行摘要、风险提示、「确认」「取消」按钮、到期倒计时(过期后按钮变灰并提示重新提问)、执行中状态、
成功/失败回执; 确认按钮防重复点击(`ClickGuard`/`UtenActionButton`); 账号/权限/服务器地址变化时清空会话(沿用 ADR-140)。

### 8.6 确认卡端点

| 端点 | 用途 | 成功 | 失败 |
| --- | --- | --- | --- |
| `GET /api/ai/chat/actions/{id}` | 查当前状态(网络结果不明时用它判断, 不要重放确认; 只在需要时读, 不要轮询: 每次成功读取记一条「查看 AI 操作确认卡」详情查看审计 `view_ai_chat_action_proposal_detail`) | 200 卡片 | 404 不存在或不是本人的(不记查看审计) |
| `POST /api/ai/chat/actions/{id}/confirm` | CLIENT 动作一次性核销 | 200 卡片(`status=CONFIRMED`) + 权威 `args` | 404; 409 + `errorCode`: `AI_ACTION_HANDLED`(已确认/已取消/已过期处理过, 包括并发双击的第二次)、`AI_ACTION_EXPIRED`、`AI_ACTION_AUTH_CHANGED`(账号授权版本、全局授权纪元或部门变化)、`AI_ACTION_SERVER_ONLY`(SERVER 动作走专用端点) |
| `POST /api/ai/chat/actions/{id}/cancel` | 取消未确认的卡; 重复取消无害 | 200 卡片(`CANCELLED`, 已处理过的返回当前状态) | 404 |
| `POST /api/ai/chat/actions/{id}/receipt` body `{"outcome":"SUCCEEDED"或"FAILED","message":"≤500 字, 可省略"}` | CLIENT 动作执行回执, 只记一次(相同结果重复提交无害) | 200 卡片(含 outcome) | 404; 409 `AI_ACTION_NOT_CONFIRMED`(没确认或已记过不同结果); 422 |
| `POST /api/ai/chat/permission-grants/confirm` body `{"proposalId":"uuid"}` + 请求头 `X-Uten-Step-Up` | PERMISSION_GRANT(超管, `ai:use` + `authorization:manage`) | 200 `{"status":"GRANTED"或"ALREADY_GRANTED","reply"}` | 403 REAUTH_REQUIRED(没有/过期的再认证凭证); 404; 409(已用过/过期/身份或授权对象变化; 业务拒绝后该卡记为 FAILED, 不能盲目重试) |

确认需要 `ai:use`(现有聊天权限), 不新增 `ai:act`; 执行时由页面 handler 或业务端点原有的权限、再认证、版本与状态校验决定能不能做成。
每次提议/确认/取消/回执/作废都写审计日志(`ai_action.propose/confirm/cancel/receipt/void/failed`), 提案行本身保存 10 分钟有效期内的状态,
清理任务把过期未确认的标为 EXPIRED, 超过任务留存天数的行删除(审计日志永久保留)。

### 8.7 前端执行顺序(CLIENT 动作)

1. 用户点「确认」→ 本地检查: 当前顶层路由 == `route`、`expiresAt` 未到、页面仍登记了 `handler`; 不满足就提示并不调用接口。
2. `POST .../confirm` → 拿到 200 的 `args`(权威参数); 409/404 按 `errorCode` 显示原因并把卡片置灰。
3. 用页面登记表里写死的映射找到 handler 执行(与页面按钮同一代码路径)。FORM 动作只改本页输入, 改动处标黄「AI 填入, 请核对」
   (`setAutomaticText` / `applyAutofillHint` 一类既有机制); SAVE/SUBMIT 动作调用页面自己的保存/提交方法, 服务端校验照旧。
4. `POST .../receipt`, 成功写 SUCCEEDED, 执行抛错写 FAILED + 一句原因; 回执请求失败不重放确认, 改用 `GET` 核对状态。
5. SERVER 动作(授权卡): 先走再认证弹窗拿 `X-Uten-Step-Up`, 再调用专用端点; 用户关闭密码弹窗视为没确认。

**文件识别(`ERP_DOCUMENT_ROUTE`, ADR-158)**: 一个文件一个回答, **最多 1 张确认卡**, 且只能是 `OPEN_GUIDED_FORM`。任务结果不意味着「正在打开」, 前端**不得**识别完自动跳页。

提交: `POST /api/ai/jobs?kind=ERP_DOCUMENT_ROUTE`, 参数只有 `message`(用户原话, ≤512 字)、`pageRoute`(提问时的页面)、可选 `workflow`
(用户点的选项: `SALES_ORDER` / `SALES_QUOTE` / `EXPENSE_CLAIM`)。任何能用对话的员工都可上传(`capabilities.canUploadDocument` 恒为 true);
`workflow` 在提交、后台处理和每次读取时都校验, 必须是本人当前可用的单据, 否则 403「当前账号没有这项业务的填写权限」。

读取结果(`filterResultForReader` 之后):

| 字段 | 说明 |
| --- | --- |
| `documentType` | 文件类型, 如 `EMPLOYEE_ROSTER`、`PAYROLL`、`ATTENDANCE`、`GOODS_LIST`、`BOM_LIST`、`CUSTOMER_LIST`、`SUPPLIER_LIST`、`STOCK_LIST`、`BANK_STATEMENT`、`INVOICE`、`SALES_ORDER`、`SALES_QUOTATION`、`SALES_TABLE`、`COMMERCIAL_INVOICE`、`MIXED_DOCUMENT`、`UNKNOWN` 等(完整清单与识别依据见 ADR-158 §3.4) |
| `typeSource` | `RULES`(本地规则按标题/表头认出) / `AI`(规则认不出, 模型按结构推测; 不会因此出卡) / `NONE`(认不出) |
| `intent` | `RECONCILE` / `IMPORT` / `FILL` / `ANALYZE` / `QUESTION` / `NONE`, 只看用户自己的话(点了选项即 `FILL`) |
| `workflow` | 选中的单据; `NONE` 表示没有选中 |
| `title` | 类型的中文叫法 |
| `summary` | 给人看的回答(纯文本, 一句一行, ≤1200 字): 是什么、凭什么看出来、你想做什么、能做/做不到什么、去哪里; 不含任何数据行的值 |
| `needsChoice` | true 时没有卡, 用户要从 `choices` 里选 |
| `choices` | `[{workflow, title}]` 这份文件能填、而且读者当前有权限填的单据; 前端显示为选项 |
| `pages` | `[{key, title, route}]` 可去的页面, 来自服务端固定目录 `AiDocumentDestinations`, 读者持有该页**全部**权限才给 |
| `blocked` | `[{title, reason}]` 读者做不了的事项与中文原因(缺什么权限或系统做不到), 不出现权限码; 只显示 |
| `profile` | `{sheets: [{name, dataRows, columns}]}` 表格结构: 最多 8 张表 × 40 列, 列名 ≤24 字, 连续 3 位以上的数字与邮箱已换成 #, 不含数据行的值; 只在对话里用, 不进表单草稿 |
| `steps` / `fields` / `fieldConfidence` / `requiresReview` / `missingFields` / `source` | 同原契约(发票字段只在选中报销申请且有权限时才有) |
| `actions` | 最多 1 张 `OPEN_GUIDED_FORM`, `args = {"workflow": "...", "sourceJobId": "<本识别任务 id>"}` |

- 什么时候出卡: 只有用途明确、本人能填、文件可靠(不是多张发票、不是多种业务混杂、没被截断、用户没说只分析)时才出 1 张; 否则 0 张。文件类型与所选单据明显不符时回答「文件与要做的单据不一致」, 不出卡。
- 每次读取都按读者**当前**权限重算 `summary`、`choices`、`pages`、`blocked` 与卡片(只保留绑定了读者仍可用单据的卡); 识别规则版本 v3 之前保存的结果读取时 403「文件识别方式已更新，请重新上传。」。
- 前端选项(chip): 只在 `needsChoice` 为 true 时、只列本账号能填的单据; 点一个就把**同一个文件**连同原话、原页面与 `workflow=<所选>` 再提交一次(用户侧显示「选择：…」), 新回答最多 1 张卡; 每个回答只能选一次。
- 前端页面按钮: 跳转前再过 `safeAiChatPath` 与路由守卫同一份判断 `locationAllowedFor`, 通过才 `go` 并收起对话框; `blocked` 以灰字「事项：原因」显示; `typeSource=AI` 时加一行「文件用途是 AI 只看表头和格式判断的(具体内容没有发给 AI), 请核对」。
- 确认卡执行: `confirm` 一次性核销 → `push` 对应新建页(不等待返回) → 等一帧取栈顶路由 → 是该表单才收起对话框并回执 SUCCEEDED; 否则回执 FAILED, 对话框保持打开, 卡上写原因(被路由守卫转到无权限页 / 没打开)。
  外壳判断主 Tab 与业务子页按栈顶叶子路由 `uri.path`(App 外壳), 所以从工作台等主 Tab push 的表单也能显示。

### 8.8 服务端接入点

- **页面类问题一次调用**: 模型同时选路和作答, 输出 `{intent, reply, usedSources, tool, arguments, action}`
  (`AiChatAnswerContract`, 用途码 `ERP_CHAT_ANSWER`)。服务端发的来源有: 页面快照(不可信段)、已审核页面说明、知识(含 `UI_CONVENTIONS`
  平台界面约定)、工具描述、对话记忆(ADR-152, 单独的 `CONVERSATION HISTORY` 段, 来源 id `conversation.history`, 见 8.10)。
- **工具类问题**: 先执行工具, 若工具实现了 `AiChatToolPort.modelFacts(result)`(默认空, 成本/信用/授权/人事类保持空)再调一次模型按事实作答,
  否则直接用工具自己的 `reply`。新增工具时在 `modelFacts` 里只放已授权、可外送的事实, 并登记到《中国大陆部署与兼容性》2.3.1。
  模型选了工具后, 还要用户这句话本身在问这个工具答的事才执行(`AiChatDialogueSupport.toolEligible`, 见 8.12)。
- **事实守卫 `AiChatAnswerGuard`**: 回答里的数字、业务编码必须出现在来源或用户原话里; 「颜色 = 状态 = 含义」行的颜色和状态必须是页面原词;
  禁止「我已保存/已为你提交」这类完成断言(页面上本来就显示的状态词除外); 只在对话记忆里出现的数字/编码, 所在的**那一行**(列表项看它的
  引导行)必须带记忆标记(「刚才说的/之前查到的/前面列出的/上一页的/earlier/as mentioned」等), 否则 `MEMORY_AS_FACT`; 「发货之前」
  「在此之前」「before」这类时间说法不算标记, 别的行提到过去对话也不算; 一行里用「；」连写的多对「颜色 = 状态」逐对检查; 去掉链接与 HTML; 限 4000 字(全面档 6000)。
  不通过时记一行 `AI chat reply replaced by deterministic answer: intent=…, problems=[…]`(只有问题类别), 然后用
  `AiChatPageStateRenderer` 按快照确定性整理(图例、待核对清单、字段状态), AI 不可用时同样如此。
- **动作提案**: 业务 feature 用 `application.port.AiChatActionProposalPort.propose(Draft)` 发卡(自带短事务, 可在只读事务里调用),
  SERVER 动作在业务事务里 `consumeServerAction` 一次性核销、成功后 `completeServerAction`, 业务拒绝时控制器调用 `failServerAction`。
- **文件识别**(ADR-158): `AiDocumentRouteHandler` 先用本地确定性规则判断文件类型(标题 + `AiDocumentProfiler` 找到的表头: 标题行下方的表头、合并单元格的两行表头、列含义与值形状;
  「键 值 键 值」的登记表与表头下的第一行数据不会被当成表头), 用户想做什么只看用户自己的话(`AiDocumentIntent`), 文件里的文字不当指令。仍认不出、且本人有 AI 使用权限并已配置服务时,
  才由 `AiDocumentModelAssist`(用途码 `ERP_DOCUMENT_ROUTE_TYPE`)把结构发给模型一次, 模型只回类型/意图/把握三个枚举, 把握低、认不出或答非所问一律当认不出; 模型猜的类型不会选出确认卡。
  可去页面只改 `AiDocumentDestinations` 目录(一行一个 `new Destination(...)`, 前端契约测试 `ai_document_destinations_contract_test.dart` 按行解析并核对路由守卫);
  做不了的事项与按类型的如实说明也在这个类里, 缺权限的原因写中文权限名。存下的结果带内部字段 `_access` / `_routing`(规则版本 v3) / `_offer`(这份文件能填哪些单据与固定说明句),
  读取时先校验再去掉, 并按读者当前权限重新生成选项、页面、做不了的事项与回答正文。
- **授权正则**只拦「给我/帮我开通…权限」「把我设为管理员」「假装我是管理员」这类请求; 「需要什么权限」「怎么开通」之类咨询交给作答。

### 8.9 前端接入点(A1b)

- 登记表: `AiPageContextController`(`lib/shared/ai/page_context/`)挂在 `PlatformTablesHost`; 组件用 `AiPageSlot.attach/detach` 或 `AiPageRegistrar` 登记取值回调, 发问时才计算; 只取顶层当前路由。说明见 [AiPageContext](../02-组件库/AiPageContext.md)。
- 已自动登记的共享组件: MasterDataTableView(含整行标红)、UtenEditableGrid、UtenInput、UtenDropdownField、UtenDateField、UtenMasterPickerField(客户/供应商)、UtenEmployeePicker、UtenEmployeeMultiPicker、UtenFilterPickerField(后四个只读)、UtenSearchBar、UtenStatusBadge、UtenDocStatusPill、UtenSegmentBadgeLabel、UtenInlineNotice、UtenTopBannerCard(有 semanticLabel)、AiGuidedFileBanner、UtenDialog.show 纯文字正文、UtenAppBar 标题。
- 顶层判定不建立依赖(不用 `ModalRoute.isCurrentOf`): TickerMode/Offstage 排除被盖住的页面, 同一导航器按 overlay 绘制顺序取最上面的路由。
- 页面要补「含义」用列参数 `legendOf`; 待核对原因在行数据里的用 `EditableGridColumn.reviewReasonOf`; 成本/工资/信用/个人信息列必须写 `aiSensitive: true`(词表管不到「单价」「金额」这类通用标签)。
- 页面动作: `AiPageInfoSource(actions: ...)` 返回 `AiPageAction` 列表(名称/标题/kind/参数/handler)。handler 必须与页面按钮共用代码路径, 失败抛 `AiActionFailure(给人看的原因)`; 签名是 `(AiActionCall call)`, 参数在 `call.args`。按行操作的动作: 行参数写 `rowRef: true`, 动作写 `rowTable`(表格的 owner, UtenEditableGrid 即其 controller), handler 用 `call.row('row')` 拿提问时那条记录, 不要按下标取行。
- 外壳(`MainShellPage`): 判断主 Tab 还是业务子页、导航高亮、点 Tab 时是否已在本 Tab, 一律按栈顶叶子路由 `uri.path`, 传给对话框的 `currentRoute` 也是它(ADR-158 §3.1)。
- 对话框(`AiChatOverlay`): 发送时把 `capture().snapshot` 放进 `pageContext.snapshot`, 把 `capture().binding` 记在这条消息上; 卡片用 `AiChatActionCard`; 确认后由 `AiPageContextController.run(l10n, binding, handler, args)` 执行(同一页面实例、参数再校验、行绑定核对); 网络结果不明只 `GET` 查状态, 不重放确认。在对话设置里关掉「读取当前页面」后, 之前消息存的快照与绑定丢弃, 重试只发问题。

### 8.10 对话设置与连续对话(ADR-152)

- `GET /api/ai/chat/capabilities` 增加 `settings`(下表)与 `reasoningEffortSupported`(当前默认服务商能否调整思考程度)。
- `PATCH /api/ai/chat/settings`(需要 `ai:use`): body 是含一个或几个字段的对象, 未知字段、错误类型或不在白名单的值整体 422;
  返回 `{settings, reasoningEffortSupported}`。存放在 `user_preferences` 的功能自管键 `ai.chat.settings`, 通用接口
  `PUT /api/user/preferences/{key}` 对 `ai.` 开头的键返回 422。

  | 字段 | 取值(默认) |
  | --- | --- |
  | `detail` | COMPREHENSIVE / **STANDARD** / CONCISE |
  | `reasoning` | FAST / **STANDARD** / DEEP(→ `AiReasoningEffort` OFF / MEDIUM / HIGH) |
  | `pageAware` | **true** / false |
  | `showSources` | **true** / false(只影响前端显示, 事实守卫照做) |
  | `memoryTurns` | 0 / 3 / **6** / 10 |
  | `replyLanguage` | **AUTO** / ZH / EN / KO |
  | `sendKey` | **ENTER** / CTRL_ENTER(纯前端) |
  | `explanationStyle` | **PLAIN** / PROFESSIONAL |
  | `showSuggestions` | **true** / false(纯前端) |

- `GET /api/ai/chat/conversations/current?conversationId=`(可省略, 省略取最近一次): 返回
  `{conversationId, turns:[{jobId, createdAt, result}], hiddenTurns}`, 最多 20 轮、旧的在前; 每轮的 `result` 与 `GET /api/ai/jobs/{id}`
  同样经读者过滤(身份戳、域、工具、页面、知识复核, 确认卡按库刷新); 身份或访问不通过的只计入 `hiddenTurns`。只查本人(`submitted_by_user`)。
  工具回答引用的业务数据已经变化(工具的 `authorizeResultRead` 复核不再认可)不算权限变化: 这一轮只返回问题和 `dataChanged: true`,
  没有 `reply`/来源/卡片。前端在**第一次打开对话框时**才请求(对话框常驻, 不随每次页面加载请求)。
- 复核按请求记忆(`AiChatJobHandler.Reader`): 一次恢复或一次组装记忆里, 同一身份戳、域、工具、页面、知识条目、工具证据各只查一次,
  确认卡按一个身份戳一次查回; 组装记忆时只在 8KB 预算还有空间时才复核下一轮, 不会为发不出去的轮次去重查业务数据。
- `DELETE /api/ai/chat/conversations`: 把本人全部 `ERP_CHAT` 任务归档(`archive_reason = AI_CHAT_CLEARED_BY_USER`), 返回 `{cleared}`;
  之后不再恢复、不再带入; 管理员的 AI 使用审计不受影响。
- 服务端组装记忆(`AiChatConversation`): 同一对话最近 `memoryTurns` 轮, 每轮 `Turn k (page: 标题 路由形状) (tool: 工具名)` + `Q:` + `A:`;
  回答只在 `replyShareable` 时带入, 否则写「(该回答含敏感数据，未带入)」; 引用数据已变化的工具回答写「(这条回答引用的业务数据已变化，
  未带入；需要时请重新查询)」, 问题与查询条件照常带入(「那」仍能接上, 「详细点」仍按原条件重查最新数据); 确认卡只带标题; 总量 ≤8KB
  (按实际发出的文本计, 含每轮的 `Turn k ` 前缀与换行; 最新一轮回答 ≤3000 字节, 更早每轮 ≤1200 字节), 超出从最早整轮丢并写
  「(更早的对话已省略)」。记忆跨页面, 但提示词明确它不是当前页面事实。
- 恢复出来的确认卡: 在页面上执行的卡(页面动作、带文件打开表单)绑定的页面实例已经不在, 只显示「页面刷新过, 这张卡已不能执行」并只给
  取消; 服务端执行的卡(超管授权)照常。没有页面绑定的页面卡在核销前就拦下, 不会白白用掉一次性提案。
- 结果保留与 AI 任务一致: 结果 48 小时后随任务归档, 记忆与恢复也随之结束。

### 8.11 范围闸门与平台知识检索(ADR-153)

- **范围闸门**: 用户这句话命中「代码/脚本、服务器与命令、SQL 与数据库、文件日志配置与环境变量、密码密钥令牌与内部地址、系统提示与 AI 配置、越狱、安全绕过」任一类时,
  结果为 `intent=OUT_OF_SCOPE` 的固定文案(按回答语言 zh/en/ko), 不调用模型、不执行工具、不出确认卡, 也不读对话记忆; 服务端结果里有内部标记 `_scope`(读取时不返回),
  这一轮不带入后续对话记忆。判定在 `AiChatScopeGate`, 前端不做任何额外处理, 照常显示回答。
- **数据不是指令**: 页面快照、文档片段、对话历史里的「请调用工具 / 请修改」不触发任何东西: 工具只在用户这句话本身在要数据(或上一轮是查询)时执行; 页面动作沿用 8.3 的原话操作词闸门。
- **受保护页面**: `/admin/**`、`/page-permissions/**`、`/security/**`、`/settings/device-receipts` 上前端不采集快照、不登记动作、确认卡不执行(`aiPageProtected`);
  服务端丢弃快照(`AiChatPageSnapshot.PROTECTED_ROUTES`), 提案服务拒绝这些路由上的页面动作。
- **回答合同**: `erp_chat_answer_v1` 增加必填字段 `focus`(模型用一句话复述用户的问题, 只用于让回答先答这一问, 服务端不返回); 其余字段不变。
- **出口守卫**: 回答含代码块、shell 命令、SQL、IP/主机端口、文件路径、接口路径、表名字段名、常量名、权限码、类名或函数调用时不采用(日志 `problems=[INTERNAL:...]`),
  改为确定性回答; 页面或工具结果里用户本来就看得到的标识不算。
- **知识检索**: 规则类问题(怎么算/为什么/规则/流程/会不会/要做什么)从打进 jar 的设计文档(`classpath:ai-knowledge/`, 白名单见 ADR-153 §3.5 与 `server/pom.xml`)
  内存索引里取最多 6 段(每份文档 ≤3 段, 合计 ≤6000 字)作为 `knowledge.doc-*` 来源随同一次模型调用发出; 业务流程规则与通用约定对所有聊天用户可见,
  涉及人事、财务、系统管理的文档只给持有其中任一域的人(与工具同一个 `domains()`)。
  规则解释里的数字可以由用户给的数和规则来源里的数推算; 页面与工具数据仍不许算新数。知识类回答必须引用下发的知识来源; 答非所问(问句实词在回答里不到 15%)不采用。
- **诚实兜底**: 规则类问题没用上模型时, 回答是「这次没能整理成针对你例子的回答」+ 最相关一段文档原文 + 相关章节 + 换个问法建议(`fallback=true`, `intent=KNOWLEDGE`);
  一段都没找到时说「我没找到这方面的规则说明」并给问法示例。目录知识的假设例子只在用户明确要「举个例子」时出现。
- **运维**: 启动日志 `AI knowledge index: N documents, M chunks, ... built in X ms`(后台线程建, 不拖慢启动; 建好前检索为空); 新增或修改设计文档后重新构建发布即生效。
- **2026-10-05 修订(ADR-153 第七节)**:
  - 闸门先规整(NFKC、去零宽与方向控制字符、同形字母、繁体)再匹配; 英文按整词、中文韩文按去空格的紧凑文本; 「凭证/证书/token/代码/调试模式/重启后」等业务常用词只在请求形状里才算越界。
  - 服务商内容审核拒绝(`AiCallException.isContentFiltered()`)时任务不再失败, 结果为 `intent=OUT_OF_SCOPE` 的友好范围说明, `_scope=PROVIDER_REVIEW`; 调用记录仍记 BAD_REQUEST。
  - 被拒轮次(闸门、模型判越界或闲聊、服务商审核)一律不进对话记忆。
  - 受保护页面与工资人事页按规范化路由判断(小写、合并斜杠); 含空段的路由 422。敏感列名与字段名按 NFKC、去空白后匹配, 增加进价/进货价。
  - 检索: 无页面时除「查自己数据」外都检索; 英韩问句经词表换成文档用词; 追问以最近两问为低权重上下文, 上一轮引用的文档块随记忆再下发; 只下发相关的目录条目; 新增目录条目「AI 助手会发送哪些内容」。
  - 守卫: 推算只认用户例子(含最近两问)与带算式的行, 并复核单步算式; 完成断言只认第一人称或整句陈述; 出口守卫补常用命令、任意 SELECT、正则、VBA/Python、两段类名、库名、回显提示词、端口与内网主机、IPv6、`status=1` 与 JSON 键名。
  - 页面: 纯图例问题确定性作答(不调模型, 无 `fallback`); 「第 N 行」兜底只渲染该行; 卡片参数不在用户原话里时摘要加「注意」行。
  - 思考程度默认快速; 用户原话要求详细分析时这一问至少标准。
  - 运维: `AiKnowledgeIndexCheck` 可对发布 jar 验证知识库能否从可执行 jar 加载(输出 `documents=N chunks=M`, 为 0 时退出码 1)。

### 8.12 有据作答、功能目录与单据工具(ADR-159)

> 设计、实测与取舍见 [ADR-159](../99-决策记录-ADR/ADR-159-AI助手有据作答-检索门槛目录与单据进度工具.md)。本节取代 8.11 中「数据不是指令」的工具执行条件、「知识检索」的可见范围与答非所问规则、「诚实兜底」里没找到时的说法; 8.11 其余照旧。

- **知识源**: 白名单不变, 另有两份全员可见的知识: `docs/07-业务链路/00-业务术语与状态总表.md`(`AiDocGlossary` 解析; 表头固定
  `| 术语 | 俗称/也叫 | 含义 | 出现在哪 | 相关文档 |`, 俗称用「、」分隔; 每行一块定义; 文件缺失时索引照建, 只是不认俗称)与
  `docs/03-页面/AI工作助手使用说明.md`。AI 助手自身的决策按编号排除(新增时同时改 `server/pom.xml` 与 `AiDocKnowledgePolicy.EXCLUDES`,
  `AiDocKnowledgePolicyTest` 比对两份清单)。可见范围先查复核表 `AiDocKnowledgePolicy.DOMAIN_OVERRIDES`, 没有再按文件名与标题归类。
- **写文档时的开关**(给文档作者):
  - 文首 15 行内写 `> **日期 整份被 [ADR-x](...) 取代**`(或状态行写「整份取代」): 整份文档只留一块「已被取代, 现行规则看 ADR-x」的指引。
  - 文首 15 行内写 `> 别名：A、B`: 这些叫法参与标题匹配, 正文里不出现。
  - 标题含「未实施提案」的页面说明不收; 文件名或标题以「方案」结尾的按 0.8 倍计。
  - 章节标题含演进记录、历史实现、仅兼容、不作当前、设计与证据快照、事件目录等的整节不收; 标题括号里的端口号、克隆库、UAT/E2E 会被删掉。
  - 页面说明的 `路由：` 行必须核对过真能打开这个页面: 功能目录按它把页面说明挂到页面上。
- **检索**(`AiDocKnowledge.search`): 问句按整词读(内置词表 `AiDocIndex.CORE_WORDS`、同义词组、日常说法表 `AiDocIndex.COLLOQUIAL`、术语表、文档别名),
  跨两个整词的字二元组不检索; 原有门槛不变(10 分, 一个词 15 分, 相对最高分 0.35, 最多 6 块 6000 字、每份文档 3 块), 另加: 最高分的块不含问句一半以上的词
  且标题章节没点到其中一个时一块不发; 一两个词的问题按标题章节放行(分数 ≥7; 两个词都在章节标题里的不看分数); 问到的术语定义先下发(最多 2 条)。
  评测与作答链路用 `ranking(question, domains, limit)` 看原始排序、用 `keyTerms(question)` 取问句的词(含术语与别名)。
- **追问**: 只有以「那/如果/要是/第二次」开头、以「呢」结尾或没有自己的词的问题才是追问; 先按这一问单独检索, 追问且找不到或自己的词不到两个时
  才带最近两问作 0.5 权重的上下文; 上一轮引用的块只在追问或新结果来自同一份文档时随记忆下发。
- **有页面时**: 只问页面本身(页面操作、页面上写了什么、第几行、颜色含义、哪些要核对)不检索, 问规则与为什么都检索。
- **工具执行条件**(`AiChatDialogueSupport.toolEligible(toolName, message)`): 查数据的问题(新增状态说法「还有吗、到了没、发货了没、批了没、到哪一步了、卡在」
  与「业务单号 + 问句」)所有只读工具都可执行; `feature_directory` 另在问「在哪里、哪个页面、怎么进、有哪些功能」时执行; `my_access` 另在问「打不开、没权限、
  看不到、点不了、按钮是灰的、缺少操作权限」时执行, 但问带单号的单据且没提权限时不执行。新工具要在别的问法下执行, 在这里加分支并加测试。
- **结果**(8.4 的字段不变):
  - 规则问题没找到依据: `intent=UNSUPPORTED`, 「我没在平台说明里找到关于「…」的说明。…」+ 用用户自己的词给的问法(三语); 查数据的问题: 「这个要查业务数据,
    我这次没能查到可靠的结果, 不想猜。…」, 不贴文档原文。兜底贴原文只在最相关一段与问句共有两个以上的词时, 且去掉带空洞的句子。
  - 模型判越界、但问题已过闸门且没有规则来源: `intent=UNSUPPORTED` 的「没找到」+ 助手能做什么, `_scope=MODEL`(不进对话记忆)。
  - 贴来的系统内部报错: 闸门类别 `INTERNAL_ERROR`, `intent=UNSUPPORTED`, 固定求助说明(三语), 不调模型, `_scope=INTERNAL_ERROR`(不进对话记忆)。
  - `UNSUPPORTED` / `CLARIFY` 回答没引用来源却写了步骤或去处: 换成确定性说明, 日志 `problems=[UNGROUNDED_STEPS]`。
- **导航守卫**(`AiChatAnswerGuard.checkNavigation`): 回答让用户去的页面、菜单、按钮必须出现在来源、页面快照、工具结果、本人能打开的功能目录名称或对话里;
  只查「去处」语境(去处词之后、页面/按钮词之前、以「工作台」开头的 `A > B`、箭头连着的「」), 强调规则的「」与写先后顺序的「>」不查。只有这一个问题时去掉
  那几行、其余照给(`Verdict.dropped()`, 日志 `AI chat reply kept without its unverified navigation lines: intent=…, problems=[NAV]`); 剩下不到一半或不足 60 字,
  或还有别的问题时整条不采用。
- **系统提示**: 加一行 `USER ACCESS (from the user's permissions; no identity): modules the user can open: …; assistant domains: …`, 来自 `AiChatUserScope`
  (经 `application.port.AiFeatureDirectoryPort.openable(permissions, superAdmin)`, 只返回模块名与页面名称、菜单路径); 这些名称算用户看得见的, 回答可以写。
- **功能目录**: `server/src/main/resources/ai-feature-map.json`(ADR-153 唯一允许提交的生成文件), 由 `test/shared/ai/ai_feature_map_test.dart` 生成并逐字比对(见第六章)。
  服务端 `features.rbac.directory.AiChatFeatureDirectory` 读取, 按客户端路由守卫同一规则判断能否打开(普通页面任一 + 全部; 模块首页任一张卡片能打开即可);
  `AiFeatureAccess` 用参数化查询从 `permissions` 表取中文权限名。新页面上线: 加路由与守卫后重新生成; 有页面说明就写核对过的 `路由：` 行, 没有就把路由加进测试的
  `_pagesWithoutDocs` 豁免清单(清单过期也会失败)。
- **工具一览**(都只读, 零新增权限码):

  | 工具 | 所在包 | 业务域与权限 | 外送(`modelFacts`) |
  | --- | --- | --- | --- |
  | `feature_directory` | `features.rbac.directory` | SELF; 读本人权限 | 找到的页面本人都能打开时: 页面名称、模块、用途、进入方法; 否则不外送 |
  | `my_access` | `features.rbac.directory` | SELF; 读本人权限 | 不外送 |
  | `sales_order_progress` | `features.sales.order` | SALES; `sales_order:view` + 订单详情页的归属范围 | 单号、阶段、日期、货品编码名称、数量、环节状态 |
  | `purchase_order_status` | `features.purchase.order` | PURCHASE; `purchase_order:view` 或 `finance_order_approval:view` + 详情页 `readDetail` 的范围 | 同上 + 到货与检验数量 |
  | `subcontract_order_status` | `features.subcontract.order` | SUBCONTRACT; 申请 `subcontract_application:view`, 订货单 `subcontract_order:view` + 归属范围 | 同上 + 缺料、需要、可用量(ADR-156) |

  单号找不到或不在本人范围内: 三个单据工具回同一句「没有找到你能查看的这张单据。…」, 证据摘要也相同; 保存的回答再次读取时 `authorizeResultRead` 按读者当前范围
  重读, 数据或范围变了 403「…已变化，请重新查询」(恢复对话时按 8.10 显示 `dataChanged`)。照这三个写新的单据工具时, Postgres 测试可复用
  `application.port.AiDocumentStatusToolPostgresSupport`(经入职接口建员工、按库重建权限)。前端「AI 使用审计」的用途名称在
  `lib/features/admin/widgets/ai_usage_audit_panel.dart` 按工具名加(三语)。
- **运维**: 启动日志改为 `AI knowledge index: N documents, M chunks, G glossary terms, …`; `AiKnowledgeIndexCheck` 输出增加 `glossaryTerms=G`(为 0 表示术语表没打进 jar,
  口语与俗称检索会变差, 但不阻断)。
