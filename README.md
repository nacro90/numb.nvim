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

After you disable the plugin, you can re-enable it by calling the `setup` again.

### Options

You can customize the behaviour with following:

```lua
require('numb').setup{
   show_numbers = true, -- Enable 'number' for the window while peeking
   show_cursorline = true -- Enable 'cursorline' for the window while peeking
   number_only = false, -- Peek only when the command is only a number instead of when it starts with a number
}
```

After running `setup`, you are good to go. You can try with entering a number to
the vim command line like `:3`.

When you disable numb, your options are kept in the module level. So after you
disable it, if you call `setup()` with no overrides, numb will be enabled with
your customized options (or default ones if you don't have any). You can
override the options again with calling `setup{...}` as mentioned above.
