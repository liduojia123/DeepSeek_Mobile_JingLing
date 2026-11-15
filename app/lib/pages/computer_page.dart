import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/harness_providers.dart';
import '../widgets/thinking_block.dart';

/// 电脑页:查看电脑上的 dsh 工作区/会话,远程派任务、看实时输出、逐条确认工具调用。
class ComputerPage extends ConsumerStatefulWidget {
  const ComputerPage({super.key});

  @override
  ConsumerState<ComputerPage> createState() => _ComputerPageState();
}

class _ComputerPageState extends ConsumerState<ComputerPage> {
  final TextEditingController _prompt = TextEditingController();
  final ScrollController _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(harnessProvider.notifier).load();
    });
  }

  @override
  void dispose() {
    _prompt.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _prompt.text.trim();
    if (text.isEmpty) return;
    _prompt.clear();
    await ref.read(harnessProvider.notifier).startTask(text);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(harnessProvider);
    final theme = Theme.of(context);

    ref.listen<HarnessState>(harnessProvider, (previous, next) {
      if (next.error != null && next.error != previous?.error) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(SnackBar(content: Text(next.error!)));
        ref.read(harnessProvider.notifier).clearError();
      }
      _scrollToBottom();
    });

    return Scaffold(
      appBar: AppBar(
        title: const Text('电脑'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.read(harnessProvider.notifier).load(),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: Column(
        children: [
          _buildNodeBar(state, theme),
          Expanded(child: _buildBody(state, theme)),
          _buildConfirmCard(state, theme),
          _buildComposer(state, theme),
        ],
      ),
    );
  }

  Widget _buildNodeBar(HarnessState state, ThemeData theme) {
    final node = state.onlineNode;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
      child: Row(
        children: [
          Icon(
            node?.online == true ? Icons.desktop_windows : Icons.desktop_access_disabled,
            size: 18,
            color: node?.online == true ? theme.colorScheme.primary : theme.colorScheme.error,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              node == null
                  ? '未连接电脑'
                  : '${node.name} · ${node.online ? '在线' : '离线'}',
              style: theme.textTheme.labelMedium,
            ),
          ),
          if (state.running)
            Text('执行中…', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary)),
        ],
      ),
    );
  }

  Widget _buildBody(HarnessState state, ThemeData theme) {
    if (state.loading) return const Center(child: CircularProgressIndicator());

    if (state.running || state.output.isNotEmpty || state.thinking.isNotEmpty) {
      return _buildTaskView(state, theme);
    }

    final snapshot = state.snapshot;
    if (snapshot == null || snapshot.sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '电脑上没有可用的 dsh 会话。\n先在电脑上打开一个会话,再回来刷新。',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ),
      );
    }

    final selectedId = state.selectedSessionId;
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        for (final workspace in snapshot.workspaces)
          ExpansionTile(
            leading: const Icon(Icons.folder_outlined),
            title: Text(workspace.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(workspace.path, maxLines: 1, overflow: TextOverflow.ellipsis),
            initiallyExpanded: workspace.sessionIds.contains(selectedId),
            children: [
              for (final session in snapshot.sessions)
                if (workspace.sessionIds.contains(session.id))
                  ListTile(
                    dense: true,
                    leading: Icon(
                      session.id == selectedId ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                      size: 18,
                    ),
                    title: Text(session.displayName, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(
                      '${session.id.substring(0, session.id.length.clamp(0, 20))}…'
                      '${session.live ? ' · 运行中' : ''}',
                    ),
                    onTap: () => ref.read(harnessProvider.notifier).selectSession(session.id),
                  ),
            ],
          ),
      ],
    );
  }

  Widget _buildTaskView(HarnessState state, ThemeData theme) {
    final selected = state.selectedSession;
    return ListView(
      controller: _scroll,
      padding: const EdgeInsets.all(16),
      children: [
        if (selected != null)
          Text(
            '会话:${selected.displayName}',
            style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.outline),
          ),
        const SizedBox(height: 8),
        if (state.thinking.trim().isNotEmpty)
          ThinkingBlock(text: state.thinking, streaming: state.running && state.output.isEmpty),
        for (final event in state.toolEvents)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              children: [
                Icon(Icons.build_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '工具调用:${(event.payload['tool'] as String?) ?? 'tool'}',
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
        if (state.output.isNotEmpty)
          SelectableText(state.output, style: theme.textTheme.bodyMedium),
        if (state.running)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Row(
              children: [
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text('电脑正在执行…', style: theme.textTheme.labelSmall),
                const Spacer(),
                TextButton.icon(
                  onPressed: () => ref.read(harnessProvider.notifier).stop(),
                  icon: const Icon(Icons.stop, size: 16),
                  label: const Text('停止'),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildConfirmCard(HarnessState state, ThemeData theme) {
    final confirm = state.confirm;
    if (confirm == null) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.shield_outlined, size: 18, color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '电脑请求执行敏感操作(${state.confirmRemaining}s 后自动拒绝)',
                  style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('工具:${confirm.tool}', style: theme.textTheme.bodySmall),
          if (confirm.reason.isNotEmpty)
            Text('理由:${confirm.reason}', style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                onPressed: () => ref.read(harnessProvider.notifier).answerConfirm(true),
                icon: const Icon(Icons.check, size: 16),
                label: const Text('批准'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => ref.read(harnessProvider.notifier).answerConfirm(false),
                icon: const Icon(Icons.close, size: 16),
                label: const Text('拒绝'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildComposer(HarnessState state, ThemeData theme) {
    final canSend = !state.running && state.selectedSessionId != null;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border(top: BorderSide(color: theme.dividerColor.withValues(alpha: 0.4))),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: TextField(
                controller: _prompt,
                minLines: 1,
                maxLines: 4,
                enabled: canSend,
                decoration: InputDecoration(
                  hintText: state.running
                      ? '电脑正在执行…'
                      : state.selectedSessionId == null
                          ? '先选一个会话'
                          : '给电脑上的 dsh 派任务…',
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: '派任务',
              onPressed: canSend ? _send : null,
              icon: const Icon(Icons.arrow_upward),
            ),
          ],
        ),
      ),
    );
  }
}
