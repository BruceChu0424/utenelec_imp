// 新增 / 编辑 AI 服务面板(宽屏右侧抽屉, 窄屏底部弹层)。
//
// 安全(ADR-133):
// - 密钥输入框只写不读: 编辑时显示服务端掩码「已配置 ••••abcd, 不改就留空」, 不回显原文;
//   不接系统自动填充, 不进表单草稿/偏好/日志, 保存成功后立即清空输入框。
// - 改了接口地址或协议而旧密钥还在: 必须重新填写密钥(或本机部署清除密钥), 服务端同样拒绝(422),
//   已存密钥只会发往原来的地址。
// - 境外服务商: 服务器没开放时不能选; 开放了也要勾选数据出境确认才能保存。
// - 保存与「用已存密钥测试」由服务端要求再认证, 网络层弹统一密码框, 本面板不挂整页遮罩。
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../components/buttons/click_guard.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/feedback/uten_inline_notice.dart';
import '../../../components/inputs/required_field_decoration.dart';
import '../../../components/inputs/uten_dropdown_field.dart';
import '../../../components/inputs/uten_input.dart';
import '../../../components/layout/uten_adaptive_panel.dart';
import '../../../components/layout/uten_collapsible_section.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_anim.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../core/ui/app_notification.dart';
import '../../../shared/ai/ai_progress_dialog.dart';
import '../models/ai_provider_models.dart';
import '../repositories/ai_provider_repository.dart';
import 'ai_connection_test_view.dart';
import 'ai_masked_key.dart';
import 'ai_settings_labels.dart';

/// 打开新增([existing] 为空)或编辑面板; 面板关闭后返回是否保存过。
Future<bool> showAiProviderEditor(
  BuildContext context, {
  required AiPresetCatalog catalog,
  AiProviderConfig? existing,
}) async {
  final saved = await showUtenAdaptivePanel<bool>(
    context: context,
    drawerWidth: 560,
    compactHeightFactor: 0.94,
    // 填了一半的密钥不该被误点空白处丢掉; 关闭走右上角按钮。
    barrierDismissible: false,
    enableDrag: false,
    builder: (_) => AiProviderEditor(catalog: catalog, existing: existing),
  );
  return saved == true;
}

enum _Probe {
  form,
  stored,
  needKey,
  storedMismatch,
  storedUnsavedAdvanced,
  overseasBlocked,
}

class AiProviderEditor extends ConsumerStatefulWidget {
  const AiProviderEditor({super.key, required this.catalog, this.existing});

  final AiPresetCatalog catalog;
  final AiProviderConfig? existing;

  @override
  ConsumerState<AiProviderEditor> createState() => _AiProviderEditorState();
}

class _AiProviderEditorState extends ConsumerState<AiProviderEditor> {
  final _formKey = GlobalKey<FormState>();

  /// 面板底部的探测反馈(提示条 / 连接测试结果): 出现或更新时滚到能看见的位置,
  /// 否则点了底栏「测试连接」, 结果落在滚动区下方, 用户以为没反应。
  final _probeFeedbackKey = GlobalKey();
  late final TextEditingController _name;
  late final TextEditingController _baseUrl;
  late final TextEditingController _model;
  final TextEditingController _apiKey = TextEditingController();
  late final TextEditingController _maxTokens;
  late final TextEditingController _timeout;

  late String _preset;
  late AiRegion _region;
  late AiProtocol _protocol;
  late AiJsonMode _jsonMode;
  late AiThinkingControl _thinking;
  late bool _sendTemperature;
  late bool _supportsVision;
  late bool _enabled;
  late bool _overseasAck;
  bool _clearKey = false;
  bool _advancedOpen = false;
  bool _submitted = false;
  bool _testing = false;
  bool _loadingModels = false;
  bool _closing = false;
  List<String> _models = const [];
  AiConnectionTestResult? _testResult;
  String? _probeNotice;

  AiProviderConfig? get _existing => widget.existing;
  bool get _editing => _existing != null;

  List<AiProviderPreset> get _presets => widget.catalog.presets;

  AiProviderPreset? get _currentPreset => widget.catalog.byCode(_preset);

