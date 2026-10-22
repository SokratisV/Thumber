# Thumber

Track your interactions with other players in World of Warcraft (WoW Forever /
TBC Classic). Mark anyone **thumbs up**, **neutral**, or **thumbs down**, with
an optional free-text note. Your mark shows up in their unit tooltip and in a
sortable list window.

> **Client support.** Runs on **WoW Forever** (interface `16001`) and on the
> **TBC Classic / Anniversary** client (interface `20505`) from the same files.
> Forever serves Classic content from the Midnight 12.x client, so it reports a
> Classic project id but only exposes the modern namespaced API — every call that
> moved is feature-detected rather than switched on project id.

## Marking players

- **Keybinds** mark your current target (falling back to mouseover). Defaults:
  **Arrow Up** = thumbs up, **Arrow Down** = thumbs down, **Arrow Left** =
  neutral, **Arrow Right** = open the list. These are claimed once on first run
  (overriding the arrow-key movement defaults); rebind or clear them any time in
  `/thumber config` or under **Esc → Key Bindings → Thumber**.
  - **Toggle:** marking a player with the mark they already have **removes**
    them (and tells you). A *different* mark just changes it. This applies to
    the keybinds and the `/thumbsup` / `/thumbsdown` / `/neutral` commands; note
    that passing a note (e.g. `/tu great tank`) updates instead of removing.
  - **Chat messages:** a keybind mark prints a line in chat ("marked" /
    "un-marked"). Turn that off with **Print a chat message when a keybind
    marks or un-marks a player** in `/thumber config`. Slash commands always
    reply in chat.
