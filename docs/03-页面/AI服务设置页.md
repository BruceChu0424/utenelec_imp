# AI 服务设置页

> **2026-10-07 改版**: 顶部改为两卡一行(「正在使用」+ 新增「今日用量」卡, 点击进 AI 用量看板); 底部「近 30 天用量」卡与内嵌「使用记录与费用」面板退役——后者升级为独立页 `/admin/ai-usage-records`(见文末 ADR-164 小节)。服务商区块恢复常显(`UtenSectionHeader` + 计数), 网格改 `UtenResponsiveGrid` 瀑布流(1/2 列封顶), 每张 `AiProviderCard` 自身可折叠(默认收起只留头部)。

> **2026-09-27 新页面(ADR-133 公共 AI 平台)**: 超级管理员在这里选择大模型服务商(DeepSeek、通义千问、Kimi、智谱、火山方舟、硅基流动、本机部署、境外服务商等)、填写接口地址/模型/密钥、测试连接、设为默认、启停并查看近 30 天用量。所有接入公共 AI 平台的功能(目前是销售「识别客户文件」)都只调用这里的**默认服务**, 换服务商不改代码、不重启。

> 路由: `/admin/ai-settings`(`RouteName.adminAiSettings`, `DraftAwareGoRoute`, **不是**表单草稿页)。
> 实现: `lib/features/admin/pages/admin_ai_settings_page.dart`; 组件 `lib/features/admin/widgets/ai_provider_card.dart` / `ai_provider_editor.dart` / `ai_connection_test_view.dart` / `ai_settings_entry_card.dart` / `ai_settings_labels.dart`; 模型 `lib/features/admin/models/ai_provider_models.dart`; 仓储 `lib/features/admin/repositories/ai_provider_repository.dart`(今日用量读 `ai_usage_dashboard_repository.dart` 的 day 窗口)。
> 后端: `server/.../features/ai/provider/`(`AiProviderController` `/api/admin/ai`, `AiProviderService`, `AiEndpointPolicy`, `AiConnectionTester`), 表 `ai_providers` / `ai_call_logs`(V742)。决策: [ADR-133](../99-决策记录-ADR/ADR-133-公共AI平台与服务商可配置.md); 开发接入: [AI 平台接入指南](../05-架构/AI平台接入指南.md); 公共进度弹窗: [AI任务进度弹窗](../02-组件库/AI任务进度弹窗.md)。

---

## 入口

- 唯一入口: 系统设置页的「AI 服务」入口卡(`AiSettingsEntryCard`, 「配置大模型服务商、密钥和连接测试」), 点击 `push` 进入, 返回回到系统设置。设置项加载成功时它是分组卡片网格的首格; 加载中、读取失败或为空时固定在页面顶部整宽。工作台「系统管理」组的「AI 服务」卡片 2026-09-28 已退役(用户口径: AI 服务属于系统设置, 不在工作台单放一张卡)。
- 路由守卫: `/admin/*` 统一要求 `authorization:manage`(`permission_by_path.dart`, 不新增权限码); 服务端 Controller 类级别 `hasAuthority('authorization:manage') and principal.superAdmin`。非超管持有 `authorization:manage` 能进页面, 但首屏读取被拒, 页面显示「只有超级管理员可以查看和修改 AI 服务」。

---

## 页面结构与状态

