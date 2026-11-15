import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/widgets/code_block.dart';
import 'package:jingling/widgets/markdown_view.dart';
import 'package:material_ui/material_ui.dart';

/// 代码块高亮:tokenizer 分类正确、不吞掉普通文本、语言标记不影响渲染安全。
void main() {
  group('tokenizeCode', () {
    test('Dart:关键字/字符串/注释/数字都能分出来', () {
      final tokens = tokenizeCode('final name = "鲸灵"; // 注释\nvar count = 42;', 'dart');
      String textOf(CodeTokenType type) =>
          tokens.where((token) => token.type == type).map((token) => token.text).join('|');

      expect(textOf(CodeTokenType.keyword), 'final|var');
      expect(textOf(CodeTokenType.string), '"鲸灵"');
      expect(textOf(CodeTokenType.comment), '// 注释');
      expect(textOf(CodeTokenType.number), '42');
      // 拼接回来必须和原文完全一致(高亮绝不能改内容)
      expect(tokens.map((token) => token.text).join(), 'final name = "鲸灵"; // 注释\nvar count = 42;');
    });

    test('Python/Shell 的 # 是注释,C 的 #include 不是', () {
      expect(
        tokenizeCode('# 说明\nprint(1)', 'python').first.type,
        CodeTokenType.comment,
      );
      expect(
        tokenizeCode('# 说明\necho hi', 'sh').first.type,
        CodeTokenType.comment,
      );
      final cTokens = tokenizeCode('#include <stdio.h>', 'c');
      expect(cTokens.any((token) => token.type == CodeTokenType.comment), isFalse);
    });

    test('没有语言标记也能跑,空串与未知语言不抛异常', () {
      expect(tokenizeCode('', 'dart'), isEmpty);
      final tokens = tokenizeCode('let x = 1; return x;', null);
      expect(tokens.any((token) => token.type == CodeTokenType.keyword), isTrue);
      expect(tokenizeCode('随便一段文字', '不存在的语言').map((token) => token.text).join(), '随便一段文字');
    });

    test('注释与字符串里的关键字不会被当成关键字', () {
      final tokens = tokenizeCode('// return final\n"class"', 'dart');
      expect(tokens.where((token) => token.type == CodeTokenType.keyword), isEmpty);
    });
  });

  group('ChatMarkdown', () {
    testWidgets('围栏代码块渲染成高亮 CodeBlock,并显示语言标签', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChatMarkdown(data: '说明:\n\n```dart\nfinal name = "鲸灵";\n```\n'),
            ),
          ),
        ),
      );
      expect(find.byType(CodeBlock), findsOneWidget);
      expect(find.text('DART'), findsOneWidget);
      expect(find.textContaining('说明'), findsOneWidget);
    });

    testWidgets('普通段落与行内代码不生成代码块', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ChatMarkdown(data: '用 `flutter test` 跑测试'),
            ),
          ),
        ),
      );
      expect(find.byType(CodeBlock), findsNothing);
    });
  });
}
