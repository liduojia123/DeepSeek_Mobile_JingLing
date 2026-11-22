import 'package:material_ui/material_ui.dart';

import '../design/theme.dart';

/// 全局搜索摘要里的一个文本片段(HANDOFF-SEARCH §4.4)。
class TextSegment {
  const TextSegment(this.text, {this.highlighted = false});

  final String text;
  final bool highlighted;
}

/// 把 [text] 按 [query] 的所有出现处(大小写不敏感)切成片段。
/// 纯函数便于单测;query 为空或未命中时返回单段原文。
List<TextSegment> highlightSegments(String text, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty || text.isEmpty) return [TextSegment(text)];
  final haystack = text.toLowerCase();
  final segments = <TextSegment>[];
  var start = 0;
  while (true) {
    final index = haystack.indexOf(needle, start);
    if (index < 0) break;
    if (index > start) segments.add(TextSegment(text.substring(start, index)));
    segments.add(TextSegment(text.substring(index, index + needle.length), highlighted: true));
    start = index + needle.length;
  }
  if (start < text.length) segments.add(TextSegment(text.substring(start)));
  return segments;
}

/// 搜索结果行里的摘要:关键词加粗 + accent 色,其余用 meta 弱化。
class SearchSnippet extends StatelessWidget {
  const SearchSnippet({super.key, required this.text, required this.query, this.maxLines = 2});

  final String text;
  final String query;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final type = typeOf(context);
    final colors = colorsOf(context);
    final segments = highlightSegments(text, query);
    return Text.rich(
      TextSpan(
        children: [
          for (final segment in segments)
            TextSpan(
              text: segment.text,
              style: segment.highlighted
                  ? type.meta.copyWith(
                      color: colors.accent,
                      fontWeight: FontWeight.w600,
                    )
                  : type.meta,
            ),
        ],
      ),
      maxLines: maxLines,
      overflow: TextOverflow.ellipsis,
    );
  }
}
