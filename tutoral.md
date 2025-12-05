# Prompty Tutorial

Prompty brings the `prompt-maker-cli` workflow straight into NeoVim so you can iterate on prompts without leaving your editor. This tutorial collects concrete examples that you can copy into your config or command line to explore every surface area of the plugin.

## Requirements checklist

- NeoVim 0.10+ with `vim.uv` available.
- `prompt-maker-cli` (a.k.a. `pmc`) installed globally or built locally and placed on your `$PATH`.
- API credentials exported (`OPENAI_API_KEY`, `GEMINI_API_KEY`, optional `GITHUB_TOKEN`) or configured in `~/.config/prompt-maker-cli/config.json`.
- Optional: `plenary.nvim` cloned next to this repo when running the test suite.

## Installing the plugin

### lazy.nvim

```lua
{
  "edward-r/prompty.nvim",
  cmd = { "Prompty", "PromptyVisual", "PromptyRefine" },
  keys = {
    { "<leader>pp", ":Prompty<CR>", mode = "n", desc = "Prompty" },
    { "<leader>pP", ":PromptyVisual<CR>", mode = "v", desc = "Prompty visual" },
    { "<leader>pr", ":PromptyRefine<CR>", mode = "n", desc = "Prompty refine" },
  },
  opts = {
    binary = "prompt-maker-cli",
    default_flags = { "--model", "sonnet" },
  },
}
```

### packer.nvim

```lua
use({
  "edward-r/prompty.nvim",
  config = function()
    require("prompty").setup()
  end,
})
```

### Manual runtimepath install

```bash
cd ~/.config/nvim/pack/plugins/start
git clone https://github.com/edward-r/prompty.nvim.git
```

Add `require("prompty").setup()` to your `init.lua` to finish wiring it up.

## Minimal configuration

```lua
require("prompty").setup({
  binary = "prompt-maker-cli",
  default_flags = { "--model", "gpt-4o-mini", "--context-template", "nvim" },
  temp_dir = vim.fn.stdpath("run") .. "/prompty",
  notifications = true,
  keymaps = {
    prompt = "<leader>pp",
    prompt_visual = "<leader>pP",
    refine = "<leader>pr",
  },
})
```

- Set `binary` when the CLI lives outside `$PATH`.
- Use `default_flags` to enforce models, templates, or verbosity flags across every run.
- Change `temp_dir` when you want transports created under `/tmp` or a RAM disk.
- Toggle `notifications` if you prefer silent telemetry.

## First runs inside NeoVim

### Launching a prompt on demand

```vim
:Prompty Draft a product update brief for v2.3
```

- Streams Markdown into the "Prompty Output" buffer.
- Telemetry (tokens, progress) appears in `:messages` and via `vim.notify` when enabled.

### Prompting without inline text

```vim
:Prompty
```

When no intent is given, Prompty asks you interactively for one via the command line prompt.

### Seeding with selected text

1. Highlight code or prose in visual mode.
2. Run `:'<,'>PromptyVisual` (or press your configured mapping).
3. The selected text becomes the intent passed to the CLI, perfect for “rewrite this block” flows.

### Refining iteratively

```vim
:Prompty Produce a concise changelog entry
" Wait for "Prompty transport ready" notification.
:PromptyRefine tighten tone + add release date
:PromptyRefine  # (with no args) sends whatever is in the refine buffer
```

- The refine buffer opens automatically once the CLI announces that the interactive transport is listening.
- Call `:lua require("prompty").finish()` whenever you want to end the active session without killing the process.

## Programmatic Lua usage

Use the module directly for scripted flows or custom commands:

```lua
local prompty = require("prompty")

prompty.generate({
  intent = "Summarize the current buffer",
  context = { vim.api.nvim_buf_get_name(0) },
  flags = { "--model", "gpt-4o", "--json" },
})
```

### Binding custom commands

```lua
vim.api.nvim_create_user_command("PromptyExplainErrors", function()
  local file = vim.api.nvim_buf_get_name(0)
  prompty.generate({
    intent = "Explain the failing tests in this file",
    context = { file },
    smart_context = true,
    flags = { "--smart-context-root", vim.loop.cwd() },
  })
end, { desc = "Ask Prompty to explain failures" })
```

### Triggering Prompty on save

```lua
vim.api.nvim_create_autocmd("BufWritePost", {
  pattern = "*.md",
  callback = function(args)
    prompty.generate({
      intent = "Polish the newsletter draft in " .. args.file,
      context = { args.file },
      flags = { "--polish" },
    })
  end,
})
```

### Sending refinements from Lua

