// Uten 品牌色板
// 文档：docs/00-项目准则/08-主题与配色.md
// 决策：ADR-004-品牌色深绿青绿.md
//
// 设计原则：
// 1. 背景走中性灰阶（slate），不铺品牌色
// 2. 浅色 / 深色模式交互主色统一用 teal（青绿），按钮 / TabBar / 导航选中色
//    在两模式下一致
// 3. 卡片/容器用白色或浅中性色，靠细边框 + 极轻阴影分层
// 4. 文字用 slate-900 / slate-600 / slate-400 三档建立层级

import 'package:flutter/material.dart';

import 'uten_tokens.dart';

/// Uten 品牌色板常量
abstract final class UtenColors {
  // ===== 品牌主色 =====
  /// 跨明暗主题使用的兼容交互色；浅色实心按钮由 ColorScheme 单独定义
  static const Color primary = teal500;

  /// 品牌深绿（兼容旧引用）
  static const Color deepGreen = teal800;

  // ===== 青绿色阶（交互态统一用 teal 系）=====
  static const Color teal50 = Color(0xFFF0FDFA);
  static const Color teal100 = Color(0xFFCCFBF1);
  static const Color teal200 = Color(0xFF99F6E4);
  static const Color teal300 = Color(0xFF5EEAD4);
  static const Color teal400 = Color(0xFF2DD4BF);
  static const Color teal500 = Color(0xFF14B8A6);
  static const Color teal600 = Color(0xFF0D9488);
  static const Color teal700 = Color(0xFF0F766E);
  static const Color teal800 = Color(0xFF115E59);
  static const Color teal900 = Color(0xFF134E4A);
  static const Color teal950 = Color(0xFF042F2E);

  /// 强调色（= teal500）
  static const Color accent = teal500;

  // ===== 中性灰阶（slate，微调加深以增强卡片分层）=====
  static const Color background = Color(0xFFF5F7FA);
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceLow = Color(0xFFF8FAFC);
  static const Color surfaceMid = Color(0xFFEEF1F5);
  static const Color surfaceHigh = Color(0xFFE3E8EF);

  /// 文字（三档建立清晰层级）
  static const Color textPrimary = Color(0xFF0F172A);
  static const Color textSecondary = Color(0xFF475569);
  static const Color textTertiary = Color(0xFF94A3B8);

  /// 边框/分隔线
  static const Color border = Color(0xFFE2E8F0);
  static const Color borderStrong = Color(0xFFCBD5E1);
  static const Color divider = Color(0xFFF1F5F9);

  // slate 色阶（备用）
  static const Color slate50 = Color(0xFFF8FAFC);
  static const Color slate100 = Color(0xFFF1F5F9);
  static const Color slate200 = Color(0xFFE2E8F0);
  static const Color slate300 = Color(0xFFCBD5E1);
  static const Color slate400 = Color(0xFF94A3B8);
  static const Color slate500 = Color(0xFF64748B);
  static const Color slate700 = Color(0xFF334155);
  static const Color slate900 = Color(0xFF0F172A);
  static const Color slate950 = Color(0xFF020617);

  // ===== 语义色 =====
  static const Color success = Color(0xFF10B981);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color errorBg = Color(0xFFFEE2E2);
  static const Color info = Color(0xFF3B82F6);

  /// 深色表面上的高对比语义前景色。
  static const Color successOnDark = Color(0xFF34D399);
  static const Color warningOnDark = Color(0xFFFBBF24);
  static const Color errorOnDark = Color(0xFFF87171);
  static const Color infoOnDark = Color(0xFF60A5FA);

  /// 品红（分类强调色，非语义状态色）：生产路线「持续生产」的类别色
  /// （2026-09-18 用户口径「路线颜色取差别大的」——与齐套绿、分批蓝拉开色相）。
  static const Color fuchsia = Color(0xFFD946EF);

  /// 品红深色表面高对比前景色
  static const Color fuchsiaOnDark = Color(0xFFE879F9);

  /// 品红柔和底色（徽章浅底）
  static const Color fuchsiaBg = Color(0xFFFDF4FF);

  /// 品红深档文字色（配合 fuchsiaBg 保证对比度）
  static const Color fuchsiaText = Color(0xFFA21CAF);

  /// 紫(部分就绪档：车间任务「部分物料可领」——与全备齐的蓝、等待的琥珀、
  /// 待选路线的红都拉开色相；2026-09-20 用户口径「部分可领和已备齐颜色要分开」)
  static const Color violet = Color(0xFF7C3AED);

  /// 紫深色表面高对比前景色
  static const Color violetOnDark = Color(0xFFA78BFA);

  /// 紫柔和底色(徽章浅底)
  static const Color violetBg = Color(0xFFEDE9FE);

  /// 紫深档文字色(配合 violetBg 保证对比度)
  static const Color violetText = Color(0xFF5B21B6);

  /// 语义色柔和底色（徽章、提示条、浅色高亮块）
  static const Color successBg = Color(0xFFECFDF5);
  static const Color warningBg = Color(0xFFFFFBEB);
  static const Color infoBg = Color(0xFFEFF6FF);

