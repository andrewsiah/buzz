part of '../message_actions.dart';

/// Report and Block for someone else's message (App Store Guideline 1.2).
class _MessageSafetySection extends StatelessWidget {
  const _MessageSafetySection({
    required this.message,
    required this.sheetContext,
    required this.pageContext,
    required this.pageRef,
  });

  final TimelineMessage message;
  final BuildContext sheetContext;
  final BuildContext pageContext;
  final WidgetRef pageRef;

  String _authorName() {
    final pubkey = message.pubkey.toLowerCase();
    return pageRef
        .read(identityNameSourcesProvider)
        .scope({pubkey})
        .labelFor(pubkey);
  }

  @override
  Widget build(BuildContext context) {
    final error = context.colors.error;
    final name = _authorName();
    return SheetActionSection(
      children: [
        ListTile(
          key: const Key('message-action-report'),
          leading: Icon(BuzzIcons.flag, color: error),
          title: Text('Report message', style: TextStyle(color: error)),
          onTap: () {
            if (!_selectMessageAction(sheetContext)) return;
            unawaited(
              showReportSheet(
                context: pageContext,
                ref: pageRef,
                authorPubkey: message.pubkey,
                authorName: name,
                eventId: message.id,
                content: message.content,
              ),
            );
          },
        ),
        ListTile(
          key: const Key('message-action-block'),
          leading: Icon(BuzzIcons.userMinus, color: error),
          title: Text(
            name.isEmpty ? 'Block this person' : 'Block $name',
            style: TextStyle(color: error),
          ),
          onTap: () {
            if (!_selectMessageAction(sheetContext)) return;
            unawaited(
              confirmBlock(
                context: pageContext,
                ref: pageRef,
                pubkey: message.pubkey,
                name: name,
              ),
            );
          },
        ),
      ],
    );
  }
}
