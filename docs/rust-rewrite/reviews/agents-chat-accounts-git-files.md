# Parity review: soprano-agents, soprano-chat, soprano-accounts, soprano-git, soprano-files

None of the five crates is clean. I found 34 differences from the Swift app; the most serious are three hangs (one in ACP process exit handling, two in the agent transcript store and git branch monitor) and two ways the Claude account code can lose a saved login. The highest-risk logic itself is faithful to Swift: ACP approvals, questions, queue/steer and cancel; Claude/Codex/omp account switching; and file create/rename/move/trash. File operations never fall back to permanent delete and never overwrite on macOS. One Linux/Windows exception: a Copy or Duplicate can still overwrite a file that appears at the target at the wrong moment (finding 32).

Tests pass: `cargo test -p soprano-agents -p soprano-chat -p soprano-accounts -p soprano-git -p soprano-files` ran 253 tests with 0 failures. I used one shared target directory for the five crates (`target/review-agents-batch`) rather than one per crate. No test covers any of the findings below. I made no edits.

Four parallel readers compared Swift and Rust function by function. I re-checked the ones marked ✔ in the source myself; the rest are their reading, with confidence noted.

## Bugs on macOS and every platform

1. **soprano-chat — the agent's exit is never reported if any process it started still holds its output** ✔
   - **Rust** `rpc.rs:317-342`: after the agent process ends, the waiter thread waits for both output-reader threads (`reader.join()`, `stderr_reader.join()`). Only then does it mark the connection exited, fail waiting requests and send `PeerEvent::Exit`.
   - **Swift** `JSONRPCConnection.swift` `start()`: `terminationHandler` reports the exit as soon as the process ends.
   - **What the user sees:** if a tool child, language server or background job still holds the agent's stdout or stderr, a crashed agent looks alive forever. No "The agent exited…" notice appears and the turn stays stuck. Because `start`/`restart` wait for every retired peer first (`session.rs:724`, `has_exited()` stays false), the tab hangs in "Starting…" for good.
   - **Fix:** don't join the stderr reader; read the stderr tail at exit time. Join the stdout reader only with a short deadline (about 250 ms), or put the agent in its own process group and signal the whole group.
   - **Test to add:** `sh -c 'sleep 30 & exit 1'` must still produce `Exit` promptly.

2. **soprano-git — the branch monitor can deadlock on macOS** ✔
   - **Rust** `branch.rs:96`: `set_watched_paths` drops a stale watcher while holding the `inner` lock. notify 8.2.2's FSEvents `stop()` (`fsevent.rs:317-332`) spins until the watcher thread's run loop is idle, then joins it. The callback on that thread (`branch.rs:161`) is blocked on the same lock.
   - **Second path:** the callback upgrades its `Weak` and ends up holding the last `Arc`, so the watchers are dropped on their own thread, which spins forever.
   - **Swift** `GitBranchMonitor.swift:121-150` does everything on the main queue, with no lock.
   - **What the user sees:** a permanent hang if a HEAD change lands while a pane's folder changes (for example `git checkout x && cd elsewhere`). This is latent: today only tests call `set_watched_paths`.
   - **Fix:** move removed watchers into a local `Vec` and drop it after unlocking; don't drop `Inner` from inside the callback.

3. **soprano-agents — transcript reads pile up instead of being skipped** ✔
   - **Rust** `store.rs:258-280`: every `Read(None)` (the 1 s tick) and every file event (including OpenCode `-wal`/`-shm` writes) runs a full `read()` for each matching reader. The channel is unbounded.
   - **Swift** `AgentTranscriptStore.read(_:)`: `reading.insert(...).inserted` drops a request while that follower is already queued or reading.
   - **What the user sees:** while an agent streams, the dashboard timeline falls further and further behind the file, and change callbacks fire in bursts.
   - **Fix:** after `recv()`, drain the channel with `try_recv()`, keep `Track`/`Stop` in order, and read each id once per batch.

4. **soprano-agents — the OpenCode reader can panic and silently freeze every dashboard timeline** ✔
   - **Rust** `opencode_reader.rs:97` calls `std::env::vars()`, which panics if any environment variable isn't valid Unicode. Swift's `ProcessInfo.environment` never traps.
   - **Where it runs:** `make_reader` is called on the store's worker thread, so the panic kills that thread. After that, `track`/`refresh` sends fail silently and every agent's timeline stops updating.
   - **Fix:** read only `XDG_DATA_HOME` with `var_os` and a lossy conversion.