| 区块 | 内容 |
|---|---|
| 顶部两卡 | 宽屏同一行(`IntrinsicHeight` + `Row`, 「正在使用」: 「今日用量」= 3:2, 两卡同高对齐), 窄屏(<780)上下堆叠 |
| 正在使用(左卡) | 渐变卡: 「正在使用: 名称 · 模型」+ 区域标签 + 上次测试(通过/未通过 + 北京时间)。没有服务 →「还没有可用的 AI 服务」+ 下一步说明; 默认服务停用 / 没密钥 / 密钥解不开 → 一句大白话原因 |
| 今日用量(右卡) | key `ai-settings-today-usage`。数据取看板 day 窗口(`GET /admin/ai/usage-dashboard?window=day`)的 `todayTokens` / `todayCalls` / `activeUsersToday`: token 大数字(`UtenAnimatedNumber`)+ 脚注「X 次调用 · Y 人使用」, 今日三值全零显示「今日暂无用量」; 读取失败整卡仍在, 只把脚注换成「用量暂时读不到, 不影响使用」; 整卡可点跳 `/admin/ai-usage`(用量与额度看板)。原「近 30 天用量」卡(每服务调用次数/成功率/token/平均耗时)2026-10-07 退役 |
| 外呼关闭提示 | 服务器 `uten.ai.outbound-enabled=false`(内部测试环境强制)时黄色提示「配置可以保存, 但不会真正调用」 |
| 服务商区块 | 常显 `UtenSectionHeader`(「服务商」+ 图标 + trailing 计数), 网格 `UtenResponsiveGrid` 瀑布流(medium 1 列 / expanded 2 列封顶, `maxColumns: 2`)——高矮卡(展开与否)不会互相撑出空白 |
| 服务商卡片 | 每张 `AiProviderCard` 自身可折叠(**默认收起**, 服务多时一屏只看「谁在用、开没开」, 要管理再展开)。头部常显: 预设首字头像(国内青绿 / 境外紫 / 本机蓝渐变, 停用变淡; 字色取主题 `onPrimary`, 深色主题换浅一档渐变保证对比度)、名称、模型、预设名(预设目录缺这条时用服务端 `presetLabel`)、区域标签(国内/境外/本机)、默认徽章、已停用徽章、启用开关、展开箭头(收起朝下、展开朝上; 点头部任意处展开, 开关自己消化点按不连带展开)。展开后: 模型、接口地址、密钥(小徽章「已配置」+ 旁边紧凑显示尾号掩码「••••abcd」(`AiMaskedKey`: 应用字体里「•」是全角, 连写会显示成「• • • •」, 所以圆点画成紧凑小点、读屏仍读掩码原文); 服务端对短密钥不留尾号时只显示「已配置」;「未配置」/「不需要」(区域为本机即不需要)/ 红色「密钥无法解密, 请重新填写」)、上次测试(小徽章只写「通过 / 未通过」, 北京时间写在旁边普通文字里, 窄屏自动换行不被省略号截断)四行信息 + 连接测试结果 + 操作 测试连接 / 编辑 / 设为默认 / 删除(按钮高 48) + 更新人信息(「谁 · 北京时间」) |
| 空状态 | 「还没有配置 AI 服务」+ 支持哪些服务商 + 「添加 AI 服务」(此时只有这一个添加按钮, 右下悬浮按钮不出现) |
| 安全说明 | 密钥加密保存只显示尾号; 保存、删除、用已存密钥测试要再次确认登录密码 |
| 右下悬浮 | 红色大按钮「添加 AI 服务」(`UtenFloatingActionGroup`, 正文 200dp 留白); 已有至少一个服务时才出现 |

加载: 首屏骨架(`UtenSkeleton` 顶部条 + 两张卡片轮廓); 已有配置数据时刷新失败只提示。今日用量在主列表加载成功后单独拉取, 失败不影响服务配置的展示与操作。使用记录与费用、计费方式与套餐额度 2026-10-07 起不在本页, 在独立页「使用记录与费用」(`/admin/ai-usage-records`, 见文末 ADR-164 小节)。
遮罩: `UtenBusyOverlay` 只包「设为默认 / 启停 / 删除」的纯网络段, 结束即撤再静默刷新; 服务端要求再认证时遮罩自动让位给统一密码框。
动画: 页面上的 AI 徽标静止; 只有进度弹窗里的徽标「呼吸」, 并服从省电档 / 系统减少动画 / TickerMode。
服务商网格宽屏最多两列(瀑布流)、窄屏一列; 深色模式、字号放大已用截图夹具核对(`UTEN_UI_FIXTURES=1`)。

---

## 新增 / 编辑面板

宽屏右侧抽屉(560), 窄屏底部弹层; 点空白处不关闭(防止丢掉填了一半的密钥), 右上角关闭。所有字段(含下拉框: 服务商、所在区域、接口协议、JSON 输出方式、思考参数写法)的名称都在框上方, 说明 ⓘ 在框内。

