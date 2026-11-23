import 'package:buzz/features/channels/channel.dart';
import 'package:buzz/features/channels/channel_actions_sheet.dart';
import 'package:buzz/features/channels/channel_management_provider.dart';
import 'package:buzz/features/channels/channel_sections/channel_sections_provider.dart';
import 'package:buzz/features/channels/channel_sections/channel_sections_storage.dart';
import 'package:buzz/shared/mentions/agent_identity_provider.dart';
import 'package:buzz/shared/relay/relay.dart';
import 'package:buzz/shared/snack_web/snack_web_launcher.dart';
import 'package:buzz/shared/theme/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';

const _channelId = '580ca78b-9dae-46f3-8854-bd671853ba32';

void main() {
  testWidgets('channel details open each web-only feature on Snack web', (
    tester,
  ) async {
    final opened = <Uri>[];
    var result = true;
    final channel = Channel(
      id: _channelId,
      name: 'general',
      channelType: 'stream',
      visibility: 'open',
      description: '',
      createdBy: 'owner',
      createdAt: DateTime(2025),
      memberCount: 1,
      isMember: true,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentPubkeyProvider.overrideWith((ref) => 'me'),
          relayConfigProvider.overrideWith(_SnackRelay.new),
          channelMembersProvider(
            _channelId,
          ).overrideWith((ref) async => const <ChannelMember>[]),
          channelSectionsProvider.overrideWith(_Sections.new),
          agentOwnersProvider.overrideWithValue(
            const AsyncValue.data(<String, String>{}),
          ),
          webLinkLauncherProvider.overrideWithValue((uri) async {
            opened.add(uri);
            if (!result) throw PlatformException(code: 'failed');
            return true;
          }),
        ],
        child: MaterialApp(
          theme: AppTheme.light(),
          home: ChannelDetailsPage(
            channel: channel,
            currentPubkey: 'me',
            onMemberTap: (_, _) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final card = find.byKey(const ValueKey('channel-details-snack-web-card'));
    await tester.scrollUntilVisible(
      card,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Open in Snack web'), findsOneWidget);
    const entries = {
      'Board': 'board',
      'Docs': 'docs',
      'The Matrix': 'matrix',
      'Poker': 'poker',
      'Apps': 'apps',
    };
    for (final MapEntry(key: label, value: panel) in entries.entries) {
      final row = find.descendant(of: card, matching: find.text(label));
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pump();
      expect(
        opened.last.toString(),
        'https://wesnack.app/?community=https%3A%2F%2Fsnack.wesnack.app'
        '&channel=$_channelId&panel=$panel',
      );
    }
    expect(opened, hasLength(5));

    // A launch failure says so instead of failing silently.
    result = false;
    await tester.tap(find.descendant(of: card, matching: find.text('Board')));
    await tester.pump();
    expect(find.text('Couldn’t open Snack.'), findsOneWidget);
  });
}

class _SnackRelay extends RelayConfigNotifier {
  @override
  RelayConfig build() => const RelayConfig(baseUrl: 'wss://snack.wesnack.app');
}

class _Sections extends ChannelSectionsNotifier {
  @override
  ChannelSectionsState build() => const ChannelSectionsState(
    isReady: true,
    store: ChannelSectionStore(),
    version: 1,
  );
}