  @override
  void initState() {
    super.initState();
    final existing = _existing;
    if (existing != null) {
      _name = TextEditingController(text: existing.name);
      _baseUrl = TextEditingController(text: existing.baseUrl);
      _model = TextEditingController(text: existing.model);
      _maxTokens = TextEditingController(text: '${existing.maxOutputTokens}');
      _timeout = TextEditingController(text: '${existing.timeoutSeconds}');
      _preset = existing.preset;
      _region = existing.region;
      _protocol = existing.protocol;
      _jsonMode = existing.jsonMode;
      _thinking = existing.thinkingControl;
      _sendTemperature = existing.sendTemperature;
      _supportsVision = existing.supportsVision;
      _enabled = existing.enabled;
      _overseasAck = existing.overseasAcknowledged;
      _models = _currentPreset?.models ?? const [];
    } else {
      _name = TextEditingController();
      _baseUrl = TextEditingController();
      _model = TextEditingController();
      _maxTokens = TextEditingController(
        text: '${AiProviderLimits.defaultOutputTokens}',
      );
      _timeout = TextEditingController(
        text: '${AiProviderLimits.defaultTimeoutSeconds}',
      );
      _region = AiRegion.mainland;
      _protocol = AiProtocol.openAiChat;
      _jsonMode = AiJsonMode.jsonObject;
      _thinking = AiThinkingControl.none;
      _sendTemperature = true;
      _supportsVision = false;
      _enabled = true;
      _overseasAck = false;
      _preset = AiProviderPreset.customCode;
      final first = _presets.where(_presetSelectable).firstOrNull;
      if (first != null) _fillFromPreset(first, previousLabel: null);
    }
    // 地址与密钥的变化会影响「需要重新填写密钥」提示和测试方式。
    _baseUrl.addListener(_onEndpointOrKeyChanged);
    _apiKey.addListener(_onEndpointOrKeyChanged);
  }

