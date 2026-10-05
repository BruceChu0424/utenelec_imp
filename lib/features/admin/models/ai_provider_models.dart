// AI 服务设置页(ADR-133)的客户端模型: 与服务端 /api/admin/ai/* 一一对应。
//
// 安全: 服务端永不下发密钥本身, 只下发「是否已配置 / 尾号掩码 / 能否解密」;
// 本文件里只有 [AiProviderForm.apiKey] 会携带用户本次新填的密钥, 且只用于请求体,
// 不进任何快照、偏好或日志。
library;

/// 服务商所在区域: 国内 / 境外 / 本机部署。
enum AiRegion {
  mainland('MAINLAND'),
  overseas('OVERSEAS'),
  local('LOCAL');

  const AiRegion(this.code);

  final String code;

  static AiRegion parse(Object? raw) => values.firstWhere(
    (value) => value.code == '${raw ?? ''}'.trim().toUpperCase(),
    orElse: () => AiRegion.mainland,
  );
}

/// 接口协议: OpenAI 兼容(绝大多数国内服务商) / Anthropic Messages。
enum AiProtocol {
  openAiChat('OPENAI_CHAT'),
  anthropicMessages('ANTHROPIC_MESSAGES');

  const AiProtocol(this.code);

  final String code;

  static AiProtocol parse(Object? raw) => values.firstWhere(
    (value) => value.code == '${raw ?? ''}'.trim().toUpperCase(),
    orElse: () => AiProtocol.openAiChat,
  );
}

/// 要求模型按 JSON 输出的方式。
enum AiJsonMode {
  none('NONE'),
  jsonObject('JSON_OBJECT'),
  jsonSchema('JSON_SCHEMA');

  const AiJsonMode(this.code);

  final String code;

  static AiJsonMode parse(Object? raw) => values.firstWhere(
    (value) => value.code == '${raw ?? ''}'.trim().toUpperCase(),
    orElse: () => AiJsonMode.jsonObject,
  );
}

/// 思考参数写法(ADR-152): AI 对话的「思考程度」按它发给服务商; 识别表格等用途
/// 仍按它关掉思考。各家参数不同, 选好服务商会自动选对。
enum AiThinkingControl {
  none('NONE'),
  deepseek('DEEPSEEK'),
  dashscope('DASHSCOPE'),
  openAiReasoning('OPENAI_REASONING'),
  zhipu('ZHIPU'),
  anthropicEffort('ANTHROPIC_EFFORT');

  const AiThinkingControl(this.code);

  final String code;

  static AiThinkingControl parse(Object? raw) => values.firstWhere(
    (value) => value.code == '${raw ?? ''}'.trim().toUpperCase(),
    orElse: () => AiThinkingControl.none,
  );
}

/// 最大输出长度与超时秒数的取值范围(与 ai_providers 表 CHECK 一致)。
abstract final class AiProviderLimits {
  static const minOutputTokens = 256;
  static const maxOutputTokens = 65536;
  static const defaultOutputTokens = 8192;
  static const minTimeoutSeconds = 10;
  static const maxTimeoutSeconds = 600;
  static const defaultTimeoutSeconds = 120;
  static const maxNameLength = 64;
  static const maxBaseUrlLength = 512;
  static const maxModelLength = 128;
}

/// 已保存的一个 AI 服务(列表 DTO)。
class AiProviderConfig {
  const AiProviderConfig({
    required this.id,
    required this.name,
    required this.preset,
    required this.region,
    required this.protocol,
    required this.baseUrl,
    required this.model,
    required this.apiKeyConfigured,
    required this.apiKeyMasked,
    required this.apiKeyUnreadable,
    required this.jsonMode,
    required this.thinkingControl,
    required this.sendTemperature,
    required this.supportsVision,
    required this.maxOutputTokens,
    required this.timeoutSeconds,
    required this.enabled,
    required this.isDefault,
    required this.overseasAcknowledged,
    required this.version,
    this.presetLabel,
    this.lastTestAt,
    this.lastTestOk,
    this.lastTestMessage,
    this.updatedAt,
    this.updatedByName,
  });

