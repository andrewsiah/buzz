import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import '../../shared/snack/snack_account.dart';
import '../../shared/snack/snack_sign_in.dart';
import '../../shared/theme/app_theme.dart';
import '../../shared/theme/grid.dart';
import '../../shared/theme/theme_extensions.dart';

/// First-launch sign-in with a Snack account: an emailed code, or Google on
/// iOS. [onOtherWays] opens the invite link / QR / saved-key entry.
class SnackSignInPage extends HookConsumerWidget {
  const SnackSignInPage({super.key, required this.onOtherWays});

  final VoidCallback onOtherWays;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(snackSignInProvider);
    final notifier = ref.read(snackSignInProvider.notifier);
    final email = useTextEditingController(text: state.email);
    final code = useTextEditingController();
    final textTheme = context.textTheme;
    final colors = context.colors;
    final busy = state.busy;

    void sendCode() => unawaited(notifier.sendCode(email.text));
    void verify() => unawaited(notifier.verifyCode(code.text));

    final List<Widget> body = switch (state.step) {
      SnackSignInStep.email => [
        Text('Sign in to Snack', style: textTheme.headlineSmall),
        const SizedBox(height: Grid.xxs),
        Text(
          'Enter your email and we’ll send you a code.',
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: Grid.sm),
        TextField(
          key: const Key('snack-sign-in-email'),
          controller: email,
          enabled: !busy,
          keyboardType: TextInputType.emailAddress,
          autofillHints: const [AutofillHints.email],
          autocorrect: false,
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => sendCode(),
          decoration: const InputDecoration(
            labelText: 'Email',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Grid.xs),
        FilledButton(
          key: const Key('snack-sign-in-send-code'),
          onPressed: busy ? null : sendCode,
          child: Text(busy ? 'Sending…' : 'Send code'),
        ),
        if (snackGoogleSupported) ...[
          const SizedBox(height: Grid.xxs),
          OutlinedButton(
            key: const Key('snack-sign-in-google'),
            onPressed: busy
                ? null
                : () => unawaited(notifier.signInWithGoogle()),
            child: const Text('Continue with Google'),
          ),
        ],
      ],
      SnackSignInStep.code => [
        Text('Check your email', style: textTheme.headlineSmall),
        const SizedBox(height: Grid.xxs),
        Text(
          'We sent a 6-digit code to ${state.email}.',
          style: textTheme.bodyMedium,
        ),
        const SizedBox(height: Grid.sm),
        TextField(
          key: const Key('snack-sign-in-code'),
          controller: code,
          enabled: !busy,
          autofocus: true,
          keyboardType: TextInputType.number,
          autofillHints: const [AutofillHints.oneTimeCode],
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(6),
          ],
          textInputAction: TextInputAction.go,
          onSubmitted: (_) => verify(),
          decoration: const InputDecoration(
            labelText: 'Code',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: Grid.xs),
        FilledButton(
          key: const Key('snack-sign-in-verify'),
          onPressed: busy ? null : verify,
          child: Text(busy ? 'Signing in…' : 'Sign in'),
        ),
        const SizedBox(height: Grid.xxs),
        TextButton(
          key: const Key('snack-sign-in-different-email'),
          onPressed: busy
              ? null
              : () {
                  code.clear();
                  unawaited(notifier.useDifferentEmail());
                },
          child: const Text('Use a different email'),
        ),
      ],
      SnackSignInStep.joining => [
        Text(
          busy ? 'Opening your communities…' : 'Almost there',
          style: textTheme.headlineSmall,
        ),
        const SizedBox(height: Grid.sm),
        if (busy)
          const Center(child: CircularProgressIndicator())
        else ...[
          FilledButton(
            key: const Key('snack-sign-in-retry'),
            onPressed: () => unawaited(notifier.retry()),
            child: const Text('Try again'),
          ),
          const SizedBox(height: Grid.xxs),
          TextButton(
            key: const Key('snack-sign-in-different-account'),
            onPressed: () {
              code.clear();
              unawaited(notifier.useDifferentEmail());
            },
            child: const Text('Use a different account'),
          ),
        ],
      ],
    };

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(Grid.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: AutofillGroup(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Semantics(
                      header: true,
                      child: Text(
                        'Snack',
                        style: textTheme.displaySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: colors.primary,
                        ),
                      ),
                    ),
                    const SizedBox(height: Grid.md),
                    ...body,
                    if (state.error case final error?) ...[
                      const SizedBox(height: Grid.xs),
                      Container(
                        key: const Key('snack-sign-in-error'),
                        padding: const EdgeInsets.all(Grid.twelve),
                        decoration: BoxDecoration(
                          color: colors.errorContainer,
                          borderRadius: BorderRadius.circular(Radii.md),
                        ),
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            error,
                            style: textTheme.bodyMedium?.copyWith(
                              color: colors.onErrorContainer,
                            ),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: Grid.md),
                    TextButton(
                      key: const Key('snack-sign-in-other-ways'),
                      onPressed: busy ? null : onOtherWays,
                      child: const Text('Other ways to join'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
