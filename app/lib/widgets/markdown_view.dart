import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:material_ui/material_ui.dart';

import 'code_block.dart';

/// 聊天正文的 Markdown 渲染:共用一套样式,围栏代码块走高亮版 [CodeBlock]。
///
/// 不能开 selectable:选中文字会吞掉长按手势,消息长按菜单(复制/重新生成/删除)就出不来。
/// 样式表手工构造而不是 `MarkdownStyleSheet.fromTheme`:本 App 的 ThemeData 来自 material_ui,
/// 与 flutter_markdown 需要的框架 ThemeData 不是同一个类型。
class ChatMarkdown extends StatelessWidget {
  const ChatMarkdown({super.key, required this.data});

  final String data;

  static final Map<String, MarkdownElementBuilder> _builders = <String, MarkdownElementBuilder>{
    'pre': CodeBlockBuilder(),
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyLarge;
    return MarkdownBody(
      data: data,
      builders: _builders,
      styleSheet: MarkdownStyleSheet(
        p: base,
        a: base?.copyWith(color: theme.colorScheme.primary, decoration: TextDecoration.underline),
        em: base?.copyWith(fontStyle: FontStyle.italic),
        strong: base?.copyWith(fontWeight: FontWeight.w700),
        h1: theme.textTheme.headlineSmall,
        h2: theme.textTheme.titleLarge,
        h3: theme.textTheme.titleMedium,
        h4: theme.textTheme.titleSmall,
        h5: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        h6: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
        blockSpacing: 8,
        blockquote: theme.textTheme.bodyMedium,
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: theme.colorScheme.outline, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.fromLTRB(10, 4, 0, 4),
        listBullet: base,
        listIndent: 20,
        // 围栏代码块的背景/圆角/内边距由 CodeBlock 自己画,这里只留排版
        codeblockPadding: EdgeInsets.zero,
        codeblockDecoration: const BoxDecoration(),
        code: base?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Roboto Mono', 'Courier New'],
          fontSize: 13,
          backgroundColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.7),
        ),
        tableHead: theme.textTheme.labelLarge,
        tableBody: base,
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
        ),
      ),
    );
  }
}
