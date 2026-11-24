import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../snack_web/snack_web_only_block.dart';
import '../theme/buzz_icons.dart';
import '../theme/theme.dart';
import 'snack_block_specs.dart';
import 'snack_choice_picks.dart';

part 'snack_block/progress_card.dart';
part 'snack_block/choices_card.dart';
part 'snack_block/chart_card.dart';

/// Answers a `snack-choices` card by posting [option] as a message.
typedef SnackChoiceAnswer = Future<void> Function(String option);

/// Draws a Snack card block (see [snackBlockLanguages]) the way Snack's web
/// app does, in a compact native form, never as raw JSON.
class SnackBlock extends ConsumerWidget {
  const SnackBlock({
    super.key,
    required this.language,
    required this.code,
    this.ink,
    this.choiceKey,
    this.onChoice,
    this.now,
  });

  /// The fence language, one of [snackBlockLanguages].
  final String language;
  final String code;

  /// Text color on an accent bubble.
  final Color? ink;

  /// The message id that remembers a picked choice.
  final String? choiceKey;

  /// Posts a picked option; null shows the options without buttons.
  final SnackChoiceAnswer? onChoice;

  /// Unix seconds, fixed for tests; null follows the clock.
  final int? now;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    switch (language.trim().toLowerCase()) {
      case 'snack-progress':
        final progress = SnackProgress.parse(code);
        if (progress == null) {
          return _BlockNote(text: 'Progress', ink: ink);
        }
        return _ProgressCard(progress: progress, ink: ink, now: now);
      case 'snack-choices':
        final choices = SnackChoices.parse(code);
        if (choices == null) return _BlockNote(text: 'Choices', ink: ink);
        return _ChoicesCard(
          choices: choices,
          ink: ink,
          // Per block, so two cards in one message don't share a pick.
          choiceKey: choiceKey == null ? null : '$choiceKey\u0000$code',
          onChoice: onChoice,
        );
      default:
        final chart = SnackChart.parse(code);
        if (chart.points.isEmpty) {
          return SnackWebOnlyBlock(label: chart.summary, ink: ink);
        }
        return _ChartCard(chart: chart, ink: ink);
    }
  }
}

/// A card's frame: a quiet outlined box that also reads on accent bubbles.
class _CardFrame extends StatelessWidget {
  const _CardFrame({required this.child, this.ink});

  final Widget child;
  final Color? ink;

  @override
  Widget build(BuildContext context) {
    final border = (ink ?? context.colors.outlineVariant).withValues(
      alpha: ink == null ? 1 : 0.4,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Grid.half),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Grid.twelve),
        decoration: BoxDecoration(
          border: Border.all(color: border),
          borderRadius: BorderRadius.circular(Radii.lg),
        ),
        child: child,
      ),
    );
  }
}

/// A block that couldn't be read yet (an agent still writing it).
class _BlockNote extends StatelessWidget {
  const _BlockNote({required this.text, this.ink});

  final String text;
  final Color? ink;

  @override
  Widget build(BuildContext context) => _CardFrame(
    ink: ink,
    child: Text(
      text,
      style: context.textTheme.bodyMedium?.copyWith(
        color: ink ?? context.colors.onSurfaceVariant,
      ),
    ),
  );
}
