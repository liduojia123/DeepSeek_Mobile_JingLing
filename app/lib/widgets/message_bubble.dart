import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:material_ui/material_ui.dart';

import '../models/models.dart';
import 'branch_switcher.dart';
import 'thinking_block.dart';

/// 用户本地回显气泡:发送后、服务端返回树之前占位。
class PendingUserBubble extends StatelessWidget {
  const PendingUserBubble({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Align(
      alignment: Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(text, style: theme.textTheme.bodyLarge),
      ),
    );
  }
}

/// 正文里按引用偏移插入 `[n]` 角标(偏移相对本轮正文,和服务端给的 start/end 一致)。
String markCitations(String text, List<Citation> citations) {
  if (text.isEmpty || citations.isEmpty) return text;
  final inserts = <int, List<String>>{};
  for (final citation in citations) {
    final position = citation.endIndex ?? -1;
    if (position < 0 || position > text.length) continue;
    inserts.putIfAbsent(position, () => <String>[]).add('[${citation.index}]');
  }
  if (inserts.isEmpty) return text;
  final buffer = StringBuffer();
  for (var index = 0; index <= text.length; index++) {
    final marks = inserts[index];
    if (marks != null) buffer.write(marks.join());
    if (index < text.length) buffer.write(text[index]);
  }
  return buffer.toString();
}

/// 流式回答气泡:思考增长 + 工具过程卡片 + 正文增长。
class StreamingAnswerBubble extends StatelessWidget {
  const StreamingAnswerBubble({super.key, required this.answer, required this.generating});

  final StreamingAnswer answer;
  final bool generating;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (answer.thinking.isNotEmpty)
            ThinkingBlock(text: answer.thinking, streaming: generating && answer.text.isEmpty),
          for (final trace in answer.toolTraces) ToolTraceCard(trace: trace),
          if (answer.text.isEmpty && generating)
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('鲸灵正在处理…', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            )
          else if (answer.text.isNotEmpty)
            MarkdownBody(data: markCitations(answer.text, answer.citations)),
        ],
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.node,
    required this.position,
    required this.count,
    required this.onBranchSelected,
    required this.onLongPress,
    this.interactive = true,
  });

  final MessageNode node;

  /// 兄弟分支里的位置(1 起)与总数;count<=1 时不显示切换器
  final int position;
  final int count;
  final ValueChanged<int> onBranchSelected;
  final VoidCallback onLongPress;
  final bool interactive;

  @override
  Widget build(BuildContext context) {
    return node.isUser ? _buildUser(context) : _buildAssistant(context);
  }

  Widget _buildUser(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: interactive ? onLongPress : null,
          child: Container(
            margin: const EdgeInsets.symmetric(vertical: 6),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
            decoration: BoxDecoration(
              color: theme.colorScheme.primaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Text(node.text, style: theme.textTheme.bodyLarge),
          ),
        ),
        if (count > 1)
          BranchSwitcher(
            position: position,
            count: count,
            enabled: interactive,
            onSelected: onBranchSelected,
          ),
      ],
    );
  }

  Widget _buildAssistant(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = node.tokensIn + node.tokensOut;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onLongPress: interactive ? onLongPress : null,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (node.thinking.trim().isNotEmpty) ThinkingBlock(text: node.thinking),
              for (final trace in node.toolTraces) ToolTraceCard(trace: trace),
              if (node.text.trim().isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    node.interrupted ? '（已中断，没有产生正文）' : '（空回答）',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  // 不能开 selectable:选中文字会吞掉长按手势,长按菜单(复制/重新生成/删除)就出不来
                  child: MarkdownBody(data: markCitations(node.text, node.citations)),
                ),
              if (node.citations.isNotEmpty) _CitationList(citations: node.citations),
              if (node.interrupted)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Chip(
                    visualDensity: VisualDensity.compact,
                    avatar: const Icon(Icons.info_outline, size: 14),
                    label: Text(
                      node.stopReason == 'error' ? '生成失败，已保留部分内容' : '已停止生成',
                      style: theme.textTheme.labelSmall,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Row(
          children: [
            if (tokens > 0)
              Text(
                '$tokens tokens · ¥${node.cost.toStringAsFixed(4)}',
                style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
              ),
            const Spacer(),
            if (interactive)
              IconButton(
                tooltip: '更多操作',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: onLongPress,
                icon: const Icon(Icons.more_horiz),
              ),
            if (count > 1)
              BranchSwitcher(
                position: position,
                count: count,
                enabled: interactive,
                onSelected: onBranchSelected,
              ),
          ],
        ),
      ],
    );
  }
}

/// 工具过程卡片:搜索/读链接/页内查找。有结果时可展开看来源列表。
class ToolTraceCard extends StatefulWidget {
  const ToolTraceCard({super.key, required this.trace});

  final ToolTrace trace;

  @override
  State<ToolTraceCard> createState() => _ToolTraceCardState();
}

class _ToolTraceCardState extends State<ToolTraceCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final trace = widget.trace;
    final icon = switch (trace.tool) {
      'deepseek_read_url' => Icons.link,
      'memory_save' => Icons.psychology,
      'memory_search' || 'memory_list' => Icons.manage_search,
      'http_request' => Icons.http,
      _ => Icons.travel_explore,
    };
    final expandable = trace.results.isNotEmpty;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: expandable ? () => setState(() => _expanded = !_expanded) : null,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(icon, size: 15, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      trace.summary,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      maxLines: _expanded ? 3 : 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (expandable)
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 16,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final result in trace.results)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            result.title,
                            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (result.siteName != null)
                            Text(
                              result.siteName!,
                              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
                            ),
                          if (result.snippet != null && result.snippet!.isNotEmpty)
                            Text(
                              result.snippet!,
                              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CitationList extends StatelessWidget {
  const _CitationList({required this.citations});

  final List<Citation> citations;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('引用', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline)),
          const SizedBox(height: 2),
          for (final citation in citations)
            Text(
              '[${citation.index}] ${citation.title.isEmpty ? citation.url : citation.title}',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }
}
