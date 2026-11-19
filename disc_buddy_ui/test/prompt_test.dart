import 'package:disc_buddy_ui/providers/prompt_provider.dart';
import 'package:disc_buddy_ui/widgets/prompt_host.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('PromptQueueNotifier', () {
    test('questions queue up and resolve in any order', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final q = c.read(promptQueueProvider.notifier);

      final pick = q.choose('Pick one', ['a', 'b'], defaultIndex: 0);
      final yes = q.confirm('Sure?');
      expect(c.read(promptQueueProvider), hasLength(2));

      q.resolve(c.read(promptQueueProvider)[1], true);
      expect(await yes, isTrue);
      q.resolve(c.read(promptQueueProvider).single, 1);
      expect(await pick, 1);
      expect(c.read(promptQueueProvider), isEmpty);
    });

    test('skipping a pick and out-of-range answers give null', () async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      final q = c.read(promptQueueProvider.notifier);

      final skipped = q.choose('Pick', ['a'], defaultIndex: 0);
      q.resolve(c.read(promptQueueProvider).single, null);
      expect(await skipped, isNull);

      final bogus = q.choose('Pick', ['a']);
      q.resolve(c.read(promptQueueProvider).single, 7);
      expect(await bogus, isNull);

      expect(await q.choose('Nothing to pick', const []), isNull);
    });

    test('disposing releases waiting questions with their defaults', () async {
      final c = ProviderContainer();
      final q = c.read(promptQueueProvider.notifier);
      final pick = q.choose('Pick', ['a', 'b'], defaultIndex: 1);
      final yes = q.confirm('Sure?', defaultValue: true);

      c.dispose();

      expect(await pick, 1);
      expect(await yes, isTrue);
    });
  });

  test('DialogPrompter strips terminal formatting from questions', () async {
    final c = ProviderContainer();
    addTearDown(c.dispose);
    final prompter = DialogPrompter(c.read(promptQueueProvider.notifier),
        context: () => ['[2/6] title_03.mkv']);

    final answer =
        prompter.confirm('   Use batch assignment? (one LLM call) [y/N] ');
    final request = c.read(promptQueueProvider).single;
    expect(request.question, 'Use batch assignment? (one LLM call)');
    expect(request.context, ['[2/6] title_03.mkv']);
    c.read(promptQueueProvider.notifier).resolve(request, false);
    expect(await answer, isFalse);

    expect(await prompter.readLine('Language: ', defaultValue: 'nl'), 'nl');
  });

  group('PromptHost', () {
    Future<ProviderContainer> pumpHost(WidgetTester tester) async {
      final c = ProviderContainer();
      addTearDown(c.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: const MaterialApp(
          home: PromptHost(child: Scaffold(body: Text('app'))),
        ),
      ));
      return c;
    }

    testWidgets('shows a pick as a dialog and returns the tapped option',
        (tester) async {
      final c = await pumpHost(tester);
      final answer = c.read(promptQueueProvider.notifier).choose(
          'Multiple series candidates are close in score:',
          ['[9.1] Seinfeld (1989)', '[8.8] Seinfeld: The Reunion'],
          defaultIndex: 0,
          context: ['[1/6] title_01.mkv']);
      await tester.pumpAndSettle();

      expect(find.text('Multiple series candidates are close in score:'),
          findsOneWidget);
      expect(find.text('[1/6] title_01.mkv'), findsOneWidget);

      await tester.tap(find.text('[8.8] Seinfeld: The Reunion'));
      await tester.pumpAndSettle();

      expect(await answer, 1);
      expect(find.byType(AlertDialog), findsNothing);
    });

    testWidgets('asks queued questions one after another', (tester) async {
      final c = await pumpHost(tester);
      final q = c.read(promptQueueProvider.notifier);
      final first = q.confirm('First?');
      final second = q.choose('Second?', ['x', 'y']);
      await tester.pumpAndSettle();

      expect(find.text('First?'), findsOneWidget);
      expect(find.text('Second?'), findsNothing);
      await tester.tap(find.text('Yes'));
      await tester.pumpAndSettle();
      expect(await first, isTrue);

      expect(find.text('Second?'), findsOneWidget);
      await tester.tap(find.text('Skip'));
      await tester.pumpAndSettle();
      expect(await second, isNull);
    });
  });
}