| 字段 | 说明与约束 |
|---|---|
| 服务商 | 服务端下发的预设(`GET /admin/ai/presets`)。选中后预填接口地址、推荐模型、协议、JSON 方式、思考参数写法、温度、图片识别、区域; **每一项仍可改**。能否选以服务端每项的 `selectable` 为准: 境外未开放时境外预设显示「(境外, 未开放)」, 服务器关闭对外调用时国内预设显示「(暂不可用)」, 都不可选; 下拉框下方逐条列出服务端给的 `unavailableReason`(去重, 带锁图标), 境外相关的完整说明在 ⓘ。新增时默认选第一个能选的预设(外呼关闭的服务器就是本机部署)。编辑时这条配置自己的预设始终可选 |
| 所在区域 | 仅「自定义」显示(国内 / 境外 / 本机); 其他预设区域由服务商决定 |
| 显示名称 | 必填, 最多 64 字, 名称唯一由服务端校验 |
| 接口地址 | 必填, https; 只有本机部署可用 http(如 `http://127.0.0.1:11434/v1`); 不带账号、问号参数和 # 片段; 最终安全判断在服务端 `AiEndpointPolicy`(SSRF、元数据地址、跳转一律拒绝) |
| 模型 | 必填, 最多 128 字; 预设推荐 ≤ 6 个时直接点选(小药丸), 「获取模型」拉服务商列表, 多于 6 个用可搜索下拉; 拿不到列表时显示服务端给的原因(如「这个服务商没有模型列表接口, 请手动填写模型名称」), 没给原因才用通用提示 |
| 密钥 | `UtenInput(isPassword)`, 不接系统自动填充, 过滤空白字符; 新增时按预设必填(区域为本机部署一律不需要, 包括「自定义」选本机; 与服务端 `requiresApiKey(region)` 同口径); 编辑时提示「已配置, 不改就留空」, 不回显原文, 输入框下方一行「当前密钥 ••••abcd」(紧凑掩码)与「清除密钥」按钮; 「清除密钥」(再点撤销)用于本机部署不需要密钥或密钥泄露先撤掉, 清除后该服务不可用直到重新填写; 编辑保存不强制重填密钥 |
| 改了接口地址 | 编辑时协议或规范化地址(协议 + 主机 + 端口 + 路径)变了而旧密钥还在: 显示「改了接口地址, 需要重新填写密钥」, 保存和测试都被拦下, 直到重新填写(或本机部署清除); 服务端同样回 422 |
| 境外确认 | 区域为境外时出现勾选框「客户资料(公司名、货品描述)会发送到境外服务商, 我已确认完成数据出境评估」, 不勾不能保存 |
| 高级设置(默认收起, 收起时箭头朝下、展开后朝上, 与全站 `UtenCollapsibleSection` 一致) | 接口协议(OpenAI 兼容 / Anthropic)、JSON 输出方式、思考参数写法(不发送 / DeepSeek / 通义千问(只关掉思考) / OpenAI / 智谱 GLM / Anthropic effort(Opus 4.5 / Sonnet 4.6 及以上); AI 对话的「思考程度」按它发给服务商, 识别表格等用途仍关思考; 选「不发送」、选通义千问写法、或模型不认思考参数(如 Claude Haiku 4.5, 服务端按模型名判断)时对话设置里思考程度锁住, 见 ADR-152)、固定输出(温度 0; OpenAI 写法下对话带了思考档时服务端不发温度)、能识别图片和扫描件、启用、最大输出长度(256 ~ 65536; 单次输出含思考的硬上限, 对话「深入」也不会超过它)、超时秒数(10 ~ 600); 高级项有错时保存会自动展开 |

底部两个大按钮(`UtenActionButton`, 高 52, 自带防连点):

- **测试连接**: 本次填了密钥 → `POST /admin/ai/providers/test`(免再认证, 只用本次密钥和当前表单全部设置, 不读已存密钥、不改配置); 没填密钥但已存密钥可用且地址/协议/模型都没改 → `POST /admin/ai/providers/{id}/test`(再认证, 请求体带当前 `{protocol, baseUrl, model}` 让服务端再核对一次, 不一致回 422; 结果记到这条配置上); 改了地址或模型又没填密钥 → 提示「请先保存, 或重新填写密钥再测试」; 改了 JSON 输出方式 / 思考参数写法 / 固定输出 / 超时又没填密钥 → 提示「高级设置改过了, 用已存的密钥测试不会带上这些改动。请先保存再测试, 或重新填写密钥后测试」(已存密钥的测试只按已保存的设置跑, 不能冒充新设置的结果; 「获取模型」不受这些设置影响, 照常可用); 需要密钥却没有 → 「测试前请先填写密钥」。改了任一会影响测试的项, 旧的测试结果立即清掉。
- **保存**: 新增 `POST /admin/ai/providers`, 编辑 `PUT /admin/ai/providers/{id}`(带打开时的 `version`, 别人改过回 409)。再认证由网络层统一密码框完成, 面板不挂整页遮罩。成功后立即清空密钥输入框、关闭面板、页面静默刷新。

### 连接测试结果

四步竖排: 网络连通 / 密钥验证 / 模型可用 / JSON 输出; 这个配置能调整思考程度时服务端多报一步「思考程度」(`THINKING`, 排在最后: 按 AI 对话默认档「标准」带思考参数实测一次, 服务商拒绝就是「没通过」并提示把思考参数写法改为「不发送」或换模型, 超时/限流是「需留意」), 每步按服务端 `status` 显示 ✓ 通过(绿) / ! 需留意(`WARN`, 琥珀色) / ✗ 没通过(红) / 空心圈 未进行(`SKIPPED`), 附耗时(毫秒)和服务端 `message`(大白话, 通过、需留意、未进行也照样显示, 例如「返回了 JSON 但内容和要求不一致, 识别客户文件可能不稳定」「还没有填写模型名称」)。右上徽标与底部总结按总体结论:

