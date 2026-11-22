import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
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
import '../widgets/batch_action_bar.dart';
import '../widgets/search_snippet.dart';
import 'conversation_grouping.dart';
import 'computer_page.dart';

typedef OpenConversation = void Function(String conversationId, {String? focusMessageId});

/// 会话抽屉(v1.6.0):窄屏首页左上角 ≡ 拉出。
class ConversationDrawer extends StatelessWidget {
  const ConversationDrawer({super.key, required this.onOpenConversation});

  final OpenConversation onOpenConversation;

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ConversationPane(
        onOpenConversation: onOpenConversation,
        onClose: () => Navigator.of(context).pop(),
      ),
    );
  }
}

/// 会话栏(v1.8.0):抽屉与 Web 双栏左侧共用同一份内容。
///
/// 全局搜索(输入即搜)→ 电脑在跑横幅 → 置顶/今天/昨天/本周/更早 分组 →
/// 长按多选 + 底部批量操作栏。`onClose` 为空时不显示收起按钮(双栏常驻)。
class ConversationPane extends ConsumerStatefulWidget {
  const ConversationPane({super.key, required this.onOpenConversation, this.onClose});

  final OpenConversation onOpenConversation;
  final VoidCallback? onClose;

  @override
  ConsumerState<ConversationPane> createState() => _ConversationPaneState();
}

