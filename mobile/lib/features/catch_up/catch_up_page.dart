import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/relay/relay.dart';
import '../../shared/theme/buzz_icons.dart';
import '../../shared/theme/theme.dart';
import '../../shared/widgets/adaptive_conversation_pane.dart';
import '../../shared/widgets/feedback_snackbar.dart';
import '../../shared/widgets/ios_glass_navigation_button.dart';
import '../channels/channel.dart';
import '../channels/channel_detail_page.dart';
import 'catch_up_card.dart';
import 'catch_up_queue.dart';
import 'catch_up_read.dart';
import 'catch_up_reader.dart';
import 'catch_up_sources.dart';
import 'catch_up_state.dart';

/// Opens a conversation from Catch-up, the only action that leaves it.
typedef CatchUpOpenConversation =
    void Function(
      BuildContext context,
      Channel channel,
      String? messageId,
      String? threadRootId,
    );

void _openConversation(
  BuildContext context,
  Channel channel,
  String? messageId,
  String? threadRootId,
) {
  unawaited(
    openConversationPane(
      context,
      messageId ?? channel.id,
      (_) => ChannelDetailPage(
        channel: channel,
        initialMessageId: messageId,
        initialThreadRootId: threadRootId,
        initialThreadRouteBehavior:
            ConversationPaneScope.maybeOf(context) == null
            ? InitialThreadRouteBehavior.replaceCurrentRoute
            : InitialThreadRouteBehavior.push,
      ),
      reopen: true,
    ),
  );
}

/// Catch-up: every unread conversation and thread aimed at you (DMs,
/// mentions, replies in your threads) as a stack of cards. Mark each read,
/// keep it for later, or undo. A port of Snack web's `CatchUpPage`.
class CatchUpPage extends HookConsumerWidget {
  const CatchUpPage({super.key, this.openConversation = _openConversation});

  final CatchUpOpenConversation openConversation;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(catchUpStateProvider);
    final entries = ref.watch(catchUpEntriesProvider);
    final evidence = ref.watch(catchUpEvidenceProvider);
    final loadingQueue = ref.watch(catchUpLoadingProvider);
    final channels = ref.watch(catchUpChannelsProvider);
    final viewer = ref.watch(myPubkeyProvider);
    final reader = ref.watch(catchUpReaderProvider);
    // Leaving Catch-up writes the reads still waiting for Undo.
    useEffect(() => reader.flush, [reader]);
    final tick = useState(0);
    void update(void Function() change) {
      change();
      if (context.mounted) tick.value++;
    }

    final byId = {for (final entry in entries) entry.key: entry};
    // Settled while building, not in an effect, so a new arrival never shows
    // on top for a moment: the card being read stays put.
    for (final entry in entries) {
      state.seen[entry.key] = entry;
    }
    final topDecided = state.steps.any((step) => step.key == state.top);
    // New messages after a decision bring the card back, with a fresh New line.
    final superseded = state.steps
        .where((step) => (byId[step.key]?.latest ?? 0) > step.latest)
        .toList();
    if (superseded.isNotEmpty) {
      state.steps = [
        for (final step in state.steps)
          if (!superseded.contains(step)) step,
      ];
      for (final step in superseded) {
        state.newLines.remove(step.key);
      }
    }
    state.order = stackOrder(
      state.order,
      entries,
      top: state.top,
      topDecided: topDecided,
      handled: {for (final step in state.steps) step.key},
      restored: state.restored,
    );
    final handled = {for (final step in state.steps) step.key};
    final deck = [
      for (final key in state.order)
        if (!handled.contains(key) &&
            (byId.containsKey(key) ||
                state.restored.contains(key) ||
                key == state.shown))
          key,
    ];
    final kept = state.steps
        .where((step) => step.action == CatchUpAction.keep)
        .length;
    final current = deck.firstOrNull;
    final next = deck.length > 1 ? deck[1] : null;
    // The top card stays put until decided: reading or replying in it may
    // clear its unread before then.
    state.shown = current;
    if (current != null) state.top = current;
    // Coming back to Catch-up lists only what is still unread.
    useEffect(() {
      state.shown = current;
      return () => state.shown = null;
    }, [state, current]);
    if (current != null &&
        parseCardKey(current).rootId == null &&
        !state.newLines.containsKey(current)) {
      state.newLines[current] = evidence[current]?.unread.oldestUnreadId;
    }