| 结论 | 条件 | 徽标 | 底部总结 |
|---|---|---|---|
| 通过 | 无失败、无需留意、`ok=true` | 通过(绿) | 「连接正常, 可以使用」 |
| 需留意 | 有 `WARN` 步骤, 或服务端 `ok=false` 但没有失败步骤(如还没填模型) | 需留意(黄) | 服务端 `summary`(如「连接成功, 但有需要注意的地方」), 没给时「连上了, 但有需要留意的地方, 请看上面的黄色提示」 |
| 没通过 | 有 `FAILED` 步骤 | 未通过(红) | 单独下发的 `advice` → 服务端 `summary`(即第一条失败原因 + 做法) → 失败步骤 `message` → 「连接没有通过, 请按提示检查后再试」; 与失败步骤说明一字不差时步骤下不再重复 |

卡片上的「测试连接」同样展示在卡片内。编辑面板里测试结果与「测试前请先填写密钥」等提示在表单末尾, 点底栏「测试连接」/「获取模型」后面板自动滚到它们(测试中的转圈与最终结果都滚进可见区; 系统「减少动画」时直接跳到位), 手机上不会出现「点了没反应」。

---

## 安全

1. **路由与服务端双层**: `/admin/*` 要求 `authorization:manage`; Controller 再校验 `principal.superAdmin`; 前端不新增权限码, 也不在页面里拼 `Perm.x`。
2. **密钥只写不读**: 列表 DTO 只有 `apiKeyConfigured` / `apiKeyMasked` / `apiKeyUnreadable`, 永远不含密钥; 页面只有「本次新填」的密钥会进请求体, 空白一律不发送。
3. **不进草稿、不进日志**: 本页不混入 `FormDraftMixin`(路由仍用 `DraftAwareGoRoute` 只为统一离开保护); 密钥不写偏好、不写路由参数、不出现在任何提示或错误文案里; 编辑面板关闭或保存成功即清空。
4. **再认证**: 增删改、设默认、启停、用已存密钥测试/取模型均 `@RequiresStepUp`; 用本次新填密钥探测 `@StepUpExempt`。页面不自己问密码。
5. **已存密钥绑定原地址**: 改了协议或地址必须重新填写密钥(前端提示 + 服务端 422), 已存密钥绝不会发往新地址。
6. **区域与出境**: 境外服务商默认关闭(服务器 `uten.ai.allow-overseas-providers`), 开放后每个境外服务都要勾选数据出境确认; 本机部署才允许 http。
7. **审计**: 服务端对 `ai_provider.create|update|delete|set_default|set_enabled` 记审计, 换密钥只记尾号; `ai_providers` 行级审计只覆盖非密钥列。
8. **写修订号**: 连接测试 / 获取模型不算业务写操作(`data_write_revision.dart` 自动写路径), 不触发全站「返回即刷新」。

---

## 服务端接口契约(前端按此解析, 字段缺失时按括号内默认值)

字段名以服务端 `AiProviderDtos`(ADR-133)为准; 两边用「服务端原样 JSON」夹具测试锁住(`ai_provider_repository_test.dart` 的 `presets parse the exact server PresetsView JSON` / `connection test results parse the exact server TestResult JSON`, 页面测试的 `_serverCatalog` / `_serverWarnResult` / `_serverAuthFailed`), 服务端改字段名这些测试会先红。

