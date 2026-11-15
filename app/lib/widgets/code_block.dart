import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:material_ui/material_ui.dart';

/// 代码块高亮:自己写一个轻量 tokenizer。
///
/// 为什么不用 flutter_highlight / highlight:它们把上百种语言的语法定义一起打进 APK,
/// 而这里只需要给模型输出的常见代码上色(关键字/字符串/注释/数字),几十行就够,
/// 也不引入新依赖。
enum CodeTokenType { plain, keyword, string, comment, number }

class CodeToken {
  const CodeToken(this.text, this.type);

  final String text;
  final CodeTokenType type;
}

class _LanguageSpec {
  const _LanguageSpec(this.label, this.keywords, {this.hashComments = false});

  final String label;
  final Set<String> keywords;

  /// `#` 开头是注释(Python / Shell / YAML);C 系语言的 `#include` 不能当注释
  final bool hashComments;
}

const Set<String> _noKeywords = <String>{};

const Set<String> _dartKeywords = <String>{
  'abstract', 'as', 'assert', 'async', 'await', 'break', 'case', 'catch', 'class', 'const',
  'continue', 'covariant', 'default', 'deferred', 'do', 'dynamic', 'else', 'enum', 'export',
  'extends', 'extension', 'external', 'factory', 'false', 'final', 'finally', 'for', 'get',
  'if', 'implements', 'import', 'in', 'interface', 'is', 'late', 'library', 'mixin', 'new',
  'null', 'on', 'operator', 'part', 'required', 'rethrow', 'return', 'sealed', 'set', 'show',
  'static', 'super', 'switch', 'sync', 'this', 'throw', 'true', 'try', 'typedef', 'var',
  'void', 'when', 'while', 'with', 'yield',
};

const Set<String> _jsKeywords = <String>{
  'as', 'async', 'await', 'break', 'case', 'catch', 'class', 'const', 'continue', 'debugger',
  'declare', 'default', 'delete', 'do', 'else', 'enum', 'export', 'extends', 'false',
  'finally', 'for', 'from', 'function', 'if', 'implements', 'import', 'in', 'instanceof',
  'interface', 'let', 'namespace', 'new', 'null', 'private', 'protected', 'public',
  'readonly', 'return', 'static', 'super', 'switch', 'this', 'throw', 'true', 'try', 'type',
  'typeof', 'undefined', 'var', 'void', 'while', 'with', 'yield',
};

const Set<String> _pythonKeywords = <String>{
  'False', 'None', 'True', 'and', 'as', 'assert', 'async', 'await', 'break', 'class',
  'continue', 'def', 'del', 'elif', 'else', 'except', 'finally', 'for', 'from', 'global',
  'if', 'import', 'in', 'is', 'lambda', 'nonlocal', 'not', 'or', 'pass', 'raise', 'return',
  'self', 'try', 'while', 'with', 'yield',
};

const Set<String> _jvmKeywords = <String>{
  'abstract', 'assert', 'boolean', 'break', 'byte', 'case', 'catch', 'char', 'class', 'const',
  'continue', 'default', 'do', 'double', 'else', 'enum', 'extends', 'false', 'final',
  'finally', 'float', 'for', 'fun', 'if', 'implements', 'import', 'instanceof', 'int',
  'interface', 'long', 'native', 'new', 'null', 'object', 'package', 'private', 'protected',
  'public', 'return', 'short', 'static', 'strictfp', 'super', 'switch', 'synchronized',
  'this', 'throw', 'throws', 'transient', 'true', 'try', 'val', 'var', 'void', 'volatile',
  'when', 'while',
};

const Set<String> _goKeywords = <String>{
  'break', 'case', 'chan', 'const', 'continue', 'default', 'defer', 'else', 'fallthrough',
  'for', 'func', 'go', 'goto', 'if', 'import', 'interface', 'map', 'nil', 'package', 'range',
  'return', 'select', 'struct', 'switch', 'type', 'var',
};

