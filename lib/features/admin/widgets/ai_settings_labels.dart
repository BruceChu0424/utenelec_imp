// AI 服务设置页的枚举 → 当前语言文案(只放显示用的映射, 不含业务判断)。
import 'package:flutter/widgets.dart';

import '../../../components/data_display/uten_status_badge.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../models/ai_provider_models.dart';

extension AiRegionLabel on AiRegion {
  String label(AppLocalizations l10n) => switch (this) {
    AiRegion.mainland => l10n.aiSettingsRegionMainland,
    AiRegion.overseas => l10n.aiSettingsRegionOverseas,
    AiRegion.local => l10n.aiSettingsRegionLocal,
  };

  UtenStatusBadgeType get badgeType => switch (this) {
    AiRegion.mainland => UtenStatusBadgeType.accent,
    AiRegion.overseas => UtenStatusBadgeType.violet,
    AiRegion.local => UtenStatusBadgeType.info,
  };
}

extension AiProtocolLabel on AiProtocol {
  String label(AppLocalizations l10n) => switch (this) {
    AiProtocol.openAiChat => l10n.aiSettingsProtocolOpenAi,
    AiProtocol.anthropicMessages => l10n.aiSettingsProtocolAnthropic,
  };
}

extension AiJsonModeLabel on AiJsonMode {
  String label(AppLocalizations l10n) => switch (this) {
    AiJsonMode.none => l10n.aiSettingsJsonModeNone,
    AiJsonMode.jsonObject => l10n.aiSettingsJsonModeObject,
    AiJsonMode.jsonSchema => l10n.aiSettingsJsonModeSchema,
  };
}

extension AiThinkingControlLabel on AiThinkingControl {
  String label(AppLocalizations l10n) => switch (this) {
    AiThinkingControl.none => l10n.aiSettingsThinkingNone,
    AiThinkingControl.deepseek => l10n.aiSettingsThinkingDeepseek,
    AiThinkingControl.dashscope => l10n.aiSettingsThinkingDashscope,
    AiThinkingControl.openAiReasoning => l10n.aiSettingsThinkingOpenAi,
  };
}

/// 连接测试步骤名称; 未知步骤用服务端给的名称。
String aiTestStepLabel(AppLocalizations l10n, AiConnectionTestStep step) =>
    switch (step.key) {
      AiConnectionTestStep.network => l10n.aiSettingsStepNetwork,
      AiConnectionTestStep.auth => l10n.aiSettingsStepAuth,
      AiConnectionTestStep.model => l10n.aiSettingsStepModel,
      AiConnectionTestStep.json => l10n.aiSettingsStepJson,
      _ => step.label ?? step.key,
    };

/// 预设显示名: 优先预设目录, 其次服务端随配置下发的 [fallback](`presetLabel`), 最后才是代码。
String aiPresetLabel(
  AiPresetCatalog catalog,
  String code, {
  String? fallback,
}) => catalog.byCode(code)?.label ?? fallback ?? code;

/// 头像上显示的一个字: 英文取首字母大写, 中文取第一个字。
String aiAvatarInitial(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 'AI';
  final first = trimmed.characters.first;
  return first.toUpperCase();
}