  @override
  void dispose() {
    _baseUrl.removeListener(_onEndpointOrKeyChanged);
    _apiKey.removeListener(_onEndpointOrKeyChanged);
    // 密钥不在内存里多留一刻。
    _apiKey.clear();
    for (final controller in [
      _name,
      _baseUrl,
      _model,
      _apiKey,
      _maxTokens,
      _timeout,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onEndpointOrKeyChanged() {
    if (!mounted) return;
    // 测试结果只对应当时的地址和密钥。
    setState(_clearProbeState);
  }

  /// 测试结果与「为什么测不了」都只对应改动前的设置。
  void _clearProbeState() {
    _testResult = null;
    _probeNotice = null;
  }

  /// 服务端说能选(或推断能选), 或者就是这条配置已保存的预设(编辑时不能把自己锁掉)。
  bool _presetSelectable(AiProviderPreset preset) =>
      widget.catalog.isSelectable(preset) || preset.code == _existing?.preset;

  /// 不能选的预设的原因(去重): 服务端给的原因优先, 没给时境外预设用本地说明。
  List<String> _lockedReasons(AppLocalizations l10n) {
    final reasons = <String>{};
    for (final preset in _presets) {
      if (_presetSelectable(preset)) continue;
      final reason =
          preset.unavailableReason ??
          (widget.catalog.isOverseasLocked(preset)
              ? l10n.aiSettingsOverseasLockedShort
              : null);
      if (reason != null) reasons.add(reason);
    }
    return reasons.toList();
  }

  void _fillFromPreset(
    AiProviderPreset preset, {
    required String? previousLabel,
  }) {
    final name = _name.text.trim();
    if (name.isEmpty || name == previousLabel) _name.text = preset.label;
    _preset = preset.code;
    _baseUrl.text = preset.baseUrl;
    _model.text = preset.models.isEmpty ? '' : preset.models.first;
    _models = preset.models;
    _protocol = preset.protocol;
    _jsonMode = preset.jsonMode;
    _thinking = preset.thinkingControl;
    _sendTemperature = preset.sendTemperature;
    _supportsVision = preset.supportsVision;
    if (!preset.regionEditable) {
      _region = preset.region;
    } else if (_region == AiRegion.overseas && !widget.catalog.allowOverseas) {
      _region = AiRegion.mainland;
    }
    _testResult = null;
    _probeNotice = null;
  }

  void _onPresetChanged(String? code) {
    final preset = widget.catalog.byCode(code);
    if (preset == null || preset.code == _preset) return;
    setState(
      () => _fillFromPreset(preset, previousLabel: _currentPreset?.label),
    );
  }

  bool get _hasNewKey => _apiKey.text.trim().isNotEmpty;

  /// 协议或规范化后的接口地址与已保存的不同。
  bool get _endpointChanged {
    final existing = _existing;
    if (existing == null) return false;
    return _protocol != existing.protocol ||
        normalizeAiBaseUrl(_baseUrl.text) !=
            normalizeAiBaseUrl(existing.baseUrl);
  }

  /// 改了地址但旧密钥还在、又没填新密钥也没清除: 不能保存。
  bool get _needsNewKey =>
      _endpointChanged &&
      (_existing?.apiKeyConfigured ?? false) &&
      !_hasNewKey &&
      !_clearKey;

  /// 这一项必须有密钥(本机部署与不需要密钥的预设除外)。
  bool get _keyRequired =>
      (_currentPreset?.requiresApiKey ?? true) && _region != AiRegion.local;

  /// 密钥框是否标必填(红星/空时红框): 新增且需要密钥, 或改了地址而旧密钥还在。
  bool get _keyFieldRequired {
    if (_clearKey) return false;
    final existing = _existing;
    if (existing == null) return _keyRequired;
    return _endpointChanged && existing.apiKeyConfigured;
  }

  bool get _overseasBlocked =>
      _region == AiRegion.overseas && !widget.catalog.allowOverseas;

  /// 影响连接测试、但「用已存密钥测试」不会带上的设置改过了(服务端按已保存的值测试)。
  bool get _probeSettingsChanged {
    final existing = _existing;
    if (existing == null) return false;
    final timeout =
        int.tryParse(_timeout.text.trim()) ?? existing.timeoutSeconds;
    return _jsonMode != existing.jsonMode ||
        _thinking != existing.thinkingControl ||
        _sendTemperature != existing.sendTemperature ||
        timeout != existing.timeoutSeconds;
  }

  /// 已保存的密钥还能用(存在、能解密、本次没有要求清除)。
  bool get _storedKeyUsable {
    final existing = _existing;
    return existing != null &&
        existing.apiKeyConfigured &&
        !existing.apiKeyUnreadable &&
        !_clearKey;
  }

  AiProviderForm _form() => AiProviderForm(
    name: _name.text,
    preset: _preset,
    region: _region,
    protocol: _protocol,
    baseUrl: _baseUrl.text,
    model: _model.text,
    apiKey: _hasNewKey ? _apiKey.text.trim() : null,
    // 原本就没存密钥时改地址, 顺带声明「不带旧密钥」, 与服务端改地址规则对齐。
    clearApiKey:
        _clearKey ||
        (_endpointChanged && !(_existing?.apiKeyConfigured ?? true)),
    jsonMode: _jsonMode,
    thinkingControl: _thinking,
    sendTemperature: _sendTemperature,
    supportsVision: _supportsVision,
    maxOutputTokens:
        int.tryParse(_maxTokens.text.trim()) ??
        AiProviderLimits.defaultOutputTokens,
    timeoutSeconds:
        int.tryParse(_timeout.text.trim()) ??
        AiProviderLimits.defaultTimeoutSeconds,
    enabled: _enabled,
    overseasAcknowledged: _overseasAck,
  );

  // ---- 校验 ----

  String? _nameError(String? value, AppLocalizations l10n) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return l10n.aiSettingsNameRequired;
    if (text.length > AiProviderLimits.maxNameLength) {
      return l10n.aiSettingsTooLong(AiProviderLimits.maxNameLength);
    }
    return null;
  }

  String? _baseUrlError(String? value, AppLocalizations l10n) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return l10n.aiSettingsBaseUrlRequired;
    if (text.length > AiProviderLimits.maxBaseUrlLength) {
      return l10n.aiSettingsTooLong(AiProviderLimits.maxBaseUrlLength);
    }
    final uri = Uri.tryParse(text);
    final scheme = uri?.scheme.toLowerCase();
    if (uri == null ||
        (scheme != 'https' && scheme != 'http') ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return l10n.aiSettingsBaseUrlInvalid;
    }
    if (scheme == 'http' && _region != AiRegion.local) {
      return l10n.aiSettingsBaseUrlHttpLocalOnly;
    }
    return null;
  }

  String? _modelError(String? value, AppLocalizations l10n) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return l10n.aiSettingsModelRequired;
    if (text.length > AiProviderLimits.maxModelLength) {
      return l10n.aiSettingsTooLong(AiProviderLimits.maxModelLength);
    }
    return null;
  }

  String? _apiKeyError(AppLocalizations l10n) {
    if (_needsNewKey) return l10n.aiSettingsUrlChangedNeedKey;
    // 编辑时允许不填(保留原密钥、清除泄露的密钥或先改别的项); 卡片会持续提示缺密钥。
    if (_hasNewKey || !_keyRequired || _editing) return null;
    return l10n.aiSettingsApiKeyRequired;
  }

  static String? _rangeError(
    String? value,
    int min,
    int max,
    AppLocalizations l10n,
  ) {
    final parsed = int.tryParse(value?.trim() ?? '');
    if (parsed == null || parsed < min || parsed > max) {
      return l10n.aiSettingsNumberRange(min, max);
    }
    return null;
  }

  bool _advancedValid(AppLocalizations l10n) =>
      _rangeError(
            _maxTokens.text,
            AiProviderLimits.minOutputTokens,
            AiProviderLimits.maxOutputTokens,
            l10n,
          ) ==
          null &&
      _rangeError(
            _timeout.text,
            AiProviderLimits.minTimeoutSeconds,
            AiProviderLimits.maxTimeoutSeconds,
            l10n,
          ) ==
          null;

