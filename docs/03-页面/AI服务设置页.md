# AI 服务设置页

> **2026-09-27 新页面(ADR-133 公共 AI 平台)**: 超级管理员在这里选择大模型服务商(DeepSeek、通义千问、Kimi、智谱、火山方舟、硅基流动、本机部署、境外服务商等)、填写接口地址/模型/密钥、测试连接、设为默认、启停并查看近 30 天用量。所有接入公共 AI 平台的功能(目前是销售「识别客户文件」)都只调用这里的**默认服务**, 换服务商不改代码、不重启。

> 路由: `/admin/ai-settings`(`RouteName.adminAiSettings`, `DraftAwareGoRoute`, **不是**表单草稿页)。
> 实现: `lib/features/admin/pages/admin_ai_settings_page.dart`; 组件 `lib/features/admin/widgets/ai_provider_card.dart` / `ai_provider_editor.dart` / `ai_connection_test_view.dart` / `ai_usage_card.dart` / `ai_settings_entry_card.dart` / `ai_settings_labels.dart`; 模型 `lib/features/admin/models/ai_provider_models.dart`; 仓储 `lib/features/admin/repositories/ai_provider_repository.dart`。
> 后端: `server/.../features/ai/provider/`(`AiProviderController` `/api/admin/ai`, `AiProviderService`, `AiEndpointPolicy`, `AiConnectionTester`), 表 `ai_providers` / `ai_call_logs`(V742)。决策: [ADR-133](../99-决策记录-ADR/ADR-133-公共AI平台与服务商可配置.md); 开发接入: [AI 平台接入指南](../05-架构/AI平台接入指南.md); 公共进度弹窗: [AI任务进度弹窗](../02-组件库/AI任务进度弹窗.md)。

---

## 入口

- 唯一入口: 系统设置页的「AI 服务」入口卡(`AiSettingsEntryCard`, 「配置大模型服务商、密钥和连接测试」), 点击 `push` 进入, 返回回到系统设置。设置项加载成功时它是分组卡片网格的首格; 加载中、读取失败或为空时固定在页面顶部整宽。工作台「系统管理」组的「AI 服务」卡片 2026-09-28 已退役(用户口径: AI 服务属于系统设置, 不在工作台单放一张卡)。
- 路由守卫: `/admin/*` 统一要求 `authorization:manage`(`permission_by_path.dart`, 不新增权限码); 服务端 Controller 类级别 `hasAuthority('authorization:manage') and principal.superAdmin`。非超管持有 `authorization:manage` 能进页面, 但首屏读取被拒, 页面显示「只有超级管理员可以查看和修改 AI 服务」。

---

## 页面结构与状态

| 区块 | 内容 |
|---|---|
| 顶部状态 | 渐变卡: 「正在使用: 名称 · 模型」+ 区域标签 + 上次测试(通过/未通过 + 北京时间)。没有服务 →「还没有可用的 AI 服务」+ 下一步说明; 默认服务停用 / 没密钥 / 密钥解不开 → 一句大白话原因 |
| 外呼关闭提示 | 服务器 `uten.ai.outbound-enabled=false`(内部测试环境强制)时黄色提示「配置可以保存, 但不会真正调用」 |
| 服务商卡片 | 预设首字头像(国内青绿 / 境外紫 / 本机蓝渐变, 停用变淡; 字色取主题 `onPrimary`, 深色主题换浅一档渐变保证对比度)、名称、预设名(预设目录缺这条时用服务端 `presetLabel`)、区域标签(国内/境外/本机)、默认徽章、已停用徽章、启用开关; 模型、接口地址、密钥(小徽章「已配置」+ 旁边紧凑显示尾号掩码「••••abcd」(`AiMaskedKey`: 应用字体里「•」是全角, 连写会显示成「• • • •」, 所以圆点画成紧凑小点、读屏仍读掩码原文); 服务端对短密钥不留尾号时只显示「已配置」;「未配置」/「不需要」(区域为本机即不需要)/ 红色「密钥无法解密, 请重新填写」)、上次测试(小徽章只写「通过 / 未通过」, 北京时间写在旁边普通文字里, 窄屏自动换行不被省略号截断); 操作 测试连接 / 编辑 / 设为默认 / 删除(按钮高 48) |
| 空状态 | 「还没有配置 AI 服务」+ 支持哪些服务商 + 「添加 AI 服务」(此时只有这一个添加按钮, 右下悬浮按钮不出现) |
| 近 30 天用量 | 每个服务: 调用次数、成功率、输入 / 输出 token、平均耗时; 读不到只提示「用量暂时读不到, 不影响使用」 |
| 安全说明 | 密钥加密保存只显示尾号; 保存、删除、用已存密钥测试要再次确认登录密码 |
| 右下悬浮 | 红色大按钮「添加 AI 服务」(`UtenFloatingActionGroup`, 正文 200dp 留白); 已有至少一个服务时才出现 |

