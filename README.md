# VimJS - a JavaScript helper plugin for Vim

VimJS parses .js files and adds scope-aware identifier highlighting, basic refactoring (renaming a variable/function) and navigation.

VimJS uses a [slightly modified](https://github.com/rojer/slimit) parser from the [slimit JS minifier](https://github.com/rspivak/slimit).

## Installation

* Fetch the [Vimball archive](https://raw.githubusercontent.com/rojer/vimjs/master/vimjs.vmb)
* Open it in Vim
* :source %

You should see output from Vimball about installed files and from now on, the plugin will be loaded whenever a .js file is opened.

Note: Because parsing can be somewhat slow, especially on larger files, it starts disabled by default and needs to be enabled .

Short video, demonstrating installation and basic use: http://youtu.be/xLrv2rF9Gpg
Slightly longer (2 minute) editing session: http://youtu.be/WjKxtT1kJ6k

Key bindings:

* Ctrl-E + E - enable/disable the plugin.

When plugin is enabled, placing the cursor within an identifier (variable or function name) will highlight other references to it.
At this time, the following additional functions become available:

* Ctrl-E + R          - rename the variable/function
* Ctrl-E + Left/Up    - jump the previous occurence of the identifier
* Ctrl-E + Right/Down - jump the next occurence of the identifier
