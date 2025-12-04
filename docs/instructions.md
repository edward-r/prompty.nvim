I want to create a NeoVim plugin to be sourced in this repository, with the potential intention of open-sourcing it to the public. This plugin is to enable me to create prompts in NeoVim using my `prompt-maker-cli` application. Below are notes that my coding assistent gleaned from the `prompt-maker-cli` repository. And I am including pertinent file paths from that repository also for context. Additionally, I’m including links to some of the official NeoVim plugin documentation.

I want to call this plugin `Prompty`, and I would like that to be the banner if this ends up in it's own window, etc.

## Quick Checklist

- Ensure `prompt-maker-cli` binary is built/installed and discoverable in `$PATH`.
- Confirm `OPENAI_API_KEY`/`GEMINI_API_KEY` (plus optional `GITHUB_TOKEN`) are set or present in `~/.config/prompt-maker-cli/config.json`.
- Capture intent via inline text, temp files, or buffer exports—never launch without validated intent input.
- Attach context through `--context`, `--url`, `--image`/`--video`, and `--smart-context-root` as needed; guard against oversized or duplicate files.
- Prefer `--json --quiet --stream jsonl` for editor integrations; parse `generation.final` and telemetry events to drive UI.
- Use `--interactive-transport <socket>` for refinement loops; send `{"type":"refine"}` / `{"type":"finish"}` messages and mirror streamed events.
- Apply `--context-template nvim` (or user template) before writing to buffers; fall back to `polishedPrompt`/`prompt` if `renderedPrompt` absent.
- Surface warnings/errors from stderr immediately (credentials, context fetch failures, upload issues) and offer corrective prompts.
- Append runs to history or expose pickers by tailing `~/.config/prompt-maker-cli/history.jsonl`.
- Clean up sockets/temp files when jobs end; cancel outstanding refinements on disconnect.

---

## 1. Purpose & Audience

- **Audience**: developers of a NeoVim plugin (Lua or TypeScript via `deno-nvim`/`node-host`) and accompanying coding agents collaborating on that plugin.
- **Goal**: expose `prompt-maker-cli` from inside NeoVim without reimplementing its business logic—use the CLI as the single source of truth for prompt contracts, telemetry, history logging, and transports.
- **Scope**: everything from installation and configuration through synchronous command execution, streaming refinement loops, media/context ingestion, diagnostics, and fallback handling.

## 2. Build & Runtime Prerequisites

- **Repository build**: from repo root run `npx nx build prompt-maker-cli --skip-nx-cache`. Artifacts land in `apps/prompt-maker-cli/dist`.
- **Global install**: `npm uninstall -g @perceptron/prompt-maker-cli` (safe no-op) then `npm install -g apps/prompt-maker-cli/dist`. The binary name is `prompt-maker-cli` (aliasable to `pmc`).
- **Direct execution**: during development you can run `node apps/prompt-maker-cli/dist/index.js ...` without reinstalling.
- **Node tooling**: plugin should locate the binary via `which prompt-maker-cli` or respect user-configured aliases.
- **Config directory**: `$HOME/.config/prompt-maker-cli/` hosts `config.json`, `history.jsonl`, and the embeddings cache; the plugin must never write arbitrary files here unless mirroring CLI behavior (e.g., context templates, transport sockets under `/tmp`).
- **Environment**: CLI relies on `OPENAI_API_KEY`, `GEMINI_API_KEY`, optional `*_BASE_URL` overrides, and `PROMPT_MAKER_*` vars. Plugin settings UI should surface these but avoid storing secrets in git.

## 3. Command Surfaces & Flag Matrix

- **Primary command**: `prompt-maker-cli [intent] [options]` maps to the “generate” workflow; `prompt-maker-cli test ...` is unrelated to prompt generation.
- **Key positional/flag inputs**: summarized below (full list in Appendix A).
  - Intent: inline argument, `--intent-file`, or stdin.
  - Context: repeated `--context` globs, `--url`, `--image`, `--video`, `--smart-context` (+ `--smart-context-root`).
  - Output controls: `--json`, `--copy`, `--open-chatgpt`, `--context-template`, `--context-file`, `--context-format`.
  - Interaction: `-i/--interactive`, `--stream jsonl`, `--interactive-transport <path>`, `--quiet`, `--no-progress`.
  - Post-processing: `--polish`, `--polish-model`.

## 4. Intent & Context Ingestion

