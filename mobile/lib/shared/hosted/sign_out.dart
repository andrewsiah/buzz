import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../community/community.dart';
import '../community/community_provider.dart';
import '../snack/snack_account.dart';
import 'account_identity_store.dart';
import 'hosted_environment.dart';
import 'hosted_flow.dart' show HostedFlow;
import 'hosted_flow_provider.dart';
import '../widgets/confirmation_dialog.dart';
import '../widgets/feedback_snackbar.dart';

/// Signs this device out: removes every community, and in a public build ends
/// the Builderlab session. Each community's key goes to this device's saved
/// identities first, so signing out never destroys a key that may exist
/// nowhere else; signing back in offers it again. In an internal build the
/// Sign in landing that follows ends the organization session.
Future<void> confirmSignOut(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final list = ref.read(communityListProvider.notifier);
  final flow = HostedEnvironment.enabled ? ref.read(hostedFlowProvider) : null;
  try {
    final communities = await ref.read(communityListProvider.future);
    final active = await ref.read(activeCommunityProvider.future);
    if (communities.isEmpty || !context.mounted) return;
    final confirmed = await showDestructiveConfirmation(
      context: context,
      title: 'Sign out?',
      message:
          'You’ll need to sign in again to use Snack on this device. '
          'Your identities stay saved on this device.',
      confirmLabel: 'Sign out',
    );
    if (!confirmed || !context.mounted) return;
    final snackPubkey = await ref.read(snackAccountProvider).accountPubkey();
    await _signOutDevice(ref, list, flow, communities, active, snackPubkey);
    // Reveal the Sign in landing under the page that signed out.
    navigator.popUntil((route) => route.isFirst);
  } catch (e) {
    messenger.showFeedbackSnackBar(
      SnackBar(content: Text('Failed to sign out: $e')),
      kind: ToastKind.error,
    );
  }
}

/// Removes every community from this device and ends both sessions. Keys
/// other than the Snack account's are kept in saved identities first.
Future<void> _signOutDevice(
  WidgetRef ref,
  CommunityListNotifier list,
  HostedFlow? flow,
  List<Community> communities,
  Community? active,
  String? snackPubkey, {
  bool accountDeleted = false,
}) async {
  // Every key is saved before any community is removed, so a failure
  // leaves each community with its only copy of its key. The Snack
  // account's key is not: it lives on the Snack server, and a saved copy
  // would let anyone with this device back in without the email code.
  final snack = ref.read(snackAccountProvider);
  for (final community in communities) {
    if (SnackAccount.isAccountCommunity(community, snackPubkey)) continue;
    await keepCommunityKey(community);
  }
  // The session ends before any community is removed, so the Sign in
  // landing never shows it and nothing started there can be cancelled by
  // it. Removed communities' push-lease revocations authenticate with the
  // push-stop credential it leaves behind.
  await flow?.endAccountSession();
  // Forgets the Snack session here and ends it on the server if reachable
  // (a deleted account has no session left to end).
  if (!accountDeleted) await snack.signOut();
  // The active community goes last, so removing the others never switches
  // to and connects another one.
  for (final community in [
    ...communities.where((c) => c.id != active?.id),
    ...communities.where((c) => c.id == active?.id),
  ]) {
    await list.removeCommunity(community.id);
  }
}

/// Settings › Delete account: after a confirmation, permanently deletes the
/// Snack account on the server, then signs this device out. The account's key
/// is not kept on the device afterwards.
Future<void> confirmDeleteAccount(BuildContext context, WidgetRef ref) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  final list = ref.read(communityListProvider.notifier);
  final flow = HostedEnvironment.enabled ? ref.read(hostedFlowProvider) : null;
  final snack = ref.read(snackAccountProvider);
  try {
    final confirmed = await showDestructiveConfirmation(
      context: context,
      title: 'Delete your account?',
      message:
          'This permanently deletes your Snack account: your email, name, '
          'key and sign-in records. It can’t be undone. Messages you '
          'already posted stay in their communities until you or the '
          'community’s owner deletes them.',
      confirmLabel: 'Delete account',
    );
    if (!confirmed || !context.mounted) return;
    final snackPubkey = await snack.accountPubkey();
    final communities = await ref.read(communityListProvider.future);
    final active = await ref.read(activeCommunityProvider.future);
    await snack.deleteAccount();
    await _signOutDevice(
      ref,
      list,
      flow,
      communities,
      active,
      snackPubkey,
      accountDeleted: true,
    );
    navigator.popUntil((route) => route.isFirst);
    messenger.showFeedbackSnackBar(
      const SnackBar(content: Text('Your Snack account was deleted.')),
      kind: ToastKind.success,
    );
  } on SnackSignedOut {
    messenger.showFeedbackSnackBar(
      const SnackBar(content: Text('Sign in again, then delete your account.')),
      kind: ToastKind.error,
    );
  } catch (e) {
    messenger.showFeedbackSnackBar(
      SnackBar(content: Text('Couldn’t delete your account: $e')),
      kind: ToastKind.error,
    );
  }
}

/// Copies [community]'s key into this device's saved identities, where
/// signing in again offers it. A failure throws, so the caller keeps the
/// community rather than delete the only copy of its key.
Future<void> keepCommunityKey(Community community) async {
  final nsec = community.nsec;
  if (nsec == null || nsec.isEmpty) return;
  await AccountIdentityStore()
      .forPairing(AccountIdentityStore.publicKeyForNsec(nsec))
      .create(nsec);
}