  factory AiProviderConfig.fromJson(Map<String, dynamic> json) =>
      AiProviderConfig(
        id: '${json['id'] ?? ''}',
        name: '${json['name'] ?? ''}',
        preset: '${json['preset'] ?? 'CUSTOM'}',
        region: AiRegion.parse(json['region']),
        protocol: AiProtocol.parse(json['protocol']),
        baseUrl: '${json['baseUrl'] ?? ''}',
        model: '${json['model'] ?? ''}',
        apiKeyConfigured: json['apiKeyConfigured'] == true,
        apiKeyMasked: _string(json['apiKeyMasked']),
        apiKeyUnreadable: json['apiKeyUnreadable'] == true,
        jsonMode: AiJsonMode.parse(json['jsonMode']),
        thinkingControl: AiThinkingControl.parse(json['thinkingControl']),
        sendTemperature: json['sendTemperature'] != false,
        supportsVision: json['supportsVision'] == true,
        maxOutputTokens:
            (json['maxOutputTokens'] as num?)?.toInt() ??
            AiProviderLimits.defaultOutputTokens,
        timeoutSeconds:
            (json['timeoutSeconds'] as num?)?.toInt() ??
            AiProviderLimits.defaultTimeoutSeconds,
        enabled: json['enabled'] != false,
        isDefault: json['isDefault'] == true,
        overseasAcknowledged: json['overseasAcknowledged'] == true,
        version: (json['version'] as num?)?.toInt() ?? 0,
        presetLabel: _string(json['presetLabel']),
        lastTestAt: _string(json['lastTestAt']),
        lastTestOk: json['lastTestOk'] is bool
            ? json['lastTestOk'] as bool
            : null,
        lastTestMessage: _string(json['lastTestMessage']),
        updatedAt: _string(json['updatedAt']),
        updatedByName: _string(json['updatedByName']),
      );

  final String id;
  final String name;

  /// 预设代码(DEEPSEEK / DASHSCOPE / ... / CUSTOM)。
  final String preset;
  final AiRegion region;
  final AiProtocol protocol;
  final String baseUrl;
  final String model;
  final bool apiKeyConfigured;

  /// 服务端掩码, 如「••••abcd」或「已配置」(短密钥不留尾号)。
  final String? apiKeyMasked;

  /// 密钥来自其他环境或加密钥匙已轮换, 服务端解不开, 需要重新填写。
  final bool apiKeyUnreadable;
  final AiJsonMode jsonMode;
  final AiThinkingControl thinkingControl;
  final bool sendTemperature;
  final bool supportsVision;
  final int maxOutputTokens;
  final int timeoutSeconds;
  final bool enabled;
  final bool isDefault;
  final bool overseasAcknowledged;
  final int version;

  /// 服务端给的预设显示名; 预设目录没加载到时用它兜底, 不直接露出预设代码。
  final String? presetLabel;
  final String? lastTestAt;
  final bool? lastTestOk;
  final String? lastTestMessage;
  final String? updatedAt;
  final String? updatedByName;

  /// 可展示的尾号掩码(如「••••abcd」); 服务端对短密钥只给「已配置」时为 null。
  String? get apiKeyTail {
    final mask = apiKeyMasked;
    if (!apiKeyConfigured || mask == null || !mask.contains('•')) return null;
    return mask;
  }

  /// 这个服务是否必须有密钥(与服务端同口径): 本机部署一律不需要, 其余看预设;
  /// 预设目录没加载到时按「需要」理解。
  bool keyRequiredWith(AiProviderPreset? preset) =>
      region != AiRegion.local && (preset?.requiresApiKey ?? true);

  /// 能真正被调用: 启用 + 有可用密钥(或本就不需要密钥)。
  bool usableWith(AiProviderPreset? preset) =>
      enabled &&
      !apiKeyUnreadable &&
      (apiKeyConfigured || !keyRequiredWith(preset));
}

/// 服务商预设: 只用于新增时预填, 每一项保存前都能改。
class AiProviderPreset {
  const AiProviderPreset({
    required this.code,
    required this.label,
    required this.region,
    required this.protocol,
    required this.baseUrl,
    required this.models,
    required this.jsonMode,
    required this.thinkingControl,
    required this.sendTemperature,
    required this.supportsVision,
    required this.requiresApiKey,
    required this.regionEditable,
    this.selectable,
    this.unavailableReason,
  });

