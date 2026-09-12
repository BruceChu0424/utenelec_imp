part of 'admin_audit_log_page.dart';

class _AuditDeviceTab extends ConsumerStatefulWidget {
  const _AuditDeviceTab({required this.detail});

  final AuditLogDetail detail;

  @override
  ConsumerState<_AuditDeviceTab> createState() => _AuditDeviceTabState();
}

class _AuditDeviceTabState extends ConsumerState<_AuditDeviceTab> {
  _LocalReceiptAuthorizationState _authorization =
      _LocalReceiptAuthorizationState.idle;

  String? get _eventId =>
      widget.detail.clientEventId ?? widget.detail.device?.clientEventId;

  Future<void> _authorizeLocalReceiptRead() async {
    final eventId = _eventId;
    if (eventId == null ||
        eventId.trim().isEmpty ||
        _authorization == _LocalReceiptAuthorizationState.loading) {
      return;
    }
    setState(() => _authorization = _LocalReceiptAuthorizationState.loading);
    try {
      await ref
          .read(apiClientProvider)
          .post(ApiEndpoints.adminAuditLocalReceiptVerification(eventId));
      if (!mounted) return;
      setState(
        () => _authorization = _LocalReceiptAuthorizationState.authorized,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _authorization = _LocalReceiptAuthorizationState.failed);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_authorization == _LocalReceiptAuthorizationState.authorized) {
      return _AuthorizedAuditDeviceTab(detail: widget.detail);
    }

    final eventId = _eventId;
    final assessment = _preAuthorizationDeviceAssessment(
      detail: widget.detail,
      eventId: eventId,
      state: _authorization,
    );
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        _DeviceEvidenceBanner(assessment: assessment),
        const SizedBox(height: UtenSpacing.s12),
        _LocalReceiptAuthorizationCard(
          eventId: eventId,
          state: _authorization,
          onAuthorize: _authorizeLocalReceiptRead,
        ),
        const SizedBox(height: UtenSpacing.s12),
        _ServerDeviceCard(detail: widget.detail),
        const SizedBox(height: UtenSpacing.s12),
        _CorrelationCard(detail: widget.detail, receipt: null),
        const SizedBox(height: UtenSpacing.s12),
        _DeviceTrustNotice(captureStatus: widget.detail.device?.captureStatus),
      ],
    );
  }
}

_DeviceEvidenceAssessment _preAuthorizationDeviceAssessment({
  required AuditLogDetail detail,
  required String? eventId,
  required _LocalReceiptAuthorizationState state,
}) {
  final server = detail.device;
  if (server == null ||
      server.captureStatus == 'legacy' ||
      server.captureStatus == 'missing') {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.unavailable,
      '这条记录没有设备快照',
      '可能是功能升级前的历史记录，或请求并非来自新版 Uten 客户端。服务器操作记录仍然有效。',
    );
  }
  if (server.captureStatus == 'invalid') {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.invalid,
      '客户端设备信息无效',
      '服务器拒绝了格式异常的设备上下文，但仍保留请求、账号、IP、结果与时间用于调查。',
    );
  }
  if (eventId == null || eventId.trim().isEmpty) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.unavailable,
      '没有可核查的本地操作 ID',
      '本条服务器记录缺少本地操作 ID，因此不会读取当前设备的本机信息或回执。',
    );
  }
  return switch (state) {
    _LocalReceiptAuthorizationState.loading => const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.loading,
      '正在申请本机回执核查授权',
      '服务端正在校验当前人员的审计查看权限并记录本次核查；此时尚未读取本机数据。',
    ),
    _LocalReceiptAuthorizationState.failed => const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.unavailable,
      '本机回执核查未获授权',
      '需联网完成授权核查；未读取本机安装标识、设备信息或操作回执。',
    ),
    _ => const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.partial,
      '尚未核查本机回执',
      '当前只展示服务器保存的证据。点击“授权并核对本机回执”后，服务端将校验权限并记录本次核查。',
    ),
  };
}

class _LocalReceiptAuthorizationCard extends StatelessWidget {
  const _LocalReceiptAuthorizationCard({
    required this.eventId,
    required this.state,
    required this.onAuthorize,
  });

  final String? eventId;
  final _LocalReceiptAuthorizationState state;
  final VoidCallback onAuthorize;