- **Intent sources**: exactly one of inline argument, `--intent-file`, or stdin must provide content. Files are capped at 512 KB, must be UTF‑8 text, and cannot contain NUL bytes (`readIntentFile`).
- **Interactive intent disambiguation**: placing a path immediately after `-i/--interactive` is treated as an implicit intent file with a warning—plugin should avoid this ambiguity by emitting explicit flags.
- **Context files**: `resolveFileContext` expands globs with `fast-glob` (`dot: true`). Missing matches trigger warnings but are not fatal. Each file becomes `<file path="…">…</file>` inside prompts.
- **Context dedupe**: plugin should keep track of already attached buffers/files to avoid redundant globbing, especially when also using smart context.
- **Context exports**: use `--show-context`, `--context-file <path>`, and `--context-format text|json` to preview or persist the blocks that feed the LLM—handy for preview windows inside NeoVim.

## 5. Remote Context Resolution

- **HTTP/HTTPS URLs**: `resolveUrlContext` downloads each URL (≤1 MB). HTML is converted to text via `html-to-text`, stripping scripts/styles. Failures log warnings but continue.
- **Duplicate suppression**: identical URLs are skipped. Only http(s) protocols allowed.
- **GitHub URLs**: `github-context.ts` recognizes `blob`, `tree`, and repo root URLs. Safeguards include file caps (≤64 KB per file, ≤60 files), ignore lists (`node_modules`, `dist`, lockfiles, archives), and automatic path prefix filtering. Responses stream progress via the `onProgress` callback—plugins can map these to NeoVim notifications.
- **Authentication**: honors `GITHUB_TOKEN` if set; otherwise uses unauthenticated requests with strict rate limits.

## 6. Smart Context (Local RAG)

- **Trigger**: `--smart-context` optionally paired with `--smart-context-root <dir>`.
- **Scan**: `fast-glob` searches `**/*.{ts,tsx,js,jsx,py,md,json}` excluding `node_modules`, build outputs, lockfiles, git metadata. Files >25 KB are skipped.
- **Embeddings**: `apps/prompt-maker-cli/src/rag/vector-store.ts` stores SHA256 hashes + embeddings in `$HOME/.config/prompt-maker-cli/embeddings_cache.json` via `@prompt-maker/core#getEmbedding`.
- **Workflow**: index (with caching) → top‑k search (default 5) against intent string → read + append unique files not already in the user-provided context list.
- **Progress reporting**: `resolveSmartContextFiles` emits messages (“Scanning…”, “Indexed…”, “Smart context ready”) that surface through progress spinners and `--stream jsonl` events; the plugin should surface these as status lines.

## 7. Media Attachments

- **Images** (`--image`): Accepts PNG/JPG/JPEG/WEBP/GIF up to 20 MB. Files are Base64 encoded into `@prompt-maker/core` image parts. Unsupported extensions or oversize files generate warnings and are skipped.
- **Videos** (`--video`): Requires Gemini models. If any `--video` flag is present and the requested model is not Gemini, the CLI auto-switches to `gemini-1.5-pro` (or configured default). Uploads use Google’s Files API via `GoogleAIFileManager`, polling until `ACTIVE` or failing with a detailed error.
- **Upload telemetry**: `upload.state` events emit `start/finish` for each file; when spinners are visible the label swaps to “Uploading…” until transfers finish. Plugin integrations should reflect this to prevent users from closing buffers mid-upload.

## 8. Model Resolution & Credentials

- **Default model**: `resolveDefaultGenerateModel` picks `promptGenerator.defaultModel`, `PROMPT_MAKER_GENERATE_MODEL`, or `gpt-4o-mini`.
- **Gemini fallback**: `resolveGeminiVideoModel` prefers `promptGenerator.defaultGeminiModel`, otherwise `gemini-1.5-pro`.
- **Credential loading**: `ensureModelCredentials` pulls env vars first, then falls back to `~/.config/prompt-maker-cli/config.json`. Missing keys throw descriptive errors before API calls, so the plugin should capture stderr and surface the message.
- **Polish model**: defaults to the generation model unless `--polish-model` or `PROMPT_MAKER_POLISH_MODEL` overrides it.

## 9. Generation & Refinement Workflow

1. **Telemetry prep**: count tokens for intent + context (using `js-tiktoken`). Results print in a cyan box/table unless `--quiet` or `--json` suppresses UI. Plugin can parse `generation.iteration.start` events for token counts when running quiet.
2. **Initial iteration**: `PromptGeneratorService.generatePrompt` builds CoT JSON prompts with `GEN_SYSTEM_PROMPT` and `buildInitialUserMessage`. Responses must be JSON containing `reasoning` and `prompt`; if parsing fails, raw text is passed through after logging a warning.
3. **Interactive mode**:
   - **TTY loop**: uses Enquirer to ask “Refine?” and prompt for instructions. Plugin integrations typically avoid this mode and prefer transports.
   - **Transport loop**: `--interactive-transport /tmp/pmc.sock` opens a Unix socket (or Windows pipe) that accepts newline-delimited JSON commands: `{"type":"refine","instruction":"..."}` or `{"type":"finish"}`. The CLI streams events back over the same socket (mirroring `--stream jsonl` output) so the plugin can update UI without parsing stdout.