  /// info 通知容器配对（与 success/error 的 *Container 同构：浅底深字 / 深底浅字）。
  /// 顶部通知 banner 的 info 类用这一对，避免再用中性灰 surfaceContainerHighest
  /// 把信息条刷成一片灰（hover 时尤其明显）。
  /// 浅色模式：浅蓝底 + blue-700 深蓝字（WCAG AA）。
  static const Color infoContainer = Color(0xFFEFF6FF); // = infoBg
  static const Color onInfoContainer = Color(0xFF1D4ED8);

  /// 深色模式：深蓝底 + blue-200 浅蓝字。
  static const Color infoContainerDark = Color(0xFF1E3A8A);
  static const Color onInfoContainerDark = Color(0xFFBFDBFE);

  /// 品牌青绿柔和底色（= teal50），用于选中态、高亮块
  static const Color tealSurface = teal50;

  /// 全站表格「选中行」实底（MasterDataTableView / UtenEditableGrid 共用，取色走
  /// [utenTableSelectedRowColor]）。2026-09-22 用户两轮口径：先是「都看不清是否选中」
  /// ——原 primaryContainer 35%（teal100 @ 35% ≈ #EEFEFA）在白底上几乎看不出来；改成
  /// teal200 实底后又「太亮，晃眼睛」。定稿为**低饱和青灰绿**：teal700 叠 20% 到白底
  /// （#CFE4E2，与白底明度差约 Excel 选中行那一档，黑 87% 字对比约 10:1），一眼看得出
  /// 选中、又不刺眼。深色主题用 primaryContainer 同款 teal900 实底（白字对比够）。
  /// 要再调深浅只改这两个常量。
  static const Color tableSelectedRow = Color(0xFFCFE4E2);
  static const Color tableSelectedRowDark = teal900;

  // ===== 分类树层级行底色（选择器滑窗 flatLevelColors 模式，2026-09-24）=====
  // 左树行按深度铺色的五档梯度：一级品牌深绿实底白字，往下逐档降饱和降明度，
  // 四档起转中性灰——「越深越淡出品牌色」。相邻档保持一眼可分辨的色差
  // （用户口径：至少 5 个层级色差、最深层固定一色、色差不要太接近、整体协调）。
  // 浅色五档：深绿 → 中青灰绿 → 浅青绿 → 中性灰 → 近白（最底层固定）。
  static const Color treeLevel1 = teal800;
  static const Color treeLevel2 = Color(0xFFBCDED8);
  static const Color treeLevel3 = Color(0xFFDDEEEA);
  static const Color treeLevel4 = Color(0xFFE3E8EF);
  static const Color treeLevel5 = Color(0xFFF8FAFC);

  /// 深色五档：深青绿三档渐沉，再转深 slate 两档（最深档融回面板底色）。
  static const Color treeLevel1Dark = teal800;
  static const Color treeLevel2Dark = teal900;
  static const Color treeLevel3Dark = teal950;
  static const Color treeLevel4Dark = Color(0xFF1E293B);
  static const Color treeLevel5Dark = Color(0xFF141C2B);

  /// 按深度取层级行底色：0–3 档各一色，4 及更深固定第五档。
  static Color treeLevelRow(int depth, {required bool dark}) {
    if (dark) {
      return switch (depth) {
        0 => treeLevel1Dark,
        1 => treeLevel2Dark,
        2 => treeLevel3Dark,
        3 => treeLevel4Dark,
        _ => treeLevel5Dark,
      };
    }
    return switch (depth) {
      0 => treeLevel1,
      1 => treeLevel2,
      2 => treeLevel3,
      3 => treeLevel4,
      _ => treeLevel5,
    };
  }

  /// 语义色深档文字色（配合 *Bg 底色使用，保证对比度）
  static const Color successText = Color(0xFF047857);
  static const Color warningText = Color(0xFFB45309);
  static const Color infoText = Color(0xFF1D4ED8);
  static const Color errorText = Color(0xFFB91C1C);

  /// 黄色「进行中」数量徽章的**实底色**(亮琥珀)。
  ///
  /// 定色过程(用户三轮反馈):
  ///   ① 2026-09-21 起初用 [warning](amber-500) + 深墨字 -> 用户要「数字加粗变白、
  ///      黄色再深点」;
  ///   ② 换成 amber-700 白字(对比度 4.5:1) -> 用户要「这个黄色不是黄色了, 稍微淡点」
  ///      —— amber-700 已经偏棕, 读起来不像黄色。当时落在 amber-600(0xFFD97706)。
  ///   ③ 2026-09-22 用户要「红变得更红, 黄变得更黄、偏亮一点, 两个色差明显点」
  ///      —— amber-600 偏暗偏橙, 和红徽章在角标那么小的尺寸上容易糊成一片。
  ///
  /// 第 ③ 轮撞上一条硬约束: **「黄更亮」与「白字」不能同时成立**。亮度一升白字对比度
  /// 就掉, amber-600 配白字已经只有 3.2:1, 再往亮调数字必糊。所以这一轮把配色整个翻过来:
  /// 底色升到亮琥珀 0xFFF5B301, 数字换成深棕 [onWarningStrong] —— 对比度 5.3:1,
  /// 比之前的白字方案还清楚, 同时和红徽章拉成「一深红 / 一亮黄」的最大色差。
  ///
  /// 明暗两档共用同一个实底: 这是自带对比度的实心药丸, 不吃表面色。
  /// 见 docs/00-项目准则/14-徽章与计数口径.md。
  static const Color warningStrong = Color(0xFFF5B301);

