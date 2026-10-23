# libfprint elan patches

These patches change libfprint's `elan` driver for the ELAN `04f3:0c6e` reader in this
laptop's power key. [ADR 0006](https://github.com/apex-linux/apex/blob/main/docs/adr/0006-fingerprint-libfprint-rebuild.md)
covers the decision and [../README.md](../README.md) covers the rebuild. This file
describes what each patch does to the capture state machine and which log lines show it.

- **Base:** libfprint tag `v1.94.100` (commit `80a4b5ec612892c5c056c48dddaa561452cf37ec`).
  Fedora 45 ships this version as `libfprint-1.94.100-1.fc45`, with no patches of its own.
  At this tag, `libfprint/drivers/elan.c` has sha256
  `b6e02523b760836374ad8a51ea523f68ea6a2a2d05d88d58f484c06688e3307b` and `elan.h` has
  `44f1697e7063d6c91c88c3d8888c6a25952c62322cf6c291083bca4650667eea`. The Source0
  tarball Fedora builds from contains the same two files.
- **Upstream master** (`6f9479c3`, 2026-09-02) has an identical `elan.c` and `elan.h`,
  so the patches apply there too.

| Patch | State | What it does |
|---|---|---|
| `0001-elan-Retry-transient-pre-scan-status-on-04f3-0c6e.patch` | enabled | Gives 0x0c6e its own quirk bit (`ELAN_0C6E`, bit 4). Turns the 0x0c58-only retry of the transient answers 0x00 and 0xaf into the mask `ELAN_RETRY_TRANSIENT_STATUS`. Logs every pre-scan answer. |
| `0002-elan-Bound-transient-retries-with-lift-semantics.patch` | enabled | Bounds that retry to `ELAN_CMD_TIMEOUT` per run. On 0x0c6e it also adds lift semantics (a transient answer after a frame ends the capture) and a 10, 50, 200 ms back-off. |
| `0101-elan-Recover-from-dark-frame-on-0c6e.patch` | carried, disabled | On 0x0c6e, a frame darker than the background reports `FP_DEVICE_RETRY_REMOVE_FINGER` at once instead of the session error `FP_DEVICE_ERROR_GENERAL`. The capture then waits for the finger to be lifted (at most 10 s) before the next calibration. After 3 such retries in a row, the next dark frame is the stock session error again. |
| `0102-elan-Settle-after-stop.patch` | carried, disabled | Backport of draft MR !647: a 10 ms settle state after `stop_cmd`, before finger-off is reported and calibration starts again. |