5. **soprano-accounts — a missing `$USER` can overwrite the saved System default login** ✔
   - **Rust** `claude.rs:104-107` uses `USER`, then `USERNAME`, then `""`, which becomes `"claude-code-user"`. **Swift** `ClaudeCodeAccountManager.swift:91` uses `USER ?? NSUserName()`.
   - **How the login is lost:** with no `USER` while a managed account is active, Rust looks up the wrong Keychain item and finds nothing. `read_live` then has no `claudeAiOauth`, so `reconcile` takes the "signed out under us" branch and writes a null login over `system-default`. That slot holds the only copy of the user's own refresh token, so it is gone.
   - **Fix:** fall back to `getpwuid(getuid())->pw_name` before `"claude-code-user"`. It happens rarely, but it violates "never lose a login".

6. **soprano-accounts — stored Claude logins go through `keyring` on macOS** ✔
   - `controller.rs:110` uses `secrets: Arc::new(KeyringStore)`. Swift used `security` (`KeychainCLI`) specifically so a rebuilt or re-signed app keeps access.
   - The porting report lists this as a deviation and calls it "one prompt". It is worse than that:
     - `usage_credentials()` reads every non-active stored account on each refresh, so "Allow" (rather than "Always Allow") means N prompts every 5 minutes, and every re-signed build starts them again.
     - "Deny" makes `read_stored` fail, so `reconcile` errors and account switching is impossible.
   - **Fix:** use `KeychainCli` for the managed service on macOS; keep `keyring` on Linux and Windows.

7. **soprano-files — on macOS, rename and move can fail with "Operation not supported"** (medium confidence)
   - **Rust** `operations.rs:476-481` uses `renamex_np(RENAME_EXCL)` for every move. The man page says it returns `ENOTSUP` on file systems without `RENAME_EXCL`. There is no fallback, while Linux has one at `:484-507`.
   - **Swift** used `FileManager.moveItem` for normal moves and `renamex_np` only for case-only renames.
   - **What the user sees:** rename/move fails on such volumes. Which volumes these are (SMB, exFAT?) is untested inference.
   - **Fix:** on `ENOTSUP`/`EINVAL`, fall back to `check_then_rename`.

8. **soprano-agents — closing the dashboard blocks the UI thread** ✔
   - **Rust** `store.rs:208-218`: `Drop` queues `Stop` behind every pending command and joins the worker on the UI thread. Combined with finding 3, that can be a long wait.
   - **Fix:** add a stop flag that the worker checks between commands, or detach the worker instead of joining.

9. **soprano-accounts — an observer that calls back into the controller deadlocks** ✔
   - **Rust** `controller.rs:298-306`: `notify` holds the non-reentrant `notifying` mutex while running observers. An observer that synchronously calls `refresh`, `select`, etc. locks it again on the same thread. Swift's `didSet` allowed re-entry.
   - **Fix:** don't hold the lock across callbacks (use a generation counter), or document the rule loudly.

10. **soprano-accounts — two quick Claude selections may apply out of order** (medium)
    - `claude.rs:139` serialises with a `std::sync::Mutex`, one thread per action; std's mutex doesn't hand the lock over in arrival order. Swift's `AsyncSerialQueue` is strictly first-in, first-out.
    - **What the user sees:** clicking A then B can leave A live.
    - **Fix:** one worker thread or channel per manager.

## Bugs on Windows and Linux only (macOS unaffected)

11. **soprano-chat, Windows — Stop/Restart kills only PowerShell** ✔
    - `rpc.rs:494-496` calls `child.kill()` on the direct child, but `soprano-launch/src/chat.rs:93-95` runs `pwsh -Command "& 'omp' …; exit $LASTEXITCODE"` with no `exec`, so omp is a grandchild.
    - **What the user sees:** an orphaned `omp acp` keeps the conversation open, and finding 1 then hangs the tab.
    - **Fix:** kill the process tree with a Job Object or `taskkill /T /F`, as `soprano-automations/src/precheck.rs` already does.