  /// 服务端 `PresetView` 用 `key` 表示预设代码(同时兼容 `preset` / `code`),
  /// 默认地址与推荐模型为 `defaultBaseUrl` / `suggestedModels`。
  factory AiProviderPreset.fromJson(Map<String, dynamic> json) {
    final code = '${json['key'] ?? json['preset'] ?? json['code'] ?? ''}'
        .trim()
        .toUpperCase();
    final models = json['models'] ?? json['suggestedModels'];
    return AiProviderPreset(
      code: code,
      label:
          _string(json['label'] ?? json['name'] ?? json['displayName']) ?? code,
      region: AiRegion.parse(json['region']),
      protocol: AiProtocol.parse(json['protocol']),
      baseUrl: _string(json['baseUrl'] ?? json['defaultBaseUrl']) ?? '',
      models: models is List
          ? [for (final model in models) ?_string(model)]
          : const [],
      jsonMode: AiJsonMode.parse(json['jsonMode']),
      thinkingControl: AiThinkingControl.parse(json['thinkingControl']),
      sendTemperature: json['sendTemperature'] != false,
      supportsVision: json['supportsVision'] == true,
      requiresApiKey: json['requiresApiKey'] != false,
      regionEditable: json['regionEditable'] is bool
          ? json['regionEditable'] as bool
          : code == customCode,
      selectable: json['selectable'] is bool
          ? json['selectable'] as bool
          : null,
      unavailableReason: _string(json['unavailableReason']),
    );
  }

  static const customCode = 'CUSTOM';

  final String code;
  final String label;
  final AiRegion region;
  final AiProtocol protocol;
  final String baseUrl;
  final List<String> models;
  final AiJsonMode jsonMode;
  final AiThinkingControl thinkingControl;
  final bool sendTemperature;
  final bool supportsVision;

  /// 本机部署(Ollama/vLLM)通常不需要密钥。
  final bool requiresApiKey;

  /// 只有「自定义」可以自己选区域; 其他预设的区域由服务商决定。
  final bool regionEditable;

  /// 服务端判定能否新选这个预设(境外未开放、服务器关闭对外调用等);
  /// null = 服务端没说, 由 [AiPresetCatalog.isSelectable] 按区域开关推断。
  final bool? selectable;

  /// 不能选时服务端给的大白话原因。
  final String? unavailableReason;
}

/// `GET /admin/ai/presets`: 预设列表 + 服务器开关。
class AiPresetCatalog {
  const AiPresetCatalog({
    required this.presets,
    required this.allowOverseas,
    required this.allowLanHttp,
    required this.outboundEnabled,
  });

  factory AiPresetCatalog.fromJson(Map<String, dynamic> json) {
    final flags = json['flags'] ?? json['serverFlags'];
    final source = flags is Map<String, dynamic> ? flags : json;
    final raw = json['presets'] ?? json['items'];
    return AiPresetCatalog(
      presets: raw is List
          ? [
              for (final item in raw)
                if (item is Map<String, dynamic>)
                  AiProviderPreset.fromJson(item),
            ].where((preset) => preset.code.isNotEmpty).toList()
          : const [],
      allowOverseas: source['allowOverseas'] == true,
      allowLanHttp: source['allowLanHttp'] == true,
      // 读不到时按「开着」理解: 真正能否外呼始终由服务端判断, 这里只影响提示。
      outboundEnabled: source['outboundEnabled'] != false,
    );
  }

  static const empty = AiPresetCatalog(
    presets: [],
    allowOverseas: false,
    allowLanHttp: false,
    outboundEnabled: true,
  );

  final List<AiProviderPreset> presets;

  /// 服务器是否允许境外服务商(默认关, 部署时显式开启)。
  final bool allowOverseas;
  final bool allowLanHttp;

  /// 服务器是否允许对外调用 AI(内部测试环境强制关)。
  final bool outboundEnabled;

  AiProviderPreset? byCode(String? code) {
    for (final preset in presets) {
      if (preset.code == code) return preset;
    }
    return null;
  }

  /// 能否新选这个预设: 以服务端的 `selectable` 为准; 服务端没给时, 境外预设要等服务器开放。
  bool isSelectable(AiProviderPreset preset) =>
      preset.selectable ??
      (preset.regionEditable ||
          preset.region != AiRegion.overseas ||
          allowOverseas);

