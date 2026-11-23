part of '../catch_up_card.dart';

class _MessageList extends ConsumerWidget {
  const _MessageList({
    required this.channelId,
    required this.rows,
    required this.dividerId,
    required this.onOpen,
    required this.onOpenThread,
  });

  final String channelId;
  final List<CatchUpMessage> rows;
  final String? dividerId;
  final ValueChanged<String> onOpen;
  final ValueChanged<String>? onOpenThread;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final labelFor = ref.watch(catchUpAuthorLabelProvider(channelId));
    final profiles = ref.watch(catchUpProfilesProvider);
    final divider = rows.indexWhere((row) => row.id == dividerId);
    // Start at the New line, else at the newest message.
    return ListView.builder(
      key: ValueKey('catch-up-rows-$channelId-$dividerId'),
      reverse: divider < 0,
      padding: const EdgeInsets.symmetric(vertical: Grid.xxs),
      itemCount: rows.length,
      itemBuilder: (context, index) {
        final row = rows[divider < 0 ? rows.length - 1 - index : index];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (row.id == dividerId) const _NewLine(),
            _MessageRow(
              message: row,
              author: labelFor(row.pubkey),
              profiles: profiles,
              onOpen: () => onOpen(row.id),
              onOpenThread: onOpenThread == null || row.replyCount == 0
                  ? null
                  : () => onOpenThread!(row.id),
            ),
          ],
        );
      },
    );
  }
}

class _MessageRow extends StatelessWidget {
  const _MessageRow({
    required this.message,
    required this.author,
    required this.profiles,
    required this.onOpen,
    required this.onOpenThread,
  });

  final CatchUpMessage message;
  final String author;
  final Map<String, UserProfile> profiles;
  final VoidCallback onOpen;
  final VoidCallback? onOpenThread;

  @override
  Widget build(BuildContext context) {
    final replies = message.replyCount == 1
        ? '1 reply'
        : '${message.replyCount} replies';
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: Grid.xs,
          vertical: Grid.xxs,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ExcludeSemantics(
              child: SmallAvatar(
                pubkey: message.pubkey,
                userCache: profiles,
                size: 32,
              ),
            ),
            const SizedBox(width: Grid.twelve),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          author,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.textTheme.labelLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: Grid.xxs),
                      Text(
                        formatMessageTime(message.createdAt),
                        style: context.textTheme.bodySmall?.copyWith(
                          color: context.colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Grid.quarter),
                  Text(message.content, style: context.textTheme.bodyLarge),
                  if (onOpenThread != null)
                    TextButton(
                      style: TextButton.styleFrom(
                        padding: EdgeInsets.zero,
                        minimumSize: const Size(0, 36),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        alignment: Alignment.centerLeft,
                      ),
                      onPressed: onOpenThread,
                      child: Text(replies),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewLine extends StatelessWidget {
  const _NewLine();

  @override
  Widget build(BuildContext context) {
    final color = context.colors.error;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Grid.xs,
        vertical: Grid.half,
      ),
      child: Row(
        children: [
          Expanded(child: Divider(color: color, height: 1)),
          const SizedBox(width: Grid.xxs),
          Text(
            'New',
            style: context.textTheme.labelSmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _Status extends StatelessWidget {
  const _Status(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Grid.xs),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: context.textTheme.bodyMedium?.copyWith(
          color: context.colors.onSurfaceVariant,
        ),
      ),
    ),
  );
}

class _Verdict extends StatelessWidget {
  const _Verdict({required this.read, required this.strength});
  final bool read;
  final double strength;

  @override
  Widget build(BuildContext context) {
    final color = read ? context.colors.primary : context.colors.tertiary;
    return Opacity(
      opacity: strength,
      child: ColoredBox(
        color: context.colors.surface.withValues(alpha: 0.85),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              read ? BuzzIcons.check : BuzzIcons.mail,
              size: 32,
              color: color,
            ),
            const SizedBox(height: Grid.xxs),
            Text(
              read ? 'Mark as read' : 'Keep unread',
              style: context.textTheme.titleLarge?.copyWith(color: color),
            ),
          ],
        ),
      ),
    );
  }
}
