# PingLeader

A World of Warcraft Forever addon that adds a button to the Looking For Group
browser: each click contacts the next listing, one person at a time.

It has two modes, picked at the top of its settings:

- **Join a group** whispers and/or asks to join the leaders of groups that
  still need one of your ticked roles. One per click.
- **Form my group** works out which roles your 5-player group still needs
  (1 tank, 1 healer, 3 DPS, counting your own role and unanswered invites) and
  invites solo players of the ticked classes who list one of them. "Invite
  next" invites one per click; "Auto-invite" invites them as they show up.
  "Dry run" invites nobody and shows who it would invite and why.

It never messages anyone it would not also invite to an open slot: automated
whisper spam gets reported and can get an account actioned.

| Command | Does |
|---|---|
| `/ping` | Contact the next listing |
| `/ping join`, `/ping form` | Switch mode |
| `/ping options` | Open the settings (or right-click the button) |
| `/ping plan` | Show who it would invite and why |
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
