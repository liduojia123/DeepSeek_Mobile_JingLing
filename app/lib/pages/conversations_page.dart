import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/harness_providers.dart';
import '../core/providers.dart';
import '../design/components/empty_state.dart';
import '../design/components/section_header.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/models.dart';
import '../widgets/search_snippet.dart';
import 'chat_page.dart';
import 'computer_page.dart';
import 'conversation_grouping.dart';
import 'memory_page.dart';
import 'settings_page.dart';
import 'usage_page.dart';

/// 会话列表(M8 §4.1;HANDOFF-SEARCH 升级为全局搜索)。
///
/// 结构:标题 + 「＋」(新建)+ 「⋯」(临时对话/记忆/电脑/用量/设置);
/// 主体:搜索框 → 电脑在跑横幅 → 置顶/今天/昨天/本周/更早;
/// 搜索框输入非空时切换为全局搜索态(服务端全量历史,结果可跳到命中消息)。
class ConversationsPage extends ConsumerStatefulWidget {
  const ConversationsPage({super.key});

  @override
  ConsumerState<ConversationsPage> createState() => _ConversationsPageState();
}

class _ConversationsPageState extends ConsumerState<ConversationsPage> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  Timer? _debounce;
  int _searchSeq = 0;
  List<SearchGroup> _results = const [];
  bool _searching = false;
  String? _searchError;

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    setState(() => _query = value);
    _debounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _results = const [];
        _searching = false;
        _searchError = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 400), () => _runSearch(query));
  }

  Future<void> _runSearch(String query) async {
    final api = ref.read(apiProvider);
    final seq = ++_searchSeq;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    if (api == null) {
      if (seq != _searchSeq || !mounted) return;
      setState(() {
        _searching = false;
        _searchError = '未连接服务器';
      });
      return;
    }
    try {
      final groups = await api.search(query);
      if (seq != _searchSeq || !mounted) return;
      setState(() {
        _results = groups;
        _searching = false;
      });
    } on ApiException catch (error) {
      if (seq != _searchSeq || !mounted) return;
      setState(() {
        _searching = false;
        _searchError = error.message;
      });
    } catch (error) {
      if (seq != _searchSeq || !mounted) return;
      setState(() {
        _searching = false;
        _searchError = '$error';
      });
    }
  }

  Future<void> _openChat(String conversationId, {String? focusMessageId}) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(conversationId: conversationId, focusMessageId: focusMessageId),
      ),
    );
    ref.invalidate(conversationsProvider);
  }

  Future<void> _createConversation({bool ephemeral = false}) async {
    try {
      final conversation = await ref.read(conversationsProvider.notifier).create(ephemeral: ephemeral);
      if (!mounted) return;
      await _openChat(conversation.id);
    } on ApiException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }

  Future<void> _showOverflow() async {
    final colors = colorsOf(context);
    final type = typeOf(context);
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.bolt_outlined),
              title: const Text('临时对话'),
              subtitle: Text(
                '不保存历史,关掉即清',
                style: type.meta.copyWith(color: colors.textMuted),
              ),
              onTap: () {
                Navigator.pop(sheetContext);
                _createConversation(ephemeral: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.psychology_outlined),
              title: const Text('记忆'),
              onTap: () {
                Navigator.pop(sheetContext);
                _open(const MemoryPage());
              },
            ),
            ListTile(
              leading: const Icon(Icons.desktop_windows_outlined),
              title: const Text('电脑'),
              onTap: () {
                Navigator.pop(sheetContext);
                _open(const ComputerPage());
              },
            ),
            ListTile(
              leading: const Icon(Icons.insights_outlined),
              title: const Text('用量'),
              onTap: () {
                Navigator.pop(sheetContext);
                _open(const UsagePage());
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('设置'),
              onTap: () {
                Navigator.pop(sheetContext);
                _open(const SettingsPage());
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRowMenu(Conversation conversation) async {
    final colors = colorsOf(context);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.drive_file_rename_outline),
              title: const Text('重命名'),
              onTap: () => Navigator.pop(sheetContext, 'rename'),
            ),
            ListTile(
              leading: Icon(conversation.pinned ? Icons.push_pin : Icons.push_pin_outlined),
              title: Text(conversation.pinned ? '取消置顶' : '置顶'),
              onTap: () => Navigator.pop(sheetContext, 'pin'),
            ),
            ListTile(
              leading: Icon(Icons.delete_outline, color: colors.danger),
              title: Text('删除', style: TextStyle(color: colors.danger)),
              onTap: () => Navigator.pop(sheetContext, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;

    switch (action) {
      case 'rename':
        final controller = TextEditingController(text: conversation.title);
        final title = await showDialog<String>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('重命名会话'),
            content: TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(hintText: '会话标题'),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text.trim()),
                child: const Text('保存'),
              ),
            ],
          ),
        );
        controller.dispose();
        if (title != null && title.isNotEmpty) {
          await ref.read(conversationsProvider.notifier).rename(conversation.id, title);
        }
        return;
      case 'pin':
        await ref.read(conversationsProvider.notifier).togglePin(conversation);
        return;
      case 'delete':
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('删除会话'),
            content: const Text('会话及其全部消息会被永久删除,确定吗?'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('删除'),
              ),
            ],
          ),
        );
        if (confirmed == true) {
          await ref.read(conversationsProvider.notifier).remove(conversation.id);
        }
        return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(conversationsProvider);
    final harness = ref.watch(harnessProvider);
    final type = typeOf(context);
    final colors = colorsOf(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('鲸灵', style: type.display),
        actions: [
          IconButton(
            tooltip: '新建对话',
            icon: const Icon(Icons.add),
            onPressed: () => _createConversation(),
          ),
          IconButton(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz),
            onPressed: _showOverflow,
          ),
          const SizedBox(width: AppSpace.xs),
        ],
      ),
      body: conversations.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: Icons.cloud_off_outlined,
          title: '加载会话失败',
          body: '$error',
          action: FilledButton(
            onPressed: () => ref.read(conversationsProvider.notifier).refresh(),
            child: const Text('重试'),
          ),
        ),
        data: (items) {
          final searchMode = _query.trim().isNotEmpty;
          final groups = groupConversations(items);
          return RefreshIndicator(
            onRefresh: () => ref.read(conversationsProvider.notifier).refresh(),
            child: ListView(
              padding: const EdgeInsets.only(bottom: AppSpace.xxxl),
              children: [
                _searchField(type, colors),
                if (searchMode) ..._searchBody(type, colors),
                if (!searchMode && harness.running) _computerBanner(colors, type),
                if (!searchMode && items.isEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: AppSpace.xxxl * 2),
                    child: EmptyState(
                      icon: Icons.forum_outlined,
                      title: '还没有对话',
                      body: '点右上角「＋」开始',
                    ),
                  )
                else if (!searchMode)
                  for (final group in groups) ...[
                    SectionHeader(group.label),
                    Card(
                      margin: const EdgeInsets.symmetric(horizontal: AppSpace.page),
                      child: Column(
                        children: [
                          for (var i = 0; i < group.items.length; i++) ...[
                            if (i > 0)
                              const Divider(height: 1, indent: AppSpace.lg, endIndent: AppSpace.lg),
                            _ConversationRow(
                              conversation: group.items[i],
                              onTap: () => _openChat(group.items[i].id),
                              onLongPress: () => _showRowMenu(group.items[i]),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ],
              ],
            ),
          );
        },
      ),
    );
  }

  /// 搜索态主体:加载 / 错误重试 / 空结果 / 分组结果(HANDOFF-SEARCH §4.2)。
  List<Widget> _searchBody(AppType type, AppColors colors) {
    if (_searchError != null) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.xxxl * 2),
          child: EmptyState(
            icon: Icons.cloud_off_outlined,
            title: '搜索失败',
            body: _searchError!,
            action: FilledButton(
              onPressed: () => _runSearch(_query.trim()),
              child: const Text('重试'),
            ),
          ),
        ),
      ];
    }
    if (_results.isEmpty && _searching) {
      return const [
        Padding(
          padding: EdgeInsets.only(top: AppSpace.xxxl),
          child: Center(child: CircularProgressIndicator()),
        ),
      ];
    }
    if (_results.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.xxxl * 2),
          child: EmptyState(
            icon: Icons.search_off_outlined,
            title: '没有找到「${_query.trim()}」',
            body: '换个关键词试试',
          ),
        ),
      ];
    }
    return [
      if (_searching) const LinearProgressIndicator(minHeight: 2),
      for (final group in _results)
        _SearchGroupCard(
          group: group,
          query: _query.trim(),
          onOpenConversation: () => _openChat(group.conversationId),
          onOpenHit: (hit) => _openChat(group.conversationId, focusMessageId: hit.messageId),
        ),
    ];
  }

  Widget _searchField(AppType type, AppColors colors) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.page, AppSpace.sm, AppSpace.page, 0),
      child: TextField(
        controller: _search,
        onChanged: _onSearchChanged,
        style: type.body,
        decoration: InputDecoration(
          hintText: '搜索全部对话',
          prefixIcon: Icon(Icons.search, size: 18, color: colors.textMuted),
          prefixIconConstraints: const BoxConstraints(minWidth: 40),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: Icon(Icons.close, size: 16, color: colors.textMuted),
                  onPressed: () {
                    _search.clear();
                    _onSearchChanged('');
                  },
                ),
          suffixIconConstraints: const BoxConstraints(minWidth: 36),
          contentPadding: const EdgeInsets.symmetric(vertical: AppSpace.md),
        ),
      ),
    );
  }

  Widget _computerBanner(AppColors colors, AppType type) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpace.page, AppSpace.md, AppSpace.page, 0),
      child: Material(
        color: colors.accentSoft,
        borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.md)),
          onTap: () => _open(const ComputerPage()),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.md),
            child: Row(
              children: [
                Icon(Icons.desktop_windows_outlined, size: 18, color: colors.accent),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    '电脑上有任务在跑 · 去看看',
                    style: type.meta.copyWith(color: colors.accent, fontWeight: FontWeight.w500),
                  ),
                ),
                Icon(Icons.chevron_right, size: 18, color: colors.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow({
    required this.conversation,
    required this.onTap,
    required this.onLongPress,
  });

  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  @override
  Widget build(BuildContext context) {
    final type = typeOf(context);
    final colors = colorsOf(context);
    final time = conversationTimeLabel(conversation.updatedAt);
    final rawPreview = conversation.preview.isEmpty ? '暂无消息' : conversation.preview;
    final preview = plainPreview(rawPreview);

    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (conversation.pinned) ...[
                  Icon(Icons.push_pin, size: 14, color: colors.textMuted),
                  const SizedBox(width: AppSpace.xs),
                ],
                if (conversation.ephemeral) ...[
                  Icon(Icons.bolt_outlined, size: 14, color: colors.textMuted),
                  const SizedBox(width: AppSpace.xs),
                ],
                Expanded(
                  child: Text(
                    conversation.displayTitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: type.bodyStrong,
                  ),
                ),
                if (time.isNotEmpty) ...[
                  const SizedBox(width: AppSpace.sm),
                  Text(time, style: type.meta.copyWith(color: colors.textMuted)),
                ],
              ],
            ),
            const SizedBox(height: AppSpace.xs),
            Text(
              preview,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: type.meta,
            ),
          ],
        ),
      ),
    );
  }
}

