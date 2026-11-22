# PingLeader

A World of Warcraft Forever addon that adds a button to the Looking For Group
browser: each click contacts the next listing, one person at a time.

It has two modes, picked at the top of its settings:

- **Join a group** whispers and/or asks to join the leaders of groups that
  still need one of your ticked roles. One per click.
- **Form my group** works out which roles your 5-player group still needs
  (1 tank, 1 healer, 3 DPS, counting your own role and unanswered invites) and
  invites solo players of the ticked classes, and above your minimum level,
  who list one of them. "Invite next" invites one per click; "Auto-invite",
  off unless you tick it, invites them as they show up, one every 2 seconds,
  until the group is full. If you're not the group leader, the game turns each
  invite into a suggestion to your leader.

It never messages anyone it would not also invite to an open slot: automated
whisper spam gets reported and can get an account actioned. Each person is
contacted once per wait period (30 minutes by default).

- **Plan popup** (`/ping plan` or "Show plan", and it opens when you tick
  Auto-invite): who is next, who is skipped
  and why (full, no room for your role, contacted 4 min ago, class not
  ticked...), and how old the results are. Addons can't search by
  themselves, so it tells you when to press Refresh.
- **Message placeholders**: `{class}` `{role}` `{level}` `{dungeon}` `{name}`.
  Hover the message box for a preview. A value the game doesn't give is left
  out, with its dangling "for".
- **Key bindings** (Key Bindings > AddOns > PingLeader): contact the next
  listing, and refresh the Looking For Group search.
- **Sound on new match**, off unless you tick it.
- It never changes Blizzard's frames, so it can't taint them, and it skips
  anyone the game hides during fights. While the game blocks addon whispers,
  it says so instead of sending.

| Command | Does |
|---|---|
| `/ping` | Contact the next listing |
| `/ping join`, `/ping form` | Switch mode |
| `/ping options` | Open the settings (or right-click the button) |
| `/ping plan` | Show who is next, who is skipped, and why |
| `/ping list` | Show who would be contacted, without sending |
| `/ping msg <text>` | Change the current mode's message |
| `/ping reset` | Forget who has been contacted |
| `/ping wait <min>` | Minutes before the same person can be contacted again |
| `/ping dump` | Save the raw LFG data (then `/reload`) for debugging |

## Install

Download the ZIP from [Releases](https://github.com/coylemichael/wow-pingleader/releases)
and extract it into `World of Warcraft/_forever_/Interface/AddOns`.

## Releasing

Publishing a GitHub Release publishes the addon:

```sh
gh release create v1.1 --generate-notes
```

The [Release workflow](.github/workflows/release.yml) checks the Lua syntax,
packages the addon with the [BigWigsMods packager](https://github.com/BigWigsMods/packager),
which writes the tag into the TOC's `## Version`, uploads it to CurseForge and
attaches the ZIP to the release. Commits and tags alone publish nothing.
`gh workflow run release.yml` builds the ZIP as a workflow artifact without
uploading it anywhere.

CurseForge setup, once:

1. Create the project on [CurseForge](https://authors.curseforge.com/) and add
   `## X-Curse-Project-ID: <id>` to `PingLeader.toc`. Until then, releases go to
   GitHub only.
2. Create an [API token](https://www.curseforge.com/account/api-tokens) and save
   it as this repository's `CF_API_KEY` secret.