`../series` lists the enabled patches and explains the 00xx/01xx numbering. Each 01xx
patch applies on top of 0001 and 0002, alone or together with the other 01xx patch,
in either order. To enable one, follow the steps in `../series`: attach the log lines
listed under [Which log lines to look for](#which-log-lines-to-look-for), `git mv` the
patch to the next free 00xx number and add it to `series`.

## The capture state machine

The elan driver is an `FpImageDevice`. Every time the image device core enters
`AWAIT_FINGER_ON`, `dev_change_state()` runs the calibration SSM and then the capture
SSM. Both of these always start with `elan_dev_reset_state()`, which clears the frames,
`last_read`, the calibration status and (with 0002) the transient-answer counters.
With 0101 it also clears the dark-frame flag, but not the count of dark-frame retries
in a row.

```
CALIBRATE_*  get_image (background) -> get_calib_mean -> [calib status loop] -> capture

CAPTURE_LED_ON              (state 0)  led_on_cmd, no answer
CAPTURE_WAIT_FINGER         (state 1)  pre_scan_cmd 0x40 0x3f, then a 1-byte read on EP 0x83.
                                       The read blocks until a finger is present or the
                                       timeout expires: 10 s (ELAN_CMD_TIMEOUT) before the
                                       first frame, 200 ms (ELAN_FINGER_TIMEOUT) after it.
CAPTURE_READ_DATA           (state 2)  looks at the answer byte (tables below)
CAPTURE_CHECK_ENOUGH_FRAMES (state 3)  subtracts the background and saves the frame.
                                       A frame darker than the background everywhere is
                                       the "dark frame" error. Fewer than 30 frames:
                                       back to state 1 with the 200 ms timeout.
                                       30 frames: done.

capture_complete()
  no error, or "transfer timed out" while in state 1:
      >= 7 frames  -> image submitted (the last 2 frames are dropped)
      <  7 frames  -> FP_DEVICE_RETRY_TOO_SHORT ("swipe too short")
  any other error  -> session error (the whole enroll/verify ends)
  always           -> STOP_CAPTURE: stop_cmd 0x00 0x0b, no answer; then finger-off
```

A read timeout in state 1 is the driver's normal way to learn that the finger was
lifted, or, before the first frame, that no finger came within 10 s. In this file,
**"the timeout path"** means that branch of `capture_complete()`. Patch 0002 ends
captures by completing the SSM without an error, which takes the same branch and
therefore has the same outcome, minus the wait.

Cancellation (for example fprintd stopping a verify) cancels the device's
`GCancellable`. A pending USB read fails with `G_IO_ERROR_CANCELLED`. A retry scheduled
with `fpi_ssm_jump_to_state_delayed()` is **not** removed. It fires after at most one
delay (200 ms or less), state 1 then submits `pre_scan_cmd` with the cancelled
cancellable, and `fpi_usb_transfer_submit()` fails that transfer at once with
`G_IO_ERROR_CANCELLED`. The SSM ends on the normal cancellation path. This is safe
because nothing else refers to the SSM while the delay is pending: no transfer is in
flight, and the driver's `dev_deactivate()` only sets a flag. libfprint itself gives no
protection here. At v1.94.100, `fpi_ssm_mark_completed()` on an SSM with a pending delay
does not refuse: its `BUG_ON` only logs a critical, then it drops the delayed jump and
completes and frees the SSM. So no future change may complete the capture SSM while a
retry is pending.

## What each pre-scan answer does

"Frames" is the number of frames saved in the current capture. fprintd's result names
are given in brackets.

### 04f3:0c6e (this laptop)

| Answer | Frames | Stock v1.94.100 | + 0001 | + 0001 + 0002 (shipped) |
|---|---|---|---|---|
| `0x55` finger present | any | Image read, frame saved, back to state 1. After 30 frames: image | same | same; also ends a run of transient answers |
| `0x00` not ready, `0xaf` busy/removed | 0 | `FP_DEVICE_ERROR_PROTO`, session ends (`enroll-disconnected`, `verify-disconnected`) | Retried every 10 ms with no bound (about 100 polls/s for as long as the answers continue) | Retried after 10, 50 and 200 ms, then every 200 ms. After 10 s of transient answers the capture ends on the timeout path: `FP_DEVICE_RETRY_TOO_SHORT` (`*-swipe-too-short`), as when no finger comes in 10 s |
| `0x00`, `0xaf` | ≥ 1 | `FP_DEVICE_ERROR_PROTO` | Retried every 10 ms. If the sensor keeps answering until the next touch, the capture is never submitted | **Finger lifted:** the capture ends at once on the timeout path. With ≥ 7 frames the image is submitted, otherwise `TOO_SHORT` |
| `0xff` "not calibrated" | any | `FP_DEVICE_ERROR_PROTO` | same | same (unchanged) |
| any other byte | any | `FP_DEVICE_ERROR_PROTO` | same | same (unchanged) |
| no answer, the read times out | 0 | after 10 s: `TOO_SHORT` | same | same |
| no answer, the read times out | ≥ 1 | after 200 ms: image with ≥ 7 frames, else `TOO_SHORT` | same | same |

A **run** is a sequence of consecutive transient answers. It starts at the first one,
is timed with `g_get_monotonic_time()`, and ends at `0x55` or at the start of the next
capture. 0002 never schedules a retry past the 10 s budget: the last delay is shortened
to fit.

### 04f3:0c58, the other device in `ELAN_RETRY_TRANSIENT_STATUS`

| Answer | Frames | Stock and + 0001 | + 0001 + 0002 |
|---|---|---|---|
| `0x00`, `0xaf` | 0 | retried every 10 ms, no bound | retried every 10 ms; a 10 s run ends on the timeout path (`TOO_SHORT`) |
| `0x00`, `0xaf` | ≥ 1 | retried every 10 ms, no bound | retried every 10 ms (**no** lift semantics); a 10 s run ends on the timeout path |

Every other answer behaves as on 0x0c6e. The 10 s bound is the only change 0002 makes
for 0x0c58. Every other elan PID keeps the stock behaviour, where anything but `0x55`
is a protocol error. For those devices the patches only add the `pre-scan status` debug
line, which is also all that changes for libfprint's own elan replay tests (a 0x0c26).

### Disabled patches

| Situation | Enabled series | + 0101 | + 0102 |
|---|---|---|---|
| Frame darker than the background, any frame count, 0x0c6e | `FP_DEVICE_ERROR_GENERAL` "An unspecified error occurred!" (`*-unknown-error`), session ends | `FP_DEVICE_RETRY_REMOVE_FINGER` (`*-remove-and-retry`) at once; the capture then waits for the lift (below) | as the series |
| 4th dark frame in a row, 0x0c6e | as above | `FP_DEVICE_ERROR_GENERAL`, as the series | as the series |
| `stop_cmd` sent at the end of a capture | finger-off is reported at once, and calibration may send `get_image` about 1 ms later | as the series | 10 ms settle state (`STOP_CAPTURE_NUM_STATES` state 1) before finger-off |

**Why 0101 waits for the lift.** Calibration takes the background right before each
capture, so a dark frame means the finger was already on the key then. The first
version of 0101 only turned the error into a retry at the end of the capture. That was
not enough: `stop_capture_complete()` reports finger-off without asking the sensor, and
enroll (or fprintd, which restarts the identify after a retry) calibrates about 1 ms
later. The new background was taken with the same finger on the key, and a resting finger
caused a fast `REMOVE_FINGER` loop. In the simulation below, that was over 700 prompts in
400 ms.

What 0101 does now on 0x0c6e:

1. At the first dark frame it reports `REMOVE_FINGER` right away, while the finger is
   still there, and drops every frame of that capture.
2. The capture goes on the way it does after a good frame: `pre_scan_cmd` with the
   200 ms `ELAN_FINGER_TIMEOUT`, with a 50 ms pause before each poll
   (`ELAN_DARK_FRAME_POLL_DELAY`). A `0x55` means the finger is still there; its frame
   is read and dropped.
3. The capture ends when the read times out, when the sensor answers `0x00`/`0xaf` (the
   0002 lift semantics, which with 0101 also count a dark frame as a finger), or 10 s
   after the dark frame (`ELAN_DARK_FRAME_LIFT_TIMEOUT`). Only then is `stop_cmd` sent
   and finger-off reported, so the next calibration normally takes its background
   without the finger.
4. At most 3 captures in a row (`ELAN_DARK_FRAME_MAX_RETRIES`) may end this way. The
   4th dark frame fails the session with `FP_DEVICE_ERROR_GENERAL`, as stock does. Any
   capture that ends without a dark frame resets the count. The count survives
   fprintd's restarts of the identify.

A finger that never leaves the key therefore gives 3 prompts 10 s apart, then the stock
error. Cancelling during the wait works as described for 0002 above.

## Which log lines to look for

Run with `G_MESSAGES_DEBUG=all`. Every line is printed as
`libfprint-<domain>-DEBUG: <hh:mm:ss.mmm>: <message>`. The messages below are exact,
except that numbers vary. `[elan] CAPTURE_NUM_STATES` is the capture SSM and
`STOP_CAPTURE_NUM_STATES` is the stop SSM.

| Domain | Message | Source | Meaning |
|---|---|---|---|
| elan | `pre-scan status: 0x55` | 0001 | one line per pre-scan answer: the byte this unit sent |
| elan | `transient pre-scan status 0x00: retry 1 in 10 ms` | 0002 | the first transient answer of a run, no frame yet (then `retry 2 in 50 ms`, `retry 3 in 200 ms`, ...) |
| elan | `transient pre-scan status for 10000 ms (52 retries): ending capture as a read timeout` | 0002 | the 10 s bound ended the capture; followed by `swipe too short: want >= 7 frames, got 0` |
| elan | `pre-scan status 0xaf after 10 frames: finger lifted` | 0002 | lift semantics (0x0c6e only) |
| elan | `swipe too short: want >= 7 frames, got 3` | stock | the `TOO_SHORT` retry |
| elan | `frame darker than background; finger present during calibration?` | stock | a dark frame |
| elan | `frame darker than background: asking to remove the finger (retry 1 of 3)` | 0101 | the dark frame became a retry |
| elan | `finger still present after the dark frame: frame dropped` | 0101 | a poll while waiting for the lift, at most every 50 ms |
| elan | `pre-scan status 0xaf after 0 frames: finger lifted` | 0101 + 0002 | the lift after a dark frame, answered with a transient byte |
| elan | `finger still present 10000 ms after the dark frame: ending capture` | 0101 | the wait for the lift ran out |
| elan | `capture after a dark frame ended; the next one calibrates again` | 0101 | end of that capture; `stop_cmd` and finger-off follow |
| elan | `frame darker than background in 4 captures in a row: giving up` | 0101 | the retry bound; followed by the stock state 3 session error |
| SSM | `[elan] SSM CAPTURE_NUM_STATES failed in state 2 with error: The driver encountered a protocol error with the device.` | stock | **the reported bug** (stock or 0001 without 0002, answer not 0x55/0x00/0xaf) |
| SSM | `[elan] SSM CAPTURE_NUM_STATES failed in state 1 with error: transfer timed out` | stock | the timeout path: finger lifted, or no finger in 10 s (text from libgusb) |
| SSM | `[elan] SSM CAPTURE_NUM_STATES failed in state 3 with error: An unspecified error occurred!` | stock | the dark-frame session error |
| SSM | `[elan] STOP_CAPTURE_NUM_STATES entering state 1` | 0102 | the settle state |

How to read a log from this laptop:

- **Which byte does the unit send?** Run `grep 'pre-scan status: 0x'`. A touch should
  give a run of `0x55`. Any other byte is the answer to the research's open question.
- **After a lift**, either line is fine. `failed in state 1 with error: transfer timed out`
  means the sensor blocks. `finger lifted` means it answers 0x00/0xaf, the case 0002
  exists for.
- **While idle** (a lock screen waiting for a finger), `transient pre-scan status ...
  retry` lines at most 5 per second, with `ending capture as a read timeout` about every
  10 s, mean the sensor answers at once when no finger is present. The bound holds.
  If there are no such lines, the sensor blocks, which is the normal case.
- **A problem with 0002:** `finger lifted` after only 1 to 3 frames while the finger
  was still on the key. That would mean this unit sends 0xaf mid-touch for "busy". In
  that case lift semantics are wrong for it: report the log and consider the 0x0c58
  behaviour (retry, bounded) by taking 0x0c6e out of `ELAN_TRANSIENT_STATUS_LIFT`.
- **Evidence for 0101:** `frame darker than background; finger present during
  calibration?` followed by `failed in state 3 with error: An unspecified error
  occurred!`. It is most likely when the key is already pressed as the capture starts.
- **0101 working, once enabled:** one `asking to remove the finger` line per touch, then
  `frame dropped` lines while the finger stays, then the lift (`failed in state 1 with
  error: transfer timed out` or `finger lifted`), and only after that the next
  `CALIBRATE_NUM_STATES`. `giving up` means four dark frames in a row even though the
  finger was lifted in between; report that log, because a lift should give a clean
  background.
- **Evidence for 0102:** a retry (`swipe too short` or `finger lifted` with too few
  frames), then `STOP_CAPTURE_NUM_STATES completed successfully`, then the next
  `CALIBRATE_NUM_STATES entering state 0`, and about 10 s later
  `SSM CALIBRATE_NUM_STATES failed in state 0 with error: transfer timed out`.

The hardware test is in
[docs/hardware/FINGERPRINT.md](https://github.com/apex-linux/apex/blob/main/docs/hardware/FINGERPRINT.md). It covers the
safe capture log, the lock-screen soak and what may be shared. `G_MESSAGES_DEBUG`
output contains no image data. `FP_DEBUG_TRANSFER=1` dumps raw frames, which are
biometric data, so it never goes into a shared log.

## How the patches were checked (2026-09-24)

All of this ran in a scratch directory on the dev host, not in CI. No hardware was
involved.

- **Applying.** Checked on a clone of the tag and on Fedora's Source0 tarball: the
  series with `git apply --check`, with GNU `patch -F0`, and with rpm's own
  `%__scm_apply_git` command (`git apply --index --reject -p1`). Also checked: 0101 and
  0102 on top of the series, alone and together in either order; 0102 on the bare tag;
  and reversing the series with `git apply -R`, which `build.sh` does. No fuzz, no
  rejects. Rechecked after the 0101 rework, on the elan files of the Source0 tarball,
  with `git apply --index` in a fresh repository and `patch -F0`: every combination
  above, both orders of 0101 and 0102 give the same tree, and each reversed set
  restores the pristine files.
- **Building.** The host has no libgusb or libusb headers, so libfprint was built with
  `meson setup -Ddrivers=elan -Ddoc=false -Dintrospection=false -Dinstalled-tests=false
  -Dudev_rules=disabled -Dudev_hwdb=disabled` against a stand-in `gusb.h` and
  `libgusb.so` that simulate the sensor. The libfprint core and the elan driver were
  the real code; only the USB layer was replaced. Two builds were made, a plain one
  and one with AddressSanitizer and LeakSanitizer. With `-Wall -Wextra` the patched
  `elan.c` shows only the 5 `-Wsign-compare` warnings the stock file already has. The
  libfprint unit tests `fpi-ssm`, `fpi-device` and `fpi-assembling` pass. The elan
  umockdev replay tests need introspection and umockdev, so they were not run here;
  `build.sh` runs them in CI.
- **Simulated sensor.** The simulator scripted the pre-scan answers for the capture
  API. The results below are from the ASan build, with no sanitizer reports.

| Scenario (0x0c6e unless noted) | Stock | + 0001 | + 0001 + 0002 |
|---|---|---|---|
| `0x00` ×3, then 10 × `0x55`, then timeout | PROTO on the first `0x00` | image | image, retries after 10, 50, 200 ms |
| 10 × `0x55`, then `0xaf` forever | PROTO | still polling after 2 s (205 polls) | `finger lifted`, image |
| 3 × `0x55`, then `0xaf` | PROTO | still polling after 2 s | `finger lifted`, `TOO_SHORT` |
| `0x00` forever (idle) | PROTO | 195 polls in 2 s | 53 polls, `TOO_SHORT` at 10.0 s |
| `0xff`, or an unknown byte | PROTO | PROTO | PROTO |
| 0x0c58: 3 × `0x55`, 5 × `0xaf`, 7 × `0x55`, timeout | image | image | image, same 10 ms retries |
| 0x0c58: `0xaf` forever after 3 frames | polls until killed (about 97/s for 120 s) | same | `TOO_SHORT` at 10.0 s (978 polls) |
| 0x0c26: `0x00` | PROTO | PROTO | PROTO |
| Cancelled 30 ms and 300 ms into a pending retry, twice in a row | n/a | n/a | `G_IO_ERROR_CANCELLED` within one delay, clean deactivation, next capture restarts the back-off at 10 ms |
| Dark frame, 0x0c6e | GENERAL | GENERAL | GENERAL; with 0101: see the next table |

**0101 (reworked after review, 2026-09-24).** A second harness drives the public
enroll, identify and capture APIs the way GNOME Settings and fprintd do. Like fprintd,
it restarts an identify that ends with a retry. It checks each scenario automatically:
94 checks, plus 6 for the 40 s run. They ran on the plain build and under ASan/LSan,
with 0101 alone and with 0102 on top. All pass, with no sanitizer report and no
libfprint warning or critical. The first version of 0101 fails 35 of the 94. With a
resting finger it gave 714 enroll prompts (1429 image reads) and 493 identify restarts
in 400 ms. After a lift, it took the next background 0.1 ms after the prompt.

| Scenario, 0x0c6e | 0101 now |
|---|---|
| Finger resting, every background dark, cancelled after 400 ms | 1 prompt, 1 calibration, a pause of 50 ms before each poll, clean cancel (enroll, identify and capture) |
| Dark frame, then lifted (the read times out) | next background 250 ms after the dark frame, after the 200 ms read timed out; identify is restarted only then |
| Dark frame, finger stays for 4 more polls, then lifted | 4 frames dropped, next background after the lift (≥ 450 ms) |
| Dark frame, then `0xaf` or `0x00` | `finger lifted` at once, no transient retry |
| 4 dark frames, lifted each time (enroll; identify with restarts) | 3 prompts, then GENERAL (identify: on the 4th start) |
| 2 dark frames, a good capture, 3 dark frames | 5 prompts, never gives up (the count restarts) |
| Finger never lifted, 40 s | prompts at 0, 10 and 20 s, GENERAL at 30 s |
| 3 good frames, then a dark frame | `REMOVE_FINGER`, no image and no `TOO_SHORT` |
| Cancelled during the lift read; `0xff` during the wait | clean cancel; PROTO session error |
| Dark frame on 0x0c58 and 0x0c26 | GENERAL (unchanged) |

Scenarios without a dark frame give the same result, retry lines and poll counts with
and without 0101 (single captures, plain and ASan builds): the rows of the first table
except cancellation, plus `0x55` ×3 then `0x00`, `0x55` ×40, no finger for 10 s, and a
0x0c26 image. The one exception is timing noise: the 10 s run of 10 ms polls on 0x0c58
gave between 981 and 988 polls in repeated runs, with or without 0101.

The corrected claim about `fpi_ssm_mark_completed()` in the 0002 section was checked
with a small test linked against `libfprint-private.a`. It completes an SSM that has a
pending `fpi_ssm_jump_to_state_delayed()`: a `BUG:*timeout*` critical is logged, the
completion callback runs at once, and the jump never fires.

Not verified: the real sensor. The byte sequences above are assumptions, and only the
test in `docs/hardware/FINGERPRINT.md` shows which ones this unit sends.

## Upstream

- 0001 is equivalent to ssubbotin/libfprint@5a89584b and a subset of MR !655. Drop it
  once upstream retries 0x00/0xaf on 0x0c6e: 0001 then stops applying (see
  [../README.md](../README.md#when-upstream-merges-mr-655)).
- 0002 is Apex's own. It is written to be offered upstream together with 0001, with the
  debug log from this laptop as evidence.
- 0102 is draft MR !647 (commit `7500a883c072`) and is unchanged apart from context.
  Drop it once !647 is merged.