4. **Refinements**: each instruction triggers a new iteration, passing the prior prompt, original intent, context, and the latest instruction into `buildRefinementMessage` (system prompt switches to `REFINE_SYSTEM_PROMPT`).
5. **Completion**: when the user stops refining, the CLI emits `interactive.state`=`complete` and returns the final prompt plus iteration count.
6. **Polish pass** (optional): `--polish` invokes `polishPrompt` with a fixed system instruction emphasizing formatting fidelity.

## 10. Streaming Events & IPC

- **Modes**: `--stream none|jsonl` controls whether events print to stdout. Even with `none`, taps can receive events (e.g., interactive transport attaches as a tap).
- **Schema** (see `StreamEvent` in `generate-command.ts`):
  - `context.telemetry` → `{ files:[{path,tokens}], intentTokens, fileTokens, totalTokens }`
  - `progress.update` → `{ label, state:'start|update|stop', scope:'url|smart|generate|polish|generic' }`
  - `upload.state` → `{ state:'start|finish', detail:{kind:'image|video', filePath} }`
  - `generation.iteration.start` → `{ iteration, intent, model, interactive, inputTokens, refinements[], latestRefinement? }`
  - `generation.iteration.complete` → `{ iteration, prompt, tokens }`
  - `interactive.state` → `{ phase:'start|prompt|refine|complete', iteration }`
  - `interactive.awaiting` → `{ mode:'transport|tty|none' }`
  - `transport.listening|transport.client.connected|transport.client.disconnected`
  - `generation.final` → `{ result: GenerateJsonPayload }`
- **Transport lifecycle**: server cleans up Unix sockets on exit (`SIGINT`, `SIGTERM`, `process.exit`). Plugin must handle reconnects and `transport.error` messages.

## 11. Output Assembly & Delivery

- **GenerateJsonPayload**: includes `intent`, `model`, `prompt`, `refinements`, `iterations`, `interactive`, `timestamp`, `contextPaths`, optional `outputPath`, `polishedPrompt`, `polishModel`, `contextTemplate`, `renderedPrompt`.
- **Context templates**: built-in `nvim` template injects a header and instructions before inserting `{{prompt}}`. User-defined templates live under `contextTemplates` in `config.json`. Plugin should let users select templates per run or default to `nvim` when targeting scratch buffers.
- **Clipboard/browser**: `--copy` uses `clipboardy`; `--open-chatgpt` opens `https://chatgpt.com/?q=...`. In headless editor environments these options should default to false unless explicitly enabled.
- **History logging**: every run (JSON payload) appends to `$HOME/.config/prompt-maker-cli/history.jsonl`. Plugins can tail this file to show recent prompts or rehydrate drafts.

## 12. Telemetry & Status Presentation

- **Token summaries**: highlight total, intent, and file tokens plus top 10 files with counts. When running `--quiet` the plugin should parse `context.telemetry` for the same data and render it in NeoVim (virtual text, floating window, etc.).
- **Spinners**: `ora` spinners appear only when `--progress` is true and stdout is a TTY. Plugins using `--quiet --stream jsonl` get deterministic `progress.update` events instead of spinners.
- **Reasoning**: setting `DEBUG=1` or `VERBOSE=1` prints `reasoning` text to stderr after each LLM call. Plugins can capture stderr to display reasoning logs or route them to a diagnostics pane.

## 13. Error Handling & Edge Cases

- **Missing intent**: CLI throws `Intent text is required…`. Plugin should prompt the user to provide text before spawning the process.
- **Invalid path/URL**: warnings are emitted but runs continue. Capture stderr so the user sees skipped files.
- **Oversized/binary intent files**: fail fast with descriptive errors (size in KB, binary detection). Provide guardrails in the plugin UI (file picker + size hint).
- **Credential errors**: `ensureModelCredentials` throws if API keys are absent—surface these immediately with actionable messaging (e.g., open plugin settings).
- **Transport disconnects**: CLI emits `transport.client.disconnected` and drains pending refinement promises; the plugin should reconnect or end the session gracefully.
- **Upload failures**: warnings identify the file and root cause. Consider showing a quickfix entry pointing at the asset path.
- **Smart context indexing failure**: CLI logs warnings but continues. Plugin may retry with reduced scope or inform the user to run without smart context.

## 14. Integration Playbooks

1. **One-shot prompt into buffer**
   - Command: `prompt-maker-cli <intent> --json --quiet --context-template nvim --context ...`
   - Steps: run job → capture stdout JSON → insert `renderedPrompt` (fallback to `polishedPrompt`/`prompt`).
