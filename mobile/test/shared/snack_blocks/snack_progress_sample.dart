/// A real `snack-progress` block, as an agent posted it (from a Catch Up
/// screenshot where the app printed it as raw JSON).
const snackProgressSample =
    r'''{"version":1,"title":"Sign in thesvpn X account","status":"running","startedAt":1795547969,"updatedAt":1795548059,"plan":[],"steps":[{"kind":"read","text":"Read /home/user/thesvpn_screenshot_IMG_1386.png","state":"done"},{"kind":"shell","text":"cat /home/user/ACCESS.md | head -150; echo ----; cat /runner/guide-computer.md | head -120","state":"done"},{"kind":"shell","text":"which snack-computer snack-screen kiss-op 2>&1; ls ~/routines/ /home/user/routines 2>/dev/null | head -50","state":"done"},{"kind":"shell","text":"curl -s 'https://api.example.org/sandboxes' | jq -c '.[] | {sandboxID, metadata, state}' 2>&1 | head -40","state":"running"}],"count":13,"agent":"Kiss","runsOn":"Claude Code · box:claude-opus-5-5"}''';

/// A message carrying [snackProgressSample], as agents post it.
const snackProgressMessage =
    'Working on this in the background.\n\n'
    '```snack-progress\n$snackProgressSample\n```';

/// Unix seconds 30 s after the sample's last update.
const snackProgressNow = 1795548089;