  @override
  Widget build(BuildContext context) {
    final loading = state == _LocalReceiptAuthorizationState.loading;
    final failed = state == _LocalReceiptAuthorizationState.failed;
    final canAuthorize = eventId?.trim().isNotEmpty == true && !loading;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _EvidenceSectionTitle(
            icon: Icons.admin_panel_settings_outlined,
            title: '授权读取当前设备的本机回执',
            subtitle: '仅按这条记录的完整本地操作 ID 精确核查，不支持枚举；授权请求本身也会写入审计日志。',
          ),
          const SizedBox(height: UtenSpacing.s12),
          Text(
            eventId == null || eventId!.trim().isEmpty
                ? '本条记录没有本地操作 ID，无法发起核查。'
                : failed
                ? '需联网完成授权核查；未读取本机回执。请确认权限和网络后重试。'
                : '授权成功前，页面不会读取本机安装标识、设备资料或操作回执。',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
          ),
          const SizedBox(height: UtenSpacing.s12),
          FilledButton.icon(
            key: const ValueKey('authorize-local-audit-receipt'),
            onPressed: canAuthorize ? onAuthorize : null,
            icon: loading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    failed
                        ? Icons.refresh_rounded
                        : Icons.phonelink_lock_outlined,
                  ),
            label: Text(
              loading
                  ? '正在授权…'
                  : failed
                  ? '重新授权并核对'
                  : '授权并核对本机回执',
            ),
          ),
        ],
      ),
    );
  }
}

class _AuthorizedAuditDeviceTab extends ConsumerWidget {
  const _AuthorizedAuditDeviceTab({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final device = detail.device;
    final eventId = detail.clientEventId ?? device?.clientEventId;
    final currentAsync = ref.watch(currentDeviceAuditProfileProvider);
    final receiptAsync = eventId == null
        ? null
        : ref.watch(localAuditReceiptProvider(eventId));
    final current = currentAsync.valueOrNull;
    final receipt = receiptAsync?.valueOrNull;
    final assessment = _assessDeviceEvidence(
      detail: detail,
      current: current,
      receipt: receipt,
      profileLoading: currentAsync.isLoading,
      profileFailed: currentAsync.hasError,
      receiptLoading: receiptAsync?.isLoading ?? false,
      receiptFailed: receiptAsync?.hasError ?? false,
    );

    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        _DeviceEvidenceBanner(assessment: assessment),
        const SizedBox(height: UtenSpacing.s12),
        _ServerDeviceCard(detail: detail),
        const SizedBox(height: UtenSpacing.s12),
        _CorrelationCard(detail: detail, receipt: receipt),
        if (receipt != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          _LocalReceiptCard(detail: detail, receipt: receipt),
        ] else if (current != null) ...[
          const SizedBox(height: UtenSpacing.s12),
          _CurrentDeviceCard(profile: current),
        ],
        const SizedBox(height: UtenSpacing.s12),
        _DeviceTrustNotice(captureStatus: device?.captureStatus),
      ],
    );
  }
}

enum _DeviceEvidenceState {
  matched,
  partial,
  mismatch,
  otherDevice,
  localMissing,
  invalid,
  unavailable,
  loading,
}

class _DeviceEvidenceAssessment {
  const _DeviceEvidenceAssessment(this.state, this.title, this.description);

  final _DeviceEvidenceState state;
  final String title;
  final String description;
}

