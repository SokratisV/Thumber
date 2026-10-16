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
- **Slash commands:**
  - `/thumbsup` (`/tu`), `/thumbsdown` (`/td`), `/neutral` (`/nt`) `[note]` —
    mark your **target** (or mouseover) and, if you pass text, set its note in one
    go. Quotes are optional: `/tu ninja looter` and `/tu "ninja looter"` both work.
  - `/thumber` (`/th`) — open the marks list.
  - `/thumber note <text>` — set a note on your target.
  - `/thumber config` — settings & keybinds.
- **In the window:** click **Target** to load your current target, then click a
  thumbs button. Type a note and press Enter. Click any row to edit it; the
  **Remove** button (or the red X on a row) deletes a mark.
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

## Data

Everything is stored locally in `ThumberDB` (per account). Cross-realm
players are keyed as `Name-Realm`; same-realm players by name. No data leaves
your client.

## License

[MIT](LICENSE). The bundled libraries under `Libs/` keep their own licenses.