  // ---- 测试与取模型 ----

  _Probe _probeVariant({required bool forModels}) {
    if (_overseasBlocked) return _Probe.overseasBlocked;
    if (_hasNewKey) return _Probe.form;
    final existing = _existing;
    if (_storedKeyUsable && existing != null) {
      final sameModel = forModels || _model.text.trim() == existing.model;
      if (_endpointChanged || !sameModel) return _Probe.storedMismatch;
      // 取模型只看地址和密钥; 测试会用到 JSON 方式、深度思考、温度和超时。
      if (!forModels && _probeSettingsChanged) {
        return _Probe.storedUnsavedAdvanced;
      }
      return _Probe.stored;
    }
    if (!_keyRequired) return _Probe.form;
    return _Probe.needKey;
  }

  /// 探测前的条件不满足时返回要显示的原因。
  String? _probeBlocker(_Probe probe, AppLocalizations l10n) => switch (probe) {
    _Probe.needKey => l10n.aiSettingsTestNeedsKey,
    _Probe.storedMismatch => l10n.aiSettingsTestStoredMismatch,
    _Probe.storedUnsavedAdvanced => l10n.aiSettingsTestStoredUnsavedAdvanced,
    _Probe.overseasBlocked => l10n.aiSettingsOverseasOffHint,
    _Probe.form || _Probe.stored => null,
  };

  bool _endpointFieldsValid(AppLocalizations l10n, {required bool withModel}) {
    final invalid =
        _baseUrlError(_baseUrl.text, l10n) != null ||
        (withModel && _modelError(_model.text, l10n) != null);
    if (invalid) _formKey.currentState?.validate();
    return !invalid;
  }