| 接口 | 请求 | 响应 |
|---|---|---|
| `GET /admin/ai/providers` | - | JSON 数组(或 `{data: [...]}`); 每项 `ProviderView{id, name, preset, presetLabel, region, protocol, baseUrl, model, apiKeyConfigured, apiKeyMasked, apiKeyUnreadable, jsonMode, thinkingControl, sendTemperature(true), supportsVision, maxOutputTokens(8192), timeoutSeconds(120), enabled(true), isDefault, overseasAcknowledged, lastTestAt, lastTestOk, lastTestMessage, version, updatedAt, updatedByName}`; 预设目录没加载到时卡片用 `presetLabel` 显示预设名, 不露出代码 |
| `GET /admin/ai/presets` | - | `PresetsView{presets: [PresetView{key, label, region(CUSTOM 为 null), protocol, defaultBaseUrl, suggestedModels: [..], jsonMode, thinkingControl, sendTemperature, supportsVision, requiresApiKey(true), registeredDomains, selectable, unavailableReason}], allowOverseas(false), allowLanHttp(false), outboundEnabled(true), overseasNotice}`。预设代码读 `key`(兼容 `preset` / `code`), 地址/模型兼容 `baseUrl` / `models`; `selectable` 缺失时按「境外预设要等 `allowOverseas`」推断; `regionEditable` 缺失时仅 CUSTOM 为 true; 开关也可放在 `flags` 对象里 |
| `GET /admin/ai/usage-dashboard?window=day` | - | 今日用量卡的数据源(ADR-164 看板 day 窗口, 详见文末小节): `todayTokens` / `todayCalls` / `activeUsersToday` 等; 失败时卡片显示「用量暂时读不到, 不影响使用」 |
| `GET /admin/ai/usage?days=30` | - | `UsageView{days, providers: [{providerId, providerName, calls, okCalls, inputTokens, outputTokens, averageLatencyMs}], total, todayTokens, dailyTokenBudget}`(平均耗时也接受 `avgLatencyMs`)。**2026-10-07 起本页不再调用**(「近 30 天用量」卡退役), 仓储方法与服务端端点保留 |
| `POST /admin/ai/providers` | 表单 `{name, preset, region, protocol, baseUrl, model, apiKey?, jsonMode, thinkingControl, sendTemperature, supportsVision, maxOutputTokens, timeoutSeconds, enabled, overseasAcknowledged}` | 忽略(页面随后重读列表) |
| `PUT /admin/ai/providers/{id}` | 同上 + `version`; `apiKey` 省略 = 保留; `clearApiKey: true` = 清除 | 忽略 |
| `DELETE /admin/ai/providers/{id}?version=` | 查询参数 `version` = 页面读到的版本号(DELETE 没有请求体; 服务端 `@RequestParam(required = false) Long version`), 别人改过回 409 | - |
| `POST /admin/ai/providers/{id}/default` | 无 | 忽略 |
| `POST /admin/ai/providers/{id}/enabled` | `{enabled: bool}` | 忽略 |
| `POST /admin/ai/providers/test` | 表单(必须带 `apiKey`, 不需要密钥的预设除外) | `TestResult{ok, summary, steps: [{key: NETWORK/AUTH/MODEL/JSON, status: OK/WARN/FAILED/SKIPPED, message, latencyMs}], testedAt}`; `ok` 在有失败或有步骤没进行时为 false; 总结也接受 `message`, 步骤另可带 `advice` |
| `POST /admin/ai/providers/{id}/test` | 卡片发起: 无; 编辑面板发起: `StoredProbeRequest{protocol, baseUrl, model}`(只用于核对, 不带密钥) | 同上 |
| `POST /admin/ai/providers/models` / `{id}/models` | 表单 / 同上但不带 `model`(换模型前正需要看列表) | `ModelsResult{models: ["name", ...], message}`; `message` 说明拿不到列表的原因(也接受 `[{id}]` / `data` 形态) |

错误一律走统一 `ApiException`(`context.appApiError`), 例如 422「接口地址已修改, 请重新填写密钥」、409 版本冲突、403 非超管或切换人只读。

---

## 验证

- `flutter test test/features/admin/admin_ai_settings_page_test.dart`: 空状态; 服务商卡默认收起、点头部展开后信息与操作齐全; 今日用量卡与「正在使用」同屏, 数字来自看板 day 窗口; 卡片只显示掩码(桌面浅色 / 窄屏深色), 短密钥只显示「已配置」; 解不开的密钥标红, 可不填新密钥直接清除; 卡片测试连接四步 ✓/✗ + 耗时 + 建议; 服务端原样结果: `WARN` 显示黄色「!」+ 说明 + 「需留意」徽标而不是「未进行」, 失败时底部是服务端总结且不在步骤下重复; 编辑改地址 → 提示且保存/测试被拦 → 重新填密钥后带 `version` 保存; 空状态只有一个添加按钮; 卡片与编辑面板的尾号掩码走 `AiMaskedKey`; 高级设置箭头收起朝下、展开朝上; 删除带 `version`; 未改配置用已存密钥测试(带当前地址核对)、改了模型不冒充、改了高级设置不冒充(取模型照常); 空模型列表显示服务端原因; 服务端原样预设: 新增预填 DeepSeek、锁定项列出服务端原因、外呼关闭时默认本机部署且国内预设「暂不可用」; 预设目录缺失时本机服务仍显示「不需要」密钥、就绪且显示预设名; 新增: 预设预填 → 点选模型 → 无密钥不测 → 填密钥测试 → 保存; 境外未开放不可选; 境外开放需勾确认; 非超管提示; 外呼关闭提示; 默认服务不能删; 启停只在网络段挂遮罩。
- `flutter test test/features/admin/ai_masked_key_test.dart`: 掩码圆点紧凑(4 个圆点不到 2 个字宽)、读屏读原文、非圆点掩码原样显示。
- `flutter test test/features/admin/ai_provider_repository_test.dart`: 各端点路径、请求体(空密钥不发、`version`、删除的 `?version=`、`clearApiKey`、境外确认、已存密钥核对体不带密钥)、服务端原样 `PresetsView` / `TestResult`(含 `WARN` / `SKIPPED` / 失败)/ `ModelsResult` 解析、本机与「自定义 + 本机」免密钥口径、非法 id 拒绝、地址规范化。
- `flutter test test/features/admin/ai_settings_entry_test.dart`: 工作台不再出现「AI 服务」卡(退役守卫); 系统设置入口卡的跳转与返回; 系统设置读取失败或没有设置项时入口卡仍在。
- 截图: `UTEN_UI_FIXTURES=1 flutter test test/features/admin/admin_ai_settings_page_test.dart` 输出到 `.codex-tmp/ai-settings-ui/`。
- 真机联调(服务端完成后): 超管账号添加 DeepSeek(或本机 Ollama)→ 测试连接四步全绿 → 设为默认 → 销售账号「识别客户文件」走通; 改接口地址不填密钥保存应被拒(422); 审计中心能查到 `ai_provider.*` 事件且无密钥明文。