- **Settings:** `/thumber config` (or the minimap button's right-click) opens the
  settings window, described under *Settings* below.
- **Slash commands:**
  - `/thumbsup` (`/tu`), `/thumbsdown` (`/td`), `/neutral` (`/nt`) `[note]` —
    mark your **target** (or mouseover) and, if you pass text, set its note in one
    go. Quotes are optional: `/tu ninja looter` and `/tu "ninja looter"` both work.
  - `/thumber` (`/th`) — open the marks list.
  - `/thumber note <text>` — set a note on your target.
  - `/thumber config` — settings & keybinds.
  - `/thumber test` — preview the group-join alert.
  - `/thumber share` — export, import, or send your marks; `/thumber send <name>`.
  - `/thumber profile` — export or import all your settings, positions and keybinds.
- **In the window:** the marks list, with search and filters. Press **Manually Mark**
  to add someone by typing their name (or **Use target**), picking a mark, and
  optionally a note, then **Save mark**. Click any row to open the same dialog on
  that player and change their mark or note, or **Remove** them; the red X on a
  row removes a mark directly.
- **Minimap button:** left-click opens the list, drag to move it around the
  minimap. Toggle it in `/thumber config`.

## Names

On **WoW Forever** every character has a first name *and* a surname, and Thumber
keeps both: marks, the list, the tooltip and chat messages all use the full
"First Surname" (type it the same way in the name box). Marks saved by earlier
versions as `First-Surname` are converted automatically the first time you log
in. On the Anniversary client nothing changes: same-realm players are keyed by
name, cross-realm players as `Name-Realm`.

## Tooltips

Hovering a player you've marked adds a coloured line to their tooltip showing
the mark (and, optionally, the note). Both can be toggled in settings:

- **Show my mark in player tooltips** — the mark line.
- **Also show the note text in tooltips** — appends your note underneath.
- **Show the whole note** — wraps the full note onto as many lines as it needs;
  turn it off for a single shortened line.

## Badges and alerts

Marked players are easy to spot without opening anything. Each of these has a
switch on the **Badges** and **Alerts** pages of the settings window.

- **Nameplate badge** — the mark's icon beside a marked player's nameplate: above,
  below, left or right of it. Pick the look (**Icon** or **Ring**) and the size.
- **Target frame badge** — a small badge on your target's portrait.
- **Chat badge** — the mark's icon at the start of a marked player's chat lines.
- **Group alert** — a toast (with a sound of your choice) when a marked player is
  in your group or raid, once per time they join. Right-click it (or click it) to
  dismiss. Try it
  with **Show real alert** or `/thumber test`. Choose its sound: Raid Warning, Alarm
  Clock, PvP Queue, or none. **Unlock the alert** (Alerts page) to drag it anywhere on screen; it remembers
  the spot.
- **Pop animation** — the target badge pops when a keybind marks your target.

**Preview.** The **Badges** page opens with a live preview (and **Alerts** with one of the toast): a mock nameplate
(level box included), target portrait, group alert and chat lines, all drawn by
the same code the game uses and redrawn the moment you change anything. **Preview
as** switches between the three marks, **Replay pop** plays the animation, and
**Show real alert** fires the actual toast.

**Fine-tuning.** Badge size; the nameplate anchor (above, below, left, right) and
an X/Y offset of up to 200 either way, to clear other nameplate elements; and which
corner of the target portrait the badge sits on (top right by default, clear of
Blizzard's level number). On nameplates the badge is layered above Blizzard's level
box; on the target frame it uses the frame's own layer, so it never covers windows.

The marks window's **Clear** button (bottom right) removes every mark the list is
showing, with the filter and search applied, so *thumbs down* + Clear removes only
the thumbs downs. It needs a second click to confirm, and an **Undo** button
appears for 15 seconds afterwards.

The marks window also has a **search box** (names and notes), **filter pills**
with counts (All / thumbs up / neutral / thumbs down), and a **last seen** column.
Hover a row for the zone and level you last saw them at. Thumber records a
sighting when you target, mouse over, or group with a marked player.

## Settings

`/thumber config` opens Thumber's own settings window, styled after FlareUI (bronze
trim over Blizzard's Collections tile): the pages down the left, the page's settings
in the middle under headings that fold, and on the right what the setting you're
pointing at does. Blizzard's own controls throughout.

| Page | What's on it |
| --- | --- |
| **General** | Tooltips (your mark, your note, the whole note), the chat message and chat icon, the minimap button |
| **Badges** | Nameplate and target-frame badges, style, size, pop animation, offsets and corner, with a live preview pinned above; **Reset badge look** |
| **Alerts** | The group alert, its sound, where it appears (unlock to drag), and a preview of the toast |
| **Sharing** | Whether to accept offers, and the share window |
| **Keybinds** | The four keys; click one and press a key, right-click clears |
| **Profile** | Export or import every setting, position and keybind as one string |

Blizzard's own Settings window (Esc → Options → AddOns → Thumber) carries a small
page with a button that opens it.

## Sharing your marks

Click **Share** in the marks window (or `/thumber share`). Two ways to hand your
marks to someone:

- **Send to a player** — type a name (or press **Target**) and **Send**
  (`/thumber send <name>` does the same). They get an **Accept / Decline**
  prompt; nothing arrives unless they accept. Only marks they don't already have
  are added, so their own marks are never overwritten. Both of you need Thumber,
  and you must be able to whisper each other.
- **Export / import** — **Export all** produces one `THUMBER:...` string. Paste it
  in Discord, a document, wherever, and the other person pastes it into the same
  box and presses **Preview import**. The preview says how many marks are new,
  how many differ from theirs, and how many they already have, then lets them
  **Add new only** or **Add new and overwrite**.

**What to share.** The two choices at the top of the share window, *All marks* and
*Thumbs down only* (each with its count), pick what goes out, for both ways. The
same choice is **What to share** in the settings. The second is for warning a friend about the players you would rather they avoided,
without handing over your whole list.

Marks only travel between the same kind of client: WoW Forever marks (with
surnames) can't be imported on the Anniversary client or the other way round.
Anything that comes in is checked first: invalid entries are dropped, colour and
link codes are stripped from names and notes, and sizes are capped. To refuse
offers entirely, untick **Let other players offer me their marks** in
`/thumber config`.

## Profile: move your whole setup

`/thumber profile` (or **Profile** in the settings window) copies *everything* about how
Thumber is set up into one string, `THUMBERPROFILE:1:...`:

- every setting (badges, alert, sound, sharing, tooltips, chat),
- where you put the **marks window**, the **alert**, and the **minimap button**,
- the settings page you last had open, and
- your four **keybinds** (they live in WoW's key bindings, not in Thumber's saved data, so
  they are read and written through the game).

Paste it on another character or another install and press **Check pasted profile**. It is
validated first (the tags and version, then every value against what the settings window
allows), you are told what it holds and how many entries were skipped, and nothing changes
until you press **Apply profile**. Applying puts everything the profile covers back to the
defaults and then sets what it contains, so the result is the same setup, and it all
redraws on the spot: no reload. Keybinds are left alone if you are in combat (apply it
again afterwards). Your **marks** are never touched; share those with **Share**.

## Languages

Thumber follows the game's language: English, Deutsch, Français, Español (España and
México), Português (Brasil), Русский, 한국어, 简体中文, 繁體中文 and Italiano. Anything
without a translation shows in English. The translations live in `Locales/`, one file per
language (`L["English text"] = "translation"`), so a correction is a one-line edit. They were
written without a native-speaker review, so wording fixes are welcome.

What is *not* translated on purpose: the slash words (`/thumbsup`, `/thumber share`, ...),
the saved-data keys, and the share and profile strings, so a mark list or profile exported
in one language imports fine in another.

## Data

Everything is stored locally in `ThumberDB` (per account). Cross-realm
players are keyed as `Name-Realm`; same-realm players by name. No data leaves
your client.

## License

[MIT](LICENSE). The bundled libraries under `Libs/` keep their own licenses.
