# prompty.nvim

Prompty is a NeoVim companion for the `prompt-maker-cli` / `pmc` toolkit. It
streams JSONL output into Markdown buffers, tracks telemetry, and lets you
iterate on prompts without leaving the editor.

> ⚙️ Requirements: NeoVim 0.9+ with `vim.uv`, and `prompt-maker-cli` available in
> your `$PATH` (or configured via `setup`).

---

## Installation

### lazy.nvim
```lua
{
  "yourname/prompty.nvim",
  cmd = { "Prompty", "PromptyVisual", "PromptyRefine" },
  keys = {
    { "<leader>pp", ":Prompty<CR>", mode = "n", desc = "Prompty" },
    { "<leader>pP", ":PromptyVisual<CR>", mode = "v", desc = "Prompty visual" },
    { "<leader>pr", ":PromptyRefine<CR>", mode = "n", desc = "Prompty refine" },
  },
  opts = {
    binary = "pmc",
    default_flags = { "--model", "sonnet" },
  },
}
```

### packer.nvim
```lua
use({
  "yourname/prompty.nvim",
  config = function()
    require("prompty").setup()
  end,
})
```

### Manual / plain runtimepath
```bash
cd ~/.config/nvim/pack/plugins/start
git clone https://github.com/yourname/prompty.nvim.git
```
Then add `require("prompty").setup()` in your `init.lua`.

---

## Quick Start

```vim
:Prompty Write a structured bug report template
```
- Streams Markdown into the "Prompty Output" buffer.
- Watch `:messages` for telemetry (token usage, progress).

```vim
:'<,'>PromptyVisual
```
- Highlight code or prose, then run to seed the intent with the selection.

```vim
:PromptyRefine tighten voice + add CTA
```
- Sends refinements over the active interactive transport.

Use the refine buffer (opened automatically once transport is ready) to jot
instructions, then run `:PromptyRefine` without arguments—its contents will be
sent as JSON `{ "type": "refine", "instruction": "..." }`.

---

## Configuration

```lua
require("prompty").setup({
  binary = "prompt-maker-cli", -- or absolute path
  default_flags = { "--model", "gpt-4o" },
  temp_dir = vim.fn.stdpath("run") .. "/prompty",
  keymaps = {
    prompt = "<leader>pp",
    prompt_visual = "<leader>pP",
    refine = "<leader>pr",
  },
})
```

| Option              | Description |
| ------------------- | ----------- |
| `binary`            | Executable name/path for `prompt-maker-cli`. Warns if not found. |
| `default_flags`     | Extra flags appended to every run (model, templates, etc.). |
| `temp_dir`          | Where interactive socket files are created. |
| `keymaps.*`         | Normal/visual bindings for the exposed commands. |
| `notifications`     | Toggle `vim.notify` messages for telemetry/errors. |

Any `generate()` call can still pass `flags`, `context`, `urls`, or
`smart_context = true` on demand.

---

## Snacks Picker Integration

Snacks exposes a flexible picker UI; Prompty can tap into it by collecting
intent text before spawning the CLI:

```lua
local prompty = require("prompty")
local snacks = require("snacks")

local function prompty_from_picker()
  snacks.picker.prompt({
    title = "Prompty Intent",
    on_submit = function(query)
      prompty.generate({ intent = query })
    end,
  })
end

vim.keymap.set("n", "<leader>sp", prompty_from_picker, { desc = "Prompty via Snacks" })
```

For file pickers, gather selection paths and pass them as `context`:
```lua
snacks.picker.git_files({
  multi = true,
  on_submit = function(items)
    local ctx = vim.tbl_map(function(item)
      return item.file
    end, items)
    prompty.generate({ intent = "Summarize selected files", context = ctx })
  end,
})
```

---

## Enhancements & Workflow Ideas
- **Snapshot buffers:** Write output to a named scratch buffer using
  `:saveas` to keep prompt iterations.
- **Autocommands:** Trigger `PromptyRefine` on `BufWritePost` for an "explain
  my latest edits" automation.
- **Context stacks:** Pair with plugins like `snacks.picker.buffers` or `telescope`
  to collect `--context` files before calling `prompty.generate`.
- **Statusline hooks:** Display `prompty.nvim` telemetry (tokens, progress) via your
  statusline by reading `vim.g.prompty_last_stats` (expose in your config).

---

## Philosophy of Use
- **Editor-first flow:** Keep intent, context, and refinement in buffers so the
  generated prompt remains auditable.
- **Iterative refinement:** Treat `:PromptyRefine` as a conversation. Short,
  focused instructions yield clearer diffs from the model.
- **Context awareness:** Prefer passing targeted files or URLs instead of entire
  repos to control token budgets and latency.
- **Composable tooling:** Prompty should stitch into your existing picker, LSP,
  and snippets workflow—avoid bespoke UI whenever native NeoVim affordances
  already exist.
- **Observability:** Watch telemetry notifications; they surface token counts
  and progress so you can manage cost/perf tradeoffs in real time.

Have an idea to enhance the experience? Open an issue or PR—examples include
support for additional telemetry sinks, richer virtual text, or adapters for
other prompt tooling ecosystems.
