# The patched source build

## Why it exists

The prebuilt binaries this project downloads are built from unmodified upstream
source. That is what makes the default install fast and dependency-free, but it also
means they cannot contain this project's UI changes:

- **smoothed tokens/second** - an EMA over the server's cumulative average, so one slow
  token does not collapse the displayed speed for the rest of the response
- **per-response speed log** - a collapsible table under each assistant message with
  generation t/s, prompt t/s, and the session average and peak

Building from source is how you get them.

## Usage

```bash
./scripts/build-from-source.sh --check   # fetch the source, verify the patch applies, stop
./scripts/build-from-source.sh           # fetch, patch, build, install
./scripts/build-from-source.sh --jobs 8  # limit build parallelism
```

`--check` is quick and is the right first step after changing anything about the pinned
commit.

## What it does

1. Clones `PrismML-Eng/llama.cpp` at the pinned commit into `.build/llama.cpp`.
2. Resets that checkout, so re-runs are predictable.
3. Applies `patches/0001-speedlog-ema-tps.patch`, after a `git apply --check`.
4. Configures with `-DLLAMA_BUILD_UI=ON -DLLAMA_USE_PREBUILT_UI=OFF`.
5. Builds `llama-server` and installs it to `bin/<backend>-patched/`.

Step 4 matters. The UI has a prebuilt-bundle download path, and a downloaded bundle
would not carry the patch, making this build identical to the prebuilt and the whole
exercise pointless.

## Requirements

- `cmake` and a C++ toolchain
- **Node.js 20+** - the UI is built from source, so Node is mandatory here
- For a HIP build, a matching ROCm installation
- Time. This is a full llama.cpp build.

The default prebuilt path needs none of this.

## Which binary runs

`scripts/lib/common.sh` resolves the server binary in this order:

1. `bin/<backend>-patched/`
2. `bin/<backend>/`

So a successful source build takes effect immediately, with no flags to remember. To go
back to the prebuilt:

```bash
rm -rf bin/<backend>-patched
```

`scripts/start-server.sh` prints the full path of the binary it is about to run, so you
can always see which one is in play.

## Verifying the patch landed

The build script checks automatically. The speed log persists its entries under a
`sessionStorage` key, and that key only exists when the patch is present, so the script
greps the built UI bundle for it:

```
[OK]   Speed-log UI patch confirmed present in the build.
```

If it cannot find the marker you get a warning, not a failure: the server still works,
only the extra panel would be missing.

By hand:

```bash
grep -r "bonsai_speed_log" .build/llama.cpp/build-<backend>/tools/ui/dist
```

In the running server, open the Web UI, send a message, and look for
`Speed log · avg N t/s · peak N t/s` under the assistant's stats row.

## What the patch changes

Three files:

| File | Change |
|---|---|
| `tools/ui/.../ChatMessageStatistics/SpeedLog.svelte` | new component: the collapsible log |
| `tools/ui/.../ChatMessageStatistics/ChatMessageStatistics.svelte` | renders the log, records one entry per finished response |
| `tools/ui/src/lib/hooks/use-processing-state.svelte.ts` | EMA smoothing on the reported tokens/second |

The EMA uses `alpha = 0.25`, skips the first token of a response (its elapsed time is
near zero, so its speed is noise), and resets between responses. It recomputes only when
the token count advances, so repeated reads during one render return the same value.

## Regenerating the patch

When the pinned commit moves, the upstream UI may have changed underneath the patch.

```bash
# 1. Get a scratch checkout at the new commit
git init -q /tmp/patch-src
git -C /tmp/patch-src remote add origin https://github.com/PrismML-Eng/llama.cpp.git
git -C /tmp/patch-src fetch --depth 1 origin <full-commit-sha>
git -C /tmp/patch-src checkout -q --detach FETCH_HEAD

# 2. Re-apply the changes by hand in that checkout, then
git -C /tmp/patch-src add -N tools/ui/src/lib/components/app/chat/ChatMessages/ChatMessageStatistics/SpeedLog.svelte
git -C /tmp/patch-src diff > patches/0001-speedlog-ema-tps.patch

# 3. Verify
./tests/run.sh --with-patch
```

Then update `PRISM_COMMIT` and `PRISM_COMMIT_FULL` in `scripts/lib/common.sh`.

## Testing

`./tests/run.sh --with-patch` fetches the pinned commit and runs `git apply --check`.
CI additionally builds the patched UI, runs `svelte-check`, and greps the produced
bundle for the speed-log marker - so a patch that compiles but silently does not ship
fails the build.
