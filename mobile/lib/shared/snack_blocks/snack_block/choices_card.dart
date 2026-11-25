part of '../snack_block.dart';

/// A question with its options. With [onChoice] each option is a button that
/// posts it as a message (as on the web); without, the options are listed.
class _ChoicesCard extends HookConsumerWidget {
  const _ChoicesCard({
    required this.choices,
    this.ink,
    this.choiceKey,
    this.onChoice,
  });

  final SnackChoices choices;
  final Color? ink;
  final String? choiceKey;
  final SnackChoiceAnswer? onChoice;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = choiceKey;
    final picked = key == null
        ? null
        : ref.watch(snackChoicePicksProvider.select((picks) => picks[key]));
    final sending = useState(false);
    final answer = onChoice;
    final quiet = ink ?? context.colors.onSurfaceVariant;

    Future<void> pick(String option) async {
      if (answer == null || sending.value || picked != null) return;
      final picks = ref.read(snackChoicePicksProvider.notifier);
      final messenger = ScaffoldMessenger.maybeOf(context);
      sending.value = true;
      if (key != null) picks.pick(key, option);
      try {
        await answer(option);
      } catch (error) {
        if (key != null) picks.clear(key);
        messenger?.showSnackBar(
          SnackBar(content: Text("Couldn't send that. Try again.")),
        );
        debugPrint('Snack choice failed: $error');
      } finally {
        if (context.mounted) sending.value = false;
      }
    }

    return _CardFrame(
      ink: ink,
      child: Column(
        key: const ValueKey('snack-choices-card'),
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (choices.question.isNotEmpty) ...[
            Text(
              choices.question,
              style: context.textTheme.bodyLarge?.copyWith(color: ink),
            ),
            const SizedBox(height: Grid.xxs),
          ],
          if (answer == null)
            for (final option in choices.options)
              Padding(
                padding: const EdgeInsets.only(bottom: Grid.quarter),
                child: Text(
                  '• $option',
                  style: context.textTheme.bodyMedium?.copyWith(color: quiet),
                ),
              )
          else
            Wrap(
              spacing: Grid.xxs,
              runSpacing: Grid.xxs,
              children: [
                for (final option in choices.options)
                  option == picked
                      ? FilledButton(
                          onPressed: null,
                          style: FilledButton.styleFrom(
                            disabledBackgroundColor:
                                ink ?? context.colors.primary,
                            disabledForegroundColor: ink == null
                                ? context.colors.onPrimary
                                : context.colors.primary,
                          ),
                          child: Semantics(selected: true, child: Text(option)),
                        )
                      : OutlinedButton(
                          onPressed: picked == null && !sending.value
                              ? () => unawaited(pick(option))
                              : null,
                          style: OutlinedButton.styleFrom(foregroundColor: ink),
                          child: Text(option),
                        ),
              ],
            ),
        ],
      ),
    );
  }
}
