import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

import 'features/snack_sign_in/snack_sign_in_page.dart';
import 'onboarding_app_entry.dart';
import 'shared/hosted/hosted_environment.dart';
import 'shared/hosted/organization_environment.dart';

/// Signed-out landing: Snack sign-in first, with the existing invite link,
/// QR and saved-key entry one tap away under "Other ways to join". Builds with
/// Builderlab enabled keep Buzz's own onboarding.
class SnackAppEntry extends HookConsumerWidget {
  const SnackAppEntry({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Fixed per build, so the hook below always runs in the same order.
    if (HostedEnvironment.enabled || OrganizationEnvironment.enabled) {
      return const OnboardingAppEntry();
    }
    final otherWays = useState(false);
    if (otherWays.value) {
      void back() => otherWays.value = false;
      return Stack(
        children: [
          Positioned.fill(child: OnboardingAppEntry(onExit: back)),
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: Material(
                type: MaterialType.transparency,
                child: TextButton.icon(
                  onPressed: back,
                  icon: const Icon(Icons.arrow_back),
                  label: const Text('Snack sign-in'),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return SnackSignInPage(onOtherWays: () => otherWays.value = true);
  }
}
