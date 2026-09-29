// 报价/订货编辑页表头上方的「识别客户文件」入口卡(ADR-134, SPEC §7.3)。
// 纯展示: 点按钮由页面启动识别流程; AI 未开启时只加一句提示(Excel 仍可按规则识别)。
import 'package:flutter/material.dart';

import '../../../components/buttons/uten_button.dart';
import '../../../core/theme/uten_colors.dart';
import '../../../core/theme/uten_tokens.dart';
import '../../../shared/ai/ai_tone.dart';
import 'sales_intake_l10n.dart';

class SalesIntakeEntryCard extends StatelessWidget {
  const SalesIntakeEntryCard({
    super.key,
    required this.onStart,
    this.aiOff = false,
    this.lastFileName,
    this.importedRows = 0,
  });

  /// null = 暂不可用(保存中或识别进行中; 进度由公共 AI 进度弹窗展示, 这里不再转圈)。
  final VoidCallback? onStart;

  /// 已确认 AI 未开启(PDF/图片不能识别, 只提示不拦截 Excel)。
  final bool aiOff;

  /// 本单最近一次导入的文件名(有值时卡片显示「已从 X 导入 N 行」)。
  final String? lastFileName;
  final int importedRows;

  @override
  Widget build(BuildContext context) {
    final l10n = salesIntakeL10n(context);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final imported = lastFileName != null;
    final compact = MediaQuery.sizeOf(context).width < 600;
    final message = imported
        ? l10n.salesIntakeBannerImported(lastFileName!, importedRows)
        : l10n.salesIntakeBannerMessage;
    final button = UtenButton(
      key: const ValueKey('sales-intake-entry-button'),
      icon: Icons.auto_awesome_rounded,
      height: 48,
      onPressed: onStart,
      child: Text(
        imported ? l10n.salesIntakeBannerAgain : l10n.salesIntakeBannerButton,
      ),
    );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.salesIntakeBannerTitle,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: UtenSpacing.s2),
        Text(
          message,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        if (aiOff) ...[
          const SizedBox(height: UtenSpacing.s4),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.info_outline_rounded,
                size: 16,
                color: AiTone.warning(theme),
              ),
              const SizedBox(width: UtenSpacing.s4),
              Flexible(
                child: Text(
                  l10n.salesIntakeAiOffHint,
                  key: const ValueKey('sales-intake-ai-off-hint'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AiTone.warning(theme),
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
    return Container(
      key: const ValueKey('sales-intake-entry-card'),
      padding: const EdgeInsets.symmetric(
        horizontal: UtenSpacing.s16,
        vertical: UtenSpacing.s12,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(UtenRadius.xl),
        gradient: LinearGradient(
          begin: AlignmentDirectional.centerStart,
          end: AlignmentDirectional.centerEnd,
          colors: dark
              ? [UtenColors.teal950, theme.colorScheme.surface]
              : [UtenColors.teal50, theme.colorScheme.surface],
        ),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.25),
        ),
      ),
      child: compact
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const _Glyph(),
                    const SizedBox(width: UtenSpacing.s12),
                    Expanded(child: text),
                  ],
                ),
                const SizedBox(height: UtenSpacing.s12),
                button,
              ],
            )
          : Row(
              children: [
                const _Glyph(),
                const SizedBox(width: UtenSpacing.s12),
                Expanded(child: text),
                const SizedBox(width: UtenSpacing.s12),
                button,
              ],
            ),
    );
  }
}

class _Glyph extends StatelessWidget {
  const _Glyph();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      height: 44,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [UtenColors.teal400, UtenColors.teal700],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(
        Icons.document_scanner_outlined,
        color: Colors.white,
        size: 22,
      ),
    );
  }
}
