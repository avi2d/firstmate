# Pi pane captures for the stale and wedge hash

These files are replay inputs for `../../fm-pane-hash-lib.test.sh`.
They come from Pi 1.0.2 and Herdr 0.9.3 on Darwin arm64, read on 2026-10-05 in an isolated Herdr lab session with a 120-column by 40-row viewer attached.

## Capture provenance

Each `*-tail` file is stdout from `fm_backend_capture herdr <session>:<pane> 40`, and each `*-viewport` file is stdout from `fm_backend_visible_capture herdr <session>:<pane>`.
The one edit is the five-letter account name in Pi's install path, which reads `user1` so every row keeps its width.
Pi ran as `pi --offline --no-session --tui-mode <mode>` with an empty `PI_CODING_AGENT_DIR`, then ran `!seq -f "LAB_LONG_LINE_%g" 1 120; printf "%0150d\n" 0` so the transcript exceeded the viewport.

| File | Mode | When it was read |
| --- | --- | --- |
| `regular-tail.capture` | regular | Idle, and byte-identical to the same read 0.3 s later |
| `regular-viewport.capture` | regular | Idle |
| `fullscreen-viewport-quiet.capture` | fullscreen | Idle, more than 2 s after any other read |
| `fullscreen-viewport-flash.capture` | fullscreen | 0.3 s after a 40-line tail read of the same unchanged idle pane |
| `fullscreen-tail-a.capture` and `fullscreen-tail-b.capture` | fullscreen | Two 40-line tail reads of one unchanged idle pane while another reader read it every 4 s |

## What the captures show

A Herdr `recent` read longer than the viewport makes fullscreen Pi draw its scrollbar in the pane's last column for about one second.
`fullscreen-viewport-flash.capture` carries that scrollbar on every transcript row, so it differs from `fullscreen-viewport-quiet.capture` although the pane never changed.
Pi wraps transcript text one cell short of the last column, so in the quiet capture only Pi's own full-width rules reach it, and the bar overwrites their last cell.
For fullscreen Pi, a `recent` read also returns a varying number of rows from above the viewport, with or without the scrollbar track, so the two tail captures differ too.
A `visible` read returns the viewport alone and never triggers the scrollbar itself.
Regular mode never draws the scrollbar, and its quiet viewport is byte-identical to the fullscreen one.
