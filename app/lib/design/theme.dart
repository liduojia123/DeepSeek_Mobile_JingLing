import 'package:material_ui/material_ui.dart';

import 'tokens.dart';

/// 把 [AppColors] 挂到 ThemeData 上,页面用 `ref`/`context` 取,不自己定义颜色。
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette(this.colors);

  final AppColors colors;

  @override
  AppPalette copyWith({AppColors? colors}) => AppPalette(colors ?? this.colors);

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    // 颜色不做插值(切换主题用整页过渡),保持实现简单
    return t < 0.5 ? this : other;
  }
}

/// 取当前配色。页面里唯一拿颜色的方式。
AppColors colorsOf(BuildContext context) =>
    Theme.of(context).extension<AppPalette>()?.colors ?? AppColors.light;

/// 取当前排版。
AppType typeOf(BuildContext context) {
  final theme = Theme.of(context);
  final colors = colorsOf(context);
  // TextTheme 已经带上令牌,这里只在需要"另一档颜色"时给个便捷入口
  return theme.textTheme.bodyLarge == null
      ? AppType.of(colors)
      : AppType(
          display: theme.textTheme.displaySmall ?? AppType.of(colors).display,
          title: theme.textTheme.titleLarge ?? AppType.of(colors).title,
          subtitle: theme.textTheme.titleMedium ?? AppType.of(colors).subtitle,
          body: theme.textTheme.bodyLarge ?? AppType.of(colors).body,
          bodyStrong: theme.textTheme.titleSmall ?? AppType.of(colors).bodyStrong,
          meta: theme.textTheme.bodySmall ?? AppType.of(colors).meta,
          mono: AppType.of(colors).mono,
        );
}

/// 浅色 / 深色主题。所有页面都从这套主题里取样式。
ThemeData buildAppTheme(Brightness brightness) {
  final colors = brightness == Brightness.dark ? AppColors.dark : AppColors.light;
  final type = AppType.of(colors);

  final scheme = ColorScheme(
    brightness: brightness,
    primary: colors.accent,
    onPrimary: colors.onAccent,
    secondary: colors.accent,
    onSecondary: colors.onAccent,
    error: colors.danger,
    onError: colors.onAccent,
    surface: colors.surface,
    onSurface: colors.text,
  );

  OutlineInputBorder outline(Color color, {double width = 1}) => OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        borderSide: BorderSide(color: color, width: width),
      );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: colors.bg,
    canvasColor: colors.bg,
    fontFamily: 'NotoSansSC',
    extensions: <ThemeExtension<dynamic>>[AppPalette(colors)],
    textTheme: TextTheme(
      displaySmall: type.display,
      titleLarge: type.title,
      titleMedium: type.subtitle,
      titleSmall: type.bodyStrong,
      bodyLarge: type.body,
      bodyMedium: type.body,
      bodySmall: type.meta,
      labelSmall: type.meta,
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: colors.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      toolbarHeight: 56,
      titleTextStyle: type.title,
      iconTheme: IconThemeData(color: colors.text, size: 22),
      actionsIconTheme: IconThemeData(color: colors.text, size: 22),
    ),
    cardTheme: CardThemeData(
      color: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
        side: BorderSide(color: colors.border),
      ),
    ),
    dividerTheme: DividerThemeData(color: colors.border, thickness: 1, space: 1),
    listTileTheme: ListTileThemeData(
      iconColor: colors.textSecondary,
      textColor: colors.text,
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.sm),
      minVerticalPadding: AppSpace.md,
      titleTextStyle: type.bodyStrong,
      subtitleTextStyle: type.meta,
      dense: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surface,
      isDense: true,
      hintStyle: type.meta.copyWith(color: colors.textMuted),
      contentPadding: const EdgeInsets.symmetric(horizontal: AppSpace.md + 2, vertical: AppSpace.md),
      border: outline(colors.border),
      enabledBorder: outline(colors.border),
      focusedBorder: outline(colors.accent, width: 1.5),
      errorBorder: outline(colors.danger),
      focusedErrorBorder: outline(colors.danger, width: 1.5),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: colors.accent,
        foregroundColor: scheme.onPrimary,
        textStyle: type.bodyStrong,
        minimumSize: const Size(0, 44),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.md))),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: colors.accent,
        textStyle: type.bodyStrong,
        minimumSize: const Size(0, 44),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: colors.text,
      contentTextStyle: type.meta.copyWith(color: colors.bg),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.md))),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: colors.accent),
    iconTheme: IconThemeData(color: colors.textSecondary, size: 22),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      titleTextStyle: type.subtitle,
      contentTextStyle: type.body,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(AppRadius.lg))),
    ),
  );
}



