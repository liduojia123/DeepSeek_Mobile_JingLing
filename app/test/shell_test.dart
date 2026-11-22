import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/design/theme.dart';
import 'package:jingling/pages/conversation_drawer.dart';
import 'package:jingling/pages/home_page.dart';
import 'package:jingling/pages/shell.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget wrap(double width) {
    return ProviderScope(
      child: MaterialApp(
        theme: buildAppTheme(Brightness.light),
        home: Scaffold(
          body: Center(
            child: SizedBox(width: width, height: 800, child: const AppShell()),
          ),
        ),
      ),
    );
  }

  // 双栏断点 1000:测试画布默认 800 宽会被夹住,先撑开
  Future<void> pumpWide(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(wrap(1400));
    await tester.pumpAndSettle();
  }

  testWidgets('宽屏:左会话栏 + 右首页双栏', (tester) async {
    await pumpWide(tester);

    expect(find.byType(ConversationPane), findsOneWidget);
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets('窄屏:单栏首页,会话栏在抽屉里(未打开不渲染)', (tester) async {
    await tester.pumpWidget(wrap(600));
    await tester.pumpAndSettle();

    expect(find.byType(ConversationPane), findsNothing);
    expect(find.byType(HomePage), findsOneWidget);
  });

  testWidgets('宽屏右栏首页不带抽屉(汉堡不出)', (tester) async {
    await pumpWide(tester);

    expect(find.byIcon(Icons.menu), findsNothing);
  });
}
