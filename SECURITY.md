# Security Policy

## Scope

numb.nvim is a small Neovim plugin. It has no runtime dependencies outside
stock Neovim and Lua, makes no network requests, spawns no subprocesses, reads
and writes no files, and handles no credentials. The realistic attack surface
is therefore narrow.

The one class of issue that is clearly in scope is **untrusted text reaching a
parser**. numb.nvim reads whatever you type on the command line and parses it
for line numbers and arithmetic. An earlier version evaluated that expression
with `load()`; it was replaced with a manual parser precisely to remove the
code-execution path. Reports of a way to get arbitrary code executed, to crash
Neovim, or to make the plugin leave the editor in a broken state through
crafted command-line input, a crafted buffer name, or crafted configuration are
welcome.

Also in scope:

- Anything that causes numb.nvim to execute code the user did not write.
- Anything that lets a repository influence Neovim's behavior through this
  plugin just by being opened (for example, via a project-local config path).

Out of scope:

- Vulnerabilities in Neovim itself. Report those to
  [neovim/neovim](https://github.com/neovim/neovim/security).
- Vulnerabilities in other plugins, even when numb.nvim is in the stack. If the
  interaction is the bug, a normal issue is the right place.
- Anything that requires the user to deliberately run malicious Lua, which they
  could do without this plugin.

## Supported Versions

Only the latest release is supported. Fixes ship in a new release; older tags
are not patched.

## Reporting a Vulnerability

Please report privately, not in a public issue:

1. Go to the [Security advisories](https://github.com/nacro90/numb.nvim/security/advisories/new)
   page and open a private vulnerability report.
2. Include the Neovim version, the numb.nvim version, a minimal
   `minimal_init.lua`, and the exact input needed to trigger the problem.

If GitHub private vulnerability reporting is unavailable to you, contact the
maintainer through their GitHub profile at
[https://github.com/nacro90](https://github.com/nacro90) and ask for a private
channel; do not include the details in a public message.

## What to Expect

This is a spare-time project maintained by one person, so there is no service
level agreement. Realistically:

- An acknowledgement once the report has been read.
- An assessment of whether it is in scope and how severe it looks.
- For a confirmed, in-scope issue, a fix in the next release, and credit in the
  advisory and `CHANGELOG.md` unless you prefer otherwise.

If a report goes unanswered for a few weeks, a polite public ping asking for
attention on an unspecified private report is fine; please still keep the
details out of it.
