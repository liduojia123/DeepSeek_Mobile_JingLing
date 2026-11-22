import 'package:flutter_test/flutter_test.dart';
import 'package:jingling/design/theme.dart';
import 'package:jingling/widgets/batch_action_bar.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late int deletes;
  late int pins;
  late int unpins;
  late int toggleAlls;
  late int renames;

  setUp(() {
    deletes = 0;
    pins = 0;
    unpins = 0;
    toggleAlls = 0;
    renames = 0;
  });

  Widget wrap({
    required int selectedCount,
    required int totalCount,
    bool busy = false,
    bool withRename = true,
  }) {
    return MaterialApp(
      theme: buildAppTheme(Brightness.light),
      home: Scaffold(
        bottomNavigationBar: BatchActionBar(
          selectedCount: selectedCount,
          totalCount: totalCount,
          busy: busy,
          onDelete: () => deletes++,
          onPin: () => pins++,
          onUnpin: () => unpins++,
          onToggleAll: () => toggleAlls++,
          onRename: withRename ? () => renames++ : null,
        ),
      ),
    );
  }

  testWidgets('恰好选中 1 个才显示重命名', (tester) async {
    await tester.pumpWidget(wrap(selectedCount: 1, totalCount: 5));
    expect(find.text('重命名'), findsOneWidget);

    await tester.pumpWidget(wrap(selectedCount: 2, totalCount: 5));
    expect(find.text('重命名'), findsNothing);
  });

  testWidgets('无选中时置顶/取消置顶/删除禁用,点击不触发', (tester) async {
    await tester.pumpWidget(wrap(selectedCount: 0, totalCount: 5));
    await tester.tap(find.text('置顶'), warnIfMissed: false);
    await tester.tap(find.text('取消置顶'), warnIfMissed: false);
    await tester.tap(find.text('删除'), warnIfMissed: false);
    await tester.pump();
    expect(pins, 0);
    expect(unpins, 0);
    expect(deletes, 0);
  });

  testWidgets('有选中时删除/置顶/取消置顶可用', (tester) async {
    await tester.pumpWidget(wrap(selectedCount: 3, totalCount: 5));
    await tester.tap(find.text('删除'));
    await tester.tap(find.text('置顶'));
    await tester.tap(find.text('取消置顶'));
    await tester.pump();
    expect(deletes, 1);
    expect(pins, 1);
    expect(unpins, 1);
  });

  testWidgets('全选按钮按选中数切换文案并可点击', (tester) async {
    await tester.pumpWidget(wrap(selectedCount: 2, totalCount: 5));
    expect(find.text('全选'), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.pump();
    expect(toggleAlls, 1);

    await tester.pumpWidget(wrap(selectedCount: 5, totalCount: 5));
    expect(find.text('取消全选'), findsOneWidget);
  });

  testWidgets('busy 期间全部禁用,防连点', (tester) async {
    await tester.pumpWidget(wrap(selectedCount: 2, totalCount: 5, busy: true));
    await tester.tap(find.text('全选'), warnIfMissed: false);
    await tester.tap(find.text('删除'), warnIfMissed: false);
    await tester.pump();
    expect(toggleAlls, 0);
    expect(deletes, 0);
  });
}