12. **soprano-accounts, Windows — Cancel or the 600 s timeout leaves the sign-in CLI running**
    - `command.rs:350-369` kills only `cmd.exe /C`.
    - **What the user sees:** `codex login` keeps port 1455, so the next sign-in fails. A leftover `claude auth login` can still write `.credentials.json` into `%TEMP%`.
    - **Fix:** the same tree kill.

13. **Windows — console windows pop up** ✔ for chat
    - `soprano-chat/rpc.rs:268-282` (one window per chat tab) and `soprano-git/reader.rs:186-200` (a flash on every git call) don't set `CREATE_NO_WINDOW` (`0x0800_0000`). `soprano-accounts/command.rs` already does.

14. **soprano-files, Windows — absolute-to-tree path mapping assumes `/`**
    - `root.rs:56-74` builds the prefix as `format!("{root}/")`, so `C:\proj/` never matches `C:\proj\src\a.rs`. The same pattern is in `tree.rs:541` and `relative_path_in_roots`.
    - **What the user sees:** the explorer never reacts to file-system events, find-files outside git returns nothing, and folders don't stay open after a rename or move.
    - **Fix:** `Path::strip_prefix`, then join the components with `/`.

15. **soprano-files, Windows — `is_valid_name` accepts `\` and `:`** (`operations.rs:416`)
    - Renaming to `..\x` moves the file out of its folder; `a:b` creates a hidden NTFS alternate stream.
    - **Fix:** under `cfg(windows)`, also reject `\:*?"<>|`, control characters, and trailing dots or spaces.

16. **soprano-files, Linux and Windows — a trash that worked can be reported as failed, with no undo** ✔
    - `trash.rs:50-65` trashes the item first, then looks it up in the trash list. A lookup miss returns `TrashFailed`, stops the rest of the selection and records no undo step, even though the item is in the trash.
    - On Windows a miss is likely: `canonicalize` gives `\\?\C:\…`, and the comparison is case-sensitive.
    - On Linux, two items with the same name trashed from the same folder within one second tie on `max_by_key(time_deleted)`, so Undo can restore the wrong one.
    - **Fix:** compare the trash list before and after the delete, and strip the verbatim prefix.

17. **soprano-agents, Windows — paths are never shown relative to the project**
    - `timeline.rs:358` uses `format!("{cwd}/")` with byte-wise `strip_prefix`, so every tool summary shows the full path. ✔
    - **Fix:** a Windows-aware `Path::strip_prefix`.

18. **soprano-accounts, Windows — stale Codex junctions are handled wrongly**
    - `codex.rs:470-478`: `symlink_metadata().is_dir()` is always false for junctions, so the code always calls `remove_file`. A dangling-link cleanup then fails silently, and when a link points elsewhere, Codex add or re-authenticate fails.
    - **Fix:** use `FileTypeExt::is_symlink_dir()`, then `remove_dir`.

