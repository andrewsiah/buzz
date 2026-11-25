import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/profile/user_cache_provider.dart';
import '../../shared/profile/user_profile.dart';
import '../../shared/snack_blocks/snack_block.dart';
import '../../shared/snack_blocks/snack_block_specs.dart';
import '../../shared/theme/buzz_icons.dart';
import '../../shared/theme/theme.dart';
import '../channels/channel.dart';
import '../channels/channel_identity_names_provider.dart';
import '../channels/channel_mutes/channel_mutes_provider.dart';
import '../channels/date_formatters.dart';
import '../channels/small_avatar.dart';
import '../channels/thread_replies_provider.dart';
import 'catch_up_messages.dart';
import 'catch_up_queue.dart';
import 'catch_up_sources.dart';
import 'catch_up_state.dart';

part 'catch_up_card/message_row.dart';

/// How far a drag must travel to count as a decision.
const catchUpSwipeThreshold = 120.0;

/// Rows shown before the first unread one, for context.
const _context = 2;

/// The newest rows a card shows; the conversation holds the rest.
const _maxRows = 40;

/// A contextual author label in a channel. Its own seam so the card can be
/// shown without the identity directory.
final catchUpAuthorLabelProvider = Provider.autoDispose
    .family<String Function(String pubkey), String>((ref, channelId) {
      final names = ref.watch(channelIdentityNamesProvider(channelId));
      return names.labelFor;
    });

/// Profiles for avatars, as the rest of the app reads them.
final catchUpProfilesProvider = Provider<Map<String, UserProfile>>(
  (ref) => ref.watch(userCacheProvider),
);

/// Whether a channel is muted, and how to change it.
final catchUpMuteProvider = Provider<CatchUpMuteControl>((ref) {
  final muted = ref.watch(catchUpMutedChannelIdsProvider);
  final notifier = ref.read(channelMutesProvider.notifier);
  return CatchUpMuteControl(
    muted: muted,
    setMuted: (channelId, value) => value
        ? notifier.muteChannel(channelId)
        : notifier.unmuteChannel(channelId),
  );
});

class CatchUpMuteControl {
  const CatchUpMuteControl({required this.muted, required this.setMuted});
  final Set<String> muted;
  final void Function(String channelId, bool muted) setMuted;
}

/// Why a card is aimed at the viewer (web `CatchUpCard` reason).
String catchUpReason({
  required String? rootId,
  required CatchUpEntry? entry,
  required Set<String> categories,
}) {
  if (rootId != null) return 'New replies in a thread';
  if (entry == null) return 'Marked unread';
  if (entry.dm) return 'Direct message';
  if (categories.contains('mention')) return 'You are @mentioned';
  if (categories.contains('thread')) return 'Replies in your thread';
  if (entry.manual) return 'Marked unread';
  return 'For you';
}

/// The card's title: a DM's other participants, else the channel's name.
String catchUpTitle(Channel? channel, String? viewer) {
  if (channel == null) return 'Conversation';
  final label = channel.displayLabel(currentPubkey: viewer).trim();
  return label.isEmpty
      ? (channel.isDm ? 'Direct message' : 'Conversation')
      : label;
}

/// One Catch-up card: a conversation's new messages under a New line, or one
/// thread. A conversation card opens a message's replies inside the card;
/// the title menu opens the real conversation.
class CatchUpCard extends HookConsumerWidget {
  const CatchUpCard({
    super.key,
    required this.channel,
    required this.channelId,
    this.rootId,
    required this.entry,
    required this.newLineId,
    required this.viewer,
    required this.onOpen,
    required this.onDecide,
  });

  final Channel? channel;
  final String channelId;

  /// A thread card: it shows this thread as its own conversation.
  final String? rootId;
  final CatchUpEntry? entry;

  /// The oldest unread message when the card first showed.
  final String? newLineId;
  final String? viewer;

