# numb.nvim

numb.nvim is a Neovim plugin that peeks lines of the buffer in non-obtrusive
way.

## Features

- Peeking buffer while entering command `:{number}`

![demo](assets/demo.gif)

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

### Options

You can customize the behaviour with following:

```lua
require('numb').setup{
   show_numbers = true, -- Enable 'number' for the window while peeking
   show_cursorline = true -- Enable 'cursorline' for the window while peeking
}
```

After running `setup`, you are good to go. You can try with entering a number to
the vim command line like `:3`.
