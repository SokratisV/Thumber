# Thumber

Track your interactions with other players in World of Warcraft (TBC Classic /
Anniversary). Mark anyone **thumbs up**, **neutral**, or **thumbs down**, with
an optional free-text note. Your mark shows up in their unit tooltip and in a
sortable list window.

## Marking players

- **Keybinds** mark your current target (falling back to mouseover). Defaults:
  **Arrow Up** = thumbs up, **Arrow Down** = thumbs down, **Arrow Left** =
  neutral, **Arrow Right** = open the list. These are claimed once on first run
  (overriding the arrow-key movement defaults); rebind or clear them any time in
  `/thumber config` or under **Esc → Key Bindings → Thumber**.
- **Slash commands** (`/thumber`, also `/th` and `/pm`):
  - `/thumber` — open the marks list.
  - `/thumber up | down | neutral [name]` — mark your target, or a named player.
  - `/thumber note <text>` — set a note on your target.
  - `/thumber config` — settings & keybinds.
  - `/thumbsup` (`/tu`), `/thumbsdown` (`/td`), `/neutral` (`/nt`) `[note]` —
    mark your **target** (or mouseover) and, if you pass text, set its note in one
    go. Quotes are optional: `/tu ninja looter` and `/tu "ninja looter"` both work.
  - `/tu config` — open settings (also `/td config`, `/neutral config`).
- **In the window:** click **Target** to load your current target, then click a
  thumbs button. Type a note and press Enter. Click any row to edit it; the
  **Remove** button (or the red X on a row) deletes a mark.
- **Minimap button:** left-click opens the list, drag to move it around the
  minimap. Toggle it in `/thumber config`.

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
