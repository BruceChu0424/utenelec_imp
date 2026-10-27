import '../../../core/theme/uten_tokens.dart';
import '../../../components/layout/uten_segment_row.dart';
import 'dart:ui' show ImmutableBuffer, ImageDescriptor;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../components/buttons/uten_back_button.dart';
import '../../../components/buttons/uten_button.dart';
import '../../../components/cards/uten_card.dart';
import '../../../components/inputs/uten_input_decoration.dart';
import '../../../components/layout/uten_app_bar.dart';
import '../../../components/layout/uten_content_container.dart';
import '../../../components/layout/uten_floating_action_group.dart';
import '../../../components/layout/uten_responsive_grid.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/network/server_config.dart';
import '../../../core/network/server_selection.dart';
import '../../../core/router/route_names.dart';
import '../../../core/router/route_access_policy.dart';
import '../../../core/theme/dark_theme.dart';
import '../../../core/theme/light_theme.dart';
import '../../../core/ui/app_notification.dart';
import '../../../core/ui/uten_notify.dart';
import '../../../shared/auth/permissions.dart';
import '../../../shared/auth/session_snapshot_provider.dart';
import '../../../shared/drafts/form_draft_navigation.dart';
import '../../../shared/platform_branding/platform_branding.dart';
import '../../../shared/platform_branding/platform_branding_provider.dart';
import '../../../shared/platform_branding/platform_brand_logo.dart';
import '../../../shared/providers/authenticated_scope_provider.dart';
import '../../../shared/providers/session_provider.dart';
import '../../../shared/providers/shared_providers.dart';
import '../../../shared/widgets/server_switch_dialog.dart';
import '../../../components/inputs/uten_field_message.dart';
import '../models/platform_server_status.dart';
import '../models/platform_settings_catalog.dart';
import '../repositories/platform_settings_repository.dart';
import '../widgets/platform_color_picker_dialog.dart';
import '../../../core/l10n/remote_access_text.dart';

Object? _settingsOwner(WidgetRef ref, {bool watch = false}) {
  final scope = watch
      ? ref.watch(authenticatedScopeProvider)
      : ref.read(authenticatedScopeProvider);
  final session = watch
      ? ref.watch(sessionProvider)
      : ref.read(sessionProvider);
  final snapshot = confirmedSessionSnapshot(
    watch
        ? ref.watch(sessionSnapshotProvider)
        : ref.read(sessionSnapshotProvider),
  );
  final server = watch
      ? ref.watch(apiBaseUrlProvider)
      : ref.read(apiBaseUrlProvider);
  final permissions = watch
      ? ref.watch(currentPermissionsProvider)
      : ref.read(currentPermissionsProvider);
  if (scope == null ||
      scope.actorId != null ||
      scope.readOnly ||
      snapshot == null ||
      session.user?.id != scope.userId ||
      !platformSettingsAllowedFor(
        permissions,
        session.user?.superAdmin == true,
      )) {
    return null;
  }
  return (scope, snapshot.generation, server);
}

/// Every editor instance belongs to one confirmed identity and server.
/// Replacing that owner disposes pending edits and ignores late responses.
class AdminPlatformSettingsPage extends ConsumerWidget {
  const AdminPlatformSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final owner = _settingsOwner(ref, watch: true);
    if (owner == null) {
      return const Scaffold(
        appBar: UtenAppBar(title: '平台设置', leading: UtenBackButton()),
        body: Center(child: Text('平台设置仅限已确认权限的超级管理员使用')),
      );
    }
    return _PlatformSettingsEditor(key: ValueKey(owner));
  }
}

class _PlatformSettingsEditor extends ConsumerStatefulWidget {
  const _PlatformSettingsEditor({super.key});
  @override
  ConsumerState<_PlatformSettingsEditor> createState() =>
      _PlatformSettingsState();
}

class _PlatformSettingsState extends ConsumerState<_PlatformSettingsEditor> {
  static const _labels = {
    'companyName': ('公司显示名称', 120),
    'platformName': ('平台名称', 80),
    'companyAliases': ('公司其他名称', 500),
    'tagline': ('品牌说明', 160),
    'primaryColor': ('主题色', 7),
    'secondaryColor': ('副主题色', 7),
    'loginNotice': ('登录页提示', 500),
    'supportPhone': ('联系电话', 50),
    'supportEmail': ('联系邮箱', 120),
    'website': ('公司网站', 200),
  };
  final _formKey = GlobalKey<FormState>();
  final _scrollController = ScrollController();
  final _controllers = <String, TextEditingController>{};
  late final Object? _owner;
  PlatformBranding? _original;
  PlatformServerStatus? _status;
  Uint8List? _logo;
  String? _logoName;
  bool _removeLogo = false;
  bool _loading = true;
  bool _saving = false;
  bool _picking = false;
  bool _verified = false;
  bool _previewDark = false;
  bool _allowPop = false;
  bool _saveUncertain = false;
  bool _cachedDisplay = false;
  final _navigationOwner = Object();
  int _section = 0;
  int _loadSeq = 0;
  String? _error;
  String? _conflict;
  bool get _current => mounted && _owner == _settingsOwner(ref);
  bool get _busy => _loading || _saving || _picking;
  bool get _dirty =>
      _original != null &&
      (_logo != null ||
          _removeLogo ||
          _controllers.entries.any(
            (e) => e.value.text.trim() != _original!.toUpdateJson()[e.key],
          ));