const Set<String> _rustKeywords = <String>{
  'Err', 'None', 'Ok', 'Some', 'as', 'async', 'await', 'break', 'const', 'continue', 'crate',
  'dyn', 'else', 'enum', 'extern', 'false', 'fn', 'for', 'if', 'impl', 'in', 'let', 'loop',
  'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return', 'self', 'static', 'struct', 'super',
  'trait', 'true', 'type', 'unsafe', 'use', 'where', 'while',
};

const Set<String> _cKeywords = <String>{
  'auto', 'bool', 'break', 'case', 'catch', 'char', 'class', 'const', 'continue', 'default',
  'delete', 'do', 'double', 'else', 'enum', 'extern', 'false', 'float', 'for', 'friend',
  'goto', 'if', 'inline', 'int', 'long', 'namespace', 'new', 'nullptr', 'operator', 'private',
  'protected', 'public', 'return', 'short', 'signed', 'sizeof', 'static', 'string', 'struct',
  'switch', 'template', 'this', 'throw', 'true', 'try', 'typedef', 'typename', 'union',
  'unsigned', 'using', 'virtual', 'void', 'volatile', 'while',
};

const Set<String> _sqlKeywords = <String>{
  'add', 'alter', 'and', 'as', 'avg', 'by', 'case', 'count', 'create', 'delete', 'distinct',
  'drop', 'else', 'end', 'from', 'group', 'having', 'in', 'inner', 'insert', 'into', 'is',
  'join', 'left', 'limit', 'max', 'min', 'not', 'null', 'offset', 'on', 'or', 'order',
  'outer', 'right', 'select', 'set', 'sum', 'table', 'then', 'update', 'values', 'when',
  'where',
};

const Set<String> _shellKeywords = <String>{
  'case', 'cd', 'do', 'done', 'echo', 'elif', 'else', 'esac', 'exit', 'export', 'fi', 'for',
  'function', 'if', 'in', 'local', 'readonly', 'return', 'set', 'source', 'sudo', 'then',
  'unset', 'while',
};

/// 没有语言标记时用全部关键字的并集:宁可多认几个词,也不让没有标注的代码全灰。
final Set<String> _genericKeywords = <String>{
  ..._dartKeywords,
  ..._jsKeywords,
  ..._pythonKeywords,
  ..._jvmKeywords,
  ..._goKeywords,
  ..._rustKeywords,
  ..._cKeywords,
  ..._sqlKeywords,
  ..._shellKeywords,
};

const Map<String, String> _aliases = <String, String>{
  'dart': 'dart',
  'js': 'javascript', 'jsx': 'javascript', 'javascript': 'javascript', 'node': 'javascript',
  'ts': 'typescript', 'tsx': 'typescript', 'typescript': 'typescript',
  'py': 'python', 'python': 'python', 'python3': 'python',
  'sh': 'shell', 'bash': 'shell', 'zsh': 'shell', 'shell': 'shell', 'console': 'shell',
  'powershell': 'shell', 'ps1': 'shell', 'bat': 'shell',
  'java': 'java', 'kt': 'kotlin', 'kts': 'kotlin', 'kotlin': 'kotlin',
  'go': 'go', 'golang': 'go',
  'rs': 'rust', 'rust': 'rust',
  'c': 'c', 'h': 'c', 'cpp': 'cpp', 'c++': 'cpp', 'cc': 'cpp', 'hpp': 'cpp', 'cxx': 'cpp',
  'cs': 'csharp', 'csharp': 'csharp', 'c#': 'csharp',
  'sql': 'sql', 'mysql': 'sql', 'postgres': 'sql', 'sqlite': 'sql',
  'json': 'json', 'json5': 'json', 'jsonc': 'json',
  'yaml': 'yaml', 'yml': 'yaml', 'toml': 'yaml', 'ini': 'yaml', 'conf': 'yaml', 'env': 'yaml',
  'html': 'html', 'xml': 'html', 'svg': 'html', 'vue': 'html',
  'css': 'css', 'scss': 'css', 'less': 'css',
  'md': 'markdown', 'markdown': 'markdown',
  'diff': 'plain', 'patch': 'plain', 'text': 'plain', 'txt': 'plain', 'plain': 'plain',
};

