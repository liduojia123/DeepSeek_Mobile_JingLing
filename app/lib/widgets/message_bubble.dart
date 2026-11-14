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

/// 流式回答气泡:思考增长 + 正文增长。
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
          if (answer.text.isEmpty && generating)
            Row(
              children: [
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 8),
                Text('鲸灵正在思考…', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            )
          else if (answer.text.isNotEmpty)
            MarkdownBody(data: answer.text, selectable: true),
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
              for (final trace in node.toolTraces) _ToolTraceCard(trace: trace),
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
                  child: MarkdownBody(data: node.text),
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

class _ToolTraceCard extends StatelessWidget {
  const _ToolTraceCard({required this.trace});

  final ToolTrace trace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Icon(Icons.build_outlined, size: 15, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '${trace.tool} · ${trace.summary}',
              style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
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