19. **soprano-accounts, Windows — a stored login may be too large for Credential Manager** (low-medium; the reader's belief, not checked)
    - The `keyring` value is limited to about 1,280 characters, and a stored login with its full `oauthAccount` is roughly 900–1,000.
    - **What the user sees:** Add can fail after a full browser sign-in, and the captured login is thrown away.

20. **soprano-files, Linux — hitting the inotify watch limit turns off live updates for the whole root**
    - In `watcher.rs:30-35`, the first watch-limit failure makes `new()` return `None`. Large repositories then never refresh automatically.
    - **Fix:** keep a watcher on partial success, or fall back to polling.

21. **soprano-files, Linux — file names that aren't valid UTF-8 can't be opened or renamed** (`listing.rs:31` stores lossy names)
    - Trash on such a file silently does nothing, because the item doesn't seem to exist.
    - **Fix:** keep the `OsString` name for building paths.

## Low severity

22. **soprano-chat:** retry on `ErrorKind::Interrupted` in the readers (`rpc.rs:396`, `:304`); today they treat it as end of output and stop for good.
23. **soprano-chat:** a waker set after `start()` is never used (`session.rs:737`), so events would pile up unprocessed.
24. **soprano-chat:** `start()` while a peer is still current drops it without terminating or retiring it. Its requests never get Swift's "Session closed" reply, and its process leaks.
25. **soprano-chat:** each read rescans a very long line from the beginning (`rpc.rs:131`); a multi-megabyte line costs hundreds of rescans.
26. **soprano-agents:** serde_json stops at nesting depth 128, while Swift's limit is 512 (`json.rs:29`). A dropped Claude or omp record can cut off all earlier history in the timeline.
27. **soprano-agents:** the Codex `turn_aborted` fallback id is a nanosecond timestamp (`codex.rs:385`), which can collide where Swift used a UUID, so one "Interrupted" notice can disappear.
28. **soprano-agents:** a transcript directory whose watch failed is never retried (`store.rs:327-350`). That transcript still updates on the 1 s refresh, which is what Swift did.
29. **soprano-agents:** with no home directory at all, `display_path` reaches `home_dir().expect(...)`. That panic is a platform-wide design choice.
30. **soprano-accounts:** failure messages don't split on a bare `\r` (`command.rs:33`), so spinner text stays in the error.
31. **soprano-files watcher:**
    - Batch de-duplication is quadratic (`watcher.rs:49-53`); use a `HashSet`.
    - It doesn't notice the root itself being renamed or deleted (Swift set `WatchRoot`).
    - One batch can still arrive after `stop()` returns, contrary to its doc comment.
32. **soprano-files `copy_item`:**
    - **Overwrite race:** it checks that the target is free, then `std::fs::copy` overwrites it, so a file that appears at that moment is replaced. This affects Copy into a folder and Duplicate.
    - **Special files:** a FIFO inside a copied folder blocks the copy forever.
    - **Permissions:** folder permissions aren't preserved.
33. **soprano-git:**
    - Natural sort compares lowercased code points, so `Ärger` sorts after `Zoo` (Finder puts it with A).
    - Find-files outside git lists the insides of `.app`/`.xcodeproj` bundles.
    - Untracked-file line counting follows symlinks (`reader.rs:104`).
    - `parse_head` returns an empty name for a ref ending in `/`.
    - The launcher finds Soprano Git with `mdfind` (which can pick a copy in the Trash) and runs `open -a` synchronously on the caller's thread.
34. **Cosmetic:** the tool-input JSON is pretty-printed differently (`turn_builder.rs:813`), and `argument_path` handles `[#TAG]` differently (`:839`).

## Checked and matching Swift

- **ACP:**
  - **Handshake:** the `initialize` parameters, steering detection, load-or-new with the replaying flag, and "The agent returned no session."
  - **Requests from the agent:** permission option parsing; no options means cancelled; the selected and cancelled bodies; elicitation accept/decline/cancel; a newer request replacing an unanswered one; `$/cancel_request`; and `-32601` for unknown methods.
  - **Prompts and turns:** queueing while not ready or while a request is on screen; steering with its fallback to `send`; `cancel` (withdraw the request, mark stop requested, send `session/cancel`); a cancelled turn keeps the queue; every session-update kind.
  - **Exit:** the last-6-lines stderr notice.
  - **Line framing and stderr:** empty lines dropped, partial lines buffered, and the 4,000-character stderr tail.
- **Transcript decoders:** every Claude, Codex, omp and OpenCode record type, plus timeline folding and branch selection. Every Swift decoder test has a Rust counterpart with the same expected values.
- **Transcript store, OpenCode reader, dashboard:** the follower constants and truncation handling, identical SQL, and dashboard sorting and wording.
- **Account switching:**
  - Claude order of operations (`read_live`, then `reconcile`, then save System default only when none is active, then `write_live`, then set active). I re-checked this side by side.
  - The all-or-nothing rollback in `write_live`.
  - `~/.claude.json`: only `oauthAccount` is replaced.
  - A failed read is never treated as "no credentials".
  - `security` arguments are passed as a vector, with no shell.
  - Atomic 0600 writes.
  - Swift-written account state decodes: camelCase keys and dates as seconds since 2001.
  - Codex and omp flows.
- **File operations:** create, folder create and rename never overwrite; case-only renames; refusing to move or copy a folder into itself; "copy", "copy 2" naming; undo/redo order and partial failure; symlinks copied and removed as links; no permanent-delete fallback in trash.
- **git:** porcelain v2 `-z` parsing (renames, conflicts, paths with spaces); numstat and diff parsing; the size limits; `.git` as a file and `commondir` worktrees.