---

## 用量与额度(ADR-164)

> **2026-10-07 改版**: 看板 KPI 四卡统一最小高度同构(图标行 + 数值 + 脚注), 窗口分段栏同一行新增「使用记录与费用」入口按钮; 设置页内嵌的「使用记录与费用」面板升级为独立页 `/admin/ai-usage-records`(汇总卡 + 按记录/按人员两视图 + 计费设置抽屉, 套餐额度接入 V826 两列), 超管可见。

> **2026-10-06 新页面(ADR-164 AI 用量看板与按人限额)**: 超级管理员在这里按人按时/日/月/年看 AI 消耗(谁用了多少 token、调了多少次、用在什么用途上, 全站今日对预算的进度), 并对某个人设个人限额(每日 token / 每日任务数, 留空=跟随全局)或停用其 AI 使用(可随时恢复)。

> 路由: `/admin/ai-usage`(看板)与 `/admin/ai-usage/:userId`(人员详情)(`RouteName.adminAiUsage` / `adminAiUsagePerson(userId)`, `DraftAwareGoRoute`, **不是**表单草稿页; 人员详情页从路径参数取 userId); `/admin/ai-usage-records`(使用记录与费用, `RouteName.adminAiUsageRecords`, 路由名 `admin-ai-usage-records`——**不能**挂在 `/admin/ai-usage/` 下, 会被 `:userId` 参数路由吞掉)。
> 实现: `lib/features/admin/pages/admin_ai_usage_page.dart` / `admin_ai_usage_person_page.dart` / `admin_ai_usage_records_page.dart`; 趋势柱卡 `lib/features/admin/widgets/ai_usage_trend_card.dart`(看板与人员详情共用); 计费设置 `lib/features/admin/widgets/ai_billing_editor.dart`; 模型 `lib/features/admin/models/ai_usage_dashboard_models.dart` / `ai_usage_audit_models.dart`; 仓储 `lib/features/admin/repositories/ai_usage_dashboard_repository.dart` / `ai_usage_audit_repository.dart`。
> 后端: `server/.../features/ai/usage/`(`AiUsageAuditController` 追加三个端点, `AiUserLimitsService` 限额读写, `AiUsageDailyService` 日汇总), 表 `ai_user_limits` / `ai_usage_daily`(V815); 套餐额度 `ai_providers.billing_quota_5h` / `billing_quota_weekly`(V826)。决策: [ADR-164](../99-决策记录-ADR/ADR-164-AI用量看板与按人限额停用.md)。

### 入口

- 看板入口: AI 服务设置页顶部「今日用量」卡(整卡可点), `push` 进入看板, 返回时设置页静默刷新(`ref.onPageResume`)。看板人员表行点击(或行操作图标)进人员详情页; 看板窗口分段栏同一行的「使用记录与费用」按钮进使用记录与费用页。
- 使用记录与费用页入口: 上述看板按钮(2026-10-07 前在设置页内嵌, 现为独立页)。
- 路由守卫: `/admin/*` 统一要求 `authorization:manage`(`permission_by_path.dart`, 不新增权限码); 各页页内叠加超管门禁(照 AI 服务设置页同款), 非超管显示「只有超级管理员可以查看」, 401/403 走拒绝态。
- `ai-feature-map.json` 随新路由重新生成(ADR-159 的生成与逐字比对机制)。

### 看板页

