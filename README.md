# Omastr

Nostr notifications for the Omarchy (Quattro) bar. Enter your npub and Omastr
connects to the relays from your NIP-65 relay list over live websockets,
showing zaps, replies, mentions, reposts and reactions — with author profiles,
avatars, quoted context and inline images/video.

Omastr is fully read-only: it never signs or publishes anything. Your npub is
your public, read-only key.

## Requirements

- Omarchy (Quattro shell)
- `qt6-websockets` (for the relay connections)
- `qt6-multimedia` with the FFmpeg backend (only needed to play videos inline;
  images work without it)

Install on Arch-based systems:

```sh
sudo pacman -S qt6-websockets qt6-multimedia-ffmpeg
```

## Install

```sh
omarchy plugin add https://github.com/barrydeen/omastr.git --enable
```

## Usage

Click the Omastr icon in the bar to open your notifications feed.

- Click any row (or press Enter on the top one) to open the event in your
  chosen web client — Primal, Jumble, Coracle or Nostrich — via a `nevent`
  deep link that tells the client which relays to fetch from.
- Images in replies render inline; videos load paused, click to play (muted).
- The gear opens Settings: default web client, per-type notification filters
  (replies & mentions, reposts, reactions, zaps), your connected relays and
  disconnect.
- Your public NIP-51 mute list is honored: notifications from muted accounts
  are hidden automatically (encrypted private mutes can't be read without
  your nsec, so only public mutes apply). The list is fetched from your
  write (outbox) relays per NIP-65; the feed itself stays on read relays.
- Newly arriving events also send a desktop notification (with sender avatar),
  clickable to the same deep link.
- Right-click the bar icon refreshes subscriptions (usually unnecessary —
  sockets are live).

## Configure

```sh
# Move the widget, e.g. to the left side of the bar
omarchy bar move io.github.barrydeen.omastr --section left
```

State (npub, relay list, read marker, settings) lives in
`~/.local/state/omarchy/settings/nostr-notifications.json`. Notification
avatars are cached under `~/.cache/omarchy/nostr/avatars/`.

## Remove

```sh
omarchy plugin remove io.github.barrydeen.omastr
```

## Notes

- Media detection uses file extensions on URLs in note content; exotic hosting
  without an extension shows as a plain link.
- The 8-bit Nostr logo in `icons/` is from
  [nostr-8bit-icons](https://github.com/erikhodl/nostr-8bit-icons).

## License

MIT
