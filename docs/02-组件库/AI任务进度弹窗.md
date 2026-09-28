# AI 任务进度弹窗(公共 AI 前端套件)

> 2026-09-27 新增(ADR-133 公共 AI 平台)。代码在 `lib/shared/ai/`(共享层, 不属于任何 feature, 任何模块都能用, 不会增加 feature 之间的依赖边)。
> 服务端对应: 作业接口 `/api/ai/jobs`(`features/ai/job`), 开发者接入步骤见 [AI 平台接入指南](../05-架构/AI平台接入指南.md); 管理员配置页见 [AI 服务设置页](../03-页面/AI服务设置页.md)。
> 第一个接入方: 销售报价单 / 订货单「识别客户文件」(`lib/features/sales/intake/`)。

## 一句话

把「上传一个文件 → 服务端排队识别 → 前端轮询进度 → 拿到结果」这一整套做成公共件: 业务页只描述**提交什么**和**有哪几步**, 其余(上传、轮询节奏、超时、取消、进度弹窗、错误文案、性能档)都由套件负责。

## 文件与公开 API

| 文件 | 公开名称 | 作用 |
|---|---|---|
| `ai_job_models.dart` | `AiJobRequest{kind, params, bytes, fileName, contentType}` | 一次提交: 原始字节直接上传(不走附件通道), `params` 作为查询参数, `kind` 为保留键 |
| | `AiJobSnapshot{id, kind, status, stage, progress, result, errorCode, errorMessage, createdAt, startedAt, finishedAt}` | 与 `GET /api/ai/jobs/{id}` 一一对应; `AiJobSnapshot.uploadingStage = 'UPLOADING'` 是客户端「上传文件」阶段 |
| | `AiJobStatus` | pending / running / succeeded / failed / cancelled, `isTerminal` |
| | `AiJobCancelToken` | `cancel()` / `isCancelled` / `whenCancelled`(轮询等待中立即醒来) |
| | `AiJobFailure{message, code, snapshot, clientMessage}` | 作业没成功; `message` 可直接展示。客户端代码: `codeCancelled` / `codeClientTimeout` / `codeJobGone` / `codeFailed`, 其余为服务端 `errorCode`; `clientMessage=true` 表示文案是客户端兜底(服务端没给原因), 经进度弹窗抛出时换成当前语言 |
| `ai_job_repository.dart` | `AiJobRepository` / `aiJobRepositoryProvider` | `submit` = `POST /ai/jobs?kind=..&<params>`(octet-stream, 请求头 `X-Uten-File-Name` 百分号编码、`X-Uten-File-Type`, 上传时限 3 分钟); `get`; `cancel` = `POST /ai/jobs/{id}/cancel` |
| `ai_job_runner.dart` | `AiJobRunner` / `aiJobRunnerProvider` | `run(request, onProgress:, cancelToken:)` 提交并轮询; `resume(jobId, ...)` 只轮询已有作业(如订货单转报价单复用同一次识别) |
| `ai_progress_dialog.dart` | `showAiProgressDialog(context, title:, subtitle:, stages:, task:)` | 公共进度弹窗; 返回终态快照, 用户取消返回 null, 失败把异常抛给调用方 |
| | `runAiJob(context, runner:, request:, title:, subtitle:, stages:)` | 最常用组合: runner.run + 进度弹窗 |
| | `AiProgressStage{key, label, serverStages}` | 弹窗里的一步, `serverStages` 是这一步覆盖的服务端阶段键 |
| | `AiSparkleBadge` / `aiMotionAllowed(context)` | 品牌青绿渐变 AI 徽标(可选「呼吸」动画)与动画开关判定 |
| `ai_status_provider.dart` | `aiStatusProvider` → `AiStatus{available, aiAllowedForMe, supportsVision, usable}` | `GET /ai/status`; 读取失败一律当作「AI 未开启」, 不打扰用户 |
| `ai_confidence_pill.dart` | `AiConfidencePill(confidence:)` / `AiConfidence.parse('HIGH'/'MEDIUM'/'LOW')` | 把握程度药丸: 把握高(绿)/ 把握中(琥珀)/ 把握低(红), 只分三档不显示分数 |

## 轮询与失败规则(AiJobRunner)

- 进度回调第一条是客户端「上传文件」快照(id 为空), 拿到作业 id 即表示上传完成。
- 节奏: 前 10 秒每 1 秒查一次, 之后每 2 秒; 最长 5 分钟, 超时后请求服务端取消并抛 `codeClientTimeout`。
- 偶发一次查询失败只跳过这一拍, 连续 3 次失败才把 `ApiException` 抛出; 作业不存在(404)抛 `codeJobGone`「这次处理的任务已不存在(可能已被清理), 请重新开始」。
- 提交被拒(没有业务权限 403、文件太大 413、同时识别太多 429、切换人只读 403)原样抛服务端 `ApiException`, 用 `context.appApiError` 展示。
- 服务端失败: `AiJobFailure(message: 服务端大白话原因, code: errorCode)`; 没给原因时用「处理没有成功, 请稍后重试」并标 `clientMessage`。
- 套件自带的文案(超时 / 作业不存在 / 兜底失败 / 已取消)都不绑定具体业务(不写「识别」), 且都标 `clientMessage`; 经进度弹窗抛出时换成当前语言(`aiJobTimeout` / `aiJobGone` / `aiJobFailedGeneric`)。直接调 `run` 不经弹窗的调用方拿到的是中文兜底, 需要多语言时自己按 `code` / `clientMessage` 换文案。
- 重复提交同一文件(服务端 10 分钟幂等)可能直接拿回已结束的作业, 成功态会立即再取一次结果, 不等待。
- 取消: 令牌取消后立即醒来, 尽力通知服务端取消(失败不影响本地结束, 服务端还有租约和清理兜底)。
- 构造参数 `sleep:` / `now:` 可注入假时钟, 测试不真等。