| 区块 | 内容 |
|---|---|
| 顶部 | `UtenAppBar`「AI 用量与额度」+ 返回 + 刷新; `UtenContentContainer` + `RefreshIndicator` |
| KPI 行 | 四卡统一最小高度同构(图标行 + 数值 + 脚注, 窄屏两列): 今日消耗(token, 附全站预算进度条与「x / y」脚本文案, ≥80% 警示色、≥100% 危险色, 不只靠色)、今日调用次数(脚注=窗口累计调用次数, 人员 `windowCalls` 求和)、今日活跃人数(脚注=全员人数)、已停用人数(危险色数字, 脚注=超限额人数) |
| 窗口切换 | 时(近 24 小时)/ 日(近 30 天)/ 月(近 12 月)/ 年(近 5 年)分段过滤, 切换即重新请求; 时窗实时查调用流水, 日/月/年查日汇总表。分段栏同一行是「使用记录与费用」入口按钮(key `ai-usage-open-records`, 52px 外框 / 44px 按钮与分段栏对齐), 点击 `push` `/admin/ai-usage-records`, 窄屏自动换行 |
| 趋势卡 | 窗口序列柱状: tokens 定高, 柱顶数值常显、桶底 label 不旋转, 峰值柱主色、其余浅色, 柱可点(Semantics 读全值); 空窗显示「暂无用量」 |
| 人员表 | 人员(姓名+工号副行/部门)、窗口消耗(token, 次行次数)、今日消耗、个人限额(token, 未设显示「跟随全局」)、状态徽章(正常 / 已超限(今日已达个人限额) / 已停用, 色+文字三态)、最近使用(相对时间); 表头筛选状态、按窗口/今日消耗排序、客户端分页(数据全量 ≤500, 每页 20); 行点击进人员详情, 行操作图标打开限额编辑 |

加载失败/空态齐备; 401/403 拒绝态同设置页。

### 人员详情页

- 顶部: `UtenAppBar`(姓名 · 工号)+ 返回 + 刷新; 已停用时顶部危险横幅「该账号的 AI 使用已被停用」。
- 今日消耗环形进度(对个人限额, 80%/100% 两档变色并带文字; 未设个人限额时按全站预算封顶并注明「未设个人限额, 按全站预算」)。
- 窗口分段 + 个人趋势柱卡(与看板同组件)。
- 全站统计包含系统或未归属账号的调用；这类用量不伪装成员工行、不计入活跃员工数。人员详情的趋势、用途和服务商分布均只统计选定账号。
- 分布区两列: 按用途 / 按服务商(label + 次数 + token, 横向比例条; label 用调用流水里的现有人话)。
- 最近使用(近 20 条: 问题摘要 / 时间 / 状态 / token, 精简展开条)。
- 「设置限额」按钮(底部)打开限额编辑面板。

### 限额编辑面板

宽屏右侧抽屉 / 窄屏底部弹层(照服务商编辑先例):

| 字段 | 说明与约束 |
|---|---|
| 停用该账号的 AI | 开关, 危险语义; 副文本「停用后不能使用 AI 对话与文件识别, 可随时恢复」; **开启停用时二次确认**(危险按钮), 恢复启用不需确认 |
| 每日 token 限额 | 数字输入, 空=跟随全局; 填了必须 ≥1, 上限 10^12 |
| 每日任务数限额 | 数字输入, 空=跟随全局; 填了必须 ≥1, 上限 10000 |
| 今日已用对照 | 面板显示该人当前今日 token 与任务数, 供参照 |

保存: `PUT /admin/ai/usage-people/{userId}/limits` 带打开时的 `rowVersion`(别人改过回 409「配置有变化, 请刷新后再保存」); 再认证由网络层统一密码框完成(`@RequiresStepUp`); 成功后成功提示并静默刷新。空值语义=跟随全局默认(helper text 常驻「留空表示跟随全局默认」)。

### 使用记录与费用页(2026-10-07 自设置页内嵌面板升级为独立页)

仅真实超管可查看跨员工记录; 本地帮助也算使用记录, 但不冒充收费调用。页内叠加超管门禁(会话 / 快照 / 服务器 / 权限任一变化即失效清空旧数据, 在途回调作废), 401/403 走拒绝态。

| 区块 | 内容 |
|---|---|
| 顶部 | `UtenAppBar`「使用记录与费用」+ 返回 + 右上「计费设置」按钮(key `ai-records-billing-open`, 没有服务商时禁用)+ 刷新; `UtenContentContainer` + `RefreshIndicator` |
| 汇总卡 | 四张等高卡(≥640 四列, 窄屏两列): 使用条数(脚注=调用模型次数)/ 实际费用(以服务商账单为准)/ 估算费用(按设置的计费单价估算)/ 费用待确认(有未设单价的调用时红色警示, 脚注「X 次调用未设单价」); 下挂「仅统计本平台」说明 |
| 工具条 | 按记录 \| 按人员 分段切换 + 时间(近 7/30/90/180 天)/ 使用人 / AI 服务三个下拉筛选; 按人员视图只留时间筛选(进按人员先解除单人锁定, 锁定某人则自动回按记录) |
| 按记录视图 | `MasterDataTableView` 表格: 时间 / 使用人(姓名+工号副行)/ 用途 / 问题内容 / AI 服务 / 模型 / 调用次数 / 输入 token / 输出 token / 费用(实际与估算分列, 跨币种不合并)/ 状态徽章(成功/失败/已取消/排队/进行中); 服务端分页 20/页; 行点开右侧抽屉(480)看详情——问题全文 `SelectableText` 可选中复制, 另列用途、服务、模型、token、费用、时间、使用人 |
| 按人员视图 | 每人一行: 使用人(姓名+工号副行)/ 条数 + 调用次数(主行条数、次行「调用模型 X 次」)/ 费用 / 「查看记录」按钮(切回按记录视图并锁定该人) |