加载: 首屏骨架(`UtenSkeleton` 顶部条 + 两张卡片轮廓); 已有数据时刷新失败只提示, 保留旧数据。
遮罩: `UtenBusyOverlay` 只包「设为默认 / 启停 / 删除」的纯网络段, 结束即撤再静默刷新; 服务端要求再认证时遮罩自动让位给统一密码框。
动画: 页面上的 AI 徽标静止; 只有进度弹窗里的徽标「呼吸」, 并服从省电档 / 系统减少动画 / TickerMode。
宽屏两列卡片, 窄屏一列; 深色模式、字号放大已用截图夹具核对(`UTEN_UI_FIXTURES=1`)。

---

## 新增 / 编辑面板

宽屏右侧抽屉(560), 窄屏底部弹层; 点空白处不关闭(防止丢掉填了一半的密钥), 右上角关闭。所有字段(含下拉框: 服务商、所在区域、接口协议、JSON 输出方式、关闭深度思考)的名称都在框上方, 说明 ⓘ 在框内。

| 字段 | 说明与约束 |
|---|---|
| 服务商 | 服务端下发的预设(`GET /admin/ai/presets`)。选中后预填接口地址、推荐模型、协议、JSON 方式、关闭深度思考写法、温度、图片识别、区域; **每一项仍可改**。能否选以服务端每项的 `selectable` 为准: 境外未开放时境外预设显示「(境外, 未开放)」, 服务器关闭对外调用时国内预设显示「(暂不可用)」, 都不可选; 下拉框下方逐条列出服务端给的 `unavailableReason`(去重, 带锁图标), 境外相关的完整说明在 ⓘ。新增时默认选第一个能选的预设(外呼关闭的服务器就是本机部署)。编辑时这条配置自己的预设始终可选 |
| 所在区域 | 仅「自定义」显示(国内 / 境外 / 本机); 其他预设区域由服务商决定 |
| 显示名称 | 必填, 最多 64 字, 名称唯一由服务端校验 |
| 接口地址 | 必填, https; 只有本机部署可用 http(如 `http://127.0.0.1:11434/v1`); 不带账号、问号参数和 # 片段; 最终安全判断在服务端 `AiEndpointPolicy`(SSRF、元数据地址、跳转一律拒绝) |
| 模型 | 必填, 最多 128 字; 预设推荐 ≤ 6 个时直接点选(小药丸), 「获取模型」拉服务商列表, 多于 6 个用可搜索下拉; 拿不到列表时显示服务端给的原因(如「这个服务商没有模型列表接口, 请手动填写模型名称」), 没给原因才用通用提示 |
| 密钥 | `UtenInput(isPassword)`, 不接系统自动填充, 过滤空白字符; 新增时按预设必填(区域为本机部署一律不需要, 包括「自定义」选本机; 与服务端 `requiresApiKey(region)` 同口径); 编辑时提示「已配置, 不改就留空」, 不回显原文, 输入框下方一行「当前密钥 ••••abcd」(紧凑掩码)与「清除密钥」按钮; 「清除密钥」(再点撤销)用于本机部署不需要密钥或密钥泄露先撤掉, 清除后该服务不可用直到重新填写; 编辑保存不强制重填密钥 |
| 改了接口地址 | 编辑时协议或规范化地址(协议 + 主机 + 端口 + 路径)变了而旧密钥还在: 显示「改了接口地址, 需要重新填写密钥」, 保存和测试都被拦下, 直到重新填写(或本机部署清除); 服务端同样回 422 |
| 境外确认 | 区域为境外时出现勾选框「客户资料(公司名、货品描述)会发送到境外服务商, 我已确认完成数据出境评估」, 不勾不能保存 |
| 高级设置(默认收起, 收起时箭头朝下、展开后朝上, 与全站 `UtenCollapsibleSection` 一致) | 接口协议(OpenAI 兼容 / Anthropic)、JSON 输出方式、关闭深度思考的写法、固定输出(温度 0)、能识别图片和扫描件、启用、最大输出长度(256 ~ 65536)、超时秒数(10 ~ 600); 高级项有错时保存会自动展开 |

底部两个大按钮(`UtenActionButton`, 高 52, 自带防连点):