  /// Opens the real conversation at [messageId], inside [threadRootId] when
  /// it is a thread.
  final void Function(String channelId, String? messageId, String? threadRootId)
  onOpen;
  final ValueChanged<CatchUpAction> onDecide;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final opened = useState<String?>(null);
    final thread = rootId ?? opened.value;
    final dx = useState(0.0);
    final title = catchUpTitle(channel, viewer);
    final evidence = ref.watch(catchUpEvidenceProvider)[channelId];
    final categories = <String>{
      for (final event in evidence?.unreadEvents ?? const [])
        if (event.rootId != null)
          'thread'
        else if (event.highPriority && !(channel?.isDm ?? false))
          'mention',
    };
    final reason = catchUpReason(
      rootId: rootId,
      entry: entry,
      categories: categories,
    );
    final mute = ref.watch(catchUpMuteProvider);
    final muted = mute.muted.contains(channelId);
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final strength = min(1.0, dx.value.abs() / catchUpSwipeThreshold);

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(
        Grid.xs,
        Grid.twelve,
        Grid.xxs,
        Grid.xxs,
      ),
      child: Row(
        children: [
          Expanded(
            child: PopupMenuButton<String>(
              tooltip: '$title options',
              position: PopupMenuPosition.under,
              onSelected: (value) {
                if (value == 'open') {
                  onOpen(channelId, thread ?? newLineId, thread);
                } else if (value == 'mute') {
                  mute.setMuted(channelId, !muted);
                }
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'open',
                  child: Text('Open conversation'),
                ),
                if (!(channel?.isDm ?? false))
                  PopupMenuItem(
                    value: 'mute',
                    child: Text(muted ? 'Unmute channel' : 'Mute channel'),
                  ),
              ],
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: Grid.half),
                      Icon(
                        BuzzIcons.chevronDown,
                        size: 16,
                        color: context.colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                  Text(
                    reason,
                    style: context.textTheme.bodySmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          IconButton.filled(
            tooltip: 'Mark as read',
            icon: const Icon(BuzzIcons.check, size: 20),
            onPressed: () => onDecide(CatchUpAction.read),
          ),
        ],
      ),
    );

    final Widget body;
    if (thread != null) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (opened.value != null && rootId == null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => opened.value = null,
                icon: const Icon(BuzzIcons.arrowLeft, size: 16),
                label: Text('Back to $title'),
              ),
            ),
          Expanded(
            child: Semantics(
              label: 'Thread',
              container: true,
              explicitChildNodes: true,
              child: _ThreadRows(
                channelId: channelId,
                rootId: thread,
                onOpen: (messageId) => onOpen(channelId, messageId, thread),
              ),
            ),
          ),
        ],
      );
    } else {
      body = _TimelineRows(
        channelId: channelId,
        newLineId: newLineId,
        onOpen: (messageId) => onOpen(channelId, messageId, null),
        onOpenThread: (messageId) => opened.value = messageId,
      );
    }

    return Semantics(
      container: true,
      label: '$title: $reason',
      customSemanticsActions: {
        const CustomSemanticsAction(label: 'Mark as read'): () =>
            onDecide(CatchUpAction.read),
        const CustomSemanticsAction(label: 'Keep unread'): () =>
            onDecide(CatchUpAction.keep),
      },
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onHorizontalDragUpdate: (details) => dx.value += details.delta.dx,
        onHorizontalDragEnd: (_) {
          final distance = dx.value;
          if (distance.abs() >= catchUpSwipeThreshold) {
            unawaited(HapticFeedback.mediumImpact());
            onDecide(distance > 0 ? CatchUpAction.read : CatchUpAction.keep);
          }
          dx.value = 0;
        },
        onHorizontalDragCancel: () => dx.value = 0,
        child: AnimatedContainer(
          duration: reducedMotion || dx.value != 0
              ? Duration.zero
              : const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
          transformAlignment: Alignment.bottomCenter,
          transform: Matrix4.translationValues(dx.value, 0, 0)
            ..rotateZ(reducedMotion ? 0 : dx.value / 24 * pi / 180),
          decoration: BoxDecoration(
            color: context.colors.surfaceContainerLow,
            borderRadius: BorderRadius.circular(Radii.container),
            border: Border.all(color: context.colors.outlineVariant),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  header,
                  Divider(height: 1, color: context.colors.outlineVariant),
                  Expanded(child: body),
                ],
              ),
              if (strength > 0)
                Positioned.fill(
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: _Verdict(read: dx.value > 0, strength: strength),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TimelineRows extends ConsumerWidget {
  const _TimelineRows({
    required this.channelId,
    required this.newLineId,
    required this.onOpen,
    required this.onOpenThread,
  });

  final String channelId;
  final String? newLineId;
  final ValueChanged<String> onOpen;
  final ValueChanged<String> onOpenThread;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final window = ref.watch(catchUpTimelineProvider(channelId));
    final messages = window.value ?? const <CatchUpMessage>[];
    if (messages.isEmpty) {
      return _Status(
        window.hasError
            ? "Couldn't load messages."
            : window.isLoading
            ? 'Loading messages…'
            : 'No messages to show. Open the conversation to see more.',
      );
    }
    final firstUnread = newLineId == null
        ? -1
        : messages.indexWhere((m) => m.id == newLineId);
    final start = firstUnread >= 0
        ? [0, firstUnread - _context, messages.length - _maxRows].reduce(max)
        : newLineId != null
        ? max(0, messages.length - _maxRows)
        : max(0, messages.length - 3);
    final rows = messages.sublist(start);
    final dividerId = firstUnread >= 0 && firstUnread >= start
        ? newLineId
        : newLineId != null
        ? rows.first.id
        : null;
    return _MessageList(
      channelId: channelId,
      rows: rows,
      dividerId: dividerId,
      onOpen: onOpen,
      onOpenThread: onOpenThread,
    );
  }
}

class _ThreadRows extends ConsumerWidget {
  const _ThreadRows({
    required this.channelId,
    required this.rootId,
    required this.onOpen,
  });

  final String channelId;
  final String rootId;
  final ValueChanged<String> onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thread = ref.watch(
      catchUpThreadProvider(
        ThreadRepliesArgs(channelId: channelId, rootId: rootId),
      ),
    );
    final messages = thread.value ?? const <CatchUpMessage>[];
    if (messages.isEmpty) {
      return _Status(
        thread.hasError
            ? "Couldn't load the thread."
            : thread.isLoading
            ? 'Loading thread…'
            : 'No replies to show. Open the thread to see more.',
      );
    }
    return _MessageList(
      channelId: channelId,
      rows: messages,
      dividerId: null,
      onOpen: onOpen,
      onOpenThread: null,
    );
  }
}