### 计费设置面板(`ai_billing_editor.dart`, 2026-10-07 自内嵌表单迁移)

右上「计费设置」打开右侧抽屉(点空白处不关闭, 防误丢, 关闭走右上角); 选服务商 → 计费方式三选一:

| 计费方式 | 字段与行为 |
|---|---|
| 未设置 | 不参与估算费用, 调用记为「费用待确认」 |
| 按量 | 币种(CNY/USD/EUR/HKD/JPY/KRW, 服务端给过的其他币种也保留下拉) + 每百万输入单价 / 每百万输出单价; 单价非法保存被拦 |
| 套餐 | 「每 5 小时额度(次)」「每周额度(次)」两个整数输入(NULL=未配置, 仅套餐模式保存, 切回其他模式自动清空) + 自动已用统计: 服务商没有公开的额度查询接口, 因为全公司 AI 调用都走平台网关落 `ai_call_logs`, billing GET 自动统计该服务商**近 5 小时 / 近 7 天的成功调用次数**作为已用(`QuotaWindow{key: FIVE_HOURS|WEEKLY, used, quota}`, 状态 LOGGED / NOT_CONFIGURED), 显示「近 5 小时已用 X / Y」「本周已用 X / Y」+ 进度条(≥80% 黄、≥100% 红), 并注明「与服务商侧口径可能略有出入」 |

保存带乐观锁 `version`(别人改过回 409, 面板留原地提示); 再认证由网络层统一密码框完成; 读/写被拒(401/403)说明服务端会话已换人, 面板自行关闭并回调宿主清数据。每次调用开始冻结价格, 后改价不重算旧记录; 未知费用明确待确认, 不同币种分列——按人用量/费用计算口径与改版前一致(实际/估算费用分离、未知 token 不折算、跨币种不合并)。

后端(V826 迁移): `ai_providers` 新增 `billing_quota_5h` / `billing_quota_weekly` 两列(integer, NULL=未配置, 仅 SUBSCRIPTION 模式保存, 切回其他模式自动清空)。

### 安全

1. **读**: 超管 + `authorization:manage` 双闸(服务端 `AiUsageAdminAccess`, 非模拟身份、非锁定); 查看看板、人员详情与使用记录**都记审计事件**(按人用量聚合属敏感管理视图, 照使用审计「查看也记」先例)。
2. **写**: 限额/停用与计费设置保存再叠加 `@RequiresStepUp` 再认证; `rowVersion` / `version` 乐观锁防并发覆盖; 服务端写显式审计(停用、限额与计费变更摘要)。
3. **强制点在服务端**: 停用拦在全部 AI 任务的提交闸、个人 token 限额拦在模型调用网关(与全站预算同点同错码), 前端只是显示; 运行中任务不追溯(提交后才被停用的, 该任务跑完但不能再提交新的)。
4. 零新增权限码; 被停用者看到「管理员已暂停你的 AI 使用, 请联系管理员。」, 不透露操作者。

### 验证(随实现收口)

- `admin_ai_usage_page_test`: fake 仓储 + 守卫断言(非超管拒绝态)、KPI 与预算进度、四窗口切换重新请求、人员表列与状态徽章三态、「跟随全局」显示、限额编辑含 409 与停用二次确认。
- `admin_ai_usage_records_page_test`: 记录页与计费设置——计费保存成功后关闭并刷新数据; 服务商列表读失败时记录照常、计费按钮禁用; 时间按平台北京时间显示; 未知费用保持未知、跨币种不合并; 记录详情展示历史服务商/模型快照; 计费手工编辑用各自返回的乐观 version; 非法单价保存被拦不发写请求; 401/403/404 隐藏旧数据与筛选、计费被拒同样清数据、计费首读失败有明确重试; 三语文案; 390 宽窄屏不溢出。
- 人员详情页测试: 环形进度(个人限额/全站预算两态)、停用横幅、分布与最近使用。
- l10n 三语键齐备; `ai-feature-map` 重生成后 `ai_feature_map_test` 通过。
- 真机联调(服务端完成后): 停用一个测试账号后其 AI 对话与文件识别提交被拦、恢复后可用; 设个人 token 限额后达到即拦且错误文案点名个人限额; 审计中心能查到查看与限额变更事件。