  Future<void> _test() async {
    final l10n = AppLocalizations.of(context);
    final probe = _probeVariant(forModels: false);
    final blocker = _probeBlocker(probe, l10n);
    if (blocker != null) {
      setState(() => _probeNotice = blocker);
      _revealProbeFeedback();
      return;
    }
    if (probe == _Probe.form && !_endpointFieldsValid(l10n, withModel: true)) {
      return;
    }
    final repository = ref.read(aiProviderRepositoryProvider);
    setState(() {
      _testing = true;
      _testResult = null;
      _probeNotice = null;
    });
    _revealProbeFeedback();
    try {
      final result = probe == _Probe.stored
          ? await repository.testStored(_existing!.id, current: _form())
          : await repository.testForm(_form());
      if (!mounted) return;
      setState(() => _testResult = result);
      _revealProbeFeedback();
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appApiError(error);
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.aiSettingsTestFailed);
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  /// 下一帧把探测反馈滚进可见区(系统「减少动画」时直接跳到位)。
  void _revealProbeFeedback() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _probeFeedbackKey.currentContext;
      if (!mounted || target == null) return;
      final reduceMotion =
          MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      Scrollable.ensureVisible(
        target,
        duration: reduceMotion ? Duration.zero : UtenAnim.normal,
        curve: UtenAnim.standard,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
      );
    });
  }

  Future<void> _fetchModels() async {
    final l10n = AppLocalizations.of(context);
    final probe = _probeVariant(forModels: true);
    final blocker = _probeBlocker(probe, l10n);
    if (blocker != null) {
      setState(() => _probeNotice = blocker);
      _revealProbeFeedback();
      return;
    }
    if (probe == _Probe.form && !_endpointFieldsValid(l10n, withModel: false)) {
      return;
    }
    final repository = ref.read(aiProviderRepositoryProvider);
    setState(() {
      _loadingModels = true;
      _probeNotice = null;
    });
    try {
      final list = probe == _Probe.stored
          ? await repository.modelsStored(_existing!.id, current: _form())
          : await repository.modelsForForm(_form());
      if (!mounted) return;
      final models = list.models;
      setState(() {
        _models = models;
        // 服务端会说明为什么没有列表(没有列表接口、密钥无效等), 没说时用通用提示。
        _probeNotice = models.isEmpty
            ? list.message ?? l10n.aiSettingsModelsEmpty
            : null;
      });
      if (models.isNotEmpty) {
        context.appSuccess(l10n.aiSettingsModelsLoaded(models.length));
      } else {
        _revealProbeFeedback();
      }
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appApiError(error);
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.aiSettingsModelsEmpty);
    } finally {
      if (mounted) setState(() => _loadingModels = false);
    }
  }

  // ---- 保存 ----

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _submitted = true);
    final formValid = _formKey.currentState?.validate() ?? false;
    final advancedValid = _advancedValid(l10n);
    final keyValid = _apiKeyError(l10n) == null;
    final overseasOk =
        _region != AiRegion.overseas || (!_overseasBlocked && _overseasAck);
    if (!formValid || !advancedValid || !keyValid || !overseasOk) {
      if (!advancedValid && !_advancedOpen) {
        setState(() => _advancedOpen = true);
      }
      context.appWarning(
        _overseasBlocked
            ? l10n.aiSettingsOverseasOffHint
            : l10n.aiSettingsFixFields,
      );
      return;
    }
    final repository = ref.read(aiProviderRepositoryProvider);
    final existing = _existing;
    try {
      if (existing == null) {
        await repository.create(_form());
      } else {
        await repository.update(
          existing.id,
          _form(),
          version: existing.version,
        );
      }
      if (!mounted) return;
      _apiKey.clear();
      context.appSuccess(l10n.aiSettingsSaved);
      _closing = true;
      Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      context.appApiError(error);
    } catch (_) {
      if (!mounted) return;
      context.appError(l10n.aiSettingsSaveFailed);
    }
  }

  void _close() {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(false);
  }

  // ---- 界面 ----

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final busy = _testing || _loadingModels;
    return Material(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          _Header(
            title: _editing ? l10n.aiSettingsEditTitle : l10n.aiSettingsAdd,
            onClose: _close,
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          Expanded(
            child: Form(
              key: _formKey,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  UtenSpacing.s20,
                  UtenSpacing.s16,
                  UtenSpacing.s20,
                  UtenSpacing.s24,
                ),
                children: [
                  ..._presetSection(l10n, theme),
                  const SizedBox(height: UtenSpacing.s16),
                  UtenInput(
                    key: const ValueKey('ai-editor-name'),
                    label: l10n.aiSettingsName,
                    hint: l10n.aiSettingsNameHint,
                    controller: _name,
                    required: true,
                    validator: (value) => _nameError(value, l10n),
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  UtenInput(
                    key: const ValueKey('ai-editor-base-url'),
                    label: l10n.aiSettingsBaseUrl,
                    hint: 'https://',
                    info: l10n.aiSettingsBaseUrlInfo,
                    controller: _baseUrl,
                    required: true,
                    keyboardType: TextInputType.url,
                    validator: (value) => _baseUrlError(value, l10n),
                  ),
                  const SizedBox(height: UtenSpacing.s16),
                  ..._modelSection(l10n, busy),
                  const SizedBox(height: UtenSpacing.s16),
                  ..._keySection(l10n, theme),
                  if (_region == AiRegion.overseas) ...[
                    const SizedBox(height: UtenSpacing.s16),
                    _overseasAckTile(l10n, theme),
                  ],
                  const SizedBox(height: UtenSpacing.s12),
                  UtenCollapsibleSection(
                    key: const ValueKey('ai-editor-advanced'),
                    title: l10n.aiSettingsAdvanced,
                    initiallyExpanded: false,
                    expanded: _advancedOpen,
                    onExpandedChanged: (open) =>
                        setState(() => _advancedOpen = open),
                    child: _advancedFields(l10n),
                  ),
                  KeyedSubtree(
                    key: _probeFeedbackKey,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (_probeNotice != null) ...[
                          const SizedBox(height: UtenSpacing.s12),
                          UtenInlineNotice(
                            key: const ValueKey('ai-editor-probe-notice'),
                            level: UtenInlineNoticeLevel.warning,
                            message: _probeNotice!,
                          ),
                        ],
                        if (_testing || _testResult != null) ...[
                          const SizedBox(height: UtenSpacing.s12),
                          AiConnectionTestView(
                            result: _testResult,
                            running: _testing,
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: theme.colorScheme.outlineVariant),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(UtenSpacing.s16),
              child: Row(
                children: [
                  Expanded(
                    child: UtenActionButton(
                      key: const ValueKey('ai-editor-test'),
                      type: UtenActionButtonType.secondary,
                      size: UtenActionButtonSize.large,
                      isExpanded: true,
                      icon: Icons.network_check_rounded,
                      label: Text(l10n.aiSettingsTest),
                      loadingLabel: Text(l10n.aiSettingsTesting),
                      onAction: _test,
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Expanded(
                    child: UtenActionButton(
                      key: const ValueKey('ai-editor-save'),
                      size: UtenActionButtonSize.large,
                      isExpanded: true,
                      icon: Icons.save_outlined,
                      label: Text(l10n.aiSettingsSave),
                      loadingLabel: Text(l10n.aiSettingsSaving),
                      onAction: _save,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _presetSection(AppLocalizations l10n, ThemeData theme) {
    final anyOverseasLocked = _presets.any(
      (preset) =>
          !_presetSelectable(preset) && widget.catalog.isOverseasLocked(preset),
    );
    final lockedReasons = _lockedReasons(l10n);
    final preset = _currentPreset;
    return [
      _labeled(
        l10n.aiSettingsPreset,
        required: true,
        UtenDropdownField(
          key: const ValueKey('ai-editor-preset'),
          info: anyOverseasLocked
              ? '${l10n.aiSettingsPresetInfo}\n${l10n.aiSettingsOverseasOffHint}'
              : l10n.aiSettingsPresetInfo,
          value: _preset,
          allowClear: false,
          searchable: false,
          required: true,
          items: [
            for (final item in _presets)
              UtenDropdownItem(
                value: item.code,
                label: _presetSelectable(item)
                    ? item.label
                    : widget.catalog.isOverseasLocked(item)
                    ? l10n.aiSettingsPresetOverseasOff(item.label)
                    : l10n.aiSettingsPresetUnavailable(item.label),
                enabled: _presetSelectable(item),
              ),
            // 预设目录缺了这条已保存的预设时也要能显示当前值。
            if (preset == null)
              UtenDropdownItem(
                value: _preset,
                label: aiPresetLabel(
                  widget.catalog,
                  _preset,
                  fallback: _existing?.presetLabel,
                ),
                visible: false,
              ),
          ],
          onChanged: _onPresetChanged,
        ),
      ),
      // 为什么有的服务商选不了: 服务端原因原样展示(境外未开放 / 服务器关闭了对外调用)。
      for (final (index, reason) in lockedReasons.indexed)
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s6),
          child: Row(
            key: ValueKey('ai-editor-preset-locked-$index'),
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  Icons.lock_outline_rounded,
                  size: 14,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: UtenSpacing.s4),
              Expanded(
                child: Text(
                  reason,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      if (preset?.regionEditable ?? true) ...[
        const SizedBox(height: UtenSpacing.s16),
        _labeled(
          l10n.aiSettingsRegion,
          required: true,
          UtenDropdownField(
            key: const ValueKey('ai-editor-region'),
            value: _region.code,
            allowClear: false,
            searchable: false,
            required: true,
            items: [
              for (final region in AiRegion.values)
                UtenDropdownItem(
                  value: region.code,
                  label:
                      region == AiRegion.overseas &&
                          !widget.catalog.allowOverseas
                      ? l10n.aiSettingsPresetOverseasOff(region.label(l10n))
                      : region.label(l10n),
                  enabled:
                      region != AiRegion.overseas ||
                      widget.catalog.allowOverseas ||
                      _existing?.region == AiRegion.overseas,
                ),
            ],
            onChanged: (code) => setState(() {
              _region = AiRegion.parse(code);
              _testResult = null;
            }),
          ),
        ),
      ],
    ];
  }

  /// 下拉框的名称放在框上方, 与本面板的文本输入框(UtenInput)同一排法、同一字样;
  /// 说明 ⓘ 仍在框内。
  Widget _labeled(String label, Widget field, {bool required = false}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        fieldLabel(
          label,
          theme,
          required: required,
          base: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurface,
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        field,
      ],
    );
  }

  List<Widget> _modelSection(AppLocalizations l10n, bool busy) => [
    Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: UtenInput(
            key: const ValueKey('ai-editor-model'),
            label: l10n.aiSettingsModel,
            hint: l10n.aiSettingsModelHint,
            controller: _model,
            required: true,
            validator: (value) => _modelError(value, l10n),
            onChanged: (_) => setState(() => _testResult = null),
          ),
        ),
        const SizedBox(width: UtenSpacing.s8),
        UtenButton(
          key: const ValueKey('ai-editor-fetch-models'),
          type: UtenButtonType.secondary,
          height: 48,
          icon: Icons.list_alt_rounded,
          isLoading: _loadingModels,
          onPressed: busy ? null : _fetchModels,
          child: Text(l10n.aiSettingsFetchModels),
        ),
      ],
    ),
    // 少量模型(预设推荐或服务商只返回几个)直接点选; 多了用可搜索下拉。
    if (_models.isNotEmpty && _models.length <= _modelChipLimit) ...[
      const SizedBox(height: UtenSpacing.s8),
      Wrap(
        key: const ValueKey('ai-editor-model-chips'),
        spacing: UtenSpacing.s8,
        runSpacing: UtenSpacing.s4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text(
            l10n.aiSettingsModelChoices,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          for (final model in _models)
            ChoiceChip(
              label: Text(model),
              selected: _model.text.trim() == model,
              onSelected: (_) => _pickModel(model),
            ),
        ],
      ),
    ] else if (_models.isNotEmpty) ...[
      const SizedBox(height: UtenSpacing.s8),
      UtenDropdownField(
        key: const ValueKey('ai-editor-model-list'),
        hintText: l10n.aiSettingsPickModel,
        value: _models.contains(_model.text.trim()) ? _model.text.trim() : null,
        allowClear: false,
        searchable: true,
        items: [
          for (final model in _models)
            UtenDropdownItem(value: model, label: model),
        ],
        onChanged: (model) {
          if (model != null) _pickModel(model);
        },
      ),
    ],
  ];

  static const _modelChipLimit = 6;

  void _pickModel(String model) => setState(() {
    _model.text = model;
    _testResult = null;
  });

  List<Widget> _keySection(AppLocalizations l10n, ThemeData theme) {
    final existing = _existing;
    final storedTail = existing?.apiKeyTail;
    final String hint;
    if (_clearKey) {
      hint = l10n.aiSettingsKeyWillClear;
    } else if (existing != null && existing.apiKeyConfigured) {
      // 尾号掩码不放进提示文字(输入框提示只能是纯文字, 圆点会显示成「• • • •」),
      // 在输入框下方和「清除密钥」同一行紧凑显示。
      hint = l10n.aiSettingsApiKeyKeepHintPlain;
    } else if (!_keyRequired) {
      hint = l10n.aiSettingsApiKeyNotNeededHint;
    } else {
      hint = l10n.aiSettingsApiKeyHint;
    }
    final unreadable =
        existing != null &&
        existing.apiKeyUnreadable &&
        !_hasNewKey &&
        !_clearKey;
    return [
      if (_needsNewKey) ...[
        UtenInlineNotice(
          key: const ValueKey('ai-editor-url-changed'),
          level: UtenInlineNoticeLevel.warning,
          title: l10n.aiSettingsUrlChangedNeedKey,
          message: _keyRequired
              ? l10n.aiSettingsUrlChangedNeedKeyDetail
              : l10n.aiSettingsUrlChangedNeedKeyLocalDetail,
        ),
        const SizedBox(height: UtenSpacing.s8),
      ] else if (unreadable) ...[
        UtenInlineNotice(
          key: const ValueKey('ai-editor-key-unreadable'),
          level: UtenInlineNoticeLevel.error,
          message: l10n.aiSettingsKeyUnreadable,
        ),
        const SizedBox(height: UtenSpacing.s8),
      ],
      UtenInput(
        key: const ValueKey('ai-editor-api-key'),
        label: l10n.aiSettingsApiKey,
        hint: hint,
        controller: _apiKey,
        isPassword: true,
        required: _keyFieldRequired,
        errorMessage: _submitted ? _apiKeyError(l10n) : null,
        // 密钥不是登录密码: 不接系统自动填充/密码管理器。
        inputFormatters: [FilteringTextInputFormatter.deny(RegExp(r'\s'))],
        onChanged: (_) {
          if (_clearKey && _hasNewKey) setState(() => _clearKey = false);
        },
      ),
      // 当前密钥尾号 + 清除: 本机部署不需要密钥, 或密钥泄露要先撤掉(保存后该服务不可用,
      // 直到重新填写)。
      if (existing != null && existing.apiKeyConfigured)
        Padding(
          padding: const EdgeInsets.only(top: UtenSpacing.s8),
          child: Row(
            children: [
              Expanded(
                child: !_clearKey && storedTail != null
                    ? Row(
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: UtenSpacing.s4),
                          Flexible(
                            child: Text(
                              l10n.aiSettingsCurrentKey,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: UtenSpacing.s6),
                          AiMaskedKey(
                            storedTail,
                            key: const ValueKey('ai-editor-key-mask'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: UtenSpacing.s8),
              UtenButton(
                key: const ValueKey('ai-editor-clear-key'),
                type: UtenButtonType.ghost,
                size: UtenButtonSize.small,
                height: 48,
                icon: _clearKey ? Icons.undo_rounded : Icons.key_off_outlined,
                onPressed: () => setState(() {
                  _clearKey = !_clearKey;
                  if (_clearKey) _apiKey.clear();
                  _testResult = null;
                }),
                child: Text(
                  _clearKey
                      ? l10n.aiSettingsUndoClear
                      : l10n.aiSettingsClearKey,
                ),
              ),
            ],
          ),
        ),
    ];
  }

  Widget _overseasAckTile(AppLocalizations l10n, ThemeData theme) {
    if (_overseasBlocked) {
      return UtenInlineNotice(
        key: const ValueKey('ai-editor-overseas-blocked'),
        level: UtenInlineNoticeLevel.error,
        message: l10n.aiSettingsOverseasOffHint,
      );
    }
    final showError = _submitted && !_overseasAck;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: UtenRadius.controlAll,
            border: Border.all(
              color: showError
                  ? theme.colorScheme.error
                  : theme.colorScheme.outlineVariant,
            ),
          ),
          child: CheckboxListTile(
            key: const ValueKey('ai-editor-overseas-ack'),
            value: _overseasAck,
            controlAffinity: ListTileControlAffinity.leading,
            shape: const RoundedRectangleBorder(
              borderRadius: UtenRadius.controlAll,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: UtenSpacing.s8,
            ),
            title: Text(
              l10n.aiSettingsOverseasAck,
              style: theme.textTheme.bodyMedium,
            ),
            onChanged: (value) => setState(() => _overseasAck = value ?? false),
          ),
        ),
        if (showError)
          Padding(
            padding: const EdgeInsets.only(top: UtenSpacing.s4),
            child: Text(
              l10n.aiSettingsOverseasAckRequired,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
      ],
    );
  }

  Widget _advancedFields(AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _labeled(
          l10n.aiSettingsProtocol,
          UtenDropdownField(
            key: const ValueKey('ai-editor-protocol'),
            info: l10n.aiSettingsProtocolInfo,
            value: _protocol.code,
            allowClear: false,
            searchable: false,
            items: [
              for (final protocol in AiProtocol.values)
                UtenDropdownItem(
                  value: protocol.code,
                  label: protocol.label(l10n),
                ),
            ],
            onChanged: (code) => setState(() {
              _protocol = AiProtocol.parse(code);
              _testResult = null;
            }),
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        _labeled(
          l10n.aiSettingsJsonMode,
          UtenDropdownField(
            key: const ValueKey('ai-editor-json-mode'),
            info: l10n.aiSettingsJsonModeInfo,
            value: _jsonMode.code,
            allowClear: false,
            searchable: false,
            items: [
              for (final mode in AiJsonMode.values)
                UtenDropdownItem(value: mode.code, label: mode.label(l10n)),
            ],
            onChanged: (code) => setState(() {
              _jsonMode = AiJsonMode.parse(code);
              _clearProbeState();
            }),
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        _labeled(
          l10n.aiSettingsThinking,
          UtenDropdownField(
            key: const ValueKey('ai-editor-thinking'),
            info: l10n.aiSettingsThinkingInfo,
            value: _thinking.code,
            allowClear: false,
            searchable: false,
            items: [
              for (final mode in AiThinkingControl.values)
                UtenDropdownItem(value: mode.code, label: mode.label(l10n)),
            ],
            onChanged: (code) => setState(() {
              _thinking = AiThinkingControl.parse(code);
              _clearProbeState();
            }),
          ),
        ),
        const SizedBox(height: UtenSpacing.s8),
        _SwitchRow(
          key: const ValueKey('ai-editor-temperature'),
          title: l10n.aiSettingsTemperature,
          subtitle: l10n.aiSettingsTemperatureInfo,
          value: _sendTemperature,
          onChanged: (value) => setState(() {
            _sendTemperature = value;
            _clearProbeState();
          }),
        ),
        _SwitchRow(
          key: const ValueKey('ai-editor-vision'),
          title: l10n.aiSettingsVision,
          subtitle: l10n.aiSettingsVisionInfo,
          value: _supportsVision,
          onChanged: (value) => setState(() => _supportsVision = value),
        ),
        _SwitchRow(
          key: const ValueKey('ai-editor-enabled'),
          title: l10n.aiSettingsEnabledSwitch,
          subtitle: l10n.aiSettingsEnabledInfo,
          value: _enabled,
          onChanged: (value) => setState(() => _enabled = value),
        ),
        const SizedBox(height: UtenSpacing.s8),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: UtenInput(
                key: const ValueKey('ai-editor-max-tokens'),
                label: l10n.aiSettingsMaxTokens,
                info: l10n.aiSettingsMaxTokensInfo,
                controller: _maxTokens,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (value) => _rangeError(
                  value,
                  AiProviderLimits.minOutputTokens,
                  AiProviderLimits.maxOutputTokens,
                  l10n,
                ),
              ),
            ),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: UtenInput(
                key: const ValueKey('ai-editor-timeout'),
                label: l10n.aiSettingsTimeout,
                info: l10n.aiSettingsTimeoutInfo,
                controller: _timeout,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (_) => setState(_clearProbeState),
                validator: (value) => _rangeError(
                  value,
                  AiProviderLimits.minTimeoutSeconds,
                  AiProviderLimits.maxTimeoutSeconds,
                  l10n,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onClose});

  final String title;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        UtenSpacing.s20,
        UtenSpacing.s12,
        UtenSpacing.s8,
        UtenSpacing.s12,
      ),
      child: Row(
        children: [
          const AiSparkleBadge(size: 36, animate: false),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('ai-editor-close'),
            tooltip: l10n.aiSettingsClose,
            icon: const Icon(Icons.close_rounded),
            onPressed: onClose,
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  const _SwitchRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      contentPadding: EdgeInsets.zero,
      title: Text(title, style: theme.textTheme.bodyLarge),
      subtitle: Text(
        subtitle,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