  /// 不能选是因为「境外服务商未开放」(用来挑选提示文案与数据出境说明)。
  bool isOverseasLocked(AiProviderPreset preset) =>
      !isSelectable(preset) &&
      preset.region == AiRegion.overseas &&
      !allowOverseas;
}

/// 新增/编辑/测试时提交的表单。
class AiProviderForm {
  const AiProviderForm({
    required this.name,
    required this.preset,
    required this.region,
    required this.protocol,
    required this.baseUrl,
    required this.model,
    this.apiKey,
    this.clearApiKey = false,
    required this.jsonMode,
    required this.thinkingControl,
    required this.sendTemperature,
    required this.supportsVision,
    required this.maxOutputTokens,
    required this.timeoutSeconds,
    required this.enabled,
    required this.overseasAcknowledged,
  });

  final String name;
  final String preset;
  final AiRegion region;
  final AiProtocol protocol;
  final String baseUrl;
  final String model;

  /// 本次新填写的密钥; 空 = 不改(编辑时保留原密钥)。
  final String? apiKey;
  final bool clearApiKey;
  final AiJsonMode jsonMode;
  final AiThinkingControl thinkingControl;
  final bool sendTemperature;
  final bool supportsVision;
  final int maxOutputTokens;
  final int timeoutSeconds;
  final bool enabled;
  final bool overseasAcknowledged;

  bool get hasNewApiKey => (apiKey ?? '').trim().isNotEmpty;

  /// 请求体。密钥只在本次确实新填了才带上; [version] 仅编辑保存时传。
  Map<String, dynamic> toJson({int? version}) => {
    'name': name.trim(),
    'preset': preset,
    'region': region.code,
    'protocol': protocol.code,
    'baseUrl': baseUrl.trim(),
    'model': model.trim(),
    if (hasNewApiKey) 'apiKey': apiKey!.trim(),
    if (clearApiKey && !hasNewApiKey) 'clearApiKey': true,
    'jsonMode': jsonMode.code,
    'thinkingControl': thinkingControl.code,
    'sendTemperature': sendTemperature,
    'supportsVision': supportsVision,
    'maxOutputTokens': maxOutputTokens,
    'timeoutSeconds': timeoutSeconds,
    'enabled': enabled,
    'overseasAcknowledged': region == AiRegion.overseas && overseasAcknowledged,
    'version': ?version,
  };

  /// 用本次新填密钥测试 / 取模型的请求体(服务端 ProbeRequest): 只带探测要用的字段,
  /// 不带名称、启用、最大输出长度等保存用字段; 密钥同样只在新填了才带。
  Map<String, dynamic> toProbeJson() => {
    'preset': preset,
    'region': region.code,
    'protocol': protocol.code,
    'baseUrl': baseUrl.trim(),
    'model': model.trim(),
    if (hasNewApiKey) 'apiKey': apiKey!.trim(),
    'jsonMode': jsonMode.code,
    'thinkingControl': thinkingControl.code,
    'sendTemperature': sendTemperature,
    'timeoutSeconds': timeoutSeconds,
    'overseasAcknowledged': region == AiRegion.overseas && overseasAcknowledged,
  };
}

