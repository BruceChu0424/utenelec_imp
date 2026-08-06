// 庆典吉祥物「小优」：按事件类型取对应美术（用户提供），文件缺失时回落品牌 IP。
// 文档：docs/02-组件库/UtenBrandMascot.md（资产路径来自 UtenAssets，禁止硬编码）。

import 'package:flutter/widgets.dart';

import '../../../components/brand/uten_brand_mascot.dart';
import '../../../core/constants/assets.dart';
import '../models/notice.dart';

/// 庆典吉祥物：生日 / 周年 / 新婚 / 新生儿 各一张「小优」美术（assets/celebration/）。
///
/// 美术文件未提供时通过 [Image.errorBuilder] 回落到 [UtenBrandMascot]（logo_ip.png），
/// 保证功能先上线、视觉随后替换。
class CelebrationMascot extends StatelessWidget {
  const CelebrationMascot({super.key, required this.type, this.size = 160});

  final NoticeType type;
  final double size;

  String get _asset => switch (type) {
    NoticeType.birthday => UtenAssets.celebrationBirthday,
    NoticeType.anniversary => UtenAssets.celebrationAnniversary,
    NoticeType.wedding => UtenAssets.celebrationWedding,
    NoticeType.newborn => UtenAssets.celebrationNewborn,
    _ => UtenAssets.logoIp,
  };

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Image.asset(
        _asset,
        fit: BoxFit.contain,
        gaplessPlayback: true,
        // 美术未到位（文件缺失/未声明）→ 回落品牌 IP，不报错不留白。
        errorBuilder: (_, _, _) => UtenBrandMascot.size(size),
      ),
    );
  }
}