class _ConversationPaneState extends ConsumerState<ConversationPane> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  Timer? _debounce;
  int _searchSeq = 0;
  List<SearchGroup> _results = const [];
  bool _searching = false;
  String? _searchError;
  bool _multiSelect = false;
  bool _batchBusy = false;
  final Set<String> _selected = {};

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
    // 搜索态与多选互斥:搜索结果行不做多选
    if (_multiSelect) _exitMultiSelect();
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

  // ---------- 批量管理(v1.5.2):长按进多选,底部操作栏批量处理 ----------

  void _enterMultiSelect(String id) {
    setState(() {
      _multiSelect = true;
      _batchBusy = false;
      _selected
        ..clear()
        ..add(id);
    });
  }

  void _exitMultiSelect() {
    setState(() {
      _multiSelect = false;
      _batchBusy = false;
      _selected.clear();
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _toggleSelectAll(List<Conversation> items) {
    setState(() {
      if (_selected.length >= items.length) {
        _selected.clear();
      } else {
        _selected
          ..clear()
          ..addAll(items.map((item) => item.id));
      }
    });
  }

  Future<void> _batchDelete() async {
    final count = _selected.length;
    if (count == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('删除 $count 个会话'),
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
    if (confirmed != true || !mounted) return;
    await _runBatch((api, id) => api.deleteConversation(id));
  }

  Future<void> _batchSetPinned({required bool pinned}) async {
    if (_selected.isEmpty) return;
    await _runBatch((api, id) => api.patchConversation(id, pinned: pinned));
  }

  /// 逐个调既有单条接口(个人量级够用,服务端零改动);失败不打断其余,最后汇总提示。
  Future<void> _runBatch(Future<void> Function(ApiClient api, String id) call) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() => _batchBusy = true);
    var failed = 0;
    for (final id in List<String>.of(_selected)) {
      try {
        await call(api, id);
      } catch (_) {
        failed++;
      }
    }
    await ref.read(conversationsProvider.notifier).refresh();
    if (!mounted) return;
    _exitMultiSelect();
    if (failed > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('有 $failed 个会话没有处理成功')));
    }
  }

  Future<void> _renameSelected(List<Conversation> items) async {
    if (_selected.length != 1) return;
    final matches = items.where((item) => item.id == _selected.single);
    if (matches.isEmpty) return;
    await _renameConversation(matches.first);
    if (mounted) _exitMultiSelect();
  }

  Future<void> _renameConversation(Conversation conversation) async {
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
  }

  @override
  Widget build(BuildContext context) {
    final conversations = ref.watch(conversationsProvider);
    final items = conversations.value ?? const <Conversation>[];
    final harness = ref.watch(harnessProvider);
    final type = typeOf(context);
    final colors = colorsOf(context);

    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(AppSpace.page, AppSpace.sm, AppSpace.page, 0),
            child: Row(
              children: [
                Expanded(
                  child: _multiSelect
                      ? Text('已选 ${_selected.length} 个', style: type.title)
                      : Text('会话', style: type.title),
                ),
                if (_multiSelect)
                  IconButton(
                    tooltip: '退出多选',
                    icon: const Icon(Icons.close),
                    onPressed: _exitMultiSelect,
                  )
                else if (widget.onClose != null)
                  IconButton(
                    tooltip: '收起',
                    icon: const Icon(Icons.menu_open_outlined),
                    onPressed: widget.onClose,
                  ),
              ],
            ),
          ),
            _searchField(type, colors),
            if (harness.running && !_multiSelect) _computerBanner(colors, type),
            Expanded(
              child: conversations.when(
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
                      padding: const EdgeInsets.only(bottom: AppSpace.lg),
                      children: [
                        if (searchMode) ..._searchBody(type, colors),
                        if (!searchMode && items.isEmpty)
                          const Padding(
                            padding: EdgeInsets.only(top: AppSpace.xxxl),
                            child: EmptyState(
                              icon: Icons.forum_outlined,
                              title: '还没有对话',
                              body: '回到首页,直接发第一条消息',
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
                                      selectionMode: _multiSelect,
                                      selected: _selected.contains(group.items[i].id),
                                      onTap: () => _multiSelect
                                          ? _toggleSelected(group.items[i].id)
                                          : widget.onOpenConversation(group.items[i].id),
                                      onLongPress: () => _multiSelect
                                          ? _toggleSelected(group.items[i].id)
                                          : _enterMultiSelect(group.items[i].id),
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
            ),
            if (_multiSelect)
              BatchActionBar(
                selectedCount: _selected.length,
                totalCount: items.length,
                busy: _batchBusy,
                onToggleAll: () => _toggleSelectAll(items),
                onRename: () => _renameSelected(items),
                onPin: () => _batchSetPinned(pinned: true),
                onUnpin: () => _batchSetPinned(pinned: false),
                onDelete: _batchDelete,
              ),
          ],
        ),
    );
  }

  /// 搜索态主体:加载 / 错误重试 / 空结果 / 分组结果(HANDOFF-SEARCH §4.2)。
  List<Widget> _searchBody(AppType type, AppColors colors) {
    if (_searchError != null) {
      return [
        Padding(
          padding: const EdgeInsets.only(top: AppSpace.xxxl),
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
          padding: const EdgeInsets.only(top: AppSpace.xxxl),
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
          onOpenConversation: () => widget.onOpenConversation(group.conversationId),
          onOpenHit: (hit) => widget.onOpenConversation(group.conversationId, focusMessageId: hit.messageId),
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
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const ComputerPage()),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.md),
            child: Row(
              children: [
                Icon(Icons.desktop_windows_outlined, size: 18, color: colors.accent),
                const SizedBox(width: AppSpace.sm),
                Expanded(
                  child: Text(
                    '电脑上有任务在跑',
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
    this.selectionMode = false,
    this.selected = false,
  });

  final Conversation conversation;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selectionMode;
  final bool selected;

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
        child: Row(
          children: [
            if (selectionMode) ...[
              Icon(
                selected ? Icons.check_circle : Icons.circle_outlined,
                size: 20,
                color: selected ? colors.accent : colors.textMuted,
              ),
              const SizedBox(width: AppSpace.sm),
            ],
            Expanded(
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
            // Web 鼠标长按不可靠,给一个显式多选入口(手机继续用长按)
            if (kIsWeb && !selectionMode)
              IconButton(
                tooltip: '多选',
                visualDensity: VisualDensity.compact,
                icon: Icon(Icons.checklist, size: 18, color: colors.textMuted),
                onPressed: onLongPress,
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
