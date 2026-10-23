# Muninn spike runbook

Runbook for the spike and bake-off in the spec
(`docs/superpowers/specs/2026-10-22-meeting-capture-design.md`, section "First step: spike and
bake-off"). Every step uses the `muninn-spike` CLI. Pass criteria are quoted from the spec;
where the spec sets no number, this runbook says so and the result goes to the owner.

## Before the first run

1. **Vendor FluidAudio, then build.** `Vendor/` is generated and gitignored, so a fresh
   checkout needs `scripts/vendor-fluidaudio.sh` first (it skips when already present).
   Timings are only meaningful from a release build.

   ```sh
   scripts/vendor-fluidaudio.sh
   scripts/swiftpm.sh build -c release --product muninn-spike
   ```

   The commands below use `S=.build/release/muninn-spike`.
2. **Permissions for the terminal that runs the spike.** macOS grants them to the terminal app
   (for example Terminal), not to the binary.
   - Microphone: the first `record` prompts for it. If it was refused, enable it under System
     Settings > Privacy & Security > Microphone.
   - System Audio Recording: the first tap prompts for it. Otherwise enable it under System
     Settings > Privacy & Security > Screen & System Audio Recording (the "System Audio
     Recording Only" list). Restart the terminal after changing either.
3. **Hugging Face must be reachable** the first time each model is used. Parakeet, WhisperKit
   and the diarizer models download then and are cached. An outbound firewall such as Little Snitch
   blocks a new binary until allowed, so allow `muninn-spike` first.
4. **Ollama on This Mac** for the `macbook` engine (the engine labelled This Mac in the app):
   it must be running, with the model from settings pulled (`ollama pull qwen3:8b` by default). Step 4 also tries a second 4-8B model
   (`ollama pull gemma3:4b`), and the Network Mac (`--engine studio`) needs `gpt-oss:20b` and `qwen3:30b-a3b` pulled.
5. **The Network Mac URL** must be set in settings; it is empty by default. The spike reads `~/.config/muninn/settings.json`
   (the app's Settings window writes the same file). Missing keys fall back to defaults, so a
   partial file works:

   ```json
   { "studio": { "api": "ollama", "baseURL": "http://<network-mac-host>:11434", "model": "gpt-oss:20b", "keepAlive": "10m" } }
   ```
6. **The Claude key** must be in the Keychain under service `be.netronix.muninn`, account
   `claude.apiKey`. Save it in the app's Settings window, or run
   `security add-generic-password -s be.netronix.muninn -a claude.apiKey -w` and type the key at
   the prompt (never on the command line). The `claude` engine sends the transcript off this Mac,
   so it only runs when you pass `--engine claude` yourself.
7. **Working folder and the background workload.** Keep all output together:

   ```sh
   W=~/Spike/$(date +%F); mkdir -p $W
   ```

   The spec: "Every measurement runs under a **written-down background workload**: the normal
   working state (for example agent sessions, dev servers, browsers), recorded so the run can
   be repeated." Use your normal background workload (for example agent sessions, dev servers,
   browsers). Before step 2, write `$W/workload.md`: which agent sessions and terminal
   sessions are open and busy, which dev servers run, which apps are open. Save a process
   snapshot next to it: `ps -Ao pid,rss,%cpu,comm -r | head -40 > $W/workload-ps.txt`. Start
   every measured run from that same state.

Settings the spike reads: engine endpoints, `claudeModel`, `finalModel`, `dictionary`,
`watchList`. Run `$S measure --seconds 2 --out $W/check.csv` once to confirm the tool runs and
that no load reads fail (a failing read prints a warning on stderr).

Recordings to supply, with participants told: a Teams call, an iPhone call taken on the Mac,
and a mic-only conversation with at least two people speaking.

## Step 1: Capture

The spec:

> - Record the Teams and Continuity calls with both sides on separate tracks. This
>   settles whether Continuity calls can be captured.
> - Check **detection**: a watched app starting to use the mic (Teams, and a call in a
>   browser) triggers the prompt.
> - Check **isolation**: with music or a video playing in another app during the call,
>   the recording holds only the call app's audio.
> - Fallbacks:
>   - No per-app isolation: record all system audio, and say so in the prompt.
>   - No reliable detection: recordings are started by hand only.
>   - Continuity capture fails: phone calls drop out of phase 1.
>
>   The spec records whichever applies.

**Detection.** Start the watcher, then start a Teams call, end it, and repeat with a call in a
browser (for example Google Meet in Chrome or Firefox):

```sh
$S detect --seconds 300
```

Look at: a `started` line within a second or two of the app taking the mic, with its bundle ID,
and an `ended` line after the call. Note any app that stays silent or reports late. The bundle
ID printed here is what `--app` takes. Pass: Teams and the browser call both produce `started`
and `ended`. Otherwise record "recordings are started by hand only".

**Teams, per-app (the isolation test).** Join a call, play music or a video in another app, and
talk for a while:

```sh
$S record --seconds 120 --app com.microsoft.teams2 --out $W/teams
```

Ctrl-C stops a recording early and still writes the files; while the capture is stopping Ctrl-C is ignored (use `Ctrl-\` or `kill` if it hangs). Look at: both `mic.caf` and `system.caf` are written, with sizes and durations that match
`--seconds`; the levels move when the other side speaks (system) or you speak (mic); the
printed `Write errors` is `none` and `Interruption` is `none`. Then listen to
`$W/teams/system.caf` (QuickTime or `afplay`): it must hold the call and not the music.
Pass: system track holds only the call app's audio. If music leaks in, per-app isolation
fails: repeat with `--all-system` and record "record all system audio, and say so in the
prompt".

**Continuity (iPhone call taken on the Mac).** Take a call that rings on the Mac. `detect` only
reports apps on the watch list, so it will not show which process carries the call audio. While
the call is on, run `$S record --seconds 1 --app does.not.exist --out $W/probe`: it fails and
prints every process with an audio object right now. Pick the one that belongs to the call
(FaceTime is the first guess; a call-services helper is possible), and use the same probe to
find an unknown Teams helper process. Then:

```sh
$S record --seconds 120 --app com.apple.FaceTime --out $W/continuity
```

If no process matches, or `system.caf` is silent while you can hear the call, repeat with
`--all-system`. Pass: the far side is audible on `system.caf`. Otherwise record "phone calls
drop out of phase 1".

**Mic only (in-person, two or more speakers):**

```sh
$S record --seconds 300 --mic-only --out $W/inperson
```

Add `--voice-processing` to any command to test echo cancellation when using the speakers
instead of a headset (the spec leaves echo handling to the builder): compare how much of the
call lands on `mic.caf` with and without it.

**Laptop speakers, echo cancellation off and on (app).** The app has a Recording-tab toggle,
"Echo cancellation (use when on speakers)", which sets `RecordingConfig.voiceProcessing`. Take
the same call twice on the laptop speakers with no headset, once with the toggle off and once
on, and compare in the app's transcript. Look at: how many of the far side's sentences also
appear as "You" (the app drops a mic run of three or more words that repeats the call track's
words when each starts from 0.15 s before to 0.5 s after the call track's word, so a few may
already be filtered); whether the near side stays clear with the toggle on; whether the call track
sounds different. Pass: with the toggle on, the far side no longer appears as "You" and your own
voice is not degraded. Record which setting should be the default.

**Muting for 10 seconds.** Auto-stop ends a recording 5 s after the call app stops using the
microphone, and some apps release the microphone on mute. During a recording, mute for 10 s and
unmute, in each of: Teams, a browser call (Meet in Chrome), and Safari. Look at: whether the
app's pill and menu show a recording that ended and a new "Record call in ..." offer, and
whether one call became two meetings. If a mute splits the meeting, auto-stop needs a longer
grace or a different signal (output activity); record which apps do it.

**Quiet stretch on a real call (silence warning).** The pill warns "No call audio for a minute — check that <App> plays through this Mac and that Muninn may record system audio" when
the call track stays below -50 dB for 60 s while the microphone has signal. During a real call
with the app's recording on, let the far side say nothing for 60 to 90 s (a pause while they read,
a muted participant, a long listen) while you keep talking or typing near the mic. Look at: whether
the warning and its notice appear on that quiet stretch; whether the call track's level in the pill
sits near or above -50 dB while the far side is silent but connected (room noise, comfort noise).
Pass: the warning does not fire while the call is up and the far side is merely quiet. If it fires on quiet calls, lower the threshold or lengthen the window in `CallAudioMonitor` and
record the values that work.

## Step 2: Live pipeline

The spec: "Run capture and live transcription together for at least 60 minutes, either during
a long real call or with a long recording played through a call app. Measure how far the live
transcript lags, memory use, and whether it stays on the Neural Engine."

`live --capture` does this in one process: it records the call app and the mic, feeds both
tracks to the live transcriber as they arrive, and samples system load every second. Start it
under the written-down workload, join a long real call (or play a long recording through the
call app), and run `powermetrics` in a second terminal:

```sh
# terminal 1: capture + live transcription + load sampling, in one process
$S live --capture --app com.microsoft.teams2 --seconds 3700 --model parakeet-v3 --out $W/live

# terminal 2: Neural Engine and GPU power
sudo powermetrics --samplers cpu_power,gpu_power,ane_power -i 10000 -n 370 > $W/live-power.txt
```

Use `--all-system` or `--mic-only` in place of `--app` for the other capture modes. Ctrl-C ends the
run early and still writes everything. The output folder holds `mic.caf`, `system.caf`,
`lag.csv` (`track,audio_time,produced_at,lag_seconds,final`), `load.csv` (the step 6 columns),
and the live text per track (`live-mic.txt`, `live-system.txt`). Rows with `final` true come
from the flush when the run ends; they are written to the CSV but left out of the lag figures.

`$S live <audio> --track mic --out $W/live-replay` replays a finished recording in real time
instead (no capture, no `load.csv`) and writes the same `lag.csv`. It reads the whole file into
memory first (about 230 MB per hour of audio), which inflates the footprint it reports. Use it
for quick lag checks only; use `live --capture` for step 2.

Look at:

- `lag.csv` and the per-track median, p95 and max lag printed at the end (final updates left out). The lag must not grow
  over the hour. The spec sets no number for lag: the builder sets the target from these
  measurements.
- The progress line every 10 s (levels, process footprint, memory pressure, CPU) and the
  `Peak footprint` at the end. The spec: "**During a recording** Muninn only captures audio and
  runs the live transcription on the Neural Engine. It stays around 2 GB of memory or less and
  leaves the graphics chip alone." Pass: footprint stays around 2 GB or less.
- `live-power.txt`: ANE power is non-zero while the run goes, and GPU power stays near zero.
  Pass: live transcription is on the Neural Engine and leaves the graphics chip alone.
- The end summary: `dropped` live chunks stays at 0, `Write errors` is `none`, `Interruption`
  is `none`.
- `load.csv` for step 6.

## Step 3: Transcription

The spec: "Run the candidate models on the recordings and compare them on Flemish accents,
mixed languages, names, and telling speakers apart, including on the mic-only sample. The owner
corrects one transcript by hand to serve as a reference."

Run every candidate on the same tracks (the Teams call's `system.caf` and `mic.caf`, the
Continuity call's, and the mic-only sample):

```sh
for m in parakeet-v3 parakeet-ultra whisper-large-v3-turbo; do
  $S transcribe $W/teams/system.caf --model $m --track system --out $W/tx/teams-system-$m
  $S transcribe $W/teams/mic.caf    --model $m --track mic    --out $W/tx/teams-mic-$m
  $S transcribe $W/continuity/system.caf --model $m --track system --out $W/tx/continuity-system-$m
  $S transcribe $W/continuity/mic.caf    --model $m --track mic    --out $W/tx/continuity-mic-$m
  $S transcribe $W/inperson/mic.caf --model $m --track mic    --out $W/tx/inperson-$m
done
$S diarize $W/teams/system.caf --out $W/diar/teams-system
$S diarize $W/continuity/system.caf --out $W/diar/continuity-system
$S diarize $W/inperson/mic.caf --out $W/diar/inperson
```

Each `transcribe` prints elapsed time and the RTF (elapsed divided by audio length; the first
run includes the model download, so repeat once for the number to keep).

**Reference and WER.** Pick one transcript, correct `transcript.md` by hand, and strip it to
plain text (one reference per track):

```sh
sed -E '/^# /d; /^$/d; s/^\*\*\[[^]]*\] [^:]*:\*\* //' corrected.md > $W/ref-teams-system.txt
for m in parakeet-v3 parakeet-ultra whisper-large-v3-turbo; do
  sed -E '/^# /d; /^$/d; s/^\*\*\[[^]]*\] [^:]*:\*\* //' $W/tx/teams-system-$m/transcript.md > $W/hyp-$m.txt
  echo $m; $S wer $W/ref-teams-system.txt $W/hyp-$m.txt
done
```

Look at: the WER and its substitution, deletion and insertion counts per model; then, by eye in
the transcripts, how each model treats Flemish accents, Dutch/French/English mixing, and the
names you put in the dictionary (company, product and client names); and in `turns.json` how many
speakers were found against how many really spoke, on the call and on the mic-only sample.

The spec sets no WER threshold. The bar is anti-goal 1: "**Poor transcription:** words, names or
speakers come out wrong often enough that the user cannot trust the transcript." The owner picks the
final model and the live model from these results. Also compare transcribe time against the
step 5 budget; the spec says "Transcription on the Network Mac happens only if the bake-off shows
This Mac can't meet that budget."

## Step 4: Summary

The spec: "Generate the recap on all three engines, and the owner judges which ones are good
enough to send." The candidate models are the spec's: on the Network Mac gpt-oss-20b and
Qwen3 30B-A3B, on This Mac models of 4-8B, plus Claude. `--llm-model` replaces the engine's
model in settings for that run, so one loop covers all of them:

```sh
T=$W/tx/teams-system-<chosen-model>/transcript.json
for m in gpt-oss:20b qwen3:30b-a3b; do
  $S summarize $T --engine studio --llm-model $m --language nl --title "Teams spike" --out $W/sum/studio-$m
done
for m in qwen3:8b gemma3:4b; do
  $S summarize $T --engine macbook --llm-model $m --language nl --title "Teams spike" --out $W/sum/macbook-$m
done
$S summarize $T --engine claude --language nl --title "Teams spike" --out $W/sum/claude
```

Model names are Ollama tags; if the Network Mac runs an OpenAI-compatible server, set its `api` in
settings and use the names that server lists. Pull any other 4-8B model you want to try and add
it to the This Mac loop. Use `--language` for the call's language (`nl`, `fr` or `en`). The transcript is rule-cleaned
first, as the app does by default. Each run prints the engine and model, subjects, action
points and elapsed seconds; read `summary.md` and compare against the call.

Judge against anti-goal 2: "**Poor summary:** the recap misses subjects, gets decisions wrong,
or assigns action points to the wrong person, so fixing it takes as long as writing it." Check
subjects missed, decisions got wrong, owners on the action points, and the language. Pass: an
engine is good enough to send when fixing its recap takes less time than writing one. The
`claude` run sends this transcript to Anthropic, which is why it is an explicit `--engine`
choice (anti-goal 5).

## Step 5: End to end

The spec: "Time hanging up to a draft recap for a typical call (about 30 minutes) and for a
90-minute recording, using each engine setup that is actually wanted." The budget:

> **From hanging up to a draft recap** takes about a minute for a typical call and no more
> than 5 minutes for the longest. This covers the final transcription, telling speakers
> apart, cleanup and the summary, and is measured with the background workload busy.

Run it on a recorded folder (one holding `mic.caf` and, for a call, `system.caf`) for each
length and each wanted engine setup, with the workload from `workload.md` running. Each `e2e`
run samples system load every second into `<out>/load.csv` itself (step 6), so there is no
separate sampler to start. Add `--llm-model <name>` to try one of the step 4 models:

```sh
$S e2e $W/teams30 --engine macbook --out $W/e2e/30min-macbook
$S e2e $W/teams30 --engine studio  --out $W/e2e/30min-studio
$S e2e $W/teams30 --engine claude  --out $W/e2e/30min-claude
$S e2e $W/teams90 --engine studio  --out $W/e2e/90min-studio
```

Pass `--model <id>` to run with a different final model than the setting. The output holds
per-stage seconds (transcribe, diarize, clean, summarize), the wall-clock total, and the final
status. Pass: total is about 60 s for the 30-minute call and at most 300 s for the 90-minute
recording. A `waiting` status means the engine was not available (Network Mac unreachable or its address not set, no Claude key).
`e2e --engine macbook` forces the engine: it loads the model even under memory pressure, unlike
the app's default path, where the summary waits when pressure is already high. Check
`pressure` in the run's `load.csv` before reading anything into a This Mac time.

This is one of the owner's hard constraints. The spec: "If either fails, the owner decides what
changes." Do not adjust the budget; report the numbers. Away from the Network Mac the budget does
not apply.

**90 minutes on qwen3:8b.** Run the 90-minute recording on This Mac with qwen3:8b
(`--engine macbook --llm-model qwen3:8b`). The app sizes Ollama's `num_ctx` per request
(characters / 3 plus the reply budget, in steps of 4096, at most 32768 on This Mac and 65536
on the Network Mac) and fails a summary whose prompt filled the window. Afterwards read the Ollama
server log (`~/.ollama/logs/server.log`) for "truncating input prompt" and for any context-shift
message. Pass: neither appears and the summary covers the start of the call as well as the end.
If the app reported "too long for the context", note the `num_ctx` it used and the transcript
length. On the Network Mac, also check the log for a model reload ("loading model") between the
cleanup and the summary requests: a changed `num_ctx` can make Ollama reload the model, which
would cost time against the budget.

**Back-to-back calls on This Mac.** Record call A, hang up, and start call B within a
minute, with This Mac as the default engine. Look at: A's status in the list while B records
(it should read "Waiting for the recording to end", with no engine buttons; a local stage of A that
is already running when B starts, one track's transcription or the diarization, finishes, and the
next stage waits: transcription, diarization and, on This Mac, cleanup and the summary);
the live transcript lag and the Neural Engine and GPU load (`powermetrics`, step 2) during B;
after B stops, that A and B both finish; and the time from A's hang-up to A's draft, which
includes the wait for B. This tests the recording gate and whether the final Parakeet pass and
live transcription can share the Neural Engine. Pass: B's live transcript does not stall and the
Mac stays workable. With the Network Mac or Claude engine, only A's local stages (transcription and
diarization) wait for B to end; once A has its transcript, a Network Mac or Claude summary does not
wait for B.

**Hanging up to a draft, measured in the app.** `e2e` starts its clock at `process()`, so it
leaves out the 5 s auto-stop grace and the flush of the live transcriber. For the 30-minute
call, time it with a stopwatch in the app: from the moment you hang up (or press Stop) to the
"Recap ready" notification. Subtract nothing. Compare it with the `e2e` total and report the
difference.

**Audio quality of the 16-bit files.** The app stores 16-bit integer PCM (about 1.5 GB for
90 minutes). Listen to a recorded call's `mic.caf` and `system.caf` and check the transcript
quality (word error rate per step 3 if you have a reference). Pass: no audible clipping or
noise, and a word error rate in line with step 3. Then decide whether a compressed format (AAC or ALAC) or a retention rule
(delete audio N days after filing) is wanted; neither exists yet.

## Step 6: Load and responsiveness

The spec: "Record memory pressure, swap activity and CPU during steps 2 and 5. The owner keeps
working during those runs: typing in the editor and terminal, switching apps. A run fails if the
owner notices lag they wouldn't accept."

`measure` samples once a second and writes
`time,pressure,free_mb,compressed_mb,swap_used_mb,swapins,swapouts,cpu_busy`:

```sh
$S measure --seconds <run length in seconds> --out $W/<step>-load.csv
```

Step 2's `live --capture` and every step 5 `e2e` run already write `load.csv` themselves; use
`measure` for anything else you want to watch. Keep working normally in the editor, terminal
and other apps while the run goes.

The thresholds below are builder heuristics for reading the numbers, not criteria from the spec.
The spec's criterion for this step is the owner's own judgement of lag. Look at:

- `pressure`: 1 is normal, 2 warning, 4 critical. Heuristic: stays at 1 (or briefly 2) with no
  sustained 4; This Mac will not load its model under pressure ("When memory
  pressure is already high, it doesn't load the model; the summary waits instead").
- `swap_used_mb` and `swapouts`: no climb during the run. The load summary printed at the
  end of each run gives the peak swap and the swap-outs over the run.
- `cpu_busy` and how the machine felt. The spec: "**The Mac becomes unworkable** while Muninn
  records or processes" is anti-goal 3. Spec criterion: no lag you wouldn't accept while typing and
  switching apps. Write down what you noticed and when; a run that fails goes to the owner.

The spec also says: "**After the call,** the final transcription and the cleanup run at
background priority and make way for interactive work." Watch for that in step 5 runs.

## Recording the results

The results pick the models and settle the builder's targets; a failed hard constraint goes to
the owner (see Performance in the spec). Keep `$W` with the workload, CSVs, transcripts and
summaries, and note which spec fallback applies to each step 1 outcome.