  /// 亮琥珀实底上的数字色(深棕)。对比度 5.3:1。
  /// 亮黄配白字必糊, 这一对是配套的, 换底色必须同时换它。
  static const Color onWarningStrong = Color(0xFF5C3D00);

  /// 红色「轮到我动手」数量徽章的**实底色**(red-600)。
  ///
  /// 与 [warningStrong] 配对使用, 2026-09-22 用户口径「红变得更红」。
  /// 不复用 [error](red-500) 也不复用 colorScheme.error: 那两个是全站语义红,
  /// 光 colorScheme.error 就有 400 多处引用(输入框错误边框、校验文案、危险图标),
  /// 为了角标把它们一起改深是过度波及。徽章有自己的实底色, 和黄徽章的
  /// [warningStrong] 同一个路子。
  ///
  /// red-500 -> red-600 白字对比度同时从 3.8:1 升到 4.8:1。
  static const Color dangerStrong = Color(0xFFDC2626);

  // ===== 生产单据纸面色板（A4 工卡 / 计划单等"纸质复刻"视图专用）=====
  // 这组颜色模拟纸张与墨色，不随 app 明暗主题切换（纸永远是白底墨字）。
  // 只允许生产单据复刻视图使用；普通业务 UI 仍走 colorScheme / 上述语义色。
  /// 纸面主墨色（深墨绿黑，标题/正文强调）
  static const Color docInk = Color(0xFF17231F);

  /// 纸面次级墨色（说明文字）
  static const Color docInkSoft = Color(0xFF52605A);

  /// 纸面表格线 / 分隔线
  static const Color docLine = Color(0xFFD5E1DB);

  /// 纸面浅底色（表头 / 汇总行底纹）
  static const Color docPaperTint = Color(0xFFF3F7F5);

  /// 纸面警示墨色（单据上的"作废/警告"字样）
  static const Color docDanger = Color(0xFFB3261E);

  // ===== 分类强调色（HR 节庆 / 快捷入口等非语义装饰色）=====
  // 用于按类别区分的图标、数字等待办强调；不是 success/warning 语义，
  // 语义状态请用上面的 success/warning/error 系列。
  /// 生日（粉）
  static const Color catPink = Color(0xFFDB2777);

  /// 周年纪念（琥珀）
  static const Color catAmber = Color(0xFFD97706);

  /// 新员工（祖母绿）
  static const Color catEmerald = Color(0xFF059669);

  /// 婚礼祝福（品红）
  static const Color catFuchsia = Color(0xFFD946EF);

  /// 新生儿（天蓝）
  static const Color catSky = Color(0xFF38BDF8);

  /// 庆典彩屑配色（CelebrationParticleField 默认值；装饰色，非语义）
  static const List<Color> festiveConfetti = [
    Color(0xFFF43F5E),
    Color(0xFFF59E0B),
    Color(0xFF14B8A6),
    Color(0xFF8B5CF6),
    Color(0xFF38BDF8),
    Color(0xFFEC4899),
  ];

  // ===== 特殊几何阴影色（不并轨 UtenElevation 双层体系的单点阴影）=====
  /// 表头筛选悬浮单元格阴影（33% 黑）
  static const Color floatingCellShadow = Color(0x55000000);

  /// 列显隐拖拽隐藏徽章阴影（40% 黑）
  static const Color dragBadgeShadow = Color(0x66000000);

  // ===== 深色主题专用 =====
  static const Color darkBackground = Color(0xFF0B1120);
  static const Color darkSurface = Color(0xFF101A2C);
  static const Color darkSurfaceLow = Color(0xFF1E293B);
  static const Color darkSurfaceHigh = Color(0xFF334155);
  static const Color darkBorder = Color(0xFF1F2A3D);
  static const Color darkBorderStrong = Color(0xFF334155);

  /// 深色文字
  static const Color darkTextPrimary = Color(0xFFF1F5F9);
  static const Color darkTextSecondary = Color(0xFF94A3B8);
  static const Color darkTextTertiary = Color(0xFF64748B);

  // ===== 阴影 token（已收敛到 UtenElevation 双层柔和阴影，此处保留兼容签名）=====
  /// 常规卡片阴影（= UtenElevation.low）
  static List<BoxShadow> cardShadow({bool isDark = false}) =>
      UtenElevation.low(isDark: isDark);

  /// 悬浮卡片阴影（= UtenElevation.mid）
  static List<BoxShadow> cardShadowLg({bool isDark = false}) =>
      UtenElevation.mid(isDark: isDark);

  /// 弹层/对话框阴影（= UtenElevation.high）
  static List<BoxShadow> popoverShadow({bool isDark = false}) =>
      UtenElevation.high(isDark: isDark);
}
