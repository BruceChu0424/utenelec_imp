// 密钥尾号掩码「••••k7Qp」的紧凑显示(ADR-133)。
//
// 应用字体 NotoSansSC 里「•」是全角字形, 连写的 4 个圆点会显示成「• • • •」。
// 这里把开头的圆点画成紧凑的小圆点、尾号照常用文字, 与字体无关; 读屏仍读服务端给的掩码原文。
// 本组件只显示服务端给的掩码, 拿不到也不处理密钥原文。
import 'package:flutter/material.dart';

class AiMaskedKey extends StatelessWidget {
  const AiMaskedKey(this.mask, {super.key, this.style});

  /// 服务端掩码, 如「••••k7Qp」; 不以圆点开头时原样显示。
  final String mask;
  final TextStyle? style;

  static final RegExp _pattern = RegExp(r'^(•+)(.*)$');

  @override
  Widget build(BuildContext context) {
    final match = _pattern.firstMatch(mask);
    if (match == null) {
      return Text(mask, style: style, maxLines: 1, softWrap: false);
    }
    final count = match.group(1)!.length;
    final tail = match.group(2)!;
    final effective = DefaultTextStyle.of(context).style.merge(style);
    final fontSize = MediaQuery.textScalerOf(
      context,
    ).scale(effective.fontSize ?? 14);
    final color = effective.color ?? Theme.of(context).colorScheme.onSurface;
    // 圆点约为字号的三分之一, 点距更小: 视觉上与等宽字体里的「••••」一样紧凑。
    final dot = fontSize * 0.34;
    final gap = fontSize * 0.16;
    return Semantics(
      label: mask,
      excludeSemantics: true,
      child: Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: EdgeInsetsDirectional.only(
                  end: tail.isEmpty ? 0 : gap * 1.5,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (var i = 0; i < count; i++)
                      Padding(
                        padding: EdgeInsetsDirectional.only(
                          end: i == count - 1 ? 0 : gap,
                        ),
                        child: SizedBox.square(
                          dimension: dot,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            if (tail.isNotEmpty) TextSpan(text: tail),
          ],
        ),
        style: style,
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}