  @override
  void initState() {
    super.initState();
    _owner = _settingsOwner(ref);
    for (final key in _labels.keys) {
      _controllers[key] = TextEditingController()..addListener(_changed);
    }
    final cached = ref
        .read(platformBrandingCacheProvider)
        .readBrand(ref.read(apiBaseUrlProvider));
    if (cached != null) {
      _accept(cached);
      _cachedDisplay = true;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  void _changed() {
    if (mounted) setState(() => _allowPop = false);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // A surrounding router also exists inside imperative dialogs/routes. Only
    // a declarative Page can safely supply the form-navigation registry key.
    if (GoRouter.maybeOf(context) == null ||
        ModalRoute.of(context)?.settings is! Page) {
      return;
    }
    FormDraftNavigation.register(
      _navigationOwner,
      RouteName.adminPlatformSettings,
      _leave,
      pageKey: GoRouterState.of(context).pageKey,
    );
  }

  Future<bool> _leave() async {
    if (!_current || _allowPop) return true;
    if (_saving || _picking) return false;
    final confirmed = await _confirmDiscard();
    if (confirmed && mounted) setState(() => _allowPop = true);
    return confirmed;
  }

  @override
  void dispose() {
    FormDraftNavigation.unregister(_navigationOwner);
    _scrollController.dispose();
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _accept(PlatformBranding branding) {
    _original = branding.forServer(ref.read(apiBaseUrlProvider));
    for (final e in branding.toUpdateJson().entries) {
      _controllers[e.key]?.text = e.value.toString();
    }
    _logo = null;
    _logoName = null;
    _removeLogo = false;
    _conflict = null;
    _saveUncertain = false;
    _cachedDisplay = false;
  }

  Future<void> _load({bool connectionOnly = false}) async {
    if (!_current || _saving) return;
    final seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _verified = false;
      _error = null;
    });
    final repository = ref.read(platformSettingsRepositoryProvider);
    try {
      final status = await repository.status();
      if (!_current || seq != _loadSeq) return;
      if (!status.databaseConnected) {
        throw NetworkException('服务器可达，但数据库连接尚未就绪，请稍后重新检测');
      }
      // Reading the configuration also verifies that this server has the feature.
      final branding = await repository.fetch();
      if (!_current || seq != _loadSeq) return;
      setState(() {
        _status = status;
        _verified = true;
        if (!connectionOnly || _original == null || !_dirty) {
          _accept(branding);
        } else if (branding.version != _original!.version) {
          _conflict = _saveUncertain
              ? '服务器已有新的设置版本，本次保存可能已生效。你的编辑已保留，请读取最新设置后核对。'
              : '服务器上的设置版本已变化。你的编辑已保留，请读取最新设置后重新确认。';
        } else {
          _saveUncertain = false;
        }
      });
    } catch (e) {
      if (!_current || seq != _loadSeq) return;
      setState(() => _error = _errorMessage(e));
    } finally {
      if (_current && seq == _loadSeq) setState(() => _loading = false);
    }
  }

  static String _errorMessage(Object error) => switch (error) {
    ApiException(httpStatus: 404) => '当前服务器版本尚未支持平台设置，请更新服务器后重试',
    ApiException(httpStatus: 401) => '登录已过期，请重新登录后连接服务器',
    ApiException(httpStatus: 403) => '当前账号无权管理此服务器的平台设置',
    ApiException(:final message) => message,
    FormatException(:final message) => message,
    _ => '暂时无法连接或读取平台设置，请检查服务器后重试',
  };

  PlatformBranding _draft({bool preview = false}) {
    String color(String key, String fallback) {
      final value = _controllers[key]!.text.trim().toUpperCase();
      return preview && !RegExp(r'^#[0-9A-F]{6}$').hasMatch(value)
          ? fallback
          : value;
    }

    return PlatformBranding(
      version: _original!.version,
      companyName: _controllers['companyName']!.text.trim(),
      platformName: _controllers['platformName']!.text.trim(),
      companyAliases: _controllers['companyAliases']!.text.trim(),
      tagline: _controllers['tagline']!.text.trim(),
      primaryColor: color('primaryColor', _original!.primaryColor),
      secondaryColor: color('secondaryColor', _original!.secondaryColor),
      loginNotice: _controllers['loginNotice']!.text.trim(),
      supportPhone: _controllers['supportPhone']!.text.trim(),
      supportEmail: _controllers['supportEmail']!.text.trim(),
      website: _controllers['website']!.text.trim(),
      hasLogo: !_removeLogo && (_logo != null || _original!.hasLogo),
      updatedAt: _original!.updatedAt,
      serverEndpoint: _original!.serverEndpoint,
    );
  }

  Future<void> _pickLogo() async {
    if (!_current || !_verified || _busy) return;
    setState(() => _picking = true);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['png', 'jpg', 'jpeg'],
        withData: true,
      );
      if (!mounted || !_current || result == null) return;
      final file = result.files.single;
      final bytes = file.bytes;
      final limit = _status?.maxLogoBytes ?? 524288;
      if (bytes == null || bytes.isEmpty || bytes.length > limit) {
        context.appError('请选择不超过 ${limit ~/ 1024} KB 的 PNG 或 JPEG 图片');
        return;
      }
      final png =
          bytes.length >= 8 &&
          listEquals(bytes.sublist(0, 8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final jpeg =
          bytes.length >= 3 &&
          bytes[0] == 255 &&
          bytes[1] == 216 &&
          bytes[2] == 255;
      if (!png && !jpeg) {
        context.appError('Logo 仅支持真实的 PNG 或 JPEG 图片');
        return;
      }
      // Metadata is checked before decoding; the server repeats all validation.
      final buffer = await ImmutableBuffer.fromUint8List(bytes);
      ImageDescriptor? descriptor;
      try {
        descriptor = await ImageDescriptor.encoded(buffer);
        final max = _status?.maxLogoDimension ?? 2048;
        if (descriptor.width > max || descriptor.height > max) {
          if (mounted && _current) context.appError('Logo 的宽和高均不能超过 $max 像素');
          return;
        }
      } finally {
        descriptor?.dispose();
        buffer.dispose();
      }
      if (!_current) return;
      setState(() {
        _logo = bytes;
        _logoName = file.name;
        _removeLogo = false;
      });
    } catch (_) {
      if (mounted && _current) context.appError('无法读取图片，请选择有效的 PNG 或 JPEG 文件');
    } finally {
      if (_current) setState(() => _picking = false);
    }
  }

  Future<void> _save() async {
    if (!_current || !_verified || _busy || !_dirty || _conflict != null) {
      return;
    }
    if (!(_formKey.currentState?.validate() ?? false)) {
      setState(() => _section = 0);
      context.appWarning('请先修正标记的设置项');
      return;
    }
    final draft = _draft();
    final repository = ref.read(platformSettingsRepositoryProvider);
    setState(() {
      _saving = true;
      _error = null;
    });
    var commandStarted = false;
    try {
      // Recheck the actual server/database immediately before the atomic command.
      final status = await repository.status();
      if (!_current) return;
      if (!status.databaseConnected) throw NetworkException('数据库尚未就绪，请重新检测连接');
      commandStarted = true;
      final saved = await repository.save(
        draft,
        logo: _logo,
        removeLogo: _removeLogo,
      );
      if (!_current) return;
      setState(() {
        _accept(saved);
        _status = status;
        _verified = true;
      });
      ref.invalidate(platformBrandingProvider);
      ref.invalidate(platformBrandingLogoProvider);
      if (mounted) context.appSuccess('平台设置已保存，登录页、导航与主题将使用新品牌');
    } on ApiException catch (e) {
      if (!_current) return;
      if (e.code == 'CONFLICT' || e.httpStatus == 409) {
        setState(() => _conflict = '设置已被其他管理员修改。你的编辑已保留，请复制需要的内容，再读取最新设置重新确认。');
      } else {
        setState(() {
          _error = _errorMessage(e);
          if (e is NetworkException ||
              e is NetworkTimeoutException ||
              (e.httpStatus ?? 0) >= 500) {
            _verified = false;
            _saveUncertain = commandStarted;
            if (commandStarted) _error = '保存结果尚未确认，请重新检测连接，再读取服务器最新设置核对。';
          }
        });
      }
    } catch (e) {
      if (!_current) return;
      setState(() {
        _error = _errorMessage(e);
        _verified = false;
        _saveUncertain = commandStarted;
        if (commandStarted) _error = '保存结果尚未确认，请重新检测连接，再读取服务器最新设置核对。';
      });
    } finally {
      if (mounted && _current) {
        setState(() => _saving = false);
        if (_error != null || _conflict != null) {
          FocusScope.of(context).unfocus();
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted || !_scrollController.hasClients) return;
            _scrollController.animateTo(
              0,
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 200),
              curve: Curves.easeOut,
            );
          });
        }
      }
    }
  }

  Future<bool> _confirmDiscard() async {
    if (!_dirty) return true;
    return await UtenNotify.alert(
              context,
              title: '有尚未保存的修改',
              message: '离开或重新读取会丢弃本次编辑。',
              confirmLabel: '丢弃修改',
              cancelLabel: '继续编辑',
            ) ==
            true &&
        _current;
  }

  Future<void> _reload() async {
    if (_busy || !await _confirmDiscard() || !_current) return;
    await _load();
  }

  Future<void> _revert() async {
    if (_busy) return;
    if (_conflict != null || _saveUncertain) {
      await _reload();
    } else {
      setState(() => _accept(_original!));
    }
  }

  Future<void> _switchServer() async {
    if (_busy || !await _confirmDiscard() || !mounted || !_current) return;
    if (_dirty) setState(() => _accept(_original!));
    await showDialog<void>(
      context: context,
      builder: (_) => const ServerSwitchDialog(),
    );
    if (_current) await _load(connectionOnly: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final endpoint = ref.watch(apiBaseUrlProvider);
    return PopScope(
      canPop: !_dirty || _allowPop,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || _busy) return;
        if (await _confirmDiscard() && _current) {
          setState(() => _allowPop = true);
          if (context.mounted) context.pop();
        }
      },
      child: Scaffold(
        appBar: const UtenAppBar(title: '平台设置', leading: UtenBackButton()),
        body: UtenContentContainer(
          child: ListView(
            controller: _scrollController,
            padding: const EdgeInsets.only(
              top: 16,
              bottom: UtenFloatingActionGroup.scrollClearance,
            ),
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('公司平台配置', style: theme.textTheme.titleLarge),
                        const SizedBox(height: UtenSpacing.s4),
                        Text(
                          '管理公司品牌、服务器连接与配置入口。',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: UtenSpacing.s12),
                  Tooltip(
                    message: '仅超级管理员 · 公司统一设置',
                    child: Icon(
                      Icons.admin_panel_settings_outlined,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _connectionSummary(endpoint),
              if (_cachedDisplay && !_verified) ...[
                const SizedBox(height: 12),
                _notice('正在显示当前服务器上次确认的品牌，暂时只读。连接验证成功后才能修改和保存。'),
              ],
              if (_error != null) ...[
                const SizedBox(height: 12),
                _notice(_error!, error: true),
              ],
              if (_conflict != null) ...[
                const SizedBox(height: 12),
                _notice(_conflict!, error: true),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: _busy ? null : _reload,
                    child: const Text('读取最新设置'),
                  ),
                ),
              ],
              const SizedBox(height: 16),
              UtenSegmentRow<int>(
                showSelectedIcon: false,
                emptySelectionAllowed: true,
                selected: {_section},
                onSelectionChanged: _busy
                    ? null
                    : (next) {
                        if (next.isEmpty || next.single == _section) return;
                        setState(() => _section = next.single);
                        _scrollController.jumpTo(0);
                      },
                segments: [
                  for (final (index, label) in const [
                    '公司与品牌',
                    '服务器与文件',
                    '配置导航',
                  ].indexed)
                    ButtonSegment(
                      value: index,
                      label: Text(label),
                      enabled: !_busy,
                    ),
                ],
              ),
              const SizedBox(height: 20),
              if (_loading && _original == null)
                const Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_section == 0 && _original != null)
                _brandEditor()
              else if (_section == 1)
                _serverDetails()
              else if (_section == 2)
                _configurationLinks()
              else
                _notice('连接验证通过后，可以设置公司名称、Logo 和主题色。'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _connectionSummary(String endpoint) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final mode = kIsWeb
        ? '当前网页入口'
        : switch (readServerMode(ref.watch(sharedPreferencesProvider))) {
            ServerMode.auto => '自动优先公司内网',
            ServerMode.local => '仅公司内网',
            ServerMode.cloud => '仅托管云端',
          };
    return UtenCard(
      key: const ValueKey('platform-connection-summary'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final details = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(UtenSpacing.s12),
                decoration: BoxDecoration(
                  color: _verified
                      ? cs.primaryContainer
                      : cs.surfaceContainerHigh,
                  borderRadius: UtenRadius.controlAll,
                ),
                child: Icon(
                  _loading
                      ? Icons.sync
                      : _verified
                      ? Icons.dns_outlined
                      : Icons.cloud_off_outlined,
                  color: _verified
                      ? cs.onPrimaryContainer
                      : cs.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _loading
                          ? '正在验证服务器和数据库…'
                          : _verified
                          ? '已连接 · 数据库已就绪'
                          : '尚未确认连接',
                      key: const ValueKey('platform-connection-state'),
                      style: theme.textTheme.titleSmall,
                    ),
                    const SizedBox(height: UtenSpacing.s4),
                    SelectableText(endpoint, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: UtenSpacing.s4),
                    Text(
                      '连接方式：$mode',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: cs.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
          final actions = Wrap(
            spacing: UtenSpacing.s4,
            runSpacing: UtenSpacing.s4,
            children: [
              UtenButton(
                type: UtenButtonType.secondary,
                size: UtenButtonSize.small,
                isLoading: _loading,
                onPressed: _busy ? null : () => _load(connectionOnly: true),
                icon: Icons.refresh,
                child: const Text('重新检测'),
              ),
              TextButton.icon(
                onPressed: _busy ? null : _switchServer,
                icon: const Icon(Icons.dns_outlined),
                label: const Text('连接方式'),
              ),
            ],
          );
          if (constraints.maxWidth >= 900 * _textScale) {
            return Row(
              children: [
                Expanded(child: details),
                const SizedBox(width: UtenSpacing.s24),
                actions,
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              details,
              const SizedBox(height: UtenSpacing.s12),
              actions,
            ],
          );
        },
      ),
    );
  }

  double get _textScale =>
      (MediaQuery.textScalerOf(context).scale(14) / 14).clamp(1.0, 3.0);

  Widget _notice(String text, {bool error = false}) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: error ? cs.errorContainer : cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(UtenRadius.lg),
      ),
      child: Text(
        text,
        style: TextStyle(color: error ? cs.onErrorContainer : cs.onSurface),
      ),
    );
  }

  Widget _brandEditor() => Form(
    key: _formKey,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final fields = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _card('公司与平台', '公司显示名称用于界面；财务与报销的法定抬头在对应业务设置中维护。', [
                  _fields(['companyName', 'platformName']),
                  _field('companyAliases', lines: 3),
                  _field('tagline'),
                  _field('loginNotice', lines: 3),
                ]),
                const SizedBox(height: 16),
                _card(
                  '品牌 Logo',
                  'PNG / JPEG · 最大 512 KB · 宽高不超过 2048 像素。图片会随保存一起上传，替换前仍使用原 Logo。',
                  [
                    if (_logoName != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Text('待保存：$_logoName'),
                      ),
                    if (_removeLogo)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 10),
                        child: Text('保存后移除上传的 Logo，使用默认公司标识'),
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          key: const ValueKey('platform-pick-logo'),
                          onPressed: _busy || !_verified ? null : _pickLogo,
                          icon: const Icon(Icons.upload_outlined),
                          label: Text(_picking ? '正在读取…' : '选择 Logo'),
                        ),
                        if (_original!.hasLogo || _logo != null)
                          TextButton(
                            onPressed: _busy || !_verified
                                ? null
                                : () => setState(() {
                                    _logo = null;
                                    _logoName = null;
                                    _removeLogo = _original!.hasLogo;
                                  }),
                            child: const Text('移除 Logo'),
                          ),
                        if (_logo != null || _removeLogo)
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(() {
                                    _logo = null;
                                    _logoName = null;
                                    _removeLogo = false;
                                  }),
                            child: const Text('恢复原 Logo'),
                          ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _card('主题配色', '输入六位色值或选择配色。预览可切换深浅模式；文字对比度由主题系统自动适配。', [
                  _fields(['primaryColor', 'secondaryColor']),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final palette in const [
                        ('青绿', '#0F766E', '#2DD4BF'),
                        ('蓝色', '#1D4ED8', '#38BDF8'),
                        ('紫色', '#7C3AED', '#C4B5FD'),
                        ('橙色', '#C2410C', '#FDBA74'),
                      ])
                        OutlinedButton(
                          onPressed: _busy || !_verified
                              ? null
                              : () {
                                  _controllers['primaryColor']!.text =
                                      palette.$2;
                                  _controllers['secondaryColor']!.text =
                                      palette.$3;
                                },
                          child: Text(palette.$1),
                        ),
                    ],
                  ),
                ]),
                const SizedBox(height: 16),
                _card('对外联系信息', '填写后会显示在登录页，请使用可以公开的公司联系方式。留空则不显示。', [
                  _fields(['supportPhone', 'supportEmail']),
                  _field('website'),
                ]),
              ],
            );
            if (constraints.maxWidth >= 1100 * _textScale) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 7, child: fields),
                  const SizedBox(width: 20),
                  Expanded(flex: 3, child: _preview()),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [fields, const SizedBox(height: 16), _preview()],
            );
          },
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            UtenButton(
              key: const ValueKey('platform-save'),
              onPressed: _busy || !_verified || !_dirty || _conflict != null
                  ? null
                  : _save,
              isLoading: _saving,
              icon: Icons.check,
              child: const Text('保存平台设置'),
            ),
            TextButton(
              onPressed: _busy || !_dirty ? null : _revert,
              child: Text(
                _conflict != null || _saveUncertain ? '撤销并读取最新' : '撤销修改',
              ),
            ),
            Text(
              _dirty
                  ? '有未保存的修改'
                  : '${_verified ? '已保存' : '上次确认'} · 版本 ${_original!.version}',
              key: const ValueKey('platform-dirty-state'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          '保存后会对当前服务器的全体用户生效。系统会确认管理员密码并记录修改；其他设备会自动刷新品牌。安装图标、安装包名称与启动画面由发布版本决定。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ),
  );

  Widget _card(
    String title,
    String subtitle,
    List<Widget> children, {
    BuildContext? localContext,
    Key? key,
  }) => UtenCard(
    key: key,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: Theme.of(
            localContext ?? context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: Theme.of(localContext ?? context).textTheme.bodySmall
              ?.copyWith(
                color: Theme.of(
                  localContext ?? context,
                ).colorScheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 16),
        ...children,
      ],
    ),
  );

  Widget _fields(List<String> keys) => LayoutBuilder(
    builder: (context, constraints) {
      if (constraints.maxWidth < 520 * _textScale) {
        return Column(children: [for (final key in keys) _field(key)]);
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: _field(keys[0])),
          const SizedBox(width: 16),
          Expanded(child: _field(keys[1])),
        ],
      );
    },
  );

  Widget _field(String key, {int lines = 1}) {
    final (label, max) = _labels[key]!;
    final colorField = key.endsWith('Color');
    final colorText = _controllers[key]!.text.trim();
    final color = RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(colorText)
        ? Color(int.parse('FF${colorText.substring(1)}', radix: 16))
        : null;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TextFormField(
        errorBuilder: utenTextFieldErrorBuilder,
        key: ValueKey('platform-$key'),
        controller: _controllers[key],
        enabled: !_busy && _verified,
        maxLines: lines,
        keyboardType: key == 'supportEmail'
            ? TextInputType.emailAddress
            : key == 'website'
            ? TextInputType.url
            : null,
        decoration: UtenInputDecoration(
          InputDecoration(
            labelText:
                '$label${key == 'companyName' || key == 'platformName' ? ' *' : ''}',
            hintText: colorField ? '#RRGGBB' : null,
            suffixIcon: !colorField
                ? null
                : IconButton(
                    tooltip: '选择$label',
                    onPressed: _busy || !_verified
                        ? null
                        : () async {
                            final selected = await showDialog<String>(
                              context: context,
                              builder: (_) => PlatformColorPickerDialog(
                                title: label,
                                initial:
                                    color ??
                                    Theme.of(context).colorScheme.primary,
                              ),
                            );
                            if (mounted && _current && selected != null) {
                              _controllers[key]!.text = selected;
                            }
                          },
                    icon: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: color ?? Theme.of(context).colorScheme.primary,
                        border: Border.all(
                          color: Theme.of(context).colorScheme.outline,
                        ),
                        borderRadius: BorderRadius.circular(UtenRadius.sm),
                      ),
                    ),
                  ),
          ),
          info: key == 'companyAliases'
              ? '每行一个名称，最多 16 个。填写单据上的公司英文名或简称，帮助客户文件识别排除我方信息；不要填写客户或供应商名称。'
              : null,
        ),
        validator: (value) {
          final text = value?.trim() ?? '';
          if ((key == 'companyName' || key == 'platformName') && text.isEmpty) {
            return '请填写$label';
          }
          if (text.length > max) return '$label不能超过 $max 个字符';
          if (key == 'companyAliases' && text.isNotEmpty) {
            final aliases = text
                .split('\n')
                .map((name) => name.trim())
                .where((name) => name.isNotEmpty)
                .toList();
            if (aliases.length > 16 ||
                aliases.any((name) => name.length < 2 || name.length > 120)) {
              return '最多填写 16 个名称，每个名称为 2 至 120 个字符';
            }
          }
          if (colorField && !RegExp(r'^#[0-9a-fA-F]{6}$').hasMatch(text)) {
            return '请输入六位色值，例如 #0F766E';
          }
          if (key == 'supportEmail' &&
              text.isNotEmpty &&
              !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(text)) {
            return '请填写有效的邮箱';
          }
          if (key == 'website' && text.isNotEmpty) {
            final uri = Uri.tryParse(text);
            if (uri == null ||
                uri.scheme != 'https' ||
                uri.host.isEmpty ||
                uri.userInfo.isNotEmpty) {
              return '请填写 https:// 开头的公司网站';
            }
          }
          return null;
        },
      ),
    );
  }

  Widget _preview() {
    final branding = _draft(preview: true);
    final previewTheme = _previewDark
        ? buildDarkTheme(branding: branding)
        : buildLightTheme(branding: branding);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(child: Text('实时预览 · 未保存')),
            TextButton(
              onPressed: () => setState(() => _previewDark = !_previewDark),
              child: Text(_previewDark ? '浅色' : '深色'),
            ),
          ],
        ),
        Theme(
          data: previewTheme,
          child: Builder(
            builder: (context) => _card('登录与导航效果', '预览只影响这里。', [
              Center(
                child: _logo != null
                    ? Image.memory(
                        _logo!,
                        height: 64,
                        width: 240,
                        fit: BoxFit.contain,
                        errorBuilder: (_, _, _) => const Text('图片无法预览'),
                      )
                    : PlatformBrandLogo(branding: branding, height: 64),
              ),
              const SizedBox(height: 18),
              Text(
                branding.platformName.isEmpty ? '平台名称' : branding.platformName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              Text(branding.companyName),
              if (branding.tagline.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(branding.tagline),
              ],
              if (branding.loginNotice.isNotEmpty) ...[
                const SizedBox(height: 12),
                Text(branding.loginNotice),
              ],
              const SizedBox(height: 18),
              UtenButton(
                onPressed: () {},
                isExpanded: true,
                child: const Text('登录平台'),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: Chip(
                  label: const Text('待办提醒'),
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.secondaryContainer,
                  labelStyle: TextStyle(
                    color: Theme.of(context).colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
            ], localContext: context),
          ),
        ),
      ],
    );
  }

  Widget _serverDetails() {
    final theme = Theme.of(context);
    // A previous successful read is not evidence for the current connection.
    final status = _verified ? _status : null;
    final storageName = switch (status?.attachmentStorageBackend) {
      null => '等待验证',
      'local' => '服务器本地目录',
      'oss' => '对象存储 (OSS)',
      'disabled' => '未配置',
      final name => name,
    };
    final storage = _card(
      'Logo 与附件存储',
      '公司品牌随数据库备份，业务附件由独立的文件存储管理。',
      [
        _settingRow('品牌 Logo', status == null ? '等待验证' : '公司数据库'),
        const Divider(height: UtenSpacing.s24),
        _settingRow('业务附件', storageName),
        const Divider(height: UtenSpacing.s24),
        _settingRow(
          '附件上传',
          status == null
              ? '等待验证'
              : status.attachmentUploadsEnabled
              ? '已配置开放'
              : '未开放',
          icon: status == null
              ? Icons.help_outline
              : status.attachmentUploadsEnabled
              ? Icons.check_circle_outline
              : Icons.pause_circle_outline,
        ),
        const SizedBox(height: UtenSpacing.s16),
        Text(
          '上传状态反映服务器配置，实际可用性以附件上传校验为准。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ],
      key: const ValueKey('platform-storage-card'),
    );
    final maintenance = _card('部署维护', '查看运行情况、数据库连接和备份记录。', [
      Align(
        alignment: Alignment.centerLeft,
        child: OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _openConfiguration(RouteName.adminServerStatus),
          icon: const Icon(Icons.dns_outlined),
          label: const Text('服务器状态与备份'),
        ),
      ),
      const SizedBox(height: UtenSpacing.s20),
      Text('由服务器维护人员管理', style: theme.textTheme.titleSmall),
      const SizedBox(height: UtenSpacing.s8),
      const Text('数据库地址、证书、文件目录、备份与加密密钥。'),
      const SizedBox(height: UtenSpacing.s8),
      Text(
        '本页的连接方式只影响当前设备。',
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    ], key: const ValueKey('platform-maintenance-card'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxWidth >= 900 * _textScale) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(flex: 3, child: storage),
                  const SizedBox(width: UtenSpacing.s16),
                  Expanded(flex: 2, child: maintenance),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                storage,
                const SizedBox(height: UtenSpacing.s16),
                maintenance,
              ],
            );
          },
        ),
        const SizedBox(height: UtenSpacing.s16),
        _card(
          '版本更新与设置保留',
          '正常更新网页、桌面或手机应用，会继续保留已有配置。',
          [
            UtenResponsiveGrid(
              itemCount: 2,
              maxColumns: 2,
              minItemWidth: 360,
              itemBuilder: (_, index, _) => _retentionSummary(
                index == 0 ? Icons.business_outlined : Icons.devices_outlined,
                index == 0 ? '公司设置 · 保存在服务器' : '个人偏好 · 保存在当前设备',
                index == 0 ? '公司名称、Logo、配色和联系信息。' : '同一访问入口、同一应用更新后继续使用。',
              ),
            ),
            const SizedBox(height: UtenSpacing.s12),
            const Divider(height: 1),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(bottom: UtenSpacing.s8),
              shape: const Border(),
              collapsedShape: const Border(),
              title: Text('查看更新与部署说明', style: theme.textTheme.bodyMedium),
              expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '公司配置随数据库备份与还原，不随安装包替换。切换到另一家公司服务器时，会重新读取该公司的品牌。',
                  style: theme.textTheme.bodySmall,
                ),
                const SizedBox(height: UtenSpacing.s8),
                Text(
                  '卸载并清除应用数据、清理浏览器数据属于额外操作，可能清除个人偏好。更换公司部署须先完成独立数据库与服务器初始化，数据库和密钥不通过本页迁移或复制。',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ],
          key: const ValueKey('platform-upgrade-card'),
        ),
      ],
    );
  }

  Widget _settingRow(String label, String value, {IconData? icon}) =>
      LayoutBuilder(
        builder: (context, constraints) {
          final theme = Theme.of(context);
          final caption = Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          );
          final content = Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: UtenSpacing.s8),
              ],
              Expanded(
                child: Text(
                  value,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          );
          if (constraints.maxWidth < 400 * _textScale) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                caption,
                const SizedBox(height: UtenSpacing.s6),
                content,
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 128 * _textScale, child: caption),
              const SizedBox(width: UtenSpacing.s16),
              Expanded(child: content),
            ],
          );
        },
      );

  Widget _retentionSummary(IconData icon, String title, String description) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: Theme.of(context).colorScheme.onSurfaceVariant),
          const SizedBox(width: UtenSpacing.s12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: UtenSpacing.s6),
                Text(description, style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
        ],
      );

  Widget _configurationLinks() {
    final entries = platformSettingsEntriesFor(
      ref.watch(currentPermissionsProvider),
      ref.watch(sessionProvider).user?.superAdmin ?? false,
    );
    const groups = [
      (
        '平台管理',
        '全公司的安全、服务和授权规则',
        ['security', 'remote-access', 'ai', 'permissions'],
      ),
      (
        '业务基础配置',
        '按业务维护公司资料、字典和运作方式',
        ['expense', 'basic-data', 'workshop-material'],
      ),
      ('运行维护', '查看当前服务器状态及配置修改记录', ['server-status', 'audit']),
      ('我的偏好', '这些设置只影响当前用户或设备', ['personal']),
    ];
    final visible = [
      for (final group in groups)
        if (entries.any((entry) => group.$3.contains(entry.id))) group,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('平台配置导航', style: Theme.of(context).textTheme.titleLarge),
        const SizedBox(height: 8),
        const Text('公司统一策略、业务基础配置和运行维护分组管理，各项使用原有权限与保存规则。'),
        const SizedBox(height: 16),
        UtenResponsiveGrid(
          itemCount: visible.length,
          maxColumns: 2,
          minItemWidth: 400,
          itemBuilder: (_, index, _) {
            final group = visible[index];
            return _card(group.$1, group.$2, [
              for (final entry in entries.where(
                (entry) => group.$3.contains(entry.id),
              ))
                _link(
                  entry.id == 'remote-access'
                      ? remoteAccessText(context, 'title')
                      : entry.title,
                  entry.id == 'remote-access'
                      ? remoteAccessText(context, 'description')
                      : entry.description,
                  switch (entry.id) {
                    'remote-access' => Icons.public_outlined,
                    'security' => Icons.security_outlined,
                    'ai' => Icons.auto_awesome_outlined,
                    'expense' => Icons.receipt_long_outlined,
                    'permissions' => Icons.admin_panel_settings_outlined,
                    'basic-data' => Icons.category_outlined,
                    'workshop-material' => Icons.warehouse_outlined,
                    'server-status' => Icons.dns_outlined,
                    'audit' => Icons.history_outlined,
                    _ => Icons.tune_outlined,
                  },
                  entry.location,
                ),
            ]);
          },
        ),
      ],
    );
  }

  Widget _link(String title, String subtitle, IconData icon, String route) =>
      ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(icon),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: const Icon(Icons.chevron_right),
        onTap: _busy ? null : () => _openConfiguration(route),
      );

  Future<void> _openConfiguration(String route) async {
    if (_busy || !await _confirmDiscard() || !_current) return;
    if (_dirty) setState(() => _accept(_original!));
    if (mounted) context.push(route);
  }
}
