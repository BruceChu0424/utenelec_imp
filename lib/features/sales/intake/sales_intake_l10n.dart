import 'package:flutter/widgets.dart';

import '../../../core/l10n/gen/app_localizations.dart';
import '../../../core/l10n/gen/app_localizations_zh.dart';

final _fallback = AppLocalizationsZh();

/// 识别客户文件相关界面文案: 跟随应用语言; 没挂本地化代理的独立预览/测试回落中文
/// (与 workflowFieldText 同口径, 避免销售编辑页在未配置语言的宿主里崩溃)。
AppLocalizations salesIntakeL10n(BuildContext context) =>
    Localizations.of<AppLocalizations>(context, AppLocalizations) ?? _fallback;