```lua
vim.api.nvim_create_user_command("PromptyCTA", function()
  prompty.refine("Add a crisp call to action and highlight the deadline")
end, {})
```

## Attaching context & flags

### Local files

```lua
prompty.generate({
  intent = "Summarize the migration plan",
  context = {
    vim.fn.expand("%"),
    vim.fn.stdpath("config") .. "/lua/plugins/migrations.lua",
  },
})
```

Each path becomes a `--context` flag behind the scenes, so you can pass one or many files per run.

### Remote URLs

```lua
prompty.generate({
  intent = "Summarize the latest API docs",
  urls = {
    "https://docs.example.com/api/overview",
    "https://raw.githubusercontent.com/org/repo/main/CHANGELOG.md",
  },
})
```

### Smart context (lightweight RAG)

```lua
prompty.generate({
  intent = "Propose improvements to the onboarding flow",
  smart_context = true,
  flags = {
    "--smart-context-root",
    vim.fn.stdpath("config"),
  },
})
```

Enabling `smart_context` tells `prompt-maker-cli` to embed files under the given root and attach the highest-value matches automatically.

### Mixing extra CLI flags

```lua
prompty.generate({
  intent = "Draft release notes",
  flags = {
    "--model", "gpt-4o-mini",
    "--context-template", "nvim",
    "--quiet",
  },
})
```

Provide any additional CLI switches through the `flags` array when you need one-off overrides.

## Media-aware prompts (CLI-side)

If you launch Prompty from the terminal, you can still reuse its defaults:

```bash
prompt-maker-cli "Describe this UI" \
  --image ~/Screenshots/mockup.png \
  --json --quiet --context-template nvim
```

Pair these runs with `:e ~/Prompty\ Output.md` to inspect the rendered prompt inside NeoVim.

## Integrations & workflow ideas

### Snacks picker for free-form intents

```lua
local prompty = require("prompty")
local snacks = require("snacks")

local function prompty_from_picker()
  snacks.picker.prompt({
    title = "Prompty Intent",
    on_submit = function(query)
      prompty.generate({ intent = query, smart_context = true })
    end,
  })
end

vim.keymap.set("n", "<leader>sp", prompty_from_picker, { desc = "Prompty via Snacks" })
```

### Feeding picker selections as context

```lua
snacks.picker.git_files({
  multi = true,
  on_submit = function(items)
    local ctx = vim.tbl_map(function(item)
      return item.file
    end, items)
    prompty.generate({
      intent = "Summarize selected files",
      context = ctx,
    })
  end,
})
```

### Snapshotting output buffers

After a run finishes, execute:

```vim
:saveas ~/prompt-archives/feature-brief.md
```

This lets you maintain a versioned library of prompts for auditors or teammates.

### Telemetry in the statusline

Expose the latest stats captured by Prompty:

```lua
local function prompty_status()
  local stats = vim.g.prompty_last_stats
  if not stats then
    return ""
  end
  return string.format("󰍉 %st | %s files", stats.totalTokens or "?", #stats.files or 0)
end
```

### Progress-driven notifications

All `progress.update` and `context.telemetry` events flow through `vim.notify` when `notifications = true`. To hook into your own UI, override `vim.notify` temporarily or collect stats from `vim.g.prompty_last_stats` (set by `prompty.ui`).

## Observing and managing sessions

- `:lua require("prompty").active_session()` returns the current session object when you need to inspect or cancel it.
- `:lua require("prompty").finish()` sends `{ "type": "finish" }` over the socket and closes the transport gracefully.
- `:lua require("prompty").refine("shorten paragraphs")` keeps you in Lua land for repeated refinements.

## Troubleshooting tips

- **CLI not found**: run `:echo vim.fn.executable("prompt-maker-cli")`—`0` means you need to install or update `binary` in your config.
- **Missing credentials**: look for stderr notifications about `ensureModelCredentials`; set `OPENAI_API_KEY`/`GEMINI_API_KEY` or edit `~/.config/prompt-maker-cli/config.json`.
- **Intent required**: Prompty warns when no intent text is present. Provide arguments or let it prompt for one.
- **Stale sockets**: set `temp_dir` to a writable path and make sure it exists (Prompty creates it automatically, but permissions issues can block transports).
- **Large context sets**: watch token summaries in `:messages`; trim context or rely on `smart_context` when totals exceed your target budget.
- **Transport disconnects**: if `PromptyRefine` fails with "No active Prompty session", start a new `:Prompty` run—the previous session ended or timed out.

Armed with these examples, you can slot Prompty into personalized keymaps, pickers, and automation flows while still leaning on the `prompt-maker-cli` toolchain for consistent results.