    Channel? channelOf(String? key) {
      if (key == null) return null;
      final channelId = parseCardKey(key).channelId;
      return channels.where((c) => c.id == channelId).firstOrNull;
    }

    void toast(String message) =>
        ScaffoldMessenger.maybeOf(context)?.showFeedbackSnackBar(
          SnackBar(content: Text(message)),
          kind: ToastKind.error,
        );

    Future<void> decide(String key, CatchUpAction action, int latest) async {
      // Read elsewhere meanwhile: nothing is left to read, and Undo must not
      // mark it unread.
      final noop =
          action == CatchUpAction.read &&
          parseCardKey(key).rootId != null &&
          !byId.containsKey(key);
      update(() {
        state.restored.remove(key);
        state.steps.add(
          CatchUpStep(key: key, action: action, latest: latest, noop: noop),
        );
      });
      if (action == CatchUpAction.keep || noop) return;
      try {
        final result = await readCard(reader, key, entries);
        final at = state.steps.indexWhere(
          (step) => step.key == key && step.action == CatchUpAction.read,
        );
        if (at >= 0 && (result == null || result.undo != null)) {
          update(() {
            state.steps[at] = result == null
                ? state.steps[at].copyWith(noop: true)
                : state.steps[at].copyWith(undo: result.undo);
          });
        }
      } catch (cause) {
        // The card comes back: nothing was read.
        update(() {
          state.steps.removeWhere(
            (step) => step.key == key && step.action == CatchUpAction.read,
          );
          state.order = [key, ...state.order.where((id) => id != key)];
          state.restored.add(key);
        });
        toast("Couldn't mark it read");
      }
    }

    void act(CatchUpAction action) {
      final key = current;
      if (key == null) return;
      final latest = (byId[key] ?? state.seen[key])?.latest ?? 0;
      unawaited(decide(key, action, latest));
    }

    void undo() {
      if (state.steps.isEmpty) return;
      final step = state.steps.last;
      update(() {
        state.steps.removeLast();
        state.restored.add(step.key);
        state.order = [step.key, ...state.order.where((id) => id != step.key)];
      });
      if (step.action == CatchUpAction.read && !step.noop) {
        unawaited(() async {
          try {
            await unreadCard(reader, step.key, step.undo);
          } catch (_) {
            toast("Couldn't mark it unread again");
          }
        }());
      }
    }

    void open(String channelId, String? messageId, String? threadRootId) {
      final channel = channels.where((c) => c.id == channelId).firstOrNull;
      if (channel == null) {
        toast('Conversation unavailable');
        return;
      }
      openConversation(context, channel, messageId, threadRootId);
    }

