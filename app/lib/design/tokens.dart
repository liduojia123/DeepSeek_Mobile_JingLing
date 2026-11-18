/// M8 设计令牌 —— 颜色 / 字号 / 间距 / 圆角 / 动效的唯一来源。
///
/// 规则(由 `test/design_tokens_test.dart` 守护):
///  1. 页面与组件里不允许出现裸 `Color(0x…)`、`fontSize: <数字>`、`EdgeInsets.all(<数字>)`;
///     要什么从这里取,或者从 `Theme.of(context)` 取。
///  2. 品牌色只用于主操作与选中态;状态用语义色。
///  3. 间距按 8pt 栅格,4 只用于行内微调。
library;

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

/// 一套配色。浅色与深色各一份,字段一一对应。
class AppColors {
  const AppColors({
    required this.bg,
    required this.surface,
    required this.surfaceSunken,
    required this.text,
    required this.textSecondary,
    required this.textMuted,
    required this.accent,
    required this.onAccent,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.danger,
    required this.border,
    required this.borderStrong,
  });

  /// 画布
  final Color bg;

  /// 卡片 / 输入框
  final Color surface;

  /// 悬停 / 分区底
  final Color surfaceSunken;
  final Color text;
  final Color textSecondary;

  /// 时间、占位、次要说明
  final Color textMuted;
  final Color accent;

  /// accent 上的文字/图标色
  final Color onAccent;

  /// 选中底(accent 的低透明度)
  final Color accentSoft;
  final Color success;
  final Color warning;
  final Color danger;
  final Color border;
  final Color borderStrong;

  static const AppColors light = AppColors(
    bg: Color(0xFFFAFAF8),
    surface: Color(0xFFFFFFFF),
    surfaceSunken: Color(0xFFF1F1EC),
    text: Color(0xFF14161A),
    textSecondary: Color(0xFF5B6270),
    textMuted: Color(0xFF8C93A0),
    accent: Color(0xFF2F5DE3),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0x1A2F5DE3),
    success: Color(0xFF1F8A56),
    warning: Color(0xFFB4711B),
    danger: Color(0xFFC0392B),
    border: Color(0x1414161A),
    borderStrong: Color(0x2414161A),
  );

  static const AppColors dark = AppColors(
    bg: Color(0xFF0F1113),
    surface: Color(0xFF171A1E),
    surfaceSunken: Color(0xFF1D2126),
    text: Color(0xFFE9EBEF),
    textSecondary: Color(0xFFA7AEBB),
    textMuted: Color(0xFF8A93A2),
    accent: Color(0xFF7FA0FF),
    onAccent: Color(0xFF0B1020),
    accentSoft: Color(0x247FA0FF),
    success: Color(0xFF3FAE79),
    warning: Color(0xFFD79A45),
    danger: Color(0xFFE06B5E),
    border: Color(0x1AFFFFFF),
    borderStrong: Color(0x29FFFFFF),
  );
}

/// 间距(8pt 栅格)
abstract final class AppSpace {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;
  static const double xxxl = 32;

  /// 页面左右边距
  static const double page = lg;
}

/// 圆角
abstract final class AppRadius {
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
}

/// 动效
abstract final class AppMotion {
  static const Duration state = Duration(milliseconds: 150);
  static const Duration page = Duration(milliseconds: 220);
  static const Curve curve = Curves.easeOutCubic;
}

/// 排版。字段与 HANDOFF-M8 §3.2 的表一一对应。
class AppType {
  const AppType({
    required this.display,
    required this.title,
    required this.subtitle,
    required this.body,
    required this.bodyStrong,
    required this.meta,
    required this.mono,
  });

  final TextStyle display;
  final TextStyle title;
  final TextStyle subtitle;
  final TextStyle body;
  final TextStyle bodyStrong;
  final TextStyle meta;
  final TextStyle mono;

  factory AppType.of(AppColors c) => AppType(
        display: _text(size: 28, height: 1.25, weight: 600, color: c.text, spacing: -0.2),
        title: _text(size: 20, height: 1.3, weight: 600, color: c.text),
        subtitle: _text(size: 16, height: 1.4, weight: 600, color: c.text),
        body: _text(size: 15, height: 1.6, weight: 400, color: c.text),
        bodyStrong: _text(size: 15, height: 1.5, weight: 600, color: c.text),
        meta: _text(size: 12, height: 1.4, weight: 400, color: c.textSecondary),
        mono: _text(size: 13, height: 1.5, weight: 400, color: c.text, mono: true),
      );
}

/// 字体的唯一入口:显式指定可变字体的 `wght` 轴,避免被系统字体顶替。
TextStyle _text({
  required double size,
  required double height,
  required int weight,
  required Color color,
  double spacing = 0,
  bool mono = false,
}) {
  if (mono) {
    return TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Roboto Mono', 'Courier New', 'NotoSansSC'],
      fontSize: size,
      height: height,
      color: color,
      letterSpacing: spacing,
    );
  }
  return TextStyle(
    fontFamily: 'NotoSansSC',
    fontFamilyFallback: const ['Noto Sans SC', 'Source Han Sans SC'],
    fontSize: size,
    height: height,
    color: color,
    fontWeight: _weight(weight),
    fontVariations: [FontVariation('wght', weight.toDouble())],
    letterSpacing: spacing,
  );
}

FontWeight _weight(int value) => switch (value) {
      <= 300 => FontWeight.w300,
      400 => FontWeight.w400,
      500 => FontWeight.w500,
      600 => FontWeight.w600,
      _ => FontWeight.w700,
    };