_DeviceEvidenceAssessment _assessDeviceEvidence({
  required AuditLogDetail detail,
  required DeviceAuditProfile? current,
  required LocalAuditReceipt? receipt,
  required bool profileLoading,
  required bool profileFailed,
  required bool receiptLoading,
  required bool receiptFailed,
}) {
  final server = detail.device;
  if (server == null ||
      server.captureStatus == 'legacy' ||
      server.captureStatus == 'missing') {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.unavailable,
      '这条记录没有设备快照',
      '可能是功能升级前的历史记录，或请求并非来自新版 Uten 客户端。服务器操作记录仍然有效。',
    );
  }
  if (server.captureStatus == 'invalid') {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.invalid,
      '客户端设备信息无效',
      '服务器拒绝了格式异常的设备上下文，但仍保留请求、账号、IP、结果与时间用于调查。',
    );
  }
  if (profileLoading || receiptLoading) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.loading,
      '正在核对本机回执',
      '正在读取当前设备的安全存储，不影响服务器审计记录。',
    );
  }
  if (profileFailed || current == null) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.unavailable,
      '当前设备信息不可读取',
      '设备插件或本机安全存储不可用，暂时只能查看服务器记录。',
    );
  }
  if (server.installationId == null ||
      server.installationId != current.installationId) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.otherDevice,
      '当前查看设备不是原操作设备',
      '浏览器和应用不能远程读取另一台设备的本地安全存储；请在原设备按本地操作 ID 核查回执。',
    );
  }
  if (receiptFailed || receipt == null) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.localMissing,
      '服务器有记录，本机回执未找到',
      '本机最多保留最近 300 条，并按系统审计总留存月数清理；清理站点数据、卸载应用或本机存储异常也会使回执不可用。',
    );
  }
  if (!receipt.integrityVerified) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.invalid,
      '本机回执完整性校验失败',
      '本机数据可能被修改、密钥已变化或写入中断；不能把这份回执作为一致性依据。服务器记录不受影响。',
    );
  }
  final attempt = receipt.attemptForRequest(detail.requestId);
  if (attempt == null) {
    if (receipt.allAttempts.every((value) => value.serverRequestId == null)) {
      return const _DeviceEvidenceAssessment(
        _DeviceEvidenceState.partial,
        '本机回执缺少服务器请求追踪号',
        '旧响应或中间网络设备没有回显关联编号；设备与本地操作仍可人工查看，但不能自动锁定具体请求尝试。',
      );
    }
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.mismatch,
      '未找到这一次服务器请求的本机尝试',
      '同一个本地操作可能因刷新令牌或网络重试产生多次 Request ID；本机尝试链中没有当前这一条。',
    );
  }
  if (attempt.outcome == 'pending' || attempt.completedAt == null) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.partial,
      '本机回执仍未完成',
      '应用可能在响应落盘前退出，或本机写入仍在进行；请稍后重开详情核查。',
    );
  }
  if (!_receiptMatches(detail, receipt)) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.mismatch,
      '本机回执与服务器记录不一致',
      '至少一个关联编号、请求字段或设备快照不同，请结合 IP、时间和字段变更人工复核。',
    );
  }
  if (attempt.serverRequestId == null || detail.requestId == null) {
    return const _DeviceEvidenceAssessment(
      _DeviceEvidenceState.partial,
      '设备与操作信息一致，关联证据不完整',
      '本机设备快照和请求字段一致，但旧响应没有完整回显服务器请求追踪号。',
    );
  }
  return const _DeviceEvidenceAssessment(
    _DeviceEvidenceState.matched,
    '本机回执与服务器记录一致',
    '安装标识、设备快照、本地操作编号、服务器请求追踪号与可比请求字段一致。'
        '此结论表示记录一致，不是硬件身份认证。',
  );
}

bool _receiptMatches(AuditLogDetail detail, LocalAuditReceipt receipt) {
  final server = detail.device;
  final attempt = receipt.attemptForRequest(detail.requestId);
  if (!receipt.integrityVerified ||
      attempt == null ||
      server == null ||
      server.installationId != receipt.installationId) {
    return false;
  }
  final eventId = detail.clientEventId ?? server.clientEventId;
  if (eventId == null || eventId != receipt.clientEventId) return false;
  if (detail.httpMethod != null &&
      detail.httpMethod!.toUpperCase() != attempt.method.toUpperCase()) {
    return false;
  }
  if (detail.httpPath != null && detail.httpPath != attempt.path) return false;
  if (detail.statusCode != null &&
      attempt.statusCode != null &&
      detail.statusCode != attempt.statusCode) {
    return false;
  }
  if (detail.statusCode != null) {
    final expectedOutcome = detail.statusCode! >= 400 ? 'failure' : 'success';
    if (attempt.outcome != expectedOutcome) return false;
  }
  if (!_sameInstant(server.clientEventAt, attempt.startedAt)) return false;
  return _sameValue(server.deviceName, receipt.device.deviceName) &&
      _sameValue(server.manufacturer, receipt.device.manufacturer) &&
      _sameValue(server.model, receipt.device.model) &&
      _sameValue(server.platform, receipt.device.platform) &&
      _sameValue(server.osVersion, receipt.device.osVersion) &&
      _sameValue(server.appVersion, receipt.device.appVersion) &&
      _sameValue(server.appBuild, receipt.device.appBuild) &&
      _sameValue(server.formFactor, receipt.device.formFactor) &&
      _sameValue(server.browserName, receipt.device.browserName) &&
      _sameValue(server.locale, receipt.device.locale) &&
      _sameValue(server.timeZone, receipt.device.timeZone) &&
      server.timeZoneOffsetMinutes == receipt.device.timeZoneOffsetMinutes &&
      server.physicalDevice == receipt.device.isPhysicalDevice;
}

