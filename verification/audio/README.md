# Audio, mixer and responsiveness repair — 1.4.1

All local authentication, startup, keyboard, audio and responsiveness fixes are consolidated into the proposed 1.4.1 patch. Intermediate local builds identified as 1.4.2 in the authentication report are historical validation steps, not another upstream release.

## Root causes and changes

- Each VLC play reapplied a captured volume, forced unmute, then ran three `pactl` commands eight times. The renderer also reposted a stale per-track slider value after each load. Remove those overrides; expose live VLC volume/mute to synchronize the renderer. Set stable LibVLC application metadata so the mixer shows Apple Music Linux rather than VLC.
- Live programmatic queue/play entered loading without any track-change event or native session load. A delayed state-event fallback starts only a settled item whose ID the engine has not already handled; ordinary track-change events take precedence.
- Premature EOF recovery sent SetTime to an ended player. SetTime only runs once the player is already playing/paused; it never restarts an ended source. Reload the source at startMs, ignore a retry after a skip, handle VLC errors and bound status requests while continuing to poll through temporary outages.
- Cache downloads used independent 10–15-minute contexts. Bind them to the server lifetime and cancel that lifetime before joining VLC input threads. Protect requests racing with a closed VLC player. Terminate SSE streams on server cancellation so HTTP shutdown does not wait for an open renderer connection. Bound Chromium cookie flushing before the final app exit, allowing up to three seconds for normal engine teardown.
- Default Chromium prefers-reduced-motion reduces decorative artwork animation; users may disable the Display preference and restart to restore it. The full-screen artwork filter ignored the saved background blur and forced 80px. Honor the saved blur; active playback already warms its queue, so skip an unrelated ten-track startup warm and limit idle startup warming to three tracks.

## Measured checks

- `AML_TEST_PULSE=1 go test ./core/vlc -run TestSystemMixer -count=1`: before the change the real owned mixer stream's mute was overwritten; after the change volume 37% and mute remained across source replacement and the isolated stream name matched its test metadata. The test uses silent synthetic WAV data, a separate test application identity (so desktop restore settings cannot affect the real app) and targets only its own PID. The installed app name is checked separately.
- `AML_TEST_PULSE=1 go test -race ./core/vlc ./cmd`: passed, including callback read cancellation, media replacement, mixer persistence and closed-player request safety.
- `go test ./...`: passed with the bundled VLC plugins/libraries available.
- Renderer recovery tests cover mid-track EOF, delayed recovery after a skip, normal end, failed reload, missing track-change events and stale polling replies. Node checks: 74 passed, 3 checks skipped, no failures.
- Real Electron authentication smoke exercises popup ownership, Enter focus, sign-in and 2FA submission. Quit smoke passes both ordinary cookie flushing and a cookie flush promise that never resolves, with storage/engine cleanup preceding exit.
- A real licensed ALAC track was sought to 60 seconds and the native player deliberately stopped. The renderer reloaded it at the last observed position, preserved volume 37% and unmuted state, and playback continued beyond 179 seconds. This tests a controlled mid-track stop, not every natural network failure.
- The SSE shutdown regression failed before cancellation was added and passed after it.
- Initial installed-build sample: eight seconds on the visible Apple Music home page, 29.125% of one CPU core across app processes, 1183.8 MiB aggregate RSS (shared pages counted per process), renderer task time 0.165s and JavaScript 0.028s. This is one local sample, not a benchmark or proof of sustained improvement. A later paused-page sample measured 44.875% CPU and 1151.9 MiB aggregate RSS, with layout work dominating. These samples do not establish sustained CPU improvement; Electron/web resource cost remains.

Live long-session playback and naturally occurring network/lease interruptions still need qualification. Synthetic recovery tests establish corrected control flow, not successful recovery from every Apple/CDN failure. The host also runs Unity and Rider, so end-to-end resource comparisons must be interpreted accordingly. No account secrets or raw private profiling logs are committed.

LibVLC identity uses the upstream [application metadata API](https://github.com/videolan/vlc/blob/master/include/vlc/libvlc.h).

Motion preference uses Chromium's [reduced-motion switch](https://chromium.googlesource.com/chromium/src/+/HEAD/ui/gfx/switches.cc).
