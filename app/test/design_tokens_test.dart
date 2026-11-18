import 'dart:io';
import 'dart:ui' show Brightness;

import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/design/theme.dart';
import 'package:jingling/design/tokens.dart';

/// M8 地基的两条护栏:
///  1. 令牌本身自洽(间距递增、圆角有值、深浅两套颜色不同);
///  2. 除令牌文件与语法高亮色板外,`lib/` 里不再出现裸 `Color(0x…)`。
void main() {
  group('令牌', () {
    test('间距按 8pt 栅格递增', () {
      final scale = [AppSpace.xs, AppSpace.sm, AppSpace.md, AppSpace.lg, AppSpace.xl, AppSpace.xxl, AppSpace.xxxl];
      for (var i = 1; i < scale.length; i++) {
        expect(scale[i], greaterThan(scale[i - 1]), reason: '第 $i 档应大于前一档');
      }
      expect(AppSpace.xs, 4);
      expect(AppSpace.md, 12);
    });

    test('圆角与动效有确定值', () {
      expect(AppRadius.sm, lessThan(AppRadius.md));
      expect(AppRadius.md, lessThan(AppRadius.lg));
      expect(AppMotion.state.inMilliseconds, greaterThan(0));
      expect(AppMotion.page.inMilliseconds, greaterThanOrEqualTo(AppMotion.state.inMilliseconds));
    });

    test('深浅两套颜色各自完整且不同', () {
      expect(AppColors.light.bg, isNot(AppColors.dark.bg));
      expect(AppColors.light.text, isNot(AppColors.dark.text));
      expect(AppColors.light.accent, isNot(AppColors.dark.accent));
    });

    test('排版用内置字体,不留给系统决定', () {
      final type = AppType.of(AppColors.light);
      for (final style in [type.display, type.title, type.subtitle, type.body, type.bodyStrong]) {
        expect(style.fontFamily, 'NotoSansSC');
        expect(style.fontVariations, isNotEmpty);
      }
      expect(type.body.fontSize, 15);
      expect(type.body.height, 1.6);
      expect(type.mono.fontFamily, 'monospace');
    });

    test('主题带 AppPalette 扩展,页面能取到配色', () {
      for (final brightness in Brightness.values) {
        final theme = buildAppTheme(brightness);
        expect(theme.extension<AppPalette>(), isNotNull);
        expect(theme.textTheme.bodyLarge?.fontFamily, 'NotoSansSC');
      }
    });
  });

  group('裸颜色扫描', () {
    // 这两个文件允许十六进制:令牌本身;代码高亮的语法色板(不随主题变,自带亮/暗映射)。
    const allowed = {'lib/design/tokens.dart', 'lib/widgets/code_block.dart'};

    test('lib/ 下除白名单外没有 Color(0x…)', () {
      final offenders = <String>[];
      final root = Directory('lib');
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final relative = entity.path.replaceAll(r'\', '/');
        if (allowed.contains(relative)) continue;
        final source = entity.readAsStringSync();
        if (source.contains(RegExp(r'Color\(0x'))) offenders.add(relative);
      }
      expect(offenders, isEmpty, reason: '这些文件应该改用 AppColors / colorsOf(context):$offenders');
    });
  });
}

