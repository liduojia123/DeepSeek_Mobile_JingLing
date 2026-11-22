import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../core/providers.dart';
import '../design/theme.dart';
import 'chat_page.dart';
import 'conversation_drawer.dart';
import 'home_page.dart';

/// 响应式壳(v1.8.0 Web):宽屏双栏(左会话栏 + 右对话区),窄屏单栏(现状)。
class AppShell extends StatelessWidget {
  const AppShell({super.key});

  /// 双栏断点:再窄就退回单栏(抽屉)。
  static const double wideBreakpoint = 1000;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) =>
          constraints.maxWidth >= wideBreakpoint ? const _WideShell() : const HomePage(),
    );
  }
}

class _WideShell extends ConsumerStatefulWidget {
  const _WideShell();

  @override
  ConsumerState<_WideShell> createState() => _WideShellState();
}

class _WideShellState extends ConsumerState<_WideShell> {
  final GlobalKey<NavigatorState> _navKey = GlobalKey<NavigatorState>();

  /// 会话栏打开会话 → 右栏推入对话页;关闭后刷新会话栏(标题/预览可能变了)。
  Future<void> _open(String conversationId, {String? focusMessageId}) async {
    await _navKey.currentState?.push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ChatPage(conversationId: conversationId, focusMessageId: focusMessageId),
      ),
    );
    ref.invalidate(conversationsProvider);
  }

  @override
  Widget build(BuildContext context) {
    final colors = colorsOf(context);
    return Scaffold(
      body: Row(
        children: [
          SizedBox(
            width: 320,
            child: Material(
              color: colors.bg,
              child: ConversationPane(onOpenConversation: _open),
            ),
          ),
          VerticalDivider(width: 1, thickness: 1, color: colors.border),
          Expanded(
            child: Navigator(
              key: _navKey,
              onGenerateRoute: (settings) => MaterialPageRoute<void>(
                builder: (_) => const HomePage(wide: true),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