final Map<String, _LanguageSpec> _specs = <String, _LanguageSpec>{
  'dart': _LanguageSpec('DART', _dartKeywords),
  'javascript': _LanguageSpec('JS', _jsKeywords),
  'typescript': _LanguageSpec('TS', _jsKeywords),
  'python': _LanguageSpec('PYTHON', _pythonKeywords, hashComments: true),
  'java': _LanguageSpec('JAVA', _jvmKeywords),
  'kotlin': _LanguageSpec('KOTLIN', _jvmKeywords),
  'go': _LanguageSpec('GO', _goKeywords),
  'rust': _LanguageSpec('RUST', _rustKeywords),
  'c': _LanguageSpec('C', _cKeywords),
  'cpp': _LanguageSpec('C++', _cKeywords),
  'csharp': _LanguageSpec('C#', _cKeywords),
  'sql': _LanguageSpec('SQL', _sqlKeywords),
  'shell': _LanguageSpec('SHELL', _shellKeywords, hashComments: true),
  'json': _LanguageSpec('JSON', _noKeywords),
  'yaml': _LanguageSpec('YAML', _noKeywords, hashComments: true),
  'html': _LanguageSpec('HTML', _noKeywords),
  'css': _LanguageSpec('CSS', _noKeywords),
  'markdown': _LanguageSpec('MARKDOWN', _noKeywords),
  'plain': _LanguageSpec('CODE', _noKeywords),
};

const Set<String> _languagesWithoutHashComments = <String>{
  'dart', 'javascript', 'typescript', 'java', 'kotlin', 'go', 'rust', 'c', 'cpp', 'csharp',
  'sql', 'json', 'html', 'css', 'markdown', 'plain',
};

_LanguageSpec _specFor(String? language) {
  final key = _canonical(language);
  final spec = _specs[key];
  if (spec != null) return spec;
  // 没标注语言:用并集,且不把 `#` 当注释(可能是 C 预处理指令)
  return _LanguageSpec('CODE', _genericKeywords, hashComments: !_languagesWithoutHashComments.contains(key));
}

String _canonical(String? language) {
  final raw = (language ?? '').trim().toLowerCase();
  if (raw.isEmpty) return '';
  final cleaned = raw.startsWith('language-') ? raw.substring('language-'.length) : raw;
  return _aliases[cleaned] ?? cleaned;
}

final RegExp _pattern = RegExp(
  r'''(/\*[\s\S]*?\*/|//[^\n]*)|("""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`)|(\b0[xX][0-9a-fA-F]+\b|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|([A-Za-z_$][A-Za-z0-9_$]*)''',
  multiLine: true,
);

final RegExp _patternHash = RegExp(
  r'''(/\*[\s\S]*?\*/|//[^\n]*|#[^\n]*)|("""[\s\S]*?"""|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\])*`)|(\b0[xX][0-9a-fA-F]+\b|\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|([A-Za-z_$][A-Za-z0-9_$]*)''',
  multiLine: true,
);

/// 把源码切成「带类型的片段」。解析不出来的一律当普通文本,绝不影响渲染。
List<CodeToken> tokenizeCode(String code, String? language) {
  if (code.isEmpty) return const [];
  final spec = _specFor(language);
  final pattern = spec.hashComments ? _patternHash : _pattern;
  final tokens = <CodeToken>[];
  var last = 0;
  for (final match in pattern.allMatches(code)) {
    if (match.start > last) {
      tokens.add(CodeToken(code.substring(last, match.start), CodeTokenType.plain));
    }
    final text = match[0] ?? '';
    final CodeTokenType type;
    if (match.group(1) != null) {
      type = CodeTokenType.comment;
    } else if (match.group(2) != null) {
      type = CodeTokenType.string;
    } else if (match.group(3) != null) {
      type = CodeTokenType.number;
    } else {
      type = spec.keywords.contains(text) ? CodeTokenType.keyword : CodeTokenType.plain;
    }
    tokens.add(CodeToken(text, type));
    last = match.end;
  }
  if (last < code.length) tokens.add(CodeToken(code.substring(last), CodeTokenType.plain));
  return tokens;
}

