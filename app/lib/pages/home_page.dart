import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:material_ui/material_ui.dart';

import '../core/api.dart';
import '../core/providers.dart';
import '../design/theme.dart';
import '../design/tokens.dart';
import '../models/models.dart';
import 'chat_page.dart';
import 'computer_page.dart';
import 'conversation_drawer.dart';
import 'memory_page.dart';
import 'settings_page.dart';
import 'usage_page.dart';

/// 输入优先首页(v1.6.0):打开就能发消息,发出去自动建会话进对话页;
/// 历史会话收进左上角抽屉(搜索/分组/批量管理都在里面)。
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  final TextEditingController _input = TextEditingController();
  final List<ChatFile> _pendingFiles = [];
  bool _searchOn = true;
  bool _thinkingOn = true;
  bool _busy = false;

  @override
  void dispose() {
    _input.dispose();
    super.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  /// 建会话 → 进对话页(首条消息/语音模式由 ChatPage 自动接力)。
  Future<void> _startChat({String? text, List<String>? fileIds, bool ephemeral = false, bool autoStartVoice = false}) async {
    final api = ref.read(apiProvider);
    if (api == null) {
      _toast('还没有配对:先在设置里完成配对');
      return;
    }
    setState(() => _busy = true);
    try {
      final conversation = await api.createConversation(ephemeral: ephemeral);
      if (!mounted) return;
      _input.clear();
      setState(() {
        _pendingFiles.clear();
        _busy = false;
      });
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChatPage(
            conversationId: conversation.id,
            initialText: text,
            initialFileIds: fileIds,
            initialSearch: _searchOn,
            initialThinking: _thinkingOn,
            autoStartVoice: autoStartVoice,
          ),
        ),
      );
      if (mounted) ref.invalidate(conversationsProvider);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast(error.message);
    }
  }

  Future<void> _send() async {
    final text = _input.text.trim();
    final files = List<ChatFile>.of(_pendingFiles);
    if (text.isEmpty && files.isEmpty) return;
    await _startChat(
      text: text,
      fileIds: files.map((file) => file.id).toList(growable: false),
    );
  }

  Future<void> _attach(String name, List<int> bytes) async {
    final api = ref.read(apiProvider);
    if (api == null) return;
    try {
      final result = await api.uploadFile(filename: name, bytes: bytes);
      if (!mounted) return;
      setState(() => _pendingFiles.add(ChatFile(id: result.fileId, name: result.name)));
    } on ApiException catch (error) {
      _toast(error.message);
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final picked = await ImagePicker().pickMultiImage(imageQuality: 85, maxWidth: 2200, limit: 6);
      if (picked.isEmpty) return;
      var added = 0;
      for (final file in picked) {
        final bytes = await file.readAsBytes();
        if (bytes.isEmpty) continue;
        await _attach(file.name, bytes);
        added += 1;
      }
      if (added > 0) _toast('已添加 $added 张图片,可以补充问题后发送');
    } catch (error) {
      _toast('选择图片失败:$error');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final picked = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2200);
      if (picked == null) return;
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty) {
        _toast('照片内容为空,再拍一张?');
        return;
      }
      await _attach(picked.name, bytes);
      _toast('照片已添加,可以补充问题后发送');
    } catch (error) {
      _toast('拍照失败:$error');
    }
  }

  Future<void> _pickFile() async {
    try {
      final file = await FilePicker.pickFile(
        type: FileType.custom,
        allowedExtensions: const [
          'pdf', 'doc', 'docx', 'ppt', 'pptx',
          'png', 'jpg', 'jpeg', 'webp', 'gif', 'bmp', 'tif', 'tiff',
          'txt', 'md', 'csv', 'json', 'xlsx', 'xls', 'epub',
        ],
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        _toast('文件内容为空');
        return;
      }
      await _attach(file.name, bytes);
    } catch (error) {
      _toast('选择文件失败:$error');
    }
  }

  /// 「＋」:拍照 / 相册 / 文件(语音在输入框右侧的麦克风)。
  Future<void> _showInputActions() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(sheetContext, 'photo'),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('相册'),
              onTap: () => Navigator.pop(sheetContext, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('文件'),
              onTap: () => Navigator.pop(sheetContext, 'file'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'photo':
        await _takePhoto();
      case 'gallery':
        await _pickFromGallery();
      case 'file':
        await _pickFile();
    }
  }

  Future<void> _showOverflow() async {
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
              subtitle: const Text('不保存历史,关掉即清'),
              onTap: () {
                Navigator.pop(sheetContext);
                _startChat(ephemeral: true);
              },
            ),
            ListTile(
              leading: const Icon(Icons.psychology_outlined),
              title: const Text('记忆'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const MemoryPage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.desktop_windows_outlined),
              title: const Text('电脑'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ComputerPage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.insights_outlined),
              title: const Text('用量'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const UsagePage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('设置'),
              onTap: () {
                Navigator.pop(sheetContext);
                Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SettingsPage()));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 首页快捷开关(药丸样式,随截图):对应对话页的「深度思考 / 智能搜索」。
  Widget _pillChip({required IconData icon, required String label, required bool on, required VoidCallback onTap}) {
    final colors = colorsOf(context);
    final type = typeOf(context);
    return InkWell(
      borderRadius: const BorderRadius.all(Radius.circular(AppRadius.pill)),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: AppSpace.md, vertical: AppSpace.xs + 2),
        decoration: BoxDecoration(
          color: on ? colors.accentSoft : colors.surface,
          borderRadius: const BorderRadius.all(Radius.circular(AppRadius.pill)),
          border: Border.all(color: on ? colors.accentSoft : colors.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: on ? colors.accent : colors.textMuted),
            const SizedBox(width: AppSpace.xs),
            Text(
              label,
              style: type.meta.copyWith(
                color: on ? colors.accent : colors.textMuted,
                fontWeight: on ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final type = typeOf(context);
    final colors = colorsOf(context);
    final canSend = !_busy && (_input.text.trim().isNotEmpty || _pendingFiles.isNotEmpty);

    return Scaffold(
      drawer: ConversationDrawer(
        onOpenConversation: (conversationId, {String? focusMessageId}) {
          Navigator.of(context).pop(); // 收起抽屉
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ChatPage(conversationId: conversationId, focusMessageId: focusMessageId),
            ),
          );
        },
      ),
      appBar: AppBar(
        actions: [
          IconButton(
            tooltip: '新对话(清空当前草稿)',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () {
              _input.clear();
              setState(() => _pendingFiles.clear());
            },
          ),
          IconButton(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz),
            onPressed: _showOverflow,
          ),
          const SizedBox(width: AppSpace.xs),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(AppRadius.lg)),
                    child: Image.asset('assets/icon/home_logo.png', width: 96, height: 96),
                  ),
                  const SizedBox(height: AppSpace.lg),
                  Text('欢迎回来,想从哪里开始?', style: type.title),
                ],
              ),
            ),
          ),
          // 输入区放 body 而不是 bottomNavigationBar:后者不随键盘上浮,会被键盘盖住(v1.6.2 修)
          SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.fromLTRB(AppSpace.page, AppSpace.sm, AppSpace.page, AppSpace.sm),
          decoration: BoxDecoration(
            color: colors.bg,
            border: Border(top: BorderSide(color: colors.border)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_pendingFiles.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      for (final file in _pendingFiles)
                        InputChip(
                          avatar: const Icon(Icons.description_outlined, size: 16),
                          label: Text(file.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          onDeleted: () => setState(() => _pendingFiles.removeWhere((item) => item.id == file.id)),
                        ),
                    ],
                  ),
                ),
              Row(
                children: [
                  _pillChip(
                    icon: Icons.psychology_outlined,
                    label: '深度思考',
                    on: _thinkingOn,
                    onTap: () => setState(() => _thinkingOn = !_thinkingOn),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  _pillChip(
                    icon: Icons.public,
                    label: '智能搜索',
                    on: _searchOn,
                    onTap: () => setState(() => _searchOn = !_searchOn),
                  ),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: '拍照 / 相册 / 文件',
                    onPressed: _busy ? null : _showInputActions,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      shape: const CircleBorder(),
                    ),
                    icon: const Icon(Icons.add, size: 20),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  Expanded(
                    child: TextField(
                      controller: _input,
                      minLines: 1,
                      maxLines: 5,
                      onChanged: (_) => setState(() {}),
                      style: type.body,
                      decoration: InputDecoration(
                        hintText: '发消息或从「＋」开始…',
                        suffixIcon: IconButton(
                          tooltip: '语音模式',
                          onPressed: _busy ? null : () => _startChat(autoStartVoice: true),
                          icon: Icon(Icons.mic_none, size: 20, color: colors.textMuted),
                        ),
                        suffixIconConstraints: const BoxConstraints(minWidth: 40),
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpace.sm),
                  IconButton(
                    tooltip: '发送',
                    onPressed: canSend ? _send : null,
                    style: IconButton.styleFrom(
                      minimumSize: const Size(44, 44),
                      backgroundColor: canSend ? colors.accent : colors.surfaceSunken,
                      foregroundColor: canSend ? colors.onAccent : colors.textMuted,
                      shape: const CircleBorder(),
                    ),
                    icon: const Icon(Icons.arrow_upward, size: 20),
                  ),
                ],
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