/// 全局搜索结果的一个会话组:标题行 + 命中行(标题匹配 / 消息摘要)。
class _SearchGroupCard extends StatelessWidget {
  const _SearchGroupCard({
    required this.group,
    required this.query,
    required this.onOpenConversation,
    required this.onOpenHit,
  });

  final SearchGroup group;
  final String query;
  final VoidCallback onOpenConversation;
  final ValueChanged<SearchHit> onOpenHit;

  @override
  Widget build(BuildContext context) {
    final type = typeOf(context);
    final colors = colorsOf(context);
    final time = conversationTimeLabel(group.updatedAt);

    return Card(
      margin: const EdgeInsets.fromLTRB(AppSpace.page, AppSpace.md, AppSpace.page, 0),
      child: Column(
        children: [
          InkWell(
            onTap: onOpenConversation,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpace.lg, vertical: AppSpace.md),
              child: Row(
                children: [
                  if (group.pinned) ...[
                    Icon(Icons.push_pin, size: 14, color: colors.textMuted),
                    const SizedBox(width: AppSpace.xs),
                  ],
                  Expanded(
                    child: Text(
                      group.title.isEmpty ? '未命名会话' : group.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: type.bodyStrong,
                    ),
                  ),
                  if (time.isNotEmpty) ...[
                    const SizedBox(width: AppSpace.sm),
                    Text(time, style: type.meta.copyWith(color: colors.textMuted)),
                  ],
                ],
              ),
            ),
          ),
          for (final hit in group.hits) ...[
            const Divider(height: 1, indent: AppSpace.lg, endIndent: AppSpace.lg),
            InkWell(
              onTap: () => onOpenHit(hit),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(AppSpace.lg, AppSpace.sm, AppSpace.lg, AppSpace.md),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: AppSpace.xs, vertical: 1),
                          decoration: BoxDecoration(
                            color: colors.accentSoft,
                            borderRadius: const BorderRadius.all(Radius.circular(AppRadius.sm)),
                          ),
                          child: Text(
                            hit.role == 'user' ? '我' : (hit.role == 'system' ? '系统' : '鲸灵'),
                            style: type.meta.copyWith(color: colors.accent),
                          ),
                        ),
                        const SizedBox(width: AppSpace.sm),
                        Text(
                          conversationTimeLabel(hit.createdAt),
                          style: type.meta.copyWith(color: colors.textMuted),
                        ),
                      ],
                    ),
                    const SizedBox(height: AppSpace.xs),
                    if (hit.isTitleHit)
                      Text('标题匹配', style: type.meta.copyWith(color: colors.textMuted))
                    else
                      SearchSnippet(text: hit.snippet, query: query),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