/// 规范化接口地址, 用于判断「接口地址是否改了」(与服务端同口径: 协议 + 主机 + 端口 + 路径)。
///
/// 解析不了返回去掉首尾空白与末尾斜杠的原文。
String normalizeAiBaseUrl(String raw) {
  var text = raw.trim();
  while (text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  final uri = Uri.tryParse(text);
  if (uri == null || !uri.hasScheme || uri.host.isEmpty) return text;
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return '${uri.scheme.toLowerCase()}://${uri.host.toLowerCase()}:${uri.port}$path';
}

/// 连接测试的一步: 网络连通 / 密钥验证 / 模型可用 / JSON 输出。
class AiConnectionTestStep {
  const AiConnectionTestStep({
    required this.key,
    required this.status,
    this.label,
    this.latencyMs,
    this.message,
    this.advice,
  });

  factory AiConnectionTestStep.fromJson(Map<String, dynamic> json) {
    final rawStatus = '${json['status'] ?? ''}'.toUpperCase();
    final ok = json['ok'];
    final status = switch (rawStatus) {
      'OK' || 'PASSED' || 'SUCCESS' => AiTestStepStatus.passed,
      'WARN' || 'WARNING' => AiTestStepStatus.warning,
      'FAILED' || 'FAIL' || 'ERROR' => AiTestStepStatus.failed,
      'SKIPPED' || 'SKIP' => AiTestStepStatus.skipped,
      _ =>
        ok == true
            ? AiTestStepStatus.passed
            : ok == false
            ? AiTestStepStatus.failed
            : AiTestStepStatus.skipped,
    };
    return AiConnectionTestStep(
      key: '${json['key'] ?? json['step'] ?? json['name'] ?? ''}'.toUpperCase(),
      status: status,
      label: _string(json['label']),
      latencyMs: (json['latencyMs'] as num?)?.toInt(),
      message: _string(json['message']),
      advice: _string(json['advice']),
    );
  }

  static const network = 'NETWORK';
  static const auth = 'AUTH';
  static const model = 'MODEL';
  static const json = 'JSON';

  /// Only reported when the provider can adjust thinking depth (ADR-152), so
  /// it is not part of the fixed [order].
  static const thinking = 'THINKING';

  /// 固定展示顺序。
  static const order = [network, auth, model, json];

  final String key;
  final AiTestStepStatus status;

  /// 服务端给的名称(未知步骤时使用)。
  final String? label;
  final int? latencyMs;
  final String? message;

  /// 大白话建议, 例如「请检查密钥是否复制完整」。服务端目前把建议直接写进 [message],
  /// 这里留给单独下发建议的实现。
  final String? advice;
}

/// 单步结果: 通过 / 能用但要留意(服务端 WARN) / 没通过 / 没进行。
enum AiTestStepStatus { passed, warning, failed, skipped }

/// 一次连接测试的总体结论。
enum AiTestOutcome {
  /// 每一步都通过。
  passed,

  /// 连上了, 但有要留意的地方(某步 WARN, 或有步骤没进行, 例如还没填模型)。
  warning,

  /// 有步骤没通过。
  failed,
}

/// `POST /admin/ai/providers[/{id}]/test` 的结果。
class AiConnectionTestResult {
  const AiConnectionTestResult({
    required this.ok,
    required this.steps,
    this.message,
    this.latencyMs,
    this.testedAt,
  });

  /// 服务端 `TestResult`: `{ok, summary, steps: [{key, status: OK|FAILED|SKIPPED|WARN,
  /// message, latencyMs}], testedAt}`; 也接受 `message` 作总结。

  factory AiConnectionTestResult.fromJson(Map<String, dynamic> json) {
    final raw = json['steps'];
    final steps = raw is List
        ? [
            for (final item in raw)
              if (item is Map<String, dynamic>)
                AiConnectionTestStep.fromJson(item),
          ]
        : <AiConnectionTestStep>[];
    final ok = json['ok'] is bool
        ? json['ok'] as bool
        : steps.isNotEmpty &&
              steps.every((step) => step.status != AiTestStepStatus.failed);
    return AiConnectionTestResult(
      ok: ok,
      steps: steps,
      message: _string(json['summary'] ?? json['message']),
      latencyMs: (json['latencyMs'] as num?)?.toInt(),
      testedAt: _string(json['testedAt']),
    );
  }

  final bool ok;
  final List<AiConnectionTestStep> steps;

  /// 服务端的一句话总结(如「连接成功, 但有需要注意的地方」; 失败时是第一条失败原因)。
  final String? message;
  final int? latencyMs;
  final String? testedAt;

  /// 按固定顺序补齐四步(服务端没报告的步骤视为未进行), 其余未知步骤排在后面。
  List<AiConnectionTestStep> get orderedSteps {
    final byKey = {for (final step in steps) step.key: step};
    return [
      for (final key in AiConnectionTestStep.order)
        byKey[key] ??
            AiConnectionTestStep(key: key, status: AiTestStepStatus.skipped),
      for (final step in steps)
        if (!AiConnectionTestStep.order.contains(step.key)) step,
    ];
  }

  /// 第一条失败步骤(用来给出总的建议)。
  AiConnectionTestStep? get firstFailure {
    for (final step in orderedSteps) {
      if (step.status == AiTestStepStatus.failed) return step;
    }
    return null;
  }

  /// 服务端报告了要留意的步骤(WARN)。
  bool get hasWarnings =>
      steps.any((step) => step.status == AiTestStepStatus.warning);

  /// 总体结论: 有失败步骤即失败; 服务端判不通过但只是有步骤没进行(如还没填模型)
  /// 或有 WARN 时为「要留意」; 什么都没报告又不通过按失败。
  AiTestOutcome get outcome {
    if (firstFailure != null) return AiTestOutcome.failed;
    if (!ok) {
      final reported = steps.any(
        (step) =>
            step.status == AiTestStepStatus.skipped ||
            step.status == AiTestStepStatus.warning,
      );
      return reported ? AiTestOutcome.warning : AiTestOutcome.failed;
    }
    return hasWarnings ? AiTestOutcome.warning : AiTestOutcome.passed;
  }
}

/// 「获取模型」的结果(服务端 `ModelsResult`): 拿不到列表时 [message] 说明原因, 仍可手填模型名。
class AiModelList {
  const AiModelList({required this.models, this.message});

  /// `{models: ["a", "b"], message}`; 也接受 `[{id: "a"}]` / `data` 形态, 去重并保持服务端顺序。
  factory AiModelList.fromJson(Map<String, dynamic> json) {
    final raw = json['models'] ?? json['data'];
    final seen = <String>{};
    return AiModelList(
      models: raw is List
          ? [
              for (final item in raw)
                if (_modelName(item) case final name? when seen.add(name)) name,
            ]
          : const [],
      message: _string(json['message']),
    );
  }

  final List<String> models;

  /// 服务端说明为什么没有列表(如「这个服务商没有模型列表接口, 请手动填写模型名称」)。
  final String? message;

  static String? _modelName(Object? item) =>
      _string(item is Map ? (item['id'] ?? item['name']) : item);
}

/// 近 N 天某个服务的调用统计(`GET /admin/ai/usage`)。
class AiProviderUsage {
  const AiProviderUsage({
    required this.providerId,
    required this.providerName,
    required this.calls,
    required this.okCalls,
    required this.inputTokens,
    required this.outputTokens,
    this.avgLatencyMs,
  });

  factory AiProviderUsage.fromJson(Map<String, dynamic> json) =>
      AiProviderUsage(
        providerId: _string(json['providerId']),
        providerName: _string(json['providerName']) ?? '',
        calls: _int(json['calls'] ?? json['callCount']),
        okCalls: _int(json['okCalls'] ?? json['successCount']),
        inputTokens: _int(json['inputTokens']),
        outputTokens: _int(json['outputTokens']),
        avgLatencyMs: (json['avgLatencyMs'] ?? json['averageLatencyMs']) is num
            ? ((json['avgLatencyMs'] ?? json['averageLatencyMs']) as num)
                  .toInt()
            : null,
      );

  final String? providerId;
  final String providerName;
  final int calls;
  final int okCalls;
  final int inputTokens;
  final int outputTokens;
  final int? avgLatencyMs;

  /// 成功率(0-1); 没调用过时为 null。
  double? get successRate => calls <= 0 ? null : okCalls / calls;
}

class AiUsageSummary {
  const AiUsageSummary({required this.days, required this.providers});

  factory AiUsageSummary.fromJson(Map<String, dynamic> json) {
    final raw = json['providers'] ?? json['items'];
    return AiUsageSummary(
      days: (json['days'] as num?)?.toInt() ?? 30,
      providers: raw is List
          ? [
              for (final item in raw)
                if (item is Map<String, dynamic>)
                  AiProviderUsage.fromJson(item),
            ]
          : const [],
    );
  }

  final int days;
  final List<AiProviderUsage> providers;

  AiProviderUsage? forProvider(AiProviderConfig provider) {
    for (final usage in providers) {
      if (usage.providerId == provider.id) return usage;
    }
    return null;
  }
}

String? _string(Object? raw) {
  if (raw == null) return null;
  final text = '$raw'.trim();
  return text.isEmpty ? null : text;
}

int _int(Object? raw) => raw is num ? raw.toInt() : 0;