bool _sameValue(String? left, String? right) =>
    (left ?? '').trim() == (right ?? '').trim();

bool _sameInstant(String? left, String? right) {
  if (left == null || right == null) return left == right;
  final leftTime = DateTime.tryParse(left)?.toUtc();
  final rightTime = DateTime.tryParse(right)?.toUtc();
  return leftTime != null && rightTime != null && leftTime == rightTime;
}

class _DeviceEvidenceBanner extends StatelessWidget {
  const _DeviceEvidenceBanner({required this.assessment});

  final _DeviceEvidenceAssessment assessment;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (color, icon, badgeType) = switch (assessment.state) {
      _DeviceEvidenceState.matched => (
        colors.primary,
        Icons.verified_user_outlined,
        UtenStatusBadgeType.success,
      ),
      _DeviceEvidenceState.partial => (
        colors.tertiary,
        Icons.fact_check_outlined,
        UtenStatusBadgeType.warning,
      ),
      _DeviceEvidenceState.mismatch || _DeviceEvidenceState.invalid => (
        colors.error,
        Icons.gpp_bad_outlined,
        UtenStatusBadgeType.danger,
      ),
      _DeviceEvidenceState.loading => (
        colors.primary,
        Icons.sync_rounded,
        UtenStatusBadgeType.info,
      ),
      _ => (
        colors.onSurfaceVariant,
        Icons.devices_other_outlined,
        UtenStatusBadgeType.info,
      ),
    };
    return Semantics(
      liveRegion: true,
      label: '${assessment.title}。${assessment.description}',
      child: Container(
        padding: const EdgeInsets.all(UtenSpacing.s16),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.10),
          borderRadius: UtenRadius.lgAll,
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: color),
            const SizedBox(width: UtenSpacing.s12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  UtenStatusBadge(
                    label: assessment.title,
                    type: badgeType,
                    size: UtenStatusBadgeSize.small,
                  ),
                  const SizedBox(height: UtenSpacing.s8),
                  Text(
                    assessment.description,
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ServerDeviceCard extends StatelessWidget {
  const _ServerDeviceCard({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context) {
    final device = detail.device;
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _EvidenceSectionTitle(
            icon: Icons.dns_outlined,
            title: '服务器保存的设备快照',
            subtitle: '收到请求时清洗并固化，后续设备改名或升级不会改写历史。',
          ),
          const SizedBox(height: UtenSpacing.s16),
          if (device == null)
            const Text('未提供')
          else
            Wrap(
              spacing: UtenSpacing.s24,
              runSpacing: UtenSpacing.s16,
              children: [
                _AuditFact(label: '设备名称', value: device.deviceName ?? '—'),
                _AuditFact(label: '设备厂商', value: device.manufacturer ?? '—'),
                _AuditFact(label: '设备型号', value: device.model ?? '—'),
                _AuditFact(label: '平台', value: device.platform ?? '—'),
                _AuditFact(label: '系统版本', value: device.osVersion ?? '—'),
                _AuditFact(
                  label: '应用版本 / 构建',
                  value:
                      '${device.appVersion ?? '—'} / ${device.appBuild ?? '—'}',
                ),
                _AuditFact(label: '设备形态', value: device.formFactor ?? '—'),
                _AuditFact(label: '浏览器', value: device.browserName ?? '—'),
                _AuditFact(label: '语言区域', value: device.locale ?? '—'),
                _AuditFact(
                  label: '本机时区',
                  value: _timeZoneLabel(
                    device.timeZone,
                    device.timeZoneOffsetMinutes,
                  ),
                ),
                _AuditFact(
                  label: '物理设备状态',
                  value: switch (device.physicalDevice) {
                    true => '客户端报告为真机',
                    false => '客户端报告为模拟器',
                    null => '未提供 / 平台不支持',
                  },
                ),
                _CopyableAuditFact(
                  label: '本机安装标识',
                  value: device.installationId ?? '—',
                ),
                _CopyableAuditFact(
                  label: '设备快照摘要',
                  value: device.profileHash ?? '—',
                ),
                _AuditFact(
                  label: '采集状态',
                  value: _captureStatusLabel(device.captureStatus),
                ),
              ],
            ),
        ],
      ),
    );
  }
}

class _CorrelationCard extends StatelessWidget {
  const _CorrelationCard({required this.detail, required this.receipt});

