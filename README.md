<h1 align="center">numb.nvim</h1>

<p align="center">
  Peek lines of the buffer while you type <code>:{number}</code>, and jump only when you mean it.
</p>

<p align="center">
  <a href="https://github.com/nacro90/numb.nvim/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/nacro90/numb.nvim/actions/workflows/ci.yml/badge.svg"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
  <img alt="Neovim 0.10+" src="https://img.shields.io/badge/neovim-0.10%2B-green?logo=neovim&logoColor=white">
</p>

![demo](https://gist.githubusercontent.com/nacro90/d9fa04d88d3f757b9ba899fd38866405/raw/f5991c839a95ed92fcc3943f9b7853a0c620d018/demo.gif)

<p align="center">
  <sub>Colorscheme: <a href="https://github.com/arzg/vim-substrata">vim-substrata</a></sub>
</p>

Typing `:120` in Vim is a blind jump: you lose your place, look around, and press
`<C-o>` to crawl back. numb.nvim previews the destination as you type it. Confirm
with `<CR>` and you are there, abort with `<Esc>` and the window goes back to the
cursor position, the window options and the vertical scroll position it had.

## Features

- **Peek numeric Ex addresses.** Absolute (`:15`), relative (`:+5`, `:-3`),
  chained (`:++`), the line symbols `:.` and `:$`, and arithmetic on any of them
  (`:.+5`, `:$-3`, `:10-2`). Out of bounds targets clamp to the first or last
  line instead of erroring. Marks and searches (`:'a`, `:/foo/`) are left to Vim
  and are not previewed.
- **Preview destructive ranges.** `:50,80d` highlights lines 50 to 80 before you
  commit. Neovim previews `:substitute` through `inccommand` and nothing else, so
  `:d`, `:y`, `:m`, `:t` and `:g` had no preview at all.
- **Faithful to Ex semantics.** Both separators are honored (`,` counts from the
  cursor, `;` from the previous address), and when more than two addresses are
  given the last two win, so `:5,10,15d` highlights the 10 to 15 that Ex will
  really act on.
- **Stays out of the way.** Per window state, folds unfolded so the target is
  really on screen, the jumplist entry pushed so `<C-o>` still works, and no
  runtime dependencies.
- **Batteries included.** `:Numb` to toggle at runtime, `vim.w.numb_peeking` for
  your statusline, `:checkhealth numb` when something looks off, and `:h numb`
  for the full reference.

## Requirements

Neovim 0.10 or newer. Nothing else; numb.nvim uses only stock Neovim and Lua.

## Installation

numb.nvim calls `setup()` itself from `plugin/numb.lua`, so it starts working as
soon as it is on your `runtimepath`. Passing options is the only reason to call
`setup()` yourself.

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ 'nacro90/numb.nvim' }

-- or, to change the defaults
{
  'nacro90/numb.nvim',
  opts = {
    centered_peeking = false,
  },
}
```

With `vim.pack`, the manager built into Neovim 0.12:

```lua
vim.pack.add {
  'https://github.com/nacro90/numb.nvim',
}
```

<details>
<summary>Pinning a version, and other plugin managers</summary>

`vim.pack.add` also takes a table with a `version` field, which accepts a branch,
a tag, a commit hash, or a range built with `vim.version.range()`:

```lua
vim.pack.add {
  { src = 'https://github.com/nacro90/numb.nvim', version = vim.version.range('1.x') },
}
```

[Paq](https://github.com/savq/paq-nvim):

```lua
paq 'nacro90/numb.nvim'
```

[vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'nacro90/numb.nvim'
```

Packer is no longer maintained and its repository is archived. Use it only if
your config already depends on it:

```lua
use 'nacro90/numb.nvim'
```

</details>

## Usage

Type a line address on the command line and watch the buffer follow along:

```vim
:3
:+12
:$-5
:80,120d
```

Nothing has to be called for that: `plugin/numb.lua` already ran `setup()`. From
an `init.vim`, pass options through `:lua` when you want to change them:

```vim
:lua require('numb').setup{ centered_peeking = false }
```

### Options

Every option may be omitted; the rest keep their defaults.

| Option | Default | Effect |
| --- | --- | --- |
| `show_numbers` | `true` | Set `number` in the peeked window |
| `show_cursorline` | `true` | Set `cursorline` in the peeked window |
| `hide_relativenumbers` | `true` | Turn `relativenumber` off, so the numbers stop shifting |
| `number_only` | `false` | Peek only when the command line is nothing but an address, so `:15` peeks and `:15,20d` does not |
| `centered_peeking` | `true` | Center the previewed line, as `zz` does |
| `range_peek` | `true` | Highlight the whole range while typing `:N,M{cmd}` |
| `disable_for_buftype` | `{}` | `buftype` values to leave alone, for example `{ 'terminal' }` |
| `disable_for_filetype` | `{}` | `filetype` values to leave alone, for example `{ 'fugitive' }` |

```lua
require('numb').setup {
  show_numbers = true,
  show_cursorline = true,
  hide_relativenumbers = true,
  number_only = false,
  centered_peeking = true,
  range_peek = true,
  disable_for_buftype = {},
  disable_for_filetype = {},
}
```

Nothing is excluded by default, terminal buffers included: Vim performs `:15` in
a terminal buffer exactly as it does anywhere else, so excluding one means
accepting a jump that happens with nothing shown before it. Exclude a type when
that is the trade you want.

A misspelled option name, or a value of the wrong type, is reported through
`vim.notify` and ignored. Invalid configuration never raises: the affected
option keeps its default and the rest of your table is applied as usual.

### Runtime control

```vim
:Numb disable   " stop peeking
:Numb enable    " resume peeking with the configuration already in effect
:Numb toggle    " flip the current state (the default when no argument is given)
```

Subcommands are tab completed. The same operations from Lua:

```lua
require('numb').enable(opts?)  -- opts is optional and overrides the config
require('numb').disable()
require('numb').is_enabled()   -- boolean
require('numb').is_peeking(winnr?) -- boolean, current window when omitted
require('numb').get_config()   -- a copy of the active options
```

Your options survive a `disable()`, so `enable()` resumes with them and there is
no need to call `setup()` again.

To keep the plugin from loading at all, set the guard variable before startup:

```lua
vim.g.loaded_numb = 1
```

### The range highlight

The range preview uses the `NumbRange` highlight group, linked to `Visual` by
default. Override it whenever you like, before or after `setup()`:

```lua
vim.api.nvim_set_hl(0, 'NumbRange', { bg = '#3a3a50' })
```

A highlight belongs to a buffer rather than a window, so the range shows up in
every split displaying that buffer. The cursor, the window options and
`vim.w.numb_peeking` stay per window.

### Statusline integration

While a peek is active, numb.nvim sets `vim.w.numb_peeking = true` in that
window, and clears it as soon as the peek ends, whether confirmed or aborted.
The scope is the window, so two splits viewing the same buffer never cross-flag
each other.

```lua
require('lualine').setup {
  sections = {
    lualine_x = {
      function() return vim.w.numb_peeking and 'peek' or '' end,
    },
  },
}
```

`require('numb').is_peeking()` answers the same question from Lua.

## Troubleshooting

Run `:checkhealth numb`. It reports the Neovim version, where numb.nvim was
loaded from, whether a second copy is shadowing it on the `runtimepath`, whether
`setup()` ran, whether the autocommands are still installed, and the
configuration currently in effect, so a pasted report is self-contained.

## Documentation

`:h numb` covers everything above in reference form, option by option and
function by function.

## Contributing

Contributions are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) has the full
workflow: layout, coding style, tests, commit conventions and changelog
discipline. In short, run `./scripts/check.sh` before opening a pull request and
add a test for whatever you changed.

Release history lives in [CHANGELOG.md](CHANGELOG.md), following
[Keep a Changelog](https://keepachangelog.com/).

## License

[MIT](LICENSE)