## 弹窗行为(showAiProgressDialog)

- 模态卡片, 圆角沿用主题对话框 18, 最宽 440; 点空白不关闭; 系统返回键 = 取消。
- 头部: AI 徽标(品牌青绿渐变 + 闪光图标, 允许动画时轻微呼吸)+ 标题 + 副标题(一般放文件名)。
- 细进度条: 取服务端 `progress` 与「当前步 / 总步数」的较大值, 平滑前进; 省电档直接跳到位。
- 分步时间线: 已完成 ✓(成功色)/ 当前转圈(带底圈)/ 未开始空心圈; **阶段只进不退**, 服务端未登记的阶段键保持当前一步。
- 排队提示: 拿到作业 id 但还在 PENDING 时显示「正在排队, 马上开始」; 超过 30 秒显示「内容较多时需要一两分钟, 请耐心等待, 不用重复点」。
- 底部: 「已用时 m:ss」+ 「取消」(按钮高 48, 适老化触控基线)。点取消**立即关闭并返回 null**, 作业在后台被取消。
- 成功立即关闭并返回终态快照(没有额外延时, 调用方测试 `pumpAndSettle` 即可); 失败关闭后抛出 `AiJobFailure`(客户端超时 / 作业不存在 / 兜底失败换成当前语言文案, 服务端原话不动)或原始异常。
- 只关自己: 作业结束时如果上面又压了别的根导航弹窗(如会话过期后的重新登录框), 弹窗按自己的路由精确移除(`removeRoute`), 不会误关上面的框, 结果照样交回调用方。
- 弹窗在根导航上: **不要**同时挂 `UtenBusyOverlay`(遮罩会盖住它); 弹窗关闭后再推路由/弹下一个面板。
- 无障碍: 当前步骤名作为 liveRegion 播报; 取消按钮与计时有语义。

## 性能档

循环动画只有两处: AI 徽标呼吸与当前步转圈。徽标呼吸同时服从 `performanceProvider`(省电档静止)、系统「减少动画」和祖先 `TickerMode`, 用户切换性能档立即生效; 还没注入偏好时(测试或极早期)按标准档处理且不报错。页面上的静态 AI 徽标请传 `animate: false`, 不要在常驻页面放循环动画。

## 用法(以后接入其他功能照抄)

```dart
// 1. 可选: AI 没开时给出提示或走不依赖 AI 的路径(真正提交时服务端仍会独立判断)。
final status = await ref.read(aiStatusProvider.future);

// 2. 提交 + 弹窗等待。stages 的 serverStages 与服务端 AiJobHandler 上报的阶段键对齐。
try {
  final snapshot = await runAiJob(
    context,
    runner: ref.read(aiJobRunnerProvider),
    request: AiJobRequest(
      kind: 'SALES_DOCUMENT_INTAKE',
      params: {'docType': 'order'},
      bytes: file.bytes!,
      fileName: file.name,
      contentType: mimeType,
    ),
    title: '正在识别客户文件',
    subtitle: file.name,
    stages: const [
      AiProgressStage(key: AiJobSnapshot.uploadingStage, label: '上传文件'),
      AiProgressStage(key: 'READ', label: '读取表格', serverStages: ['READING']),
      AiProgressStage(key: 'MATCH', label: '匹配货品', serverStages: ['MATCHING_GOODS']),
    ],
  );
  if (snapshot == null || !context.mounted) return; // 用户取消
  final result = snapshot.result!; // 按本功能自己的结果契约解析
} on AiJobFailure catch (failure) {
  if (context.mounted) context.appError(failure.message);
} on ApiException catch (error) {
  if (context.mounted) context.appApiError(error);
}
```

需要自己控制提交与轮询(例如复用已有作业)时用 `showAiProgressDialog(..., task: (onProgress, token) => runner.resume(jobId, onProgress: onProgress, cancelToken: token))`。

## 注意

- 结果只在作业成功后短时间保留(服务端 48 小时, 用过即清), 业务页拿到后应立即转成自己的界面状态; 不要把整份结果写进表单草稿以外的地方。
- 作业结果属于提交人本人, 换账号或权限变化后读取会失败, 需要重新识别。
- 提交与取消不算业务写操作(`data_write_revision.dart` 已登记自动写路径), 不会触发全站「返回即刷新」。
- 面向业务人员的文案不出现「置信度 / 模型 / 服务商」等技术词。

## 测试

- `test/shared/ai/ai_job_runner_test.dart`: 进度序列、1s/2s 节奏、失败原因、取消(等待中立即醒来、提交前取消不上传)、5 分钟超时、偶发/连续查询失败、作业消失、提交被拒、幂等已完成、resume、服务端取消。
- `test/shared/ai/ai_progress_dialog_test.dart`: 标题/步骤/计时、阶段只进不退、排队与慢提示、取消(按钮高 ≥ 48)与系统返回、失败与超时文案、兜底失败换成当前语言且保留服务端错误码、上面压着别的弹窗时只关自己、提交被拒原样抛出、`runAiJob` 串真实 runner、徽标动画服从性能档与系统减少动画、把握药丸三档配色。
- `test/shared/ai/ai_job_repository_test.dart`: 提交的查询参数/请求头/时限、保留键、非法 id、`ApiClient.postBytes` 透传到 Dio、写修订号自动路径、`aiStatusProvider` 失败降级。
- 业务方测试请注入假 `AiJobRepository`(或 `AiJobRunner(sleep: (_) async {})`), 不要真等轮询。
