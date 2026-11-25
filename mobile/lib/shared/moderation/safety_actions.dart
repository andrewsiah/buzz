import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../community/community_provider.dart';
import '../snack/snack_account.dart';
import '../theme/theme.dart';
import '../widgets/confirmation_dialog.dart';
import '../widgets/feedback_snackbar.dart';
import '../widgets/modal_presentation.dart';
import 'moderation.dart';

/// Why someone reports a message or person. Values match `POST /api/reports`.
const reportReasons = <(String, String)>[
  ('spam', 'Spam or scam'),
  ('harassment', 'Harassment or bullying'),
  ('hate', 'Hate speech'),
  ('sexual', 'Sexual content'),
  ('violence', 'Violence or threats'),
  ('self_harm', 'Self-harm'),
  ('other', 'Something else'),
];

/// The active community's https origin, the form reports name it by.
Future<String> _communityOrigin(WidgetRef ref) async {
  final community = await ref.read(activeCommunityProvider.future);
  final relay = Uri.tryParse(community?.relayUrl ?? '');
  if (relay == null || relay.host.isEmpty) return '';
  return Uri(
    scheme: 'https',
    host: relay.host,
    port: relay.hasPort ? relay.port : null,
  ).toString();
}

/// Reports a message ([eventId] set) or a person to Snack, and hides it here
/// right away. The sheet lets the person block the author in the same step.
Future<void> showReportSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String authorPubkey,
  required String authorName,
  String? eventId,
  String? content,
}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final sent = await showBuzzModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ReportSheet(
      authorPubkey: authorPubkey,
      authorName: authorName,
      eventId: eventId,
      content: content,
    ),
  );
  if (sent == true) {
    messenger?.showFeedbackSnackBar(
      const SnackBar(
        content: Text('Thanks. We review every report within 24 hours.'),
      ),
      kind: ToastKind.success,
    );
  }
}

class _ReportSheet extends HookConsumerWidget {
  const _ReportSheet({
    required this.authorPubkey,
    required this.authorName,
    this.eventId,
    this.content,
  });

  final String authorPubkey;
  final String authorName;
  final String? eventId;
  final String? content;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final reason = useState<String?>(null);
    final alsoBlock = useState(false);
    final busy = useState(false);
    final error = useState<String?>(null);
    final isMessage = eventId != null;
    final name = authorName.trim().isEmpty ? 'this person' : authorName.trim();

    Future<void> submit() async {
      final picked = reason.value;
      if (picked == null || busy.value) return;
      busy.value = true;
      error.value = null;
      try {
        await ref
            .read(snackAccountProvider)
            .report(
              kind: isMessage ? 'message' : 'user',
              community: await _communityOrigin(ref),
              author: authorPubkey,
              reason: picked,
              eventId: eventId,
              content: content,
              blocked: alsoBlock.value,
            );
      } on SnackAccountException catch (e) {
        busy.value = false;
        error.value = e is SnackSignedOut
            ? 'Sign in again to send a report.'
            : e.message;
        return;
      }
      final moderation = ref.read(moderationProvider.notifier);
      if (isMessage) moderation.hideMessage(eventId!);
      if (alsoBlock.value) moderation.block(authorPubkey, name: authorName);
      if (context.mounted) Navigator.of(context).pop(true);
    }

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(
          Grid.gutter,
          0,
          Grid.gutter,
          Grid.xs,
        ),
        child: Column(
          key: const Key('report-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              isMessage ? 'Report message' : 'Report $name',
              style: context.textTheme.titleLarge,
            ),
            const SizedBox(height: Grid.xxs),
            Text(
              'Snack reviews every report within 24 hours and removes '
              'content and people that break our Terms. $name won’t be told '
              'who reported.',
              style: context.textTheme.bodyMedium?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Grid.xs),
            RadioGroup<String>(
              groupValue: reason.value,
              onChanged: (value) => reason.value = value,
              child: Column(
                children: [
                  for (final (value, label) in reportReasons)
                    RadioListTile<String>(
                      key: Key('report-reason-$value'),
                      value: value,
                      title: Text(label),
                      contentPadding: EdgeInsets.zero,
                    ),
                ],
              ),
            ),
            SwitchListTile.adaptive(
              key: const Key('report-also-block'),
              contentPadding: EdgeInsets.zero,
              value: alsoBlock.value,
              onChanged: (value) => alsoBlock.value = value,
              title: Text('Also block $name'),
              subtitle: const Text('You won’t see their messages.'),
            ),
            if (error.value != null) ...[
              const SizedBox(height: Grid.xxs),
              Text(error.value!, style: TextStyle(color: context.colors.error)),
            ],
            const SizedBox(height: Grid.xs),
            FilledButton(
              key: const Key('report-submit'),
              style: FilledButton.styleFrom(
                backgroundColor: context.colors.error,
                foregroundColor: context.colors.onError,
              ),
              onPressed: reason.value == null || busy.value ? null : submit,
              child: Text(busy.value ? 'Sending…' : 'Report'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Blocks [pubkey] on this device after a confirmation, and tells Snack so a
/// person can review the account. Their messages disappear right away.
Future<void> confirmBlock({
  required BuildContext context,
  required WidgetRef ref,
  required String pubkey,
  required String name,
}) async {
  final label = name.trim().isEmpty ? 'this person' : name.trim();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final confirmed = await showDestructiveConfirmation(
    context: context,
    title: 'Block $label?',
    message:
        'You won’t see their messages anywhere in Snack. They won’t be told. '
        'You can unblock them in Settings › Blocked people.',
    confirmLabel: 'Block',
  );
  if (!confirmed) return;
  ref.read(moderationProvider.notifier).block(pubkey, name: name);
  // Let Snack know too (best effort: the block itself works offline).
  final snack = ref.read(snackAccountProvider);
  unawaited(
    _communityOrigin(ref)
        .then(
          (community) => snack.report(
            kind: 'user',
            community: community,
            author: pubkey,
            reason: 'other',
            blocked: true,
          ),
        )
        .then<void>((_) {}, onError: (Object _) {}),
  );
  messenger?.showFeedbackSnackBar(
    SnackBar(content: Text('$label is blocked.')),
    kind: ToastKind.success,
  );
}

/// Settings › Blocked people: everyone blocked on this device, to unblock.
class BlockedPeopleList extends ConsumerWidget {
  const BlockedPeopleList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blocked = ref.watch(moderationProvider).blocked;
    if (blocked.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(Grid.gutter),
        child: Text(
          'No one is blocked. To block someone, long-press one of their '
          'messages or open their profile.',
          style: context.textTheme.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      );
    }
    return Column(
      children: [
        for (final entry in blocked.entries)
          ListTile(
            title: Text(
              entry.value.trim().isEmpty
                  ? '${entry.key.substring(0, 12)}…'
                  : entry.value,
            ),
            trailing: TextButton(
              onPressed: () =>
                  ref.read(moderationProvider.notifier).unblock(entry.key),
              child: const Text('Unblock'),
            ),
          ),
      ],
    );
  }
}
