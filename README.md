# numb.nvim

numb.nvim is a Neovim plugin that peeks lines of the buffer in non-obtrusive
way.

## Features

Peeking the buffer while entering command `:{number}`

![demo](https://gist.githubusercontent.com/nacro90/d9fa04d88d3f757b9ba899fd38866405/raw/f5991c839a95ed92fcc3943f9b7853a0c620d018/demo.gif)

The colorscheme is [vim-substrata](https://github.com/arzg/vim-substrata)

## Installation

### Packer

```lua
use 'nacro90/numb.nvim'
```

### Paq

```lua
paq 'nacro90/numb.nvim'
```

### Plug

```viml
Plug 'nacro90/numb.nvim'
```

### Lazy.nvim

```lua
{
  'nacro90/numb.nvim',
}

-- or optionally pass `opts` to customize config
{
  'nacro90/numb.nvim',
  opts = {
    -- customizable config here, see Options below
  }
}
```

## Usage

Setup with default options:

```lua
require('numb').setup()
```

If you are using a init.vim instead of init.lua, you will need to load the plugin like this:

```Vimscript
:lua require('numb').setup()
```

Disable the plugin globally:

```lua
require('numb').disable()
```

You can also control the plugin at runtime through the `:Numb` user command,
which supports tab-completed subcommands:

```vim
:Numb disable   " stop peeking
:Numb enable    " resume peeking (preserves your config)
:Numb toggle    " flip the current state (default when no argument is given)
```

The matching Lua API is:

```lua
require('numb').disable()
require('numb').enable()
require('numb').is_enabled()           -- returns boolean
require('numb').is_peeking(winnr?)     -- returns boolean (current window if omitted)
```

`enable()` preserves the options previously passed to `setup{...}`, so you do
not need to re-call `setup()` after a `disable()`.

### Statusline Integration

While a peek is active, numb.nvim sets the window-local flag
`vim.w.numb_peeking = true`. The flag is cleared (set back to `nil`) as soon
as the peek ends, whether confirmed or aborted. The scope is **per window**
so two splits viewing the same buffer never cross-flag each other.

A minimal lualine component using the flag:

```lua
require('lualine').setup{
  sections = {
    lualine_x = {
      function() return vim.w.numb_peeking and 'peek' or '' end,
    },
  },
}
```

Programmatic consumers can call `require('numb').is_peeking()` instead.

### Options

You can customize the behaviour with following:

```lua
require('numb').setup{
  show_numbers = true, -- Enable 'number' for the window while peeking
  show_cursorline = true, -- Enable 'cursorline' for the window while peeking
  hide_relativenumbers = true, -- Enable turning off 'relativenumber' for the window while peeking
  number_only = false, -- Peek only when the command is only a number instead of when it starts with a number
  centered_peeking = true, -- Peeked line will be centered relative to window
}
```

After running `setup`, you are good to go. You can try with entering a number to
the vim command line like `:3`.

When you disable numb, your options are kept in the module level. So after you
disable it, calling `enable()` (or `setup()` again) restores the plugin with
your customized options. You can override the options at any time by calling
`setup{...}` again or by passing them to `enable{...}`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow: setup, coding style, testing, commit conventions, and changelog discipline. Before opening a pull request, run `scripts/check.sh` to ensure Stylua formatting, the headless smoke test, and the automated regression tests all pass.

## Changelog

Release history is tracked in [CHANGELOG.md](CHANGELOG.md) following the [Keep a Changelog](https://keepachangelog.com/) format.
