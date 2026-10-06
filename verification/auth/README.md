# Authentication and startup repair — 2026-10-06

## Observed failures

The installed application's local log showed two `WAITING_2FA` transitions followed by a SIGSEGV during CGO, and repeated `write EIO` exceptions after terminal detachment. Personal logs are not committed.

Source investigation found:

- Follow-up installed-profile login rejected credentials with Apple error `957384` and generic FairPlay code `-1`. The earlier immutable-password change freed its buffer before the borrowed Android string reached `setPassword`. The new production-handler test reproduced a heap use-after-free under ASan before the fix and passed after release was moved beyond credentials submission. It covers a 1024-byte password and two successive verification replies. Live Apple login after this fix remains unqualified.

- Both layers of the native authentication bridge omitted the GUI callback/data, so verification codes could not reach Apple's credentials handler.
- The renderer posted verification codes to `https://127.0.0.1:20025api/v1/drm/challenge`.
- Retried codes appended to the previous password and could overflow its fixed allocation; native paths/credentials also outlived caller-owned CGO buffers.
- Transport initialization wrote invented account tokens and emitted `RUNNING` before Apple authentication. Unrelated state updates erased pending challenges; failed FairPlay retained playback capabilities.
- A fixed 512-byte request body could truncate longer developer tokens and produce invalid authentication JSON. It now uses complete, escaped JSON serialization, tested with a 4096-byte token.
- Detached recovery workers survived library shutdown. Mapped Android libraries and mutexes were destroyed despite background references.
- Web sign-in popups navigated the original player, losing `window.opener`. Last.fm provider popups were not managed. Apple storage-access requests were denied unconditionally.
- Engine startup killed arbitrary port/lock owners and unlinked the flock file. Spawn errors, overlapping starts, and restart timers during quit were not controlled.
- Development launch did not build the engine or injected bundles, and ignored dependency installation failure.

## Automated and runtime validation

- `node --test electron/test/*.test.mjs electron/test/engine/*.test.mjs electron/tests/*.test.mjs`: 67 passed, 2 skipped, 0 failed on the packaged checkout.
- `go test ./...` in `engine`: all packages passed, including VLC tests with bundled libraries/plugins available.
- `go test -race ./core/drm`: passed.
- `go test -race -tags 'native_backend drm_testhelpers' ./core/drm`: passed. Includes a real Go → C → exported Go authentication callback, cancellation/truncation and native inflight lifecycle tests.
- `make -C drm test-auth test-recovery test-auth-transport test-subscription test-music-token-request test-credential-handler`: passed. Production credential-handler lifetime, credentials, recovery, subscription bounds and long-token JSON tests use ASan/UBSan; transport tests link the actual DRM library.
- `electron --no-sandbox verification/auth/electron-smoke.mjs`: passed in Electron 43.1.0. Real popup keeps its opener/partition/player; real renderer displays 2FA, posts the correct endpoint and completes against synthetic API responses. No Apple credentials are used.
- Packaged native engine: two isolated startups on port 20125, signed-out state, HTTP 409 for unrequested verification replies, graceful SIGTERM shutdown and restart all passed. Account data and Chromium profile were isolated.
- `python3 verification/auth/engine-smoke.py --session-directory DIR`: restores only a temporary copy, checks failure/ready state, rejects unsolicited codes, and preserves the session lock across two graceful shutdowns.
- Native library, CGO engine, renderer bundles, Electron directory package and `.run` installer built successfully. Installer's bundled-file equality checks passed.

The validation host used Go 1.27.1 and build headers extracted to `/tmp` from distribution packages. Production requirements remain those documented in README. No host-wide compiler packages were installed.

## Installed profile validation

The updated app opened a visible Apple Music page with the existing web session still authorized and renderer bridge/bundles loaded. This uncovered a separate native crash during eager restoration of the incomplete account database left by the previous failed login: `offline_available()` read the second entry of an empty subscription-status vector. Explicit bounds checks now reject this incomplete state, with a clear failed-authentication snapshot and preserved account files. Two native packaged-engine startups and graceful shutdowns using a private copy of the affected profile passed. The final installed build also opened a visible authorized web player, loaded the bridge/bundles, showed Settings with Sign In available, and ran one engine with zero SIGSEGV/uncaught exceptions during the check. The actual DRM login still requires user qualification.

## Account qualification still required

1. Web email/password sign-in and trusted-device code complete inside the app.
2. DRM sign-in requests and accepts the actual Apple 2FA code.
3. An incorrect code can be retried without a crash.
4. Lossless playback works; close/reopen retains both sessions.
5. Last.fm/ListenBrainz authorization succeeds with the intended account.
6. iPhone QR/passkey authentication: not qualified. Popup fixes alone do not establish native platform authenticator support.

Private Apple libraries do not expose a complete thread teardown API. Libraries now remain mapped while the app-owned recovery worker is stopped and callbacks cleared; repeated live Apple authentication remains part of account qualification.

## Upstream PR draft

**Title:** Fix native DRM 2FA, account persistence, web auth popups and engine lifecycle

Apple's verification challenges could never reach the GUI because the native callback bridge was disconnected. Even when entered, codes were posted to a malformed URL. Login retries modified and could overflow passwords, and shutdown left recovery workers using unloaded libraries. Web authentication also destroyed the original player by replacing its window with the popup URL.

Connect the complete authentication callback path, preserve pending challenges and genuine account state, build immutable credential replies and retain native-owned inputs. Keep auth popups connected to their opener, limit storage permission exceptions to Apple pages, and coordinate engine startup/shutdown without killing unrelated processes or replacing the session flock inode. Development launch builds all required components.

Validation: Node suites, all Go packages, DRM race/CGO callback tests, native sanitizer/transport tests, real Electron synthetic auth flow, packaged engine startup/restart and installer consistency checks. Live Apple/iPhone/provider account qualification is pending; this should remain a draft PR until those results are recorded.

Electron popup behavior reference: https://www.electronjs.org/docs/latest/api/window-open
