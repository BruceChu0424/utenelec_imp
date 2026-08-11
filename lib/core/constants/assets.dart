// 静态资源路径常量
// 文档：docs/00-项目准则/01-命名规范.md § 3.2
//
// 业务代码禁止散落硬编码 `Image.asset('assets/...')`，统一从此处引用。
// 新增 asset 时在此处加一行，所有引用方通过 UtenAssets.xxx 取路径。

abstract final class UtenAssets {
  // —— 图片 ——
  /// 横向品牌名锁版：UTEN + ELEC（图 405×74，5.47:1）
  /// 用于页面顶部、卡片标题、外发营销图等需要突出品牌但空间窄的地方。
  static const String logoName = 'assets/images/logo_name.png';

  /// 品牌 IP / 吉祥物：戴黄色安全帽的"德国工程师"（图 747×778，约 1:1）
  /// 用于启动屏、登录页侧图、About 页、空状态装饰等需要大画幅品牌氛围的地方。
  static const String logoIp = 'assets/images/logo_ip.png';

  /// 庆典「小优」吉祥物美术（按事件，由用户提供；文件缺失时由 widget 回落到 logoIp）。
  /// 用于登录庆典弹窗与今日概览庆典卡片。建议正方形、透明背景、≥512×512。
  static const String celebrationBirthday =
      'assets/celebration/xiaoyou_birthday.png';
  static const String celebrationAnniversary =
      'assets/celebration/xiaoyou_anniversary.png';
  static const String celebrationWedding =
      'assets/celebration/xiaoyou_wedding.png';
  static const String celebrationNewborn =
      'assets/celebration/xiaoyou_newborn.png';

  // —— 目录（pubspec.yaml 同步声明的 asset 根）——
  static const String dirImages = 'assets/images/';
  static const String dirIcons = 'assets/icons/';
  static const String dirLottie = 'assets/lottie/';
  static const String dirCelebration = 'assets/celebration/';
}