2. **Interactive refinement split**
   - Start CLI with `--quiet --stream jsonl --interactive-transport /tmp/pmc.sock` inside a background job.
   - Plugin tails stdout for JSONL events, displays prompts in a buffer, and sends `refine`/`finish` commands over the socket based on user input.
3. **Context preview workflow**
   - Use `--context-file /tmp/pmc-context.json --context-format json --show-context`.
   - Plugin parses the JSON for an expandable tree view and optionally caches context for auditing.
4. **History-driven picker**
   - Tail `$HOME/.config/prompt-maker-cli/history.jsonl` (or periodically parse) to feed a Telescope picker listing recent intents/prompts.
   - Selecting an entry can repopulate buffers or re-run with `--intent-file` referencing saved drafts.
5. **Media-assisted runs**
   - Validate selected images/videos before invoking CLI (check extension + size).
   - Display upload progress based on `upload.state` events and prevent user from interrupting until finish.
6. **Automated guardrails**
   - Monitor `context.telemetry.totalTokens`; if above a threshold (e.g., 30k), warn the user or prompt to trim context.
   - Enforce linear command queueing when multiple runs share the same socket path to avoid collisions.

## 15. Appendix

### A. High-value Flags

| Flag                                       | Purpose                                           |
| ------------------------------------------ | ------------------------------------------------- |
| `<intent>` / `--intent-file` / stdin       | Provide rough intent text.                        |
| `-c, --context <glob>`                     | Attach local files. Repeatable.                   |
| `--url <https://…>`                        | Pull remote docs or GitHub repos.                 |
| `--image <path>` / `--video <path>`        | Inline media (image Base64, video uploads).       |
| `--smart-context` / `--smart-context-root` | Enable embedding-based file selection.            |
| `-i, --interactive`                        | Enable TTY refinement loop.                       |
| `--interactive-transport <path>`           | Socket/pipe commands + streaming events.          |
| `--stream jsonl`                           | Emit newline-delimited structured events.         |
| `--json`                                   | Print final payload for programmatic consumption. |
| `--context-template <name>`                | Wrap final prompt (built-in `nvim`).              |
| `--copy`, `--open-chatgpt`                 | Clipboard/browser handoff.                        |
| `--polish`, `--polish-model`               | Post-generation refinement.                       |
| `--quiet`, `--no-progress`                 | Suppress UI spinners/banners.                     |

### B. Environment Variables & Config Keys

| Key                                  | Meaning                                    |
| ------------------------------------ | ------------------------------------------ |
| `OPENAI_API_KEY` / `OPENAI_BASE_URL` | OpenAI credentials (env overrides config). |
| `GEMINI_API_KEY` / `GEMINI_BASE_URL` | Gemini credentials + custom endpoints.     |
| `GITHUB_TOKEN`                       | Optional token for GitHub API rate limits. |
| `PROMPT_MAKER_GENERATE_MODEL`        | Default generation model override.         |
| `PROMPT_MAKER_POLISH_MODEL`          | Default polishing model.                   |
| `PROMPT_MAKER_CLI_CONFIG`            | Custom config file path.                   |
| `DEBUG` / `VERBOSE`                  | Enable reasoning logs to stderr.           |

Config file example (`~/.config/prompt-maker-cli/config.json`):

```json
{
  "openaiApiKey": "sk-…",
  "geminiApiKey": "gk-…",
  "promptGenerator": {
    "defaultModel": "gemini-1.5-flash",
    "defaultGeminiModel": "gemini-1.5-pro"
  },
  "contextTemplates": {
    "nvim": "## NeoVim Prompt Buffer\n\n{{prompt}}",
    "scratch": "# Prompt Vault\n\n{{prompt}}"
  }
}
```

### C. File & Socket Locations

- CLI binary: global npm prefix (e.g., `~/.nvm/versions/node/v22.15.0/bin/prompt-maker-cli`).
- Config/history: `$HOME/.config/prompt-maker-cli/` (`config.json`, `history.jsonl`, `embeddings_cache.json`).
- Transport sockets: plugin chooses path (e.g., `/tmp/pmc.nvim.sock`). Clean up stale sockets before binding.
- Context exports: plugin-controlled temp dir (respect user preferences, clean up automatically).

### D. Event Handling Checklist

1. Always parse stdout as JSONL when `--stream jsonl` is active.
2. Treat stderr as human-readable diagnostics (warnings, reasoning, spinner fallbacks).
3. Handle `transport.error` messages by notifying the user and prompting for corrected commands.
4. When the CLI exits, stop sending commands, close socket handles, and clean up temp files.