    final Widget body;
    if (current != null) {
      final (:channelId, :rootId) = parseCardKey(current);
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Grid.xs, Grid.xxs, Grid.xs, 0),
              child: Stack(
                children: [
                  if (next != null)
                    Positioned.fill(
                      top: Grid.twelve,
                      left: Grid.xxs,
                      right: Grid.xxs,
                      child: ExcludeSemantics(
                        child: _CardPeek(
                          title:
                              '${catchUpTitle(channelOf(next), viewer)}'
                              '${parseCardKey(next).rootId != null ? ' · Thread' : ''}',
                        ),
                      ),
                    ),
                  Positioned.fill(
                    bottom: Grid.xxs,
                    child: CatchUpCard(
                      key: ValueKey(current),
                      channel: channelOf(current),
                      channelId: channelId,
                      rootId: rootId,
                      entry: byId[current] ?? state.seen[current],
                      newLineId: state.newLines[current],
                      viewer: viewer,
                      onOpen: open,
                      onDecide: act,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Grid.xs,
              Grid.xxs,
              Grid.xs,
              Grid.half,
            ),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () => act(CatchUpAction.keep),
                    child: const Text('Keep unread'),
                  ),
                ),
                const SizedBox(width: Grid.twelve),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: () => act(CatchUpAction.read),
                    child: const Text('Mark as read'),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(
              Grid.xs,
              0,
              Grid.xs,
              MediaQuery.paddingOf(context).bottom + Grid.xxs,
            ),
            child: Text(
              'Swipe right to mark read, left to keep unread.',
              textAlign: TextAlign.center,
              style: context.textTheme.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      );
    } else if (loadingQueue) {
      body = Center(
        child: Text(
          'Looking for anything aimed at you…',
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      );
    } else {
      body = _EmptyState(
        kept: kept,
        onGoThroughKept: () => update(() {
          final keptIds = [
            for (final step in state.steps)
              if (step.action == CatchUpAction.keep) step.key,
          ];
          state.steps.removeWhere((step) => step.action == CatchUpAction.keep);
          state.restored.addAll(keptIds);
        }),
      );
    }

    final title = current != null ? '${deck.length} Left' : 'Catch up';
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
            act(CatchUpAction.read),
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
            act(CatchUpAction.keep),
        const SingleActivator(LogicalKeyboardKey.keyZ): undo,
        const SingleActivator(LogicalKeyboardKey.keyU): undo,
        const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): undo,
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: context.colors.surface,
          body: SafeArea(
            bottom: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Header(
                  title: title,
                  onUndo: state.steps.isEmpty ? null : undo,
                ),
                Expanded(child: body),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onUndo});
  final String title;
  final VoidCallback? onUndo;

  @override
  Widget build(BuildContext context) {
    void close() => Navigator.of(context).maybePop();
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Grid.gutter,
        vertical: Grid.xxs,
      ),
      child: Row(
        children: [
          if (Navigator.of(context).canPop())
            Padding(
              padding: const EdgeInsets.only(right: Grid.twelve),
              child: defaultTargetPlatform == TargetPlatform.iOS
                  ? IosGlassNavigationButton(
                      icon: IosGlassNavigationIcon.close,
                      semanticLabel: 'Close catch up',
                      width: 44,
                      height: 44,
                      controlSize: 44,
                      foregroundColor: context.colors.onSurface,
                      onPressed: close,
                    )
                  : IconButton(
                      tooltip: 'Close catch up',
                      icon: const Icon(BuzzIcons.x),
                      onPressed: close,
                    ),
            ),
          Expanded(
            child: Semantics(
              header: true,
              child: Text(
                title,
                style: context.textTheme.titleMedium?.copyWith(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          if (onUndo != null)
            TextButton.icon(
              onPressed: onUndo,
              icon: const Icon(BuzzIcons.refreshCcw, size: 16),
              label: const Text('Undo'),
            ),
        ],
      ),
    );
  }
}

class _CardPeek extends StatelessWidget {
  const _CardPeek({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: context.colors.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(Radii.container),
    ),
    child: Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.all(Grid.half),
        child: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: context.textTheme.labelSmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ),
    ),
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.kept, required this.onGoThroughKept});
  final int kept;
  final VoidCallback onGoThroughKept;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Grid.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(BuzzIcons.checkCheck, size: 40, color: context.colors.primary),
          const SizedBox(height: Grid.xs),
          Text(
            "You're all caught up",
            textAlign: TextAlign.center,
            style: context.textTheme.titleLarge?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: Grid.xxs),
          Text(
            kept > 0
                ? 'You kept $kept ${kept == 1 ? 'conversation' : 'conversations'} unread for later.'
                : 'Mentions, DMs and replies in your threads show up here as cards.',
            textAlign: TextAlign.center,
            style: context.textTheme.bodyMedium?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          if (kept > 0) ...[
            const SizedBox(height: Grid.xs),
            FilledButton(
              onPressed: onGoThroughKept,
              child: const Text('Go through kept conversations'),
            ),
          ],
        ],
      ),
    ),
  );
}