- **测试连接**: 本次填了密钥 → `POST /admin/ai/providers/test`(免再认证, 只用本次密钥和当前表单全部设置, 不读已存密钥、不改配置); 没填密钥但已存密钥可用且地址/协议/模型都没改 → `POST /admin/ai/providers/{id}/test`(再认证, 请求体带当前 `{protocol, baseUrl, model}` 让服务端再核对一次, 不一致回 422; 结果记到这条配置上); 改了地址或模型又没填密钥 → 提示「请先保存, 或重新填写密钥再测试」; 改了 JSON 输出方式 / 关闭深度思考 / 固定输出 / 超时又没填密钥 → 提示「高级设置改过了, 用已存的密钥测试不会带上这些改动。请先保存再测试, 或重新填写密钥后测试」(已存密钥的测试只按已保存的设置跑, 不能冒充新设置的结果; 「获取模型」不受这些设置影响, 照常可用); 需要密钥却没有 → 「测试前请先填写密钥」。改了任一会影响测试的项, 旧的测试结果立即清掉。
- **保存**: 新增 `POST /admin/ai/providers`, 编辑 `PUT /admin/ai/providers/{id}`(带打开时的 `version`, 别人改过回 409)。再认证由网络层统一密码框完成, 面板不挂整页遮罩。成功后立即清空密钥输入框、关闭面板、页面静默刷新。

### 连接测试结果

四步竖排: 网络连通 / 密钥验证 / 模型可用 / JSON 输出, 每步按服务端 `status` 显示 ✓ 通过(绿) / ! 需留意(`WARN`, 琥珀色) / ✗ 没通过(红) / 空心圈 未进行(`SKIPPED`), 附耗时(毫秒)和服务端 `message`(大白话, 通过、需留意、未进行也照样显示, 例如「返回了 JSON 但内容和要求不一致, 识别客户文件可能不稳定」「还没有填写模型名称」)。右上徽标与底部总结按总体结论:

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
| `GET /admin/ai/usage?days=30` | - | `UsageView{days, providers: [{providerId, providerName, calls, okCalls, inputTokens, outputTokens, averageLatencyMs}], total, todayTokens, dailyTokenBudget}`(平均耗时也接受 `avgLatencyMs`) |
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

- `flutter test test/features/admin/admin_ai_settings_page_test.dart`: 空状态; 卡片只显示掩码(桌面浅色 / 窄屏深色), 短密钥只显示「已配置」; 解不开的密钥标红, 可不填新密钥直接清除; 卡片测试连接四步 ✓/✗ + 耗时 + 建议; 服务端原样结果: `WARN` 显示黄色「!」+ 说明 + 「需留意」徽标而不是「未进行」, 失败时底部是服务端总结且不在步骤下重复; 编辑改地址 → 提示且保存/测试被拦 → 重新填密钥后带 `version` 保存; 空状态只有一个添加按钮; 卡片与编辑面板的尾号掩码走 `AiMaskedKey`; 高级设置箭头收起朝下、展开朝上; 删除带 `version`; 未改配置用已存密钥测试(带当前地址核对)、改了模型不冒充、改了高级设置不冒充(取模型照常); 空模型列表显示服务端原因; 服务端原样预设: 新增预填 DeepSeek、锁定项列出服务端原因、外呼关闭时默认本机部署且国内预设「暂不可用」; 预设目录缺失时本机服务仍显示「不需要」密钥、就绪且显示预设名; 新增: 预设预填 → 点选模型 → 无密钥不测 → 填密钥测试 → 保存; 境外未开放不可选; 境外开放需勾确认; 非超管提示; 外呼关闭提示; 默认服务不能删; 启停只在网络段挂遮罩。
- `flutter test test/features/admin/ai_masked_key_test.dart`: 掩码圆点紧凑(4 个圆点不到 2 个字宽)、读屏读原文、非圆点掩码原样显示。
- `flutter test test/features/admin/ai_provider_repository_test.dart`: 各端点路径、请求体(空密钥不发、`version`、删除的 `?version=`、`clearApiKey`、境外确认、已存密钥核对体不带密钥)、服务端原样 `PresetsView` / `TestResult`(含 `WARN` / `SKIPPED` / 失败)/ `ModelsResult` 解析、本机与「自定义 + 本机」免密钥口径、非法 id 拒绝、地址规范化。
- `flutter test test/features/admin/ai_settings_entry_test.dart`: 工作台不再出现「AI 服务」卡(退役守卫); 系统设置入口卡的跳转与返回; 系统设置读取失败或没有设置项时入口卡仍在。
- 截图: `UTEN_UI_FIXTURES=1 flutter test test/features/admin/admin_ai_settings_page_test.dart` 输出到 `.codex-tmp/ai-settings-ui/`。
- 真机联调(服务端完成后): 超管账号添加 DeepSeek(或本机 Ollama)→ 测试连接四步全绿 → 设为默认 → 销售账号「识别客户文件」走通; 改接口地址不填密钥保存应被拒(422); 审计中心能查到 `ai_provider.*` 事件且无密钥明文。