/// 渲染一个代码块:语言标签 + 复制按钮 + 高亮正文(横向滚动,不自动换行)。
class CodeBlock extends StatefulWidget {
  const CodeBlock({super.key, required this.code, this.language});

  final String code;
  final String? language;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final palette = _CodePalette.of(context);
    final spec = _specFor(widget.language);
    final tokens = tokenizeCode(widget.code, widget.language);
    final base = TextStyle(
      fontFamily: 'monospace',
      fontFamilyFallback: const ['Roboto Mono', 'Courier New'],
      fontSize: 12.5,
      height: 1.45,
      color: palette.plain,
    );

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: palette.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 10, right: 2),
            child: Row(
              children: [
                Text(
                  spec.label,
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 0.8,
                    fontWeight: FontWeight.w600,
                    color: palette.comment,
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: _copy,
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  icon: Icon(
                    _copied ? Icons.check : Icons.copy_all_outlined,
                    size: 14,
                    color: palette.comment,
                  ),
                  label: Text(
                    _copied ? '已复制' : '复制',
                    style: TextStyle(fontSize: 10, color: palette.comment),
                  ),
                ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: Text.rich(
              TextSpan(
                style: base,
                children: [
                  for (final token in tokens)
                    TextSpan(
                      text: token.text,
                      style: switch (token.type) {
                        CodeTokenType.plain => null,
                        CodeTokenType.keyword => TextStyle(color: palette.keyword),
                        CodeTokenType.string => TextStyle(color: palette.string),
                        CodeTokenType.comment => TextStyle(color: palette.comment),
                        CodeTokenType.number => TextStyle(color: palette.number),
                      },
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CodePalette {
  const _CodePalette({
    required this.background,
    required this.border,
    required this.plain,
    required this.keyword,
    required this.string,
    required this.comment,
    required this.number,
  });

  final Color background;
  final Color border;
  final Color plain;
  final Color keyword;
  final Color string;
  final Color comment;
  final Color number;

  static const _light = _CodePalette(
    background: Color(0xFFF3F4F6),
    border: Color(0xFFE1E4E8),
    plain: Color(0xFF1F2328),
    keyword: Color(0xFF7B1FA2),
    string: Color(0xFF2E7D32),
    comment: Color(0xFF6E7781),
    number: Color(0xFFB45309),
  );

  static const _dark = _CodePalette(
    background: Color(0xFF1B1D21),
    border: Color(0xFF2E3238),
    plain: Color(0xFFE6E6E6),
    keyword: Color(0xFFC792EA),
    string: Color(0xFFA5D6A7),
    comment: Color(0xFF8B949E),
    number: Color(0xFFE5A663),
  );

  static _CodePalette of(BuildContext context) =>
      Theme.of(context).brightness == Brightness.dark ? _dark : _light;
}

/// flutter_markdown 的 `pre` 构建器:把默认单色代码块换成高亮版。
///
/// 走的是 flutter_markdown 给块级 builder 预留的 `visitText` 钩子(pre 的文字直接交给
/// builder),外层仍由库套一层 codeblockDecoration(这里设成透明,背景由 CodeBlock 自己画)。
class CodeBlockBuilder extends MarkdownElementBuilder {
  CodeBlockBuilder();

  String? _language;

  @override
  void visitElementBefore(md.Element element) {
    _language = _languageOf(element);
  }

  @override
  Widget? visitText(md.Text text, TextStyle? preferredStyle) {
    if (text.text.trim().isEmpty) return null;
    return CodeBlock(code: text.text, language: _language);
  }

  static String? _languageOf(md.Element element) {
    for (final child in element.children ?? const <md.Node>[]) {
      if (child is md.Element) {
        final cls = child.attributes['class'];
        if (cls != null && cls.isNotEmpty) return cls;
      }
    }
    return element.attributes['class'];
  }
}
