import 'package:flutter/material.dart';

import '../../../components/feedback/uten_inline_notice.dart';
import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';
import '../../../core/network/api_exception.dart';
import '../../../core/theme/uten_tokens.dart';
import '../weight_params.dart';

/// 单重参数读取失败的原因 (服务端文案优先, 含第一条字段原因)。
String weightParamsErrorReason(Object error, AppLocalizations l10n) {
  if (error is ApiException) {
    final message = error.message.trim();
    final field = error.fieldErrors?.firstOrNull?.message.trim();
    if (field != null && field.isNotEmpty && field != message) {
      return message.isEmpty ? field : '$message: $field';
    }
    if (message.isNotEmpty) return message;
  }
  return l10n.weightParamsLoadFailedUnknown;
}

/// 页面级「单重参数读取失败」提示 (ADR-151): 取参失败不再静默。
///
/// 重量从不阻断数量登记, 所以只提示不拦截; 「重试」只重取上次失败的行。
/// 页面没有用到单重缓存 ([cache] 为 null) 或没有失败时不占位。
class WeightParamsLoadNotice extends StatelessWidget {
  const WeightParamsLoadNotice({
    super.key,
    required this.cache,
    this.padding = const EdgeInsets.only(bottom: UtenSpacing.s8),
  });

  final WeightParamsCache? cache;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final cache = this.cache;
    if (cache == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: cache,
      builder: (context, _) {
        final error = cache.lastError;
        if (error == null || !cache.hasFailed) return const SizedBox.shrink();
        final l10n =
            Localizations.of<AppLocalizations>(context, AppLocalizations) ??
            AppLocalizationsZh();
        return Padding(
          padding: padding,
          child: UtenInlineNotice(
            key: const Key('weight-params-load-notice'),
            level: UtenInlineNoticeLevel.warning,
            message: l10n.weightParamsLoadFailed(
              weightParamsErrorReason(error, l10n),
            ),
            trailing: TextButton(
              key: const Key('weight-params-load-retry'),
              onPressed: cache.retryFailed,
              child: Text(l10n.commonRetry),
            ),
          ),
        );
      },
    );
  }
}
