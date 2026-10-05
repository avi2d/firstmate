# Pi pane captures for the stale and wedge hash

These files are replay inputs for `../../fm-pane-hash-lib.test.sh`.
They come from Pi 1.0.2 and Herdr 0.9.3 on Darwin arm64, read on 2026-10-05 in an isolated Herdr lab session with a 120-column by 40-row viewer attached.

## Capture provenance

Each `*-tail` file is stdout from `fm_backend_capture herdr <session>:<pane> 40`, the read `bin/fm-watch.sh` takes every poll.
The one edit is the five-letter account name in Pi's install path, which reads `user1` so every row keeps its width.
Pi ran as `pi --offline --no-session --tui-mode <mode>` with an empty `PI_CODING_AGENT_DIR`, then ran `!seq -f "LAB_LONG_LINE_%g" 1 120; printf "%0150d\n" 0` so the transcript exceeded the viewport.

| File | Mode | When it was read |
| --- | --- | --- |
| `regular-tail.capture` | regular | Idle, and byte-identical to the same read 0.3 s later |
| `fullscreen-tail-a.capture` and `fullscreen-tail-b.capture` | fullscreen | Two 40-line tail reads of one unchanged idle pane while another reader read it every 4 s |

## What the captures show

The two fullscreen tails differ although the pane never changed.