  final AuditLogDetail detail;
  final LocalAuditReceipt? receipt;

  @override
  Widget build(BuildContext context) {
    final eventId = detail.clientEventId ?? detail.device?.clientEventId;
    final localReceipt = receipt;
    final matchedAttempt = localReceipt?.attemptForRequest(detail.requestId);
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _EvidenceSectionTitle(
            icon: Icons.link_rounded,
            title: '操作关联编号与时间',
            subtitle: '本地操作编号串联客户端回执；请求追踪号串联服务器请求与数据库变更。',
          ),
          const SizedBox(height: UtenSpacing.s16),
          Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s16,
            children: [
              _CopyableAuditFact(
                label: '服务器请求追踪号',
                value: detail.requestId ?? '—',
              ),
              _CopyableAuditFact(label: '本地操作编号', value: eventId ?? '—'),
              _AuditFact(
                label: '服务器记录时间',
                value: _AdminAuditLogPageState._fmtTime(detail.createdAt),
              ),
              _AuditFact(
                label: '客户端发起时间',
                value: _AdminAuditLogPageState._fmtTime(
                  detail.device?.clientEventAt,
                ),
              ),
              if (matchedAttempt != null)
                _AuditFact(
                  label: '本机回执完成时间',
                  value: _AdminAuditLogPageState._fmtTime(
                    matchedAttempt.completedAt,
                  ),
                ),
              if (localReceipt != null)
                _AuditFact(
                  label: '本机请求尝试次数',
                  value: '${localReceipt.allAttempts.length} 次',
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LocalReceiptCard extends StatelessWidget {
  const _LocalReceiptCard({required this.detail, required this.receipt});

  final AuditLogDetail detail;
  final LocalAuditReceipt receipt;

  @override
  Widget build(BuildContext context) {
    final server = detail.device;
    final attempt =
        receipt.attemptForRequest(detail.requestId) ?? receipt.latestAttempt;
    final comparisons = <(String, String?, String?)>[
      ('本机安装标识', server?.installationId, receipt.installationId),
      ('设备名称', server?.deviceName, receipt.device.deviceName),
      ('设备厂商', server?.manufacturer, receipt.device.manufacturer),
      ('设备型号', server?.model, receipt.device.model),
      ('平台', server?.platform, receipt.device.platform),
      ('系统版本', server?.osVersion, receipt.device.osVersion),
      ('应用版本', server?.appVersion, receipt.device.appVersion),
      ('应用构建', server?.appBuild, receipt.device.appBuild),
      ('设备形态', server?.formFactor, receipt.device.formFactor),
      ('浏览器', server?.browserName, receipt.device.browserName),
      ('语言区域', server?.locale, receipt.device.locale),
      ('时区', server?.timeZone, receipt.device.timeZone),
      (
        '时区偏移(分钟)',
        server?.timeZoneOffsetMinutes?.toString(),
        receipt.device.timeZoneOffsetMinutes?.toString(),
      ),
      (
        '物理设备状态',
        _physicalDeviceLabel(server?.physicalDevice),
        _physicalDeviceLabel(receipt.device.isPhysicalDevice),
      ),
      (
        '客户端发起时间',
        _normalizedTime(server?.clientEventAt),
        _normalizedTime(attempt.startedAt),
      ),
      ('服务器请求追踪号', detail.requestId, attempt.serverRequestId),
      (
        '请求方式',
        _httpMethodLabel(detail.httpMethod),
        _httpMethodLabel(attempt.method),
      ),
      ('请求路径', detail.httpPath, attempt.path),
      ('请求状态码', detail.statusCode?.toString(), attempt.statusCode?.toString()),
      (
        '请求结果',
        detail.statusCode == null
            ? null
            : detail.statusCode! >= 400
            ? '失败'
            : '成功',
        _requestOutcomeLabel(attempt.outcome),
      ),
    ];
    return UtenCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.all(UtenSpacing.s16),
            child: _EvidenceSectionTitle(
              icon: Icons.phonelink_lock_outlined,
              title: '当前设备的本机回执',
              subtitle: '异步尽力写入，使用安全存储中的随机密钥校验普通本地篡改；不保存请求体、查询参数或令牌。',
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              UtenSpacing.s16,
              0,
              UtenSpacing.s16,
              UtenSpacing.s12,
            ),
            child: UtenStatusBadge(
              label: receipt.integrityVerified ? '本机完整性校验通过' : '本机完整性校验失败',
              type: receipt.integrityVerified
                  ? UtenStatusBadgeType.success
                  : UtenStatusBadgeType.danger,
              icon: receipt.integrityVerified
                  ? Icons.verified_outlined
                  : Icons.warning_amber_rounded,
              size: UtenStatusBadgeSize.small,
            ),
          ),
          const Divider(height: 1),
          for (var index = 0; index < comparisons.length; index++) ...[
            _DeviceCompareRow(
              label: comparisons[index].$1,
              serverValue: comparisons[index].$2,
              localValue: comparisons[index].$3,
            ),
            if (index != comparisons.length - 1) const Divider(height: 1),
          ],
          const Divider(height: 1),
          ExpansionTile(
            title: Text('请求尝试链(${receipt.allAttempts.length} 次)'),
            subtitle: const Text('自动刷新令牌或网络重试会保留为同一操作下的多次请求'),
            children: [
              for (final entry in receipt.allAttempts.indexed)
                ListTile(
                  dense: true,
                  leading: CircleAvatar(
                    radius: 14,
                    child: Text('${entry.$1 + 1}'),
                  ),
                  title: Text(
                    '${_httpMethodLabel(entry.$2.method)} ${entry.$2.path}',
                  ),
                  subtitle: SelectableText(
                    '请求追踪号：${entry.$2.serverRequestId ?? '—'}\n'
                    '开始：${_AdminAuditLogPageState._fmtTime(entry.$2.startedAt)} · '
                    '完成：${_AdminAuditLogPageState._fmtTime(entry.$2.completedAt)}',
                  ),
                  trailing: Text(
                    '${entry.$2.statusCode ?? '—'} · '
                    '${_requestOutcomeLabel(entry.$2.outcome) ?? '结果未记录'}',
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

String? _physicalDeviceLabel(bool? value) => switch (value) {
  true => '实体设备',
  false => '模拟环境',
  null => null,
};

String? _normalizedTime(String? value) => value == null
    ? null
    : DisplayDateTime.beijing(
        value,
        fallback: '时间格式无效',
      ).replaceFirst('(北京)', '(北京时间)');

class _CurrentDeviceCard extends StatelessWidget {
  const _CurrentDeviceCard({required this.profile});

  final DeviceAuditProfile profile;

  @override
  Widget build(BuildContext context) {
    return UtenCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _EvidenceSectionTitle(
            icon: Icons.computer_rounded,
            title: '当前查看设备',
            subtitle: '仅用于判断能否读取原操作设备的本地回执。',
          ),
          const SizedBox(height: UtenSpacing.s16),
          Wrap(
            spacing: UtenSpacing.s24,
            runSpacing: UtenSpacing.s16,
            children: [
              _AuditFact(label: '设备', value: profile.displayLabel),
              _AuditFact(label: '平台', value: profile.platform),
              _CopyableAuditFact(
                label: '本机安装标识',
                value: profile.installationId,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DeviceCompareRow extends StatelessWidget {
  const _DeviceCompareRow({
    required this.label,
    required this.serverValue,
    required this.localValue,
  });

  final String label;
  final String? serverValue;
  final String? localValue;

  @override
  Widget build(BuildContext context) {
    final comparable =
        serverValue?.trim().isNotEmpty == true &&
        localValue?.trim().isNotEmpty == true;
    final matches = comparable && _sameValue(serverValue, localValue);
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final status = UtenStatusBadge(
            label: !comparable
                ? '不可比'
                : matches
                ? '一致'
                : '不一致',
            type: !comparable
                ? UtenStatusBadgeType.info
                : matches
                ? UtenStatusBadgeType.success
                : UtenStatusBadgeType.danger,
            icon: !comparable
                ? Icons.remove_rounded
                : matches
                ? Icons.check_rounded
                : Icons.close_rounded,
            size: UtenStatusBadgeSize.small,
          );
          final serverPanel = _AuditDiffValue(
            label: '服务器',
            value: serverValue?.trim().isNotEmpty == true ? serverValue! : '—',
          );
          final localPanel = _AuditDiffValue(
            label: '本机回执',
            value: localValue?.trim().isNotEmpty == true ? localValue! : '—',
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                  status,
                ],
              ),
              const SizedBox(height: UtenSpacing.s8),
              if (constraints.maxWidth < 520)
                Column(
                  children: [
                    serverPanel,
                    const SizedBox(height: UtenSpacing.s8),
                    localPanel,
                  ],
                )
              else
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: serverPanel),
                    const SizedBox(width: UtenSpacing.s8),
                    Expanded(child: localPanel),
                  ],
                ),
            ],
          );
        },
      ),
    );
  }
}

class _EvidenceSectionTitle extends StatelessWidget {
  const _EvidenceSectionTitle({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: theme.colorScheme.primary),
        const SizedBox(width: UtenSpacing.s8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: UtenSpacing.s4),
              Text(
                subtitle,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DeviceTrustNotice extends StatelessWidget {
  const _DeviceTrustNotice({required this.captureStatus});

  final String? captureStatus;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(UtenSpacing.s12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: UtenRadius.mdAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: UtenSpacing.s8),
          Expanded(
            child: Text(
              '可信度说明：服务器可以证明它在该时间收到这些客户端声明并处理了请求；本机 HMAC 只能发现普通编辑或写入损坏，回执仍可被清除，改造客户端也能伪造设备名、型号和安装标识。系统不采集 IMEI、MAC、硬盘序列号。若需更强证明，应另接企业 MDM、设备证书或平台设备证明。当前采集状态：${_captureStatusLabel(captureStatus)}。',
              style: theme.textTheme.bodySmall?.copyWith(height: 1.5),
            ),
          ),
        ],
      ),
    );
  }
}

class _CopyableAuditFact extends StatelessWidget {
  const _CopyableAuditFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 200, maxWidth: 360),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Row(
            children: [
              Expanded(child: SelectableText(value)),
              IconButton(
                tooltip: '复制$label',
                onPressed: value == '—'
                    ? null
                    : () async {
                        await Clipboard.setData(ClipboardData(text: value));
                        if (context.mounted) context.appSuccess('$label已复制');
                      },
                icon: const Icon(Icons.copy_rounded, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

String _timeZoneLabel(String? name, int? offsetMinutes) {
  if (name == null && offsetMinutes == null) return '—';
  if (offsetMinutes == null) return name ?? '—';
  final sign = offsetMinutes >= 0 ? '+' : '-';
  final absolute = offsetMinutes.abs();
  final hours = (absolute ~/ 60).toString().padLeft(2, '0');
  final minutes = (absolute % 60).toString().padLeft(2, '0');
  return '${name ?? '本机时区'} · UTC$sign$hours:$minutes';
}

String _captureStatusLabel(String? value) => switch (value) {
  'present' => '完整',
  'partial' => '部分字段',
  'invalid' => '格式无效',
  'missing' => '未提供',
  'legacy' => '历史记录',
  _ => '未知',
};

class _AuditTechnicalTab extends StatelessWidget {
  const _AuditTechnicalTab({required this.detail});

  final AuditLogDetail detail;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.only(bottom: UtenSpacing.s16),
      children: [
        UtenCard(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.info_outline_rounded,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: UtenSpacing.s12),
              Expanded(
                child: Text(
                  '以下内容仅用于技术排查。普通核查请优先阅读概览、业务变化和设备证据。',
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        UtenCard(
          padding: EdgeInsets.zero,
          child: ExpansionTile(
            key: const ValueKey('audit-technical-expansion'),
            title: const Text('展开技术排查数据'),
            subtitle: const Text('包含操作关联编号、请求路径、中文对象类型和客户端标识'),
            children: [
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(UtenSpacing.s16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: UtenSpacing.s24,
                      runSpacing: UtenSpacing.s16,
                      children: [
                        _AuditFact(
                          label: '动作名称',
                          value: detail.actionLabel?.trim().isNotEmpty == true
                              ? detail.actionLabel!.trim()
                              : _AdminAuditLogPageState._actionLabel(
                                  detail.action,
                                ),
                        ),
                        _AuditFact(
                          label: '对象类型',
                          value: detail.objectLabel?.trim().isNotEmpty == true
                              ? detail.objectLabel!.trim()
                              : _objectTypeLabel(detail.targetType).isNotEmpty
                              ? _objectTypeLabel(detail.targetType)
                              : '未记录可读对象类型',
                        ),
                        _AuditFact(
                          label: '记录来源',
                          value: _sourceLabel(detail.eventSource),
                        ),
                        _CopyableAuditFact(
                          label: '操作关联编号',
                          value: detail.requestId ?? '—',
                        ),
                        _AuditFact(label: '网络来源地址', value: detail.ip ?? '—'),
                        _AuditFact(
                          label: '请求方法',
                          value: _httpMethodLabel(detail.httpMethod),
                        ),
                        _AuditFact(
                          label: '请求状态码',
                          value: detail.statusCode?.toString() ?? '—',
                        ),
                        _AuditFact(
                          label: '处理耗时',
                          value: detail.durationMs == null
                              ? '—'
                              : '${detail.durationMs} 毫秒',
                        ),
                        if (detail.targetId?.trim().isNotEmpty == true)
                          _CopyableAuditFact(
                            label: '业务对象内部编号',
                            value: detail.targetId!,
                          ),
                      ],
                    ),
                    if (detail.httpPath?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: UtenSpacing.s16),
                      _AuditFact(label: '请求路径', value: detail.httpPath!),
                    ],
                    if (detail.userAgent?.trim().isNotEmpty == true) ...[
                      const SizedBox(height: UtenSpacing.s16),
                      _AuditFact(label: '客户端标识', value: detail.userAgent!),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: UtenSpacing.s12),
        Text(
          '请求正文、密码、令牌、手机号、地址、银行账号和自由文本不会复制进审计详情。',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}

String _categoryLabel(String value) => switch (value) {
  'security' => '安全事件',
  'authorization' => '权限变更',
  'authentication' => '登录认证',
  'export' => '数据导出',
  'data_change' => '数据变更',
  'system' => '系统设置',
  _ => '业务操作',
};

String _sourceLabel(String value) => switch (value) {
  'request' => '请求覆盖记录',
  'database' => '数据库变更快照',
  'security' => '安全层拒绝事件',
  _ => '业务显式事件',
};

String _httpMethodLabel(String? value) => switch (value?.trim().toUpperCase()) {
  'GET' => '读取',
  'POST' => '提交',
  'PUT' => '整体更新',
  'PATCH' => '局部更新',
  'DELETE' => '删除',
  'HEAD' => '读取响应信息',
  _ => '请求方式未记录',
};

String? _requestOutcomeLabel(String? value) =>
    switch (value?.trim().toLowerCase()) {
      'success' || 'succeeded' => '成功',
      'failure' || 'failed' => '失败',
      'timeout' => '请求超时',
      'cancelled' || 'canceled' => '已取消',
      null || '' => null,
      _ => '结果待核查',
    };

class _AuditDetailHeader extends StatelessWidget {
  const _AuditDetailHeader({
    required this.title,
    required this.onClose,
    this.subtitle,
    this.onLocateRequest,
  });

  final String title;
  final String? subtitle;
  final VoidCallback onClose;
  final VoidCallback? onLocateRequest;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(UtenSpacing.s16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle!,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '关闭',
                onPressed: onClose,
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
          if (onLocateRequest != null) ...[
            const SizedBox(height: UtenSpacing.s8),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                key: const ValueKey('audit-locate-same-request'),
                onPressed: onLocateRequest,
                icon: const Icon(Icons.account_tree_outlined, size: 18),
                label: const Text('查看同一操作'),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _AuditFact extends StatelessWidget {
  const _AuditFact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 150, maxWidth: 320),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          SelectableText(value),
        ],
      ),
    );
  }
}

class _AuditJsonPanel extends StatelessWidget {
  const _AuditJsonPanel({
    required this.label,
    required this.rawJson,
    required this.icon,
  });

  final String label;
  final String? rawJson;
  final IconData icon;

  static String _pretty(String? value) {
    if (value == null || value.trim().isEmpty) return '无';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(value));
    } catch (_) {
      return value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: UtenRadius.lgAll,
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.all(UtenSpacing.s12),
            child: Row(
              children: [
                Icon(icon, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: UtenSpacing.s8),
                Text(
                  label,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(UtenSpacing.s12),
              child: SelectableText(
                _pretty(rawJson),
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.45,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
