" Vimball Archiver by Charles E. Campbell, Jr., Ph.D.
UseVimball
finish
ftplugin/javascript_vimjs.vim	[[[1
322
" Copyright 2015 Deomid 'rojer' Ryabkov
"
" Licensed under Apache License, Version 2.0.
" See the accompanying LICENSE file.
"
" https://github.com/rojer/vimjs

if !has('python')
  echo "Error: Required vim compiled with +python"
  finish
endif

if exists("g:loaded_vimjs")
  finish
endif
let g:loaded_vimjs = 1


fu! s:HighlightJSInit()

  exec 'highlight link JSError ErrorMsg'
  exec 'highlight link JSWarning SpellBad'
  exec 'highlight link JSVar MatchParen'

  augroup HighlightJS
    autocmd!
      au BufReadPost   *.js call <SID>ParseJS()
      au BufWritePost  *.js call <SID>ParseJS()
      au CursorMoved   *.js call <SID>HighlightJS()
      au CursorMovedI  *.js call <SID>HighlightJS()
  augroup END
  
  noremap <silent> <C-e>e       :call <SID>ToggleHighlightJS()<CR>
  noremap <silent> <C-e>r       :call <SID>RenameJSVar()<CR>

  noremap <silent> <C-e><Left>  :call <SID>HighlightPreviousJSVar()<CR>
  noremap <silent> <C-e><Up>    :call <SID>HighlightPreviousJSVar()<CR>
  noremap <silent> <C-e><Right> :call <SID>HighlightNextJSVar()<CR>
  noremap <silent> <C-e><Down>  :call <SID>HighlightNextJSVar()<CR>

  python <<EOF
import vim

# import sys
# sys.path.append('/home/rojer/vimjs/slimit/src')

from slimit import ast
from slimit import scope
from slimit import parser
from slimit.visitors import nodevisitor
from slimit.visitors import scopevisitor

# buffer name -> State
buffer_state = {}
enabled = False


class State(object):
  def __init__(self):
    self.parse_seq = -1
    self.render_seq = -1
    self.rendered_line_range = (-1, -1)
    self.warnings = []
    self.errors = []
    self.var_map = {}
    self.cur_hl_node = None
    self.implicit_globals = []


# TODO(rojer): This should come from some standard JS library function list.
OK_GLOBALS = frozenset([
  'window', 'document', 'navigator',
  'JSON', 'Math', 'XMLHttpRequest',
  'chrome', 'console',
  'localStorage',
  '$',  # jQuery object.
  'Array', 'atob', 'Blob', 'Uint8Array', 'setTimeout', 'encodeURIComponent',
  'parseInt', 'clearTimeout', 'encodeURI',
]);


def _GetUndoSeq():
  return int(vim.eval('undotree()["seq_cur"]'))


def _GetState():
  state = buffer_state.get(vim.current.buffer.name)
  if state:
    return state
  return State()


def MaybeParse():
  if not enabled: return
  if not vim.current.buffer.name.endswith('.js'): return
  state = _GetState()
  if state.parse_seq == _GetUndoSeq():
    return
  state = _Parse()
  state.parse_seq = _GetUndoSeq()
  buf_name = vim.current.buffer.name
  buffer_state[buf_name] = state
  MaybeRender()


def _Parse():
  state = State()
  p = parser.Parser()
  try:
    tree = p.parse('\n'.join(vim.current.buffer))
  except SyntaxError, e:
    print 'bad syntax:', str(e)
    return state

  sym_table = scope.SymbolTable()
  visitor = scopevisitor.ScopeTreeVisitor(sym_table)
  visitor.visit(tree)

  visitor = nodevisitor.NodeVisitor()
  for node in visitor.visit(tree):
    if (not isinstance(node, ast.Identifier) or
        not getattr(node, '_mangle_candidate', False)):
      continue
    name = node.value
    symbol = node.scope.resolve(name)
    if symbol is None: # and isinstance(node.scope, scope.GlobalScope):
      # This is Javascript, undeclared globals are ok. We treat them as global vars,
      # though it's not completely true.
      symbol = scope.VarSymbol(name=name)
      sym_table.globals.define(symbol)
      state.implicit_globals.append(symbol)
    node.symbol = symbol
    symbol.nodes.append(node)

    line, col_start = node.pos
    col_end = col_start + len(name)
    state.var_map.setdefault(line, []).append((col_start, col_end, node))

  return state


def _GetNodeUnderCursor(state):
  cursor_line, cursor_col = vim.current.window.cursor
  cursor_col += 1  # Zero-based.

  line_nodes = state.var_map.get(cursor_line, [])
  for node_col_start, node_col_end, node in line_nodes:
    if (cursor_col >= node_col_start and
        cursor_col < node_col_end):
      return node
  return None


def _HighLightNode(node, hl):
  line, col = node.pos
  vim.command(r'call matchadd("%s", "' % hl +
              r'\\%' + str(line) + 'l' +
              r'\\%' + str(col) + 'c' + ('.' * len(node.value)) + r'")')


def _PointCursorAtNode(node):
  vim.current.window.cursor = (node.pos[0], node.pos[1] - 1)
  MaybeRender()


def MaybeRender():
  if not enabled: return
  if not vim.current.buffer.name.endswith('.js'): return

  state = _GetState()
  cur_seq = _GetUndoSeq()
  if state.parse_seq != cur_seq:
    vim.command('call clearmatches()')
    return  # Wait for parsing to catch up.

  redraw = (state.render_seq != cur_seq)

  hl_node = _GetNodeUnderCursor(state)
  if hl_node != state.cur_hl_node:
    redraw = True
  state.cur_hl_node = hl_node

  cur_line = vim.current.window.cursor[0]
  if (cur_line - state.rendered_line_range[0] <= vim.current.window.height or
      state.rendered_line_range[1] - cur_line <= vim.current.window.height):
    redraw = True

  if not redraw: return

  vim.command('call clearmatches()')

  render_window_size = max(10, int(vim.current.window.height * 1.5))
  render_from = int(cur_line - render_window_size)
  render_to = int(cur_line + render_window_size)
  def _InLineRange(node):
    return node.pos[0] >= render_from and node.pos[0] <= render_to

  for sym in state.implicit_globals:
    for node in sym.nodes:
      if _InLineRange(node) and node.value not in OK_GLOBALS:
        _HighLightNode(node, 'JSWarning')

  if state.cur_hl_node:
    state.cur_hl_node.symbol.nodes.sort(key=lambda a: a.pos)
    for node in state.cur_hl_node.symbol.nodes:
      if _InLineRange(node):
        _HighLightNode(node, 'JSVar')

  state.render_seq = cur_seq
  state.rendered_line_range = (render_from, render_to)


def RenameVar():
  if not vim.current.buffer.name.endswith('.js'): return
  if not enabled:
    print 'JS highlighting is disabled, enable it first.'
    return
  state = _GetState()
  if not state.cur_hl_node:
    print 'Point cursor at the variable to rename.'
    return
  var_name = state.cur_hl_node.value
  vim.command(r'call inputsave()')
  new_name = vim.eval(r'input("New name for \"%s\": ")' % var_name)
  vim.command(r'call inputrestore()')
  vim.command(r'call clearmatches()')
  print
  if new_name:
    num_replaced = 0
    prev_line = -1
    buf = vim.current.buffer
    for node in state.cur_hl_node.symbol.nodes:
      assert node.value == var_name, '%s vs %s' % (node.value, var_name)
      line = node.pos[0]
      if line != prev_line:
        assert line > prev_line
        col_offset = 0
        prev_line = line
      col_start = node.pos[1] + col_offset
      col_end = col_start + len(node.value)

      line0, col_start0, col_end0 = line-1, col_start-1, col_end-1
      new_line = buf[line0][:col_start0] + new_name + buf[line0][col_end0:]
      col_offset += (len(new_name) - len(node.value))
      buf[line0] = new_line

      node.value = new_name
      node.pos = (line, col_start)
      num_replaced += 1
    print '%d replacements made.' % num_replaced
    MaybeParse()
    _PointCursorAtNode(state.cur_hl_node)

MaybeParse()

EOF

endfu

fu! s:ParseJS()
  python <<EOF
MaybeParse()
EOF
endfu

fu! s:HighlightJS()
  python <<EOF
MaybeRender()
EOF
endfu

fu! s:ToggleHighlightJS()
  python <<EOF
if enabled:
  enabled = False
  vim.command('call clearmatches()')
else:
  enabled = True
  MaybeParse()
  MaybeRender()
EOF
endfu

fu! s:RenameJSVar()
  python <<EOF
RenameVar()
EOF
endfu

fu! s:HighlightPreviousJSVar()
  python <<EOF
state = _GetState()
if state.cur_hl_node:
  prev_node = None
  sym_nodes = state.cur_hl_node.symbol.nodes
  for node in sym_nodes:
    if node == state.cur_hl_node:
      if not prev_node:
        prev_node = sym_nodes[-1]
      break
    prev_node = node
  _PointCursorAtNode(prev_node)
EOF
endfu

fu! s:HighlightNextJSVar()
  python <<EOF
state = _GetState()
if state.cur_hl_node:
  prev_node = None
  sym_nodes = state.cur_hl_node.symbol.nodes
  for node in sym_nodes:
    if prev_node == state.cur_hl_node:
      break
    prev_node = node
  else:
    node = sym_nodes[0]
  _PointCursorAtNode(node)
EOF
endfu

call <SID>HighlightJSInit()
python2/slimit/CREDIT	[[[1
27
Patches
-------

- Waldemar Kornewald
- Maurizio Sambati https://github.com/duilio
- Aron Griffis https://github.com/agriffis
- lelit https://github.com/lelit
- Dan McDougall https://github.com/liftoff
- harig https://github.com/harig
- Mike Taylor https://github.com/miketaylr


Bug reports
-----------

- Rui Pereira
- Dima Kozlov
- BadKnees https://github.com/BadKnees
- Waldemar Kornewald
- Michał Bartoszkiewicz https://github.com/embe
- Hasan Yasin Öztürk https://github.com/hasanyasin
- David K. Hess https://github.com/davidkhess
- Robert Cadena https://github.com/rcadena
- rivol https://github.com/rivol
- Maurizio Sambati https://github.com/duilio
- fdev31 https://github.com/fdev31
- edmellum https://github.com/edmellum
python2/slimit/LICENSE	[[[1
19
Copyright (c) 2011 Ruslan Spivak

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
python2/slimit/README.rst	[[[1
213
::

      _____ _      _____ __  __ _____ _______
     / ____| |    |_   _|  \/  |_   _|__   __|
    | (___ | |      | | | \  / | | |    | |
     \___ \| |      | | | |\/| | | |    | |
     ____) | |____ _| |_| |  | |_| |_   | |
    |_____/|______|_____|_|  |_|_____|  |_|

NOTE: Modified for VimJS -- https://github.com/rojer/slimit

Welcome to SlimIt
==================================

`SlimIt` is a JavaScript minifier written in Python.
It compiles JavaScript into more compact code so that it downloads
and runs faster.

`SlimIt` also provides a library that includes a JavaScript parser,
lexer, pretty printer and a tree visitor.

`http://slimit.readthedocs.org/ <http://slimit.readthedocs.org/>`_

Installation
------------

::

    $ [sudo] pip install slimit

Or the bleeding edge version from the git master branch:

::

    $ [sudo] pip install git+https://github.com/rspivak/slimit.git#egg=slimit


There is also an official DEB package available at
`http://packages.debian.org/sid/slimit <http://packages.debian.org/sid/slimit>`_


Let's minify some code
----------------------

From the command line:

::

    $ slimit -h
    Usage: slimit [options] [input file]

    If no input file is provided STDIN is used by default.
    Minified JavaScript code is printed to STDOUT.

    Options:
      -h, --help            show this help message and exit
      -m, --mangle          mangle names
      -t, --mangle-toplevel
                            mangle top level scope (defaults to False)

    $ cat test.js
    var foo = function( obj ) {
            for ( var name in obj ) {
                    return false;
            }
            return true;
    };
    $
    $ slimit --mangle < test.js
    var foo=function(a){for(var b in a)return false;return true;};

Or using library API:

>>> from slimit import minify
>>> text = """
... var foo = function( obj ) {
...         for ( var name in obj ) {
...                 return false;
...         }
...         return true;
... };
... """
>>> print minify(text, mangle=True, mangle_toplevel=True)
var a=function(a){for(var b in a)return false;return true;};


Iterate over, modify a JavaScript AST and pretty print it
---------------------------------------------------------

>>> from slimit.parser import Parser
>>> from slimit.visitors import nodevisitor
>>> from slimit import ast
>>>
>>> parser = Parser()
>>> tree = parser.parse('for(var i=0; i<10; i++) {var x=5+i;}')
>>> for node in nodevisitor.visit(tree):
...     if isinstance(node, ast.Identifier) and node.value == 'i':
...         node.value = 'hello'
...
>>> print tree.to_ecma() # print awesome javascript :)
for (var hello = 0; hello < 10; hello++) {
  var x = 5 + hello;
}
>>>

Writing custom node visitor
---------------------------

>>> from slimit.parser import Parser
>>> from slimit.visitors.nodevisitor import ASTVisitor
>>>
>>> text = """
... var x = {
...     "key1": "value1",
...     "key2": "value2"
... };
... """
>>>
>>> class MyVisitor(ASTVisitor):
...     def visit_Object(self, node):
...         """Visit object literal."""
...         for prop in node:
...             left, right = prop.left, prop.right
...             print 'Property key=%s, value=%s' % (left.value, right.value)
...             # visit all children in turn
...             self.visit(prop)
...
>>>
>>> parser = Parser()
>>> tree = parser.parse(text)
>>> visitor = MyVisitor()
>>> visitor.visit(tree)
Property key="key1", value="value1"
Property key="key2", value="value2"

Using lexer in your project
---------------------------

>>> from slimit.lexer import Lexer
>>> lexer = Lexer()
>>> lexer.input('a = 1;')
>>> for token in lexer:
...     print token
...
LexToken(ID,'a',1,0)
LexToken(EQ,'=',1,2)
LexToken(NUMBER,'1',1,4)
LexToken(SEMI,';',1,5)

You can get one token at a time using ``token`` method:

>>> lexer.input('a = 1;')
>>> while True:
...     token = lexer.token()
...     if not token:
...         break
...     print token
...
LexToken(ID,'a',1,0)
LexToken(EQ,'=',1,2)
LexToken(NUMBER,'1',1,4)
LexToken(SEMI,';',1,5)

`LexToken` instance has different attributes:

>>> lexer.input('a = 1;')
>>> token = lexer.token()
>>> token.type, token.value, token.lineno, token.lexpos
('ID', 'a', 1, 0)

Benchmarks
----------

**SAM** - JQuery size after minification in bytes (the smaller number the better)

+-------------------------------+------------+------------+------------+
| Original jQuery 1.6.1 (bytes) | SlimIt SAM | rJSmin SAM | jsmin SAM  |
+===============================+============+============+============+
| 234,995                       | 94,290     | 134,215    | 134,819    |
+-------------------------------+------------+------------+------------+

Roadmap
-------
- when doing name mangling handle cases with 'eval' and 'with'
- foo["bar"] ==> foo.bar
- consecutive declarations: var a = 10; var b = 20; ==> var a=10,b=20;
- reduce simple constant expressions if the result takes less space:
  1 +2 * 3 ==> 7
- IF statement optimizations

  1. if (foo) bar(); else baz(); ==> foo?bar():baz();
  2. if (!foo) bar(); else baz(); ==> foo?baz():bar();
  3. if (foo) bar(); ==> foo&&bar();
  4. if (!foo) bar(); ==> foo||bar();
  5. if (foo) return bar(); else return baz(); ==> return foo?bar():baz();
  6. if (foo) return bar(); else something(); ==> {if(foo)return bar();something()}

- remove unreachable code that follows a return, throw, break or
  continue statement, except function/variable declarations
- parsing speed improvements

Acknowledgments
---------------
- The lexer and parser are built with `PLY <http://www.dabeaz.com/ply/>`_
- Several test cases and regexes from `jslex <https://bitbucket.org/ned/jslex>`_
- Some visitor ideas - `pycparser <http://code.google.com/p/pycparser/>`_
- Many grammar rules are taken from `rkelly <https://github.com/tenderlove/rkelly>`_
- Name mangling and different optimization ideas - `UglifyJS <https://github.com/mishoo/UglifyJS>`_
- ASI implementation was inspired by `pyjsparser <http://bitbucket.org/mvantellingen/pyjsparser>`_

License
-------
The MIT License (MIT)
python2/slimit/ast.py	[[[1
419
###############################################################################
#
# Copyright (c) 2011 Ruslan Spivak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

__author__ = 'Ruslan Spivak <ruslan.spivak@gmail.com>'


class Node(object):
    def __init__(self, children=None):
        self._children_list = [] if children is None else children

    def __iter__(self):
        for child in self.children():
            if child is not None:
                yield child

    def children(self):
        return self._children_list

    def to_ecma(self):
        # Can't import at module level as ecmavisitor depends
        # on ast module...
        from slimit.visitors.ecmavisitor import ECMAVisitor
        visitor = ECMAVisitor()
        return visitor.visit(self)

class Program(Node):
    pass

class Block(Node):
    pass

class Boolean(Node):
    def __init__(self, value):
        self.value = value

    def children(self):
        return []

class Null(Node):
    def __init__(self, value):
        self.value = value

    def children(self):
        return []

class Number(Node):
    def __init__(self, value):
        self.value = value

    def children(self):
        return []

class Identifier(Node):
    def __init__(self, value, pos):
        self.value = value
        self.pos = pos

    def children(self):
        return []

    def __repr__(self):
      return '[%s @ %s]' % (self.value, self.pos)

class String(Node):
    def __init__(self, value):
        self.value = value

    def children(self):
        return []

class Regex(Node):
    def __init__(self, value):
        self.value = value

    def children(self):
        return []

class Array(Node):
    def __init__(self, items):
        self.items = items

    def children(self):
        return self.items

class Object(Node):
    def __init__(self, properties=None):
        self.properties = [] if properties is None else properties

    def children(self):
        return self.properties

class NewExpr(Node):
    def __init__(self, identifier, args=None):
        self.identifier = identifier
        self.args = [] if args is None else args

    def children(self):
        return [self.identifier, self.args]

class FunctionCall(Node):
    def __init__(self, identifier, args=None):
        self.identifier = identifier
        self.args = [] if args is None else args

    def children(self):
        return [self.identifier] + self.args

class BracketAccessor(Node):
    def __init__(self, node, expr):
        self.node = node
        self.expr = expr

    def children(self):
        return [self.node, self.expr]

class DotAccessor(Node):
    def __init__(self, node, identifier):
        self.node = node
        self.identifier = identifier

    def children(self):
        return [self.node, self.identifier]

class Assign(Node):
    def __init__(self, op, left, right):
        self.op = op
        self.left = left
        self.right = right

    def children(self):
        return [self.left, self.right]

class GetPropAssign(Node):
    def __init__(self, prop_name, elements):
        """elements - function body"""
        self.prop_name = prop_name
        self.elements = elements

    def children(self):
        return [self.prop_name] + self.elements

class SetPropAssign(Node):
    def __init__(self, prop_name, parameters, elements):
        """elements - function body"""
        self.prop_name = prop_name
        self.parameters = parameters
        self.elements = elements

    def children(self):
        return [self.prop_name] + self.parameters + self.elements

class VarStatement(Node):
    pass

class VarDecl(Node):
    def __init__(self, identifier, initializer=None):
        self.identifier = identifier
        self.identifier._mangle_candidate = True
        self.initializer = initializer

    def children(self):
        return [self.identifier, self.initializer]

class UnaryOp(Node):
    def __init__(self, op, value, postfix=False):
        self.op = op
        self.value = value
        self.postfix = postfix

    def children(self):
        return [self.value]

class BinOp(Node):
    def __init__(self, op, left, right):
        self.op = op
        self.left = left
        self.right = right

    def children(self):
        return [self.left, self.right]

class Conditional(Node):
    """Conditional Operator ( ? : )"""
    def __init__(self, predicate, consequent, alternative):
        self.predicate = predicate
        self.consequent = consequent
        self.alternative = alternative

    def children(self):
        return [self.predicate, self.consequent, self.alternative]

class If(Node):
    def __init__(self, predicate, consequent, alternative=None):
        self.predicate = predicate
        self.consequent = consequent
        self.alternative = alternative

    def children(self):
        return [self.predicate, self.consequent, self.alternative]

class DoWhile(Node):
    def __init__(self, predicate, statement):
        self.predicate = predicate
        self.statement = statement

    def children(self):
        return [self.predicate, self.statement]

class While(Node):
    def __init__(self, predicate, statement):
        self.predicate = predicate
        self.statement = statement

    def children(self):
        return [self.predicate, self.statement]

class For(Node):
    def __init__(self, init, cond, count, statement):
        self.init = init
        self.cond = cond
        self.count = count
        self.statement = statement

    def children(self):
        return [self.init, self.cond, self.count, self.statement]

class ForIn(Node):
    def __init__(self, item, iterable, statement):
        self.item = item
        self.iterable = iterable
        self.statement = statement

    def children(self):
        return [self.item, self.iterable, self.statement]

class Continue(Node):
    def __init__(self, identifier=None):
        self.identifier = identifier

    def children(self):
        return [self.identifier]

class Break(Node):
    def __init__(self, identifier=None):
        self.identifier = identifier

    def children(self):
        return [self.identifier]

class Return(Node):
    def __init__(self, expr=None):
        self.expr = expr

    def children(self):
        return [self.expr]

class With(Node):
    def __init__(self, expr, statement):
        self.expr = expr
        self.statement = statement

    def children(self):
        return [self.expr, self.statement]

class Switch(Node):
    def __init__(self, expr, cases, default=None):
        self.expr = expr
        self.cases = cases
        self.default = default

    def children(self):
        return [self.expr] + self.cases + [self.default]

class Case(Node):
    def __init__(self, expr, elements):
        self.expr = expr
        self.elements = elements if elements is not None else []

    def children(self):
        return [self.expr] + self.elements

class Default(Node):
    def __init__(self, elements):
        self.elements = elements if elements is not None else []

    def children(self):
        return self.elements

class Label(Node):
    def __init__(self, identifier, statement):
        self.identifier = identifier
        self.statement = statement

    def children(self):
        return [self.identifier, self.statement]

class Throw(Node):
    def __init__(self, expr):
        self.expr = expr

    def children(self):
        return [self.expr]

class Try(Node):
    def __init__(self, statements, catch=None, fin=None):
        self.statements = statements
        self.catch = catch
        self.fin = fin

    def children(self):
        return [self.statements] + [self.catch, self.fin]

class Catch(Node):
    def __init__(self, identifier, elements):
        self.identifier = identifier
        # CATCH identifiers are subject to name mangling. we need to mark them.
        self.identifier._mangle_candidate = True
        self.elements = elements

    def children(self):
        return [self.identifier, self.elements]

class Finally(Node):
    def __init__(self, elements):
        self.elements = elements

    def children(self):
        return self.elements

class Debugger(Node):
    def __init__(self, value):
        self.value = value

    def children(self):
        return []


class FuncBase(Node):
    def __init__(self, identifier, parameters, elements):
        self.identifier = identifier
        self.parameters = parameters if parameters is not None else []
        self.elements = elements if elements is not None else []
        self._init_ids()

    def _init_ids(self):
        # function declaration/expression name and parameters are identifiers
        # and therefore are subject to name mangling. we need to mark them.
        if self.identifier is not None:
            self.identifier._mangle_candidate = True
        for param in self.parameters:
            param._mangle_candidate = True

    def children(self):
        return [self.identifier] + self.parameters + self.elements

class FuncDecl(FuncBase):
    pass

# The only difference is that function expression might not have an identifier
class FuncExpr(FuncBase):
    pass


class Comma(Node):
    def __init__(self, left, right):
        self.left = left
        self.right = right

    def children(self):
        return [self.left, self.right]

class EmptyStatement(Node):
    def __init__(self, value):
        self.value = value

    def children(self):
        return []

class ExprStatement(Node):
    def __init__(self, expr):
        self.expr = expr

    def children(self):
        return [self.expr]

class Elision(Node):
    def __init__(self, value):
        self.value = value

    def children(self):
        return []

class This(Node):
    def __init__(self):
        pass

    def children(self):
        return []
python2/slimit/__init__.py	[[[1
25
###############################################################################
#
# Copyright (c) 2011 Ruslan Spivak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

__author__ = 'Ruslan Spivak <ruslan.spivak@gmail.com>'
python2/slimit/lexer.py	[[[1
439
###############################################################################
#
# Copyright (c) 2011 Ruslan Spivak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

__author__ = 'Ruslan Spivak <ruslan.spivak@gmail.com>'

import ply.lex

from slimit.unicode_chars import (
    LETTER,
    DIGIT,
    COMBINING_MARK,
    CONNECTOR_PUNCTUATION,
    )

# See "Regular Expression Literals" at
# http://www.mozilla.org/js/language/js20-2002-04/rationale/syntax.html
TOKENS_THAT_IMPLY_DIVISON = frozenset([
    'ID',
    'NUMBER',
    'STRING',
    'REGEX',
    'TRUE',
    'FALSE',
    'NULL',
    'THIS',
    'PLUSPLUS',
    'MINUSMINUS',
    'RPAREN',
    'RBRACE',
    'RBRACKET',
    ])


class Lexer(object):
    """A JavaScript lexer.

    >>> from slimit.lexer import Lexer
    >>> lexer = Lexer()

    Lexer supports iteration:

    >>> lexer.input('a = 1;')
    >>> for token in lexer:
    ...     print token
    ...
    LexToken(ID,'a',1,0)
    LexToken(EQ,'=',1,2)
    LexToken(NUMBER,'1',1,4)
    LexToken(SEMI,';',1,5)

    Or call one token at a time with 'token' method:

    >>> lexer.input('a = 1;')
    >>> while True:
    ...     token = lexer.token()
    ...     if not token:
    ...         break
    ...     print token
    ...
    LexToken(ID,'a',1,0)
    LexToken(EQ,'=',1,2)
    LexToken(NUMBER,'1',1,4)
    LexToken(SEMI,';',1,5)

    >>> lexer.input('a = 1;')
    >>> token = lexer.token()
    >>> token.type, token.value, token.lineno, token.lexpos
    ('ID', 'a', 1, 0)

    For more information see:
    http://www.ecma-international.org/publications/files/ECMA-ST/ECMA-262.pdf
    """
    def __init__(self):
        self.prev_token = None
        self.cur_token = None
        self.next_tokens = []
        self.build()

    def build(self, **kwargs):
        """Build the lexer."""
        self.lexer = ply.lex.lex(object=self, **kwargs)

    def input(self, text):
        self.lexer.input(text)

    def token(self):
        if self.next_tokens:
            return self.next_tokens.pop()

        lexer = self.lexer
        while True:
            pos = lexer.lexpos
            try:
                char = lexer.lexdata[pos]
                while char in ' \t':
                    pos += 1
                    char = lexer.lexdata[pos]
                next_char = lexer.lexdata[pos + 1]
            except IndexError:
                tok = self._get_update_token()
                if tok is not None and tok.type == 'LINE_TERMINATOR':
                    continue
                else:
                    return tok

            if char != '/' or (char == '/' and next_char in ('/', '*')):
                tok = self._get_update_token()
                if tok.type == 'LINE_TERMINATOR':
                    lexer.lineno += 1
                    continue
                elif tok.type in ('LINE_COMMENT', 'BLOCK_COMMENT'):
                    continue
                else:
                    return tok

            # current character is '/' which is either division or regex
            cur_token = self.cur_token
            is_division_allowed = (
                cur_token is not None and
                cur_token.type in TOKENS_THAT_IMPLY_DIVISON
                )
            if is_division_allowed:
                return self._get_update_token()
            else:
                self.prev_token = self.cur_token
                self.cur_token = self._read_regex()
                return self.cur_token

    def auto_semi(self, token):
        if (token is None or token.type == 'RBRACE'
            or self._is_prev_token_lt()
            ):
            if token:
                self.next_tokens.append(token)
            return self._create_semi_token(token)

    def _is_prev_token_lt(self):
        return self.prev_token and self.prev_token.type == 'LINE_TERMINATOR'

    def _read_regex(self):
        self.lexer.begin('regex')
        token = self.lexer.token()
        self.lexer.begin('INITIAL')
        return token

    def _get_update_token(self):
        self.prev_token = self.cur_token
        self.cur_token = self.lexer.token()
        # insert semicolon before restricted tokens
        # See section 7.9.1 ECMA262
        if (self.cur_token is not None
            and self.cur_token.type == 'LINE_TERMINATOR'
            and self.prev_token is not None
            and self.prev_token.type in ['BREAK', 'CONTINUE',
                                         'RETURN', 'THROW']
            ):
            return self._create_semi_token(self.cur_token)
        return self.cur_token

    def _create_semi_token(self, orig_token):
        token = ply.lex.LexToken()
        token.type = 'SEMI'
        token.value = ';'
        if orig_token is not None:
            token.lineno = orig_token.lineno
            token.lexpos = orig_token.lexpos
        else:
            token.lineno = 0
            token.lexpos = 0
        return token

    # iterator protocol
    def __iter__(self):
        return self

    def next(self):
        token = self.token()
        if not token:
            raise StopIteration

        return token

    states = (
        ('regex', 'exclusive'),
        )

    keywords = (
        'BREAK', 'CASE', 'CATCH', 'CONTINUE', 'DEBUGGER', 'DEFAULT', 'DELETE',
        'DO', 'ELSE', 'FINALLY', 'FOR', 'FUNCTION', 'IF', 'IN',
        'INSTANCEOF', 'NEW', 'RETURN', 'SWITCH', 'THIS', 'THROW', 'TRY',
        'TYPEOF', 'VAR', 'VOID', 'WHILE', 'WITH', 'NULL', 'TRUE', 'FALSE',
        # future reserved words - well, it's uncommented now to make
        # IE8 happy because it chokes up on minification:
        # obj["class"] -> obj.class
        'CLASS', 'CONST', 'ENUM', 'EXPORT', 'EXTENDS', 'IMPORT', 'SUPER',
        )
    keywords_dict = dict((key.lower(), key) for key in keywords)

    tokens = (
        # Punctuators
        'PERIOD', 'COMMA', 'SEMI', 'COLON',     # . , ; :
        'PLUS', 'MINUS', 'MULT', 'DIV', 'MOD',  # + - * / %
        'BAND', 'BOR', 'BXOR', 'BNOT',          # & | ^ ~
        'CONDOP',                               # conditional operator ?
        'NOT',                                  # !
        'LPAREN', 'RPAREN',                     # ( and )
        'LBRACE', 'RBRACE',                     # { and }
        'LBRACKET', 'RBRACKET',                 # [ and ]
        'EQ', 'EQEQ', 'NE',                     # = == !=
        'STREQ', 'STRNEQ',                      # === and !==
        'LT', 'GT',                             # < and >
        'LE', 'GE',                             # <= and >=
        'OR', 'AND',                            # || and &&
        'PLUSPLUS', 'MINUSMINUS',               # ++ and --
        'LSHIFT',                               # <<
        'RSHIFT', 'URSHIFT',                    # >> and >>>
        'PLUSEQUAL', 'MINUSEQUAL',              # += and -=
        'MULTEQUAL', 'DIVEQUAL',                # *= and /=
        'LSHIFTEQUAL',                          # <<=
        'RSHIFTEQUAL', 'URSHIFTEQUAL',          # >>= and >>>=
        'ANDEQUAL', 'MODEQUAL',                 # &= and %=
        'XOREQUAL', 'OREQUAL',                  # ^= and |=

        # Terminal types
        'NUMBER', 'STRING', 'ID', 'REGEX',

        # Properties
        'GETPROP', 'SETPROP',

        # Comments
        'LINE_COMMENT', 'BLOCK_COMMENT',

        'LINE_TERMINATOR',
        ) + keywords

    # adapted from https://bitbucket.org/ned/jslex
    t_regex_REGEX = r"""(?:
        /                       # opening slash
        # First character is..
        (?: [^*\\/[]            # anything but * \ / or [
        |   \\.                 # or an escape sequence
        |   \[                  # or a class, which has
                (?: [^\]\\]     # anything but \ or ]
                |   \\.         # or an escape sequence
                )*              # many times
            \]
        )
        # Following characters are same, except for excluding a star
        (?: [^\\/[]             # anything but \ / or [
        |   \\.                 # or an escape sequence
        |   \[                  # or a class, which has
                (?: [^\]\\]     # anything but \ or ]
                |   \\.         # or an escape sequence
                )*              # many times
            \]
        )*                      # many times
        /                       # closing slash
        [a-zA-Z0-9]*            # trailing flags
        )
        """

    t_regex_ignore = ' \t'

    def t_regex_error(self, token):
        raise TypeError(
            "Error parsing regular expression '%s' at %s" % (
                token.value, token.lineno)
            )

    # Punctuators
    t_PERIOD        = r'\.'
    t_COMMA         = r','
    t_SEMI          = r';'
    t_COLON         = r':'
    t_PLUS          = r'\+'
    t_MINUS         = r'-'
    t_MULT          = r'\*'
    t_DIV           = r'/'
    t_MOD           = r'%'
    t_BAND          = r'&'
    t_BOR           = r'\|'
    t_BXOR          = r'\^'
    t_BNOT          = r'~'
    t_CONDOP        = r'\?'
    t_NOT           = r'!'
    t_LPAREN        = r'\('
    t_RPAREN        = r'\)'
    t_LBRACE        = r'{'
    t_RBRACE        = r'}'
    t_LBRACKET      = r'\['
    t_RBRACKET      = r'\]'
    t_EQ            = r'='
    t_EQEQ          = r'=='
    t_NE            = r'!='
    t_STREQ         = r'==='
    t_STRNEQ        = r'!=='
    t_LT            = r'<'
    t_GT            = r'>'
    t_LE            = r'<='
    t_GE            = r'>='
    t_OR            = r'\|\|'
    t_AND           = r'&&'
    t_PLUSPLUS      = r'\+\+'
    t_MINUSMINUS    = r'--'
    t_LSHIFT        = r'<<'
    t_RSHIFT        = r'>>'
    t_URSHIFT       = r'>>>'
    t_PLUSEQUAL     = r'\+='
    t_MINUSEQUAL    = r'-='
    t_MULTEQUAL     = r'\*='
    t_DIVEQUAL      = r'/='
    t_LSHIFTEQUAL   = r'<<='
    t_RSHIFTEQUAL   = r'>>='
    t_URSHIFTEQUAL  = r'>>>='
    t_ANDEQUAL      = r'&='
    t_MODEQUAL      = r'%='
    t_XOREQUAL      = r'\^='
    t_OREQUAL       = r'\|='

    t_LINE_COMMENT  = r'//[^\r\n]*'
    t_BLOCK_COMMENT = r'/\*[^*]*\*+([^/*][^*]*\*+)*/'

    t_LINE_TERMINATOR = r'[\n\r]'

    t_ignore = ' \t'

    t_NUMBER = r"""
    (?:
        0[xX][0-9a-fA-F]+              # hex_integer_literal
     |  0[0-7]+                        # or octal_integer_literal (spec B.1.1)
     |  (?:                            # or decimal_literal
            (?:0|[1-9][0-9]*)          # decimal_integer_literal
            \.                         # dot
            [0-9]*                     # decimal_digits_opt
            (?:[eE][+-]?[0-9]+)?       # exponent_part_opt
         |
            \.                         # dot
            [0-9]+                     # decimal_digits
            (?:[eE][+-]?[0-9]+)?       # exponent_part_opt
         |
            (?:0|[1-9][0-9]*)          # decimal_integer_literal
            (?:[eE][+-]?[0-9]+)?       # exponent_part_opt
         )
    )
    """

    string = r"""
    (?:
        # double quoted string
        (?:"                               # opening double quote
            (?: [^"\\\n\r]                 # no \, line terminators or "
                | \\[a-zA-Z!-\/:-@\[-`{-~] # or escaped characters
                | \\x[0-9a-fA-F]{2}        # or hex_escape_sequence
                | \\u[0-9a-fA-F]{4}        # or unicode_escape_sequence
            )*?                            # zero or many times
            (?: \\\n                       # multiline ?
              (?:
                [^"\\\n\r]                 # no \, line terminators or "
                | \\[a-zA-Z!-\/:-@\[-`{-~] # or escaped characters
                | \\x[0-9a-fA-F]{2}        # or hex_escape_sequence
                | \\u[0-9a-fA-F]{4}        # or unicode_escape_sequence
              )*?                          # zero or many times
            )*
        ")                                 # closing double quote
        |
        # single quoted string
        (?:'                               # opening single quote
            (?: [^'\\\n\r]                 # no \, line terminators or '
                | \\[a-zA-Z!-\/:-@\[-`{-~] # or escaped characters
                | \\x[0-9a-fA-F]{2}        # or hex_escape_sequence
                | \\u[0-9a-fA-F]{4}        # or unicode_escape_sequence
            )*?                            # zero or many times
            (?: \\\n                       # multiline ?
              (?:
                [^'\\\n\r]                 # no \, line terminators or '
                | \\[a-zA-Z!-\/:-@\[-`{-~] # or escaped characters
                | \\x[0-9a-fA-F]{2}        # or hex_escape_sequence
                | \\u[0-9a-fA-F]{4}        # or unicode_escape_sequence
              )*?                          # zero or many times
            )*
        ')                                 # closing single quote
    )
    """  # "

    @ply.lex.TOKEN(string)
    def t_STRING(self, token):
        # remove escape + new line sequence used for strings
        # written across multiple lines of code
        token.value = token.value.replace('\\\n', '')
        return token

    # XXX: <ZWNJ> <ZWJ> ?
    identifier_start = r'(?:' + r'[a-zA-Z_$]' + r'|' + LETTER + r')+'
    identifier_part = (
        r'(?:' + COMBINING_MARK + r'|' + r'[0-9a-zA-Z_$]' + r'|' + DIGIT +
        r'|' + CONNECTOR_PUNCTUATION + r')*'
        )
    identifier = identifier_start + identifier_part

    getprop = r'get' + r'(?=\s' + identifier + r')'
    @ply.lex.TOKEN(getprop)
    def t_GETPROP(self, token):
        return token

    setprop = r'set' + r'(?=\s' + identifier + r')'
    @ply.lex.TOKEN(setprop)
    def t_SETPROP(self, token):
        return token

    @ply.lex.TOKEN(identifier)
    def t_ID(self, token):
        token.type = self.keywords_dict.get(token.value, 'ID')
        return token

    def t_error(self, token):
        print 'Illegal character %r at %s:%s after %s' % (
            token.value[0], token.lineno, token.lexpos, self.prev_token)
        token.lexer.skip(1)
python2/slimit/lextab.py	[[[1
9
# lextab.py. This file automatically created by PLY (version 3.4). Don't edit!
_tabversion   = '3.4'
_lextokens    = {'BOR': 1, 'LBRACKET': 1, 'WITH': 1, 'MINUS': 1, 'RPAREN': 1, 'PLUS': 1, 'IMPORT': 1, 'VOID': 1, 'BLOCK_COMMENT': 1, 'GT': 1, 'RBRACE': 1, 'ENUM': 1, 'PERIOD': 1, 'GE': 1, 'EXTENDS': 1, 'VAR': 1, 'THIS': 1, 'MINUSEQUAL': 1, 'TYPEOF': 1, 'OR': 1, 'DELETE': 1, 'DIVEQUAL': 1, 'RETURN': 1, 'RSHIFTEQUAL': 1, 'EQEQ': 1, 'SETPROP': 1, 'BNOT': 1, 'URSHIFTEQUAL': 1, 'TRUE': 1, 'COLON': 1, 'FUNCTION': 1, 'LINE_COMMENT': 1, 'FOR': 1, 'PLUSPLUS': 1, 'ELSE': 1, 'TRY': 1, 'EQ': 1, 'AND': 1, 'LBRACE': 1, 'CONTINUE': 1, 'NOT': 1, 'OREQUAL': 1, 'MOD': 1, 'RSHIFT': 1, 'DEFAULT': 1, 'WHILE': 1, 'NEW': 1, 'CASE': 1, 'MODEQUAL': 1, 'NE': 1, 'MULTEQUAL': 1, 'SWITCH': 1, 'CATCH': 1, 'STREQ': 1, 'INSTANCEOF': 1, 'PLUSEQUAL': 1, 'GETPROP': 1, 'FALSE': 1, 'CONDOP': 1, 'BREAK': 1, 'LINE_TERMINATOR': 1, 'ANDEQUAL': 1, 'DO': 1, 'CONST': 1, 'NUMBER': 1, 'EXPORT': 1, 'LSHIFT': 1, 'DIV': 1, 'NULL': 1, 'MULT': 1, 'DEBUGGER': 1, 'LE': 1, 'SEMI': 1, 'BXOR': 1, 'LT': 1, 'COMMA': 1, 'CLASS': 1, 'REGEX': 1, 'STRING': 1, 'BAND': 1, 'FINALLY': 1, 'STRNEQ': 1, 'LPAREN': 1, 'IN': 1, 'MINUSMINUS': 1, 'ID': 1, 'IF': 1, 'XOREQUAL': 1, 'LSHIFTEQUAL': 1, 'URSHIFT': 1, 'RBRACKET': 1, 'SUPER': 1, 'THROW': 1}
_lexreflags   = 0
_lexliterals  = ''
_lexstateinfo = {'regex': 'exclusive', 'INITIAL': 'inclusive'}
_lexstatere   = {'regex': [('(?P<t_regex_REGEX>(?:\n        /                       # opening slash\n        # First character is..\n        (?: [^*\\\\/[]            # anything but * \\ / or [\n        |   \\\\.                 # or an escape sequence\n        |   \\[                  # or a class, which has\n                (?: [^\\]\\\\]     # anything but \\ or ]\n                |   \\\\.         # or an escape sequence\n                )*              # many times\n            \\]\n        )\n        # Following characters are same, except for excluding a star\n        (?: [^\\\\/[]             # anything but \\ / or [\n        |   \\\\.                 # or an escape sequence\n        |   \\[                  # or a class, which has\n                (?: [^\\]\\\\]     # anything but \\ or ]\n                |   \\\\.         # or an escape sequence\n                )*              # many times\n            \\]\n        )*                      # many times\n        /                       # closing slash\n        [a-zA-Z0-9]*            # trailing flags\n        )\n        )', [None, (None, 'REGEX')])], 'INITIAL': [(u'(?P<t_STRING>\n    (?:\n        # double quoted string\n        (?:"                               # opening double quote\n            (?: [^"\\\\\\n\\r]                 # no \\, line terminators or "\n                | \\\\[a-zA-Z!-\\/:-@\\[-`{-~] # or escaped characters\n                | \\\\x[0-9a-fA-F]{2}        # or hex_escape_sequence\n                | \\\\u[0-9a-fA-F]{4}        # or unicode_escape_sequence\n            )*?                            # zero or many times\n            (?: \\\\\\n                       # multiline ?\n              (?:\n                [^"\\\\\\n\\r]                 # no \\, line terminators or "\n                | \\\\[a-zA-Z!-\\/:-@\\[-`{-~] # or escaped characters\n                | \\\\x[0-9a-fA-F]{2}        # or hex_escape_sequence\n                | \\\\u[0-9a-fA-F]{4}        # or unicode_escape_sequence\n              )*?                          # zero or many times\n            )*\n        ")                                 # closing double quote\n        |\n        # single quoted string\n        (?:\'                               # opening single quote\n            (?: [^\'\\\\\\n\\r]                 # no \\, line terminators or \'\n                | \\\\[a-zA-Z!-\\/:-@\\[-`{-~] # or escaped characters\n                | \\\\x[0-9a-fA-F]{2}        # or hex_escape_sequence\n                | \\\\u[0-9a-fA-F]{4}        # or unicode_escape_sequence\n            )*?                            # zero or many times\n            (?: \\\\\\n                       # multiline ?\n              (?:\n                [^\'\\\\\\n\\r]                 # no \\, line terminators or \'\n                | \\\\[a-zA-Z!-\\/:-@\\[-`{-~] # or escaped characters\n                | \\\\x[0-9a-fA-F]{2}        # or hex_escape_sequence\n                | \\\\u[0-9a-fA-F]{4}        # or unicode_escape_sequence\n              )*?                          # zero or many times\n            )*\n        \')                                 # closing single quote\n    )\n    )|(?P<t_GETPROP>get(?=\\s(?:[a-zA-Z_$]|[A-Za-z\xaa\xb5\xba\xc0-\xd6\xd8-\xf6\xf8-\u02c1\u02c6-\u02d1\u02e0-\u02e4\u02ec\u02ee\u0370-\u0374\u0376\u0377\u037a-\u037d\u0386\u0388-\u038a\u038c\u038e-\u03a1\u03a3-\u03f5\u03f7-\u0481\u048a-\u0523\u0531-\u0556\u0559\u0561-\u0587\u05d0-\u05ea\u05f0-\u05f2\u0621-\u064a\u066e\u066f\u0671-\u06d3\u06d5\u06e5\u06e6\u06ee\u06ef\u06fa-\u06fc\u06ff\u0710\u0712-\u072f\u074d-\u07a5\u07b1\u07ca-\u07ea\u07f4\u07f5\u07fa\u0904-\u0939\u093d\u0950\u0958-\u0961\u0971\u0972\u097b-\u097f\u0985-\u098c\u098f\u0990\u0993-\u09a8\u09aa-\u09b0\u09b2\u09b6-\u09b9\u09bd\u09ce\u09dc\u09dd\u09df-\u09e1\u09f0\u09f1\u0a05-\u0a0a\u0a0f\u0a10\u0a13-\u0a28\u0a2a-\u0a30\u0a32\u0a33\u0a35\u0a36\u0a38\u0a39\u0a59-\u0a5c\u0a5e\u0a72-\u0a74\u0a85-\u0a8d\u0a8f-\u0a91\u0a93-\u0aa8\u0aaa-\u0ab0\u0ab2\u0ab3\u0ab5-\u0ab9\u0abd\u0ad0\u0ae0\u0ae1\u0b05-\u0b0c\u0b0f\u0b10\u0b13-\u0b28\u0b2a-\u0b30\u0b32\u0b33\u0b35-\u0b39\u0b3d\u0b5c\u0b5d\u0b5f-\u0b61\u0b71\u0b83\u0b85-\u0b8a\u0b8e-\u0b90\u0b92-\u0b95\u0b99\u0b9a\u0b9c\u0b9e\u0b9f\u0ba3\u0ba4\u0ba8-\u0baa\u0bae-\u0bb9\u0bd0\u0c05-\u0c0c\u0c0e-\u0c10\u0c12-\u0c28\u0c2a-\u0c33\u0c35-\u0c39\u0c3d\u0c58\u0c59\u0c60\u0c61\u0c85-\u0c8c\u0c8e-\u0c90\u0c92-\u0ca8\u0caa-\u0cb3\u0cb5-\u0cb9\u0cbd\u0cde\u0ce0\u0ce1\u0d05-\u0d0c\u0d0e-\u0d10\u0d12-\u0d28\u0d2a-\u0d39\u0d3d\u0d60\u0d61\u0d7a-\u0d7f\u0d85-\u0d96\u0d9a-\u0db1\u0db3-\u0dbb\u0dbd\u0dc0-\u0dc6\u0e01-\u0e30\u0e32\u0e33\u0e40-\u0e46\u0e81\u0e82\u0e84\u0e87\u0e88\u0e8a\u0e8d\u0e94-\u0e97\u0e99-\u0e9f\u0ea1-\u0ea3\u0ea5\u0ea7\u0eaa\u0eab\u0ead-\u0eb0\u0eb2\u0eb3\u0ebd\u0ec0-\u0ec4\u0ec6\u0edc\u0edd\u0f00\u0f40-\u0f47\u0f49-\u0f6c\u0f88-\u0f8b\u1000-\u102a\u103f\u1050-\u1055\u105a-\u105d\u1061\u1065\u1066\u106e-\u1070\u1075-\u1081\u108e\u10a0-\u10c5\u10d0-\u10fa\u10fc\u1100-\u1159\u115f-\u11a2\u11a8-\u11f9\u1200-\u1248\u124a-\u124d\u1250-\u1256\u1258\u125a-\u125d\u1260-\u1288\u128a-\u128d\u1290-\u12b0\u12b2-\u12b5\u12b8-\u12be\u12c0\u12c2-\u12c5\u12c8-\u12d6\u12d8-\u1310\u1312-\u1315\u1318-\u135a\u1380-\u138f\u13a0-\u13f4\u1401-\u166c\u166f-\u1676\u1681-\u169a\u16a0-\u16ea\u1700-\u170c\u170e-\u1711\u1720-\u1731\u1740-\u1751\u1760-\u176c\u176e-\u1770\u1780-\u17b3\u17d7\u17dc\u1820-\u1877\u1880-\u18a8\u18aa\u1900-\u191c\u1950-\u196d\u1970-\u1974\u1980-\u19a9\u19c1-\u19c7\u1a00-\u1a16\u1b05-\u1b33\u1b45-\u1b4b\u1b83-\u1ba0\u1bae\u1baf\u1c00-\u1c23\u1c4d-\u1c4f\u1c5a-\u1c7d\u1d00-\u1dbf\u1e00-\u1f15\u1f18-\u1f1d\u1f20-\u1f45\u1f48-\u1f4d\u1f50-\u1f57\u1f59\u1f5b\u1f5d\u1f5f-\u1f7d\u1f80-\u1fb4\u1fb6-\u1fbc\u1fbe\u1fc2-\u1fc4\u1fc6-\u1fcc\u1fd0-\u1fd3\u1fd6-\u1fdb\u1fe0-\u1fec\u1ff2-\u1ff4\u1ff6-\u1ffc\u2071\u207f\u2090-\u2094\u2102\u2107\u210a-\u2113\u2115\u2119-\u211d\u2124\u2126\u2128\u212a-\u212d\u212f-\u2139\u213c-\u213f\u2145-\u2149\u214e\u2183\u2184\u2c00-\u2c2e\u2c30-\u2c5e\u2c60-\u2c6f\u2c71-\u2c7d\u2c80-\u2ce4\u2d00-\u2d25\u2d30-\u2d65\u2d6f\u2d80-\u2d96\u2da0-\u2da6\u2da8-\u2dae\u2db0-\u2db6\u2db8-\u2dbe\u2dc0-\u2dc6\u2dc8-\u2dce\u2dd0-\u2dd6\u2dd8-\u2dde\u2e2f\u3005\u3006\u3031-\u3035\u303b\u303c\u3041-\u3096\u309d-\u309f\u30a1-\u30fa\u30fc-\u30ff\u3105-\u312d\u3131-\u318e\u31a0-\u31b7\u31f0-\u31ff\u3400\u4db5\u4e00\u9fc3\ua000-\ua48c\ua500-\ua60c\ua610-\ua61f\ua62a\ua62b\ua640-\ua65f\ua662-\ua66e\ua67f-\ua697\ua717-\ua71f\ua722-\ua788\ua78b\ua78c\ua7fb-\ua801\ua803-\ua805\ua807-\ua80a\ua80c-\ua822\ua840-\ua873\ua882-\ua8b3\ua90a-\ua925\ua930-\ua946\uaa00-\uaa28\uaa40-\uaa42\uaa44-\uaa4b\uac00\ud7a3\uf900-\ufa2d\ufa30-\ufa6a\ufa70-\ufad9\ufb00-\ufb06\ufb13-\ufb17\ufb1d\ufb1f-\ufb28\ufb2a-\ufb36\ufb38-\ufb3c\ufb3e\ufb40\ufb41\ufb43\ufb44\ufb46-\ufbb1\ufbd3-\ufd3d\ufd50-\ufd8f\ufd92-\ufdc7\ufdf0-\ufdfb\ufe70-\ufe74\ufe76-\ufefc\uff21-\uff3a\uff41-\uff5a\uff66-\uffbe\uffc2-\uffc7\uffca-\uffcf\uffd2-\uffd7\uffda-\uffdc])+(?:[\u0300-\u036f\u0483-\u0487\u0591-\u05bd\u05bf\u05c1\u05c2\u05c4\u05c5\u05c7\u0610-\u061a\u064b-\u065e\u0670\u06d6-\u06dc\u06df-\u06e4\u06e7\u06e8\u06ea-\u06ed\u0711\u0730-\u074a\u07a6-\u07b0\u07eb-\u07f3\u0816-\u0819\u081b-\u0823\u0825-\u0827\u0829-\u082d\u0900-\u0902\u093c\u0941-\u0948\u094d\u0951-\u0955\u0962\u0963\u0981\u09bc\u09c1-\u09c4\u09cd\u09e2\u09e3\u0a01\u0a02\u0a3c\u0a41\u0a42\u0a47\u0a48\u0a4b-\u0a4d\u0a51\u0a70\u0a71\u0a75\u0a81\u0a82\u0abc\u0ac1-\u0ac5\u0ac7\u0ac8\u0acd\u0ae2\u0ae3\u0b01\u0b3c\u0b3f\u0b41-\u0b44\u0b4d\u0b56\u0b62\u0b63\u0b82\u0bc0\u0bcd\u0c3e-\u0c40\u0c46-\u0c48\u0c4a-\u0c4d\u0c55\u0c56\u0c62\u0c63\u0cbc\u0cbf\u0cc6\u0ccc\u0ccd\u0ce2\u0ce3\u0d41-\u0d44\u0d4d\u0d62\u0d63\u0dca\u0dd2-\u0dd4\u0dd6\u0e31\u0e34-\u0e3a\u0e47-\u0e4e\u0eb1\u0eb4-\u0eb9\u0ebb\u0ebc\u0ec8-\u0ecd\u0f18\u0f19\u0f35\u0f37\u0f39\u0f71-\u0f7e\u0f80-\u0f84\u0f86\u0f87\u0f90-\u0f97\u0f99-\u0fbc\u0fc6\u102d-\u1030\u1032-\u1037\u1039\u103a\u103d\u103e\u1058\u1059\u105e-\u1060\u1071-\u1074\u1082\u1085\u1086\u108d\u109d\u135f\u1712-\u1714\u1732-\u1734\u1752\u1753\u1772\u1773\u17b7-\u17bd\u17c6\u17c9-\u17d3\u17dd\u180b-\u180d\u18a9\u1920-\u1922\u1927\u1928\u1932\u1939-\u193b\u1a17\u1a18\u1a56\u1a58-\u1a5e\u1a60\u1a62\u1a65-\u1a6c\u1a73-\u1a7c\u1a7f\u1b00-\u1b03\u1b34\u1b36-\u1b3a\u1b3c\u1b42\u1b6b-\u1b73\u1b80\u1b81\u1ba2-\u1ba5\u1ba8\u1ba9\u1c2c-\u1c33\u1c36\u1c37\u1cd0-\u1cd2\u1cd4-\u1ce0\u1ce2-\u1ce8\u1ced\u1dc0-\u1de6\u1dfd-\u1dff\u20d0-\u20dc\u20e1\u20e5-\u20f0\u2cef-\u2cf1\u2de0-\u2dff\u302a-\u302f\u3099\u309a\ua66f\ua67c\ua67d\ua6f0\ua6f1\ua802\ua806\ua80b\ua825\ua826\ua8c4\ua8e0-\ua8f1\ua926-\ua92d\ua947-\ua951\ua980-\ua982\ua9b3\ua9b6-\ua9b9\ua9bc\uaa29-\uaa2e\uaa31\uaa32\uaa35\uaa36\uaa43\uaa4c\uaab0\uaab2-\uaab4\uaab7\uaab8\uaabe\uaabf\uaac1\uabe5\uabe8\uabed\ufb1e\ufe00-\ufe0f\ufe20-\ufe26]|[\u0903\u093e-\u0940\u0949-\u094c\u094e\u0982\u0983\u09be-\u09c0\u09c7\u09c8\u09cb\u09cc\u09d7\u0a03\u0a3e-\u0a40\u0a83\u0abe-\u0ac0\u0ac9\u0acb\u0acc\u0b02\u0b03\u0b3e\u0b40\u0b47\u0b48\u0b4b\u0b4c\u0b57\u0bbe\u0bbf\u0bc1\u0bc2\u0bc6-\u0bc8\u0bca-\u0bcc\u0bd7\u0c01-\u0c03\u0c41-\u0c44\u0c82\u0c83\u0cbe\u0cc0-\u0cc4\u0cc7\u0cc8\u0cca\u0ccb\u0cd5\u0cd6\u0d02\u0d03\u0d3e-\u0d40\u0d46-\u0d48\u0d4a-\u0d4c\u0d57\u0d82\u0d83\u0dcf-\u0dd1\u0dd8-\u0ddf\u0df2\u0df3\u0f3e\u0f3f\u0f7f\u102b\u102c\u1031\u1038\u103b\u103c\u1056\u1057\u1062-\u1064\u1067-\u106d\u1083\u1084\u1087-\u108c\u108f\u109a-\u109c\u17b6\u17be-\u17c5\u17c7\u17c8\u1923-\u1926\u1929-\u192b\u1930\u1931\u1933-\u1938\u19b0-\u19c0\u19c8\u19c9\u1a19-\u1a1b\u1a55\u1a57\u1a61\u1a63\u1a64\u1a6d-\u1a72\u1b04\u1b35\u1b3b\u1b3d-\u1b41\u1b43\u1b44\u1b82\u1ba1\u1ba6\u1ba7\u1baa\u1c24-\u1c2b\u1c34\u1c35\u1ce1\u1cf2\ua823\ua824\ua827\ua880\ua881\ua8b4-\ua8c3\ua952\ua953\ua983\ua9b4\ua9b5\ua9ba\ua9bb\ua9bd-\ua9c0\uaa2f\uaa30\uaa33\uaa34\uaa4d\uaa7b\uabe3\uabe4\uabe6\uabe7\uabe9\uabea\uabec]|[0-9a-zA-Z_$]|[0-9\u0660-\u0669\u06f0-\u06f9\u07c0-\u07c9\u0966-\u096f\u09e6-\u09ef\u0a66-\u0a6f\u0ae6-\u0aef\u0b66-\u0b6f\u0be6-\u0bef\u0c66-\u0c6f\u0ce6-\u0cef\u0d66-\u0d6f\u0e50-\u0e59\u0ed0-\u0ed9\u0f20-\u0f29\u1040-\u1049\u1090-\u1099\u17e0-\u17e9\u1810-\u1819\u1946-\u194f\u19d0-\u19da\u1a80-\u1a89\u1a90-\u1a99\u1b50-\u1b59\u1bb0-\u1bb9\u1c40-\u1c49\u1c50-\u1c59\ua620-\ua629\ua8d0-\ua8d9\ua900-\ua909\ua9d0-\ua9d9\uaa50-\uaa59\uabf0-\uabf9\uff10-\uff19]|[_\u203f\u2040\u2054\ufe33\ufe34\ufe4d-\ufe4f\uff3f])*))|(?P<t_SETPROP>set(?=\\s(?:[a-zA-Z_$]|[A-Za-z\xaa\xb5\xba\xc0-\xd6\xd8-\xf6\xf8-\u02c1\u02c6-\u02d1\u02e0-\u02e4\u02ec\u02ee\u0370-\u0374\u0376\u0377\u037a-\u037d\u0386\u0388-\u038a\u038c\u038e-\u03a1\u03a3-\u03f5\u03f7-\u0481\u048a-\u0523\u0531-\u0556\u0559\u0561-\u0587\u05d0-\u05ea\u05f0-\u05f2\u0621-\u064a\u066e\u066f\u0671-\u06d3\u06d5\u06e5\u06e6\u06ee\u06ef\u06fa-\u06fc\u06ff\u0710\u0712-\u072f\u074d-\u07a5\u07b1\u07ca-\u07ea\u07f4\u07f5\u07fa\u0904-\u0939\u093d\u0950\u0958-\u0961\u0971\u0972\u097b-\u097f\u0985-\u098c\u098f\u0990\u0993-\u09a8\u09aa-\u09b0\u09b2\u09b6-\u09b9\u09bd\u09ce\u09dc\u09dd\u09df-\u09e1\u09f0\u09f1\u0a05-\u0a0a\u0a0f\u0a10\u0a13-\u0a28\u0a2a-\u0a30\u0a32\u0a33\u0a35\u0a36\u0a38\u0a39\u0a59-\u0a5c\u0a5e\u0a72-\u0a74\u0a85-\u0a8d\u0a8f-\u0a91\u0a93-\u0aa8\u0aaa-\u0ab0\u0ab2\u0ab3\u0ab5-\u0ab9\u0abd\u0ad0\u0ae0\u0ae1\u0b05-\u0b0c\u0b0f\u0b10\u0b13-\u0b28\u0b2a-\u0b30\u0b32\u0b33\u0b35-\u0b39\u0b3d\u0b5c\u0b5d\u0b5f-\u0b61\u0b71\u0b83\u0b85-\u0b8a\u0b8e-\u0b90\u0b92-\u0b95\u0b99\u0b9a\u0b9c\u0b9e\u0b9f\u0ba3\u0ba4\u0ba8-\u0baa\u0bae-\u0bb9\u0bd0\u0c05-\u0c0c\u0c0e-\u0c10\u0c12-\u0c28\u0c2a-\u0c33\u0c35-\u0c39\u0c3d\u0c58\u0c59\u0c60\u0c61\u0c85-\u0c8c\u0c8e-\u0c90\u0c92-\u0ca8\u0caa-\u0cb3\u0cb5-\u0cb9\u0cbd\u0cde\u0ce0\u0ce1\u0d05-\u0d0c\u0d0e-\u0d10\u0d12-\u0d28\u0d2a-\u0d39\u0d3d\u0d60\u0d61\u0d7a-\u0d7f\u0d85-\u0d96\u0d9a-\u0db1\u0db3-\u0dbb\u0dbd\u0dc0-\u0dc6\u0e01-\u0e30\u0e32\u0e33\u0e40-\u0e46\u0e81\u0e82\u0e84\u0e87\u0e88\u0e8a\u0e8d\u0e94-\u0e97\u0e99-\u0e9f\u0ea1-\u0ea3\u0ea5\u0ea7\u0eaa\u0eab\u0ead-\u0eb0\u0eb2\u0eb3\u0ebd\u0ec0-\u0ec4\u0ec6\u0edc\u0edd\u0f00\u0f40-\u0f47\u0f49-\u0f6c\u0f88-\u0f8b\u1000-\u102a\u103f\u1050-\u1055\u105a-\u105d\u1061\u1065\u1066\u106e-\u1070\u1075-\u1081\u108e\u10a0-\u10c5\u10d0-\u10fa\u10fc\u1100-\u1159\u115f-\u11a2\u11a8-\u11f9\u1200-\u1248\u124a-\u124d\u1250-\u1256\u1258\u125a-\u125d\u1260-\u1288\u128a-\u128d\u1290-\u12b0\u12b2-\u12b5\u12b8-\u12be\u12c0\u12c2-\u12c5\u12c8-\u12d6\u12d8-\u1310\u1312-\u1315\u1318-\u135a\u1380-\u138f\u13a0-\u13f4\u1401-\u166c\u166f-\u1676\u1681-\u169a\u16a0-\u16ea\u1700-\u170c\u170e-\u1711\u1720-\u1731\u1740-\u1751\u1760-\u176c\u176e-\u1770\u1780-\u17b3\u17d7\u17dc\u1820-\u1877\u1880-\u18a8\u18aa\u1900-\u191c\u1950-\u196d\u1970-\u1974\u1980-\u19a9\u19c1-\u19c7\u1a00-\u1a16\u1b05-\u1b33\u1b45-\u1b4b\u1b83-\u1ba0\u1bae\u1baf\u1c00-\u1c23\u1c4d-\u1c4f\u1c5a-\u1c7d\u1d00-\u1dbf\u1e00-\u1f15\u1f18-\u1f1d\u1f20-\u1f45\u1f48-\u1f4d\u1f50-\u1f57\u1f59\u1f5b\u1f5d\u1f5f-\u1f7d\u1f80-\u1fb4\u1fb6-\u1fbc\u1fbe\u1fc2-\u1fc4\u1fc6-\u1fcc\u1fd0-\u1fd3\u1fd6-\u1fdb\u1fe0-\u1fec\u1ff2-\u1ff4\u1ff6-\u1ffc\u2071\u207f\u2090-\u2094\u2102\u2107\u210a-\u2113\u2115\u2119-\u211d\u2124\u2126\u2128\u212a-\u212d\u212f-\u2139\u213c-\u213f\u2145-\u2149\u214e\u2183\u2184\u2c00-\u2c2e\u2c30-\u2c5e\u2c60-\u2c6f\u2c71-\u2c7d\u2c80-\u2ce4\u2d00-\u2d25\u2d30-\u2d65\u2d6f\u2d80-\u2d96\u2da0-\u2da6\u2da8-\u2dae\u2db0-\u2db6\u2db8-\u2dbe\u2dc0-\u2dc6\u2dc8-\u2dce\u2dd0-\u2dd6\u2dd8-\u2dde\u2e2f\u3005\u3006\u3031-\u3035\u303b\u303c\u3041-\u3096\u309d-\u309f\u30a1-\u30fa\u30fc-\u30ff\u3105-\u312d\u3131-\u318e\u31a0-\u31b7\u31f0-\u31ff\u3400\u4db5\u4e00\u9fc3\ua000-\ua48c\ua500-\ua60c\ua610-\ua61f\ua62a\ua62b\ua640-\ua65f\ua662-\ua66e\ua67f-\ua697\ua717-\ua71f\ua722-\ua788\ua78b\ua78c\ua7fb-\ua801\ua803-\ua805\ua807-\ua80a\ua80c-\ua822\ua840-\ua873\ua882-\ua8b3\ua90a-\ua925\ua930-\ua946\uaa00-\uaa28\uaa40-\uaa42\uaa44-\uaa4b\uac00\ud7a3\uf900-\ufa2d\ufa30-\ufa6a\ufa70-\ufad9\ufb00-\ufb06\ufb13-\ufb17\ufb1d\ufb1f-\ufb28\ufb2a-\ufb36\ufb38-\ufb3c\ufb3e\ufb40\ufb41\ufb43\ufb44\ufb46-\ufbb1\ufbd3-\ufd3d\ufd50-\ufd8f\ufd92-\ufdc7\ufdf0-\ufdfb\ufe70-\ufe74\ufe76-\ufefc\uff21-\uff3a\uff41-\uff5a\uff66-\uffbe\uffc2-\uffc7\uffca-\uffcf\uffd2-\uffd7\uffda-\uffdc])+(?:[\u0300-\u036f\u0483-\u0487\u0591-\u05bd\u05bf\u05c1\u05c2\u05c4\u05c5\u05c7\u0610-\u061a\u064b-\u065e\u0670\u06d6-\u06dc\u06df-\u06e4\u06e7\u06e8\u06ea-\u06ed\u0711\u0730-\u074a\u07a6-\u07b0\u07eb-\u07f3\u0816-\u0819\u081b-\u0823\u0825-\u0827\u0829-\u082d\u0900-\u0902\u093c\u0941-\u0948\u094d\u0951-\u0955\u0962\u0963\u0981\u09bc\u09c1-\u09c4\u09cd\u09e2\u09e3\u0a01\u0a02\u0a3c\u0a41\u0a42\u0a47\u0a48\u0a4b-\u0a4d\u0a51\u0a70\u0a71\u0a75\u0a81\u0a82\u0abc\u0ac1-\u0ac5\u0ac7\u0ac8\u0acd\u0ae2\u0ae3\u0b01\u0b3c\u0b3f\u0b41-\u0b44\u0b4d\u0b56\u0b62\u0b63\u0b82\u0bc0\u0bcd\u0c3e-\u0c40\u0c46-\u0c48\u0c4a-\u0c4d\u0c55\u0c56\u0c62\u0c63\u0cbc\u0cbf\u0cc6\u0ccc\u0ccd\u0ce2\u0ce3\u0d41-\u0d44\u0d4d\u0d62\u0d63\u0dca\u0dd2-\u0dd4\u0dd6\u0e31\u0e34-\u0e3a\u0e47-\u0e4e\u0eb1\u0eb4-\u0eb9\u0ebb\u0ebc\u0ec8-\u0ecd\u0f18\u0f19\u0f35\u0f37\u0f39\u0f71-\u0f7e\u0f80-\u0f84\u0f86\u0f87\u0f90-\u0f97\u0f99-\u0fbc\u0fc6\u102d-\u1030\u1032-\u1037\u1039\u103a\u103d\u103e\u1058\u1059\u105e-\u1060\u1071-\u1074\u1082\u1085\u1086\u108d\u109d\u135f\u1712-\u1714\u1732-\u1734\u1752\u1753\u1772\u1773\u17b7-\u17bd\u17c6\u17c9-\u17d3\u17dd\u180b-\u180d\u18a9\u1920-\u1922\u1927\u1928\u1932\u1939-\u193b\u1a17\u1a18\u1a56\u1a58-\u1a5e\u1a60\u1a62\u1a65-\u1a6c\u1a73-\u1a7c\u1a7f\u1b00-\u1b03\u1b34\u1b36-\u1b3a\u1b3c\u1b42\u1b6b-\u1b73\u1b80\u1b81\u1ba2-\u1ba5\u1ba8\u1ba9\u1c2c-\u1c33\u1c36\u1c37\u1cd0-\u1cd2\u1cd4-\u1ce0\u1ce2-\u1ce8\u1ced\u1dc0-\u1de6\u1dfd-\u1dff\u20d0-\u20dc\u20e1\u20e5-\u20f0\u2cef-\u2cf1\u2de0-\u2dff\u302a-\u302f\u3099\u309a\ua66f\ua67c\ua67d\ua6f0\ua6f1\ua802\ua806\ua80b\ua825\ua826\ua8c4\ua8e0-\ua8f1\ua926-\ua92d\ua947-\ua951\ua980-\ua982\ua9b3\ua9b6-\ua9b9\ua9bc\uaa29-\uaa2e\uaa31\uaa32\uaa35\uaa36\uaa43\uaa4c\uaab0\uaab2-\uaab4\uaab7\uaab8\uaabe\uaabf\uaac1\uabe5\uabe8\uabed\ufb1e\ufe00-\ufe0f\ufe20-\ufe26]|[\u0903\u093e-\u0940\u0949-\u094c\u094e\u0982\u0983\u09be-\u09c0\u09c7\u09c8\u09cb\u09cc\u09d7\u0a03\u0a3e-\u0a40\u0a83\u0abe-\u0ac0\u0ac9\u0acb\u0acc\u0b02\u0b03\u0b3e\u0b40\u0b47\u0b48\u0b4b\u0b4c\u0b57\u0bbe\u0bbf\u0bc1\u0bc2\u0bc6-\u0bc8\u0bca-\u0bcc\u0bd7\u0c01-\u0c03\u0c41-\u0c44\u0c82\u0c83\u0cbe\u0cc0-\u0cc4\u0cc7\u0cc8\u0cca\u0ccb\u0cd5\u0cd6\u0d02\u0d03\u0d3e-\u0d40\u0d46-\u0d48\u0d4a-\u0d4c\u0d57\u0d82\u0d83\u0dcf-\u0dd1\u0dd8-\u0ddf\u0df2\u0df3\u0f3e\u0f3f\u0f7f\u102b\u102c\u1031\u1038\u103b\u103c\u1056\u1057\u1062-\u1064\u1067-\u106d\u1083\u1084\u1087-\u108c\u108f\u109a-\u109c\u17b6\u17be-\u17c5\u17c7\u17c8\u1923-\u1926\u1929-\u192b\u1930\u1931\u1933-\u1938\u19b0-\u19c0\u19c8\u19c9\u1a19-\u1a1b\u1a55\u1a57\u1a61\u1a63\u1a64\u1a6d-\u1a72\u1b04\u1b35\u1b3b\u1b3d-\u1b41\u1b43\u1b44\u1b82\u1ba1\u1ba6\u1ba7\u1baa\u1c24-\u1c2b\u1c34\u1c35\u1ce1\u1cf2\ua823\ua824\ua827\ua880\ua881\ua8b4-\ua8c3\ua952\ua953\ua983\ua9b4\ua9b5\ua9ba\ua9bb\ua9bd-\ua9c0\uaa2f\uaa30\uaa33\uaa34\uaa4d\uaa7b\uabe3\uabe4\uabe6\uabe7\uabe9\uabea\uabec]|[0-9a-zA-Z_$]|[0-9\u0660-\u0669\u06f0-\u06f9\u07c0-\u07c9\u0966-\u096f\u09e6-\u09ef\u0a66-\u0a6f\u0ae6-\u0aef\u0b66-\u0b6f\u0be6-\u0bef\u0c66-\u0c6f\u0ce6-\u0cef\u0d66-\u0d6f\u0e50-\u0e59\u0ed0-\u0ed9\u0f20-\u0f29\u1040-\u1049\u1090-\u1099\u17e0-\u17e9\u1810-\u1819\u1946-\u194f\u19d0-\u19da\u1a80-\u1a89\u1a90-\u1a99\u1b50-\u1b59\u1bb0-\u1bb9\u1c40-\u1c49\u1c50-\u1c59\ua620-\ua629\ua8d0-\ua8d9\ua900-\ua909\ua9d0-\ua9d9\uaa50-\uaa59\uabf0-\uabf9\uff10-\uff19]|[_\u203f\u2040\u2054\ufe33\ufe34\ufe4d-\ufe4f\uff3f])*))|(?P<t_ID>(?:[a-zA-Z_$]|[A-Za-z\xaa\xb5\xba\xc0-\xd6\xd8-\xf6\xf8-\u02c1\u02c6-\u02d1\u02e0-\u02e4\u02ec\u02ee\u0370-\u0374\u0376\u0377\u037a-\u037d\u0386\u0388-\u038a\u038c\u038e-\u03a1\u03a3-\u03f5\u03f7-\u0481\u048a-\u0523\u0531-\u0556\u0559\u0561-\u0587\u05d0-\u05ea\u05f0-\u05f2\u0621-\u064a\u066e\u066f\u0671-\u06d3\u06d5\u06e5\u06e6\u06ee\u06ef\u06fa-\u06fc\u06ff\u0710\u0712-\u072f\u074d-\u07a5\u07b1\u07ca-\u07ea\u07f4\u07f5\u07fa\u0904-\u0939\u093d\u0950\u0958-\u0961\u0971\u0972\u097b-\u097f\u0985-\u098c\u098f\u0990\u0993-\u09a8\u09aa-\u09b0\u09b2\u09b6-\u09b9\u09bd\u09ce\u09dc\u09dd\u09df-\u09e1\u09f0\u09f1\u0a05-\u0a0a\u0a0f\u0a10\u0a13-\u0a28\u0a2a-\u0a30\u0a32\u0a33\u0a35\u0a36\u0a38\u0a39\u0a59-\u0a5c\u0a5e\u0a72-\u0a74\u0a85-\u0a8d\u0a8f-\u0a91\u0a93-\u0aa8\u0aaa-\u0ab0\u0ab2\u0ab3\u0ab5-\u0ab9\u0abd\u0ad0\u0ae0\u0ae1\u0b05-\u0b0c\u0b0f\u0b10\u0b13-\u0b28\u0b2a-\u0b30\u0b32\u0b33\u0b35-\u0b39\u0b3d\u0b5c\u0b5d\u0b5f-\u0b61\u0b71\u0b83\u0b85-\u0b8a\u0b8e-\u0b90\u0b92-\u0b95\u0b99\u0b9a\u0b9c\u0b9e\u0b9f\u0ba3\u0ba4\u0ba8-\u0baa\u0bae-\u0bb9\u0bd0\u0c05-\u0c0c\u0c0e-\u0c10\u0c12-\u0c28\u0c2a-\u0c33\u0c35-\u0c39\u0c3d\u0c58\u0c59\u0c60\u0c61\u0c85-\u0c8c\u0c8e-\u0c90\u0c92-\u0ca8\u0caa-\u0cb3\u0cb5-\u0cb9\u0cbd\u0cde\u0ce0\u0ce1\u0d05-\u0d0c\u0d0e-\u0d10\u0d12-\u0d28\u0d2a-\u0d39\u0d3d\u0d60\u0d61\u0d7a-\u0d7f\u0d85-\u0d96\u0d9a-\u0db1\u0db3-\u0dbb\u0dbd\u0dc0-\u0dc6\u0e01-\u0e30\u0e32\u0e33\u0e40-\u0e46\u0e81\u0e82\u0e84\u0e87\u0e88\u0e8a\u0e8d\u0e94-\u0e97\u0e99-\u0e9f\u0ea1-\u0ea3\u0ea5\u0ea7\u0eaa\u0eab\u0ead-\u0eb0\u0eb2\u0eb3\u0ebd\u0ec0-\u0ec4\u0ec6\u0edc\u0edd\u0f00\u0f40-\u0f47\u0f49-\u0f6c\u0f88-\u0f8b\u1000-\u102a\u103f\u1050-\u1055\u105a-\u105d\u1061\u1065\u1066\u106e-\u1070\u1075-\u1081\u108e\u10a0-\u10c5\u10d0-\u10fa\u10fc\u1100-\u1159\u115f-\u11a2\u11a8-\u11f9\u1200-\u1248\u124a-\u124d\u1250-\u1256\u1258\u125a-\u125d\u1260-\u1288\u128a-\u128d\u1290-\u12b0\u12b2-\u12b5\u12b8-\u12be\u12c0\u12c2-\u12c5\u12c8-\u12d6\u12d8-\u1310\u1312-\u1315\u1318-\u135a\u1380-\u138f\u13a0-\u13f4\u1401-\u166c\u166f-\u1676\u1681-\u169a\u16a0-\u16ea\u1700-\u170c\u170e-\u1711\u1720-\u1731\u1740-\u1751\u1760-\u176c\u176e-\u1770\u1780-\u17b3\u17d7\u17dc\u1820-\u1877\u1880-\u18a8\u18aa\u1900-\u191c\u1950-\u196d\u1970-\u1974\u1980-\u19a9\u19c1-\u19c7\u1a00-\u1a16\u1b05-\u1b33\u1b45-\u1b4b\u1b83-\u1ba0\u1bae\u1baf\u1c00-\u1c23\u1c4d-\u1c4f\u1c5a-\u1c7d\u1d00-\u1dbf\u1e00-\u1f15\u1f18-\u1f1d\u1f20-\u1f45\u1f48-\u1f4d\u1f50-\u1f57\u1f59\u1f5b\u1f5d\u1f5f-\u1f7d\u1f80-\u1fb4\u1fb6-\u1fbc\u1fbe\u1fc2-\u1fc4\u1fc6-\u1fcc\u1fd0-\u1fd3\u1fd6-\u1fdb\u1fe0-\u1fec\u1ff2-\u1ff4\u1ff6-\u1ffc\u2071\u207f\u2090-\u2094\u2102\u2107\u210a-\u2113\u2115\u2119-\u211d\u2124\u2126\u2128\u212a-\u212d\u212f-\u2139\u213c-\u213f\u2145-\u2149\u214e\u2183\u2184\u2c00-\u2c2e\u2c30-\u2c5e\u2c60-\u2c6f\u2c71-\u2c7d\u2c80-\u2ce4\u2d00-\u2d25\u2d30-\u2d65\u2d6f\u2d80-\u2d96\u2da0-\u2da6\u2da8-\u2dae\u2db0-\u2db6\u2db8-\u2dbe\u2dc0-\u2dc6\u2dc8-\u2dce\u2dd0-\u2dd6\u2dd8-\u2dde\u2e2f\u3005\u3006\u3031-\u3035\u303b\u303c\u3041-\u3096\u309d-\u309f\u30a1-\u30fa\u30fc-\u30ff\u3105-\u312d\u3131-\u318e\u31a0-\u31b7\u31f0-\u31ff\u3400\u4db5\u4e00\u9fc3\ua000-\ua48c\ua500-\ua60c\ua610-\ua61f\ua62a\ua62b\ua640-\ua65f\ua662-\ua66e\ua67f-\ua697\ua717-\ua71f\ua722-\ua788\ua78b\ua78c\ua7fb-\ua801\ua803-\ua805\ua807-\ua80a\ua80c-\ua822\ua840-\ua873\ua882-\ua8b3\ua90a-\ua925\ua930-\ua946\uaa00-\uaa28\uaa40-\uaa42\uaa44-\uaa4b\uac00\ud7a3\uf900-\ufa2d\ufa30-\ufa6a\ufa70-\ufad9\ufb00-\ufb06\ufb13-\ufb17\ufb1d\ufb1f-\ufb28\ufb2a-\ufb36\ufb38-\ufb3c\ufb3e\ufb40\ufb41\ufb43\ufb44\ufb46-\ufbb1\ufbd3-\ufd3d\ufd50-\ufd8f\ufd92-\ufdc7\ufdf0-\ufdfb\ufe70-\ufe74\ufe76-\ufefc\uff21-\uff3a\uff41-\uff5a\uff66-\uffbe\uffc2-\uffc7\uffca-\uffcf\uffd2-\uffd7\uffda-\uffdc])+(?:[\u0300-\u036f\u0483-\u0487\u0591-\u05bd\u05bf\u05c1\u05c2\u05c4\u05c5\u05c7\u0610-\u061a\u064b-\u065e\u0670\u06d6-\u06dc\u06df-\u06e4\u06e7\u06e8\u06ea-\u06ed\u0711\u0730-\u074a\u07a6-\u07b0\u07eb-\u07f3\u0816-\u0819\u081b-\u0823\u0825-\u0827\u0829-\u082d\u0900-\u0902\u093c\u0941-\u0948\u094d\u0951-\u0955\u0962\u0963\u0981\u09bc\u09c1-\u09c4\u09cd\u09e2\u09e3\u0a01\u0a02\u0a3c\u0a41\u0a42\u0a47\u0a48\u0a4b-\u0a4d\u0a51\u0a70\u0a71\u0a75\u0a81\u0a82\u0abc\u0ac1-\u0ac5\u0ac7\u0ac8\u0acd\u0ae2\u0ae3\u0b01\u0b3c\u0b3f\u0b41-\u0b44\u0b4d\u0b56\u0b62\u0b63\u0b82\u0bc0\u0bcd\u0c3e-\u0c40\u0c46-\u0c48\u0c4a-\u0c4d\u0c55\u0c56\u0c62\u0c63\u0cbc\u0cbf\u0cc6\u0ccc\u0ccd\u0ce2\u0ce3\u0d41-\u0d44\u0d4d\u0d62\u0d63\u0dca\u0dd2-\u0dd4\u0dd6\u0e31\u0e34-\u0e3a\u0e47-\u0e4e\u0eb1\u0eb4-\u0eb9\u0ebb\u0ebc\u0ec8-\u0ecd\u0f18\u0f19\u0f35\u0f37\u0f39\u0f71-\u0f7e\u0f80-\u0f84\u0f86\u0f87\u0f90-\u0f97\u0f99-\u0fbc\u0fc6\u102d-\u1030\u1032-\u1037\u1039\u103a\u103d\u103e\u1058\u1059\u105e-\u1060\u1071-\u1074\u1082\u1085\u1086\u108d\u109d\u135f\u1712-\u1714\u1732-\u1734\u1752\u1753\u1772\u1773\u17b7-\u17bd\u17c6\u17c9-\u17d3\u17dd\u180b-\u180d\u18a9\u1920-\u1922\u1927\u1928\u1932\u1939-\u193b\u1a17\u1a18\u1a56\u1a58-\u1a5e\u1a60\u1a62\u1a65-\u1a6c\u1a73-\u1a7c\u1a7f\u1b00-\u1b03\u1b34\u1b36-\u1b3a\u1b3c\u1b42\u1b6b-\u1b73\u1b80\u1b81\u1ba2-\u1ba5\u1ba8\u1ba9\u1c2c-\u1c33\u1c36\u1c37\u1cd0-\u1cd2\u1cd4-\u1ce0\u1ce2-\u1ce8\u1ced\u1dc0-\u1de6\u1dfd-\u1dff\u20d0-\u20dc\u20e1\u20e5-\u20f0\u2cef-\u2cf1\u2de0-\u2dff\u302a-\u302f\u3099\u309a\ua66f\ua67c\ua67d\ua6f0\ua6f1\ua802\ua806\ua80b\ua825\ua826\ua8c4\ua8e0-\ua8f1\ua926-\ua92d\ua947-\ua951\ua980-\ua982\ua9b3\ua9b6-\ua9b9\ua9bc\uaa29-\uaa2e\uaa31\uaa32\uaa35\uaa36\uaa43\uaa4c\uaab0\uaab2-\uaab4\uaab7\uaab8\uaabe\uaabf\uaac1\uabe5\uabe8\uabed\ufb1e\ufe00-\ufe0f\ufe20-\ufe26]|[\u0903\u093e-\u0940\u0949-\u094c\u094e\u0982\u0983\u09be-\u09c0\u09c7\u09c8\u09cb\u09cc\u09d7\u0a03\u0a3e-\u0a40\u0a83\u0abe-\u0ac0\u0ac9\u0acb\u0acc\u0b02\u0b03\u0b3e\u0b40\u0b47\u0b48\u0b4b\u0b4c\u0b57\u0bbe\u0bbf\u0bc1\u0bc2\u0bc6-\u0bc8\u0bca-\u0bcc\u0bd7\u0c01-\u0c03\u0c41-\u0c44\u0c82\u0c83\u0cbe\u0cc0-\u0cc4\u0cc7\u0cc8\u0cca\u0ccb\u0cd5\u0cd6\u0d02\u0d03\u0d3e-\u0d40\u0d46-\u0d48\u0d4a-\u0d4c\u0d57\u0d82\u0d83\u0dcf-\u0dd1\u0dd8-\u0ddf\u0df2\u0df3\u0f3e\u0f3f\u0f7f\u102b\u102c\u1031\u1038\u103b\u103c\u1056\u1057\u1062-\u1064\u1067-\u106d\u1083\u1084\u1087-\u108c\u108f\u109a-\u109c\u17b6\u17be-\u17c5\u17c7\u17c8\u1923-\u1926\u1929-\u192b\u1930\u1931\u1933-\u1938\u19b0-\u19c0\u19c8\u19c9\u1a19-\u1a1b\u1a55\u1a57\u1a61\u1a63\u1a64\u1a6d-\u1a72\u1b04\u1b35\u1b3b\u1b3d-\u1b41\u1b43\u1b44\u1b82\u1ba1\u1ba6\u1ba7\u1baa\u1c24-\u1c2b\u1c34\u1c35\u1ce1\u1cf2\ua823\ua824\ua827\ua880\ua881\ua8b4-\ua8c3\ua952\ua953\ua983\ua9b4\ua9b5\ua9ba\ua9bb\ua9bd-\ua9c0\uaa2f\uaa30\uaa33\uaa34\uaa4d\uaa7b\uabe3\uabe4\uabe6\uabe7\uabe9\uabea\uabec]|[0-9a-zA-Z_$]|[0-9\u0660-\u0669\u06f0-\u06f9\u07c0-\u07c9\u0966-\u096f\u09e6-\u09ef\u0a66-\u0a6f\u0ae6-\u0aef\u0b66-\u0b6f\u0be6-\u0bef\u0c66-\u0c6f\u0ce6-\u0cef\u0d66-\u0d6f\u0e50-\u0e59\u0ed0-\u0ed9\u0f20-\u0f29\u1040-\u1049\u1090-\u1099\u17e0-\u17e9\u1810-\u1819\u1946-\u194f\u19d0-\u19da\u1a80-\u1a89\u1a90-\u1a99\u1b50-\u1b59\u1bb0-\u1bb9\u1c40-\u1c49\u1c50-\u1c59\ua620-\ua629\ua8d0-\ua8d9\ua900-\ua909\ua9d0-\ua9d9\uaa50-\uaa59\uabf0-\uabf9\uff10-\uff19]|[_\u203f\u2040\u2054\ufe33\ufe34\ufe4d-\ufe4f\uff3f])*)|(?P<t_NUMBER>\n    (?:\n        0[xX][0-9a-fA-F]+              # hex_integer_literal\n     |  0[0-7]+                        # or octal_integer_literal (spec B.1.1)\n     |  (?:                            # or decimal_literal\n            (?:0|[1-9][0-9]*)          # decimal_integer_literal\n            \\.                         # dot\n            [0-9]*                     # decimal_digits_opt\n            (?:[eE][+-]?[0-9]+)?       # exponent_part_opt\n         |\n            \\.                         # dot\n            [0-9]+                     # decimal_digits\n            (?:[eE][+-]?[0-9]+)?       # exponent_part_opt\n         |\n            (?:0|[1-9][0-9]*)          # decimal_integer_literal\n            (?:[eE][+-]?[0-9]+)?       # exponent_part_opt\n         )\n    )\n    )|(?P<t_BLOCK_COMMENT>/\\*[^*]*\\*+([^/*][^*]*\\*+)*/)|(?P<t_LINE_COMMENT>//[^\\r\\n]*)|(?P<t_LINE_TERMINATOR>[\\n\\r])|(?P<t_PLUSPLUS>\\+\\+)|(?P<t_OR>\\|\\|)|(?P<t_URSHIFTEQUAL>>>>=)|(?P<t_XOREQUAL>\\^=)|(?P<t_OREQUAL>\\|=)|(?P<t_LSHIFTEQUAL><<=)|(?P<t_STRNEQ>!==)|(?P<t_RSHIFTEQUAL>>>=)|(?P<t_URSHIFT>>>>)|(?P<t_PLUSEQUAL>\\+=)|(?P<t_MULTEQUAL>\\*=)|(?P<t_STREQ>===)|(?P<t_PERIOD>\\.)|(?P<t_PLUS>\\+)|(?P<t_MODEQUAL>%=)|(?P<t_DIVEQUAL>/=)|(?P<t_RBRACKET>\\])|(?P<t_CONDOP>\\?)|(?P<t_BOR>\\|)|(?P<t_LSHIFT><<)|(?P<t_LE><=)|(?P<t_BXOR>\\^)|(?P<t_LPAREN>\\()|(?P<t_MULT>\\*)|(?P<t_NE>!=)|(?P<t_MINUSMINUS>--)|(?P<t_AND>&&)|(?P<t_LBRACKET>\\[)|(?P<t_GE>>=)|(?P<t_RPAREN>\\))|(?P<t_RSHIFT>>>)|(?P<t_ANDEQUAL>&=)|(?P<t_MINUSEQUAL>-=)|(?P<t_EQEQ>==)|(?P<t_LBRACE>{)|(?P<t_LT><)|(?P<t_COMMA>,)|(?P<t_EQ>=)|(?P<t_BNOT>~)|(?P<t_RBRACE>})|(?P<t_DIV>/)|(?P<t_MOD>%)|(?P<t_SEMI>;)|(?P<t_MINUS>-)|(?P<t_GT>>)|(?P<t_COLON>:)|(?P<t_BAND>&)|(?P<t_NOT>!)', [None, (u't_STRING', 'STRING'), (u't_GETPROP', 'GETPROP'), (u't_SETPROP', 'SETPROP'), (u't_ID', 'ID'), (None, 'NUMBER'), (None, 'BLOCK_COMMENT'), None, (None, 'LINE_COMMENT'), (None, 'LINE_TERMINATOR'), (None, 'PLUSPLUS'), (None, 'OR'), (None, 'URSHIFTEQUAL'), (None, 'XOREQUAL'), (None, 'OREQUAL'), (None, 'LSHIFTEQUAL'), (None, 'STRNEQ'), (None, 'RSHIFTEQUAL'), (None, 'URSHIFT'), (None, 'PLUSEQUAL'), (None, 'MULTEQUAL'), (None, 'STREQ'), (None, 'PERIOD'), (None, 'PLUS'), (None, 'MODEQUAL'), (None, 'DIVEQUAL'), (None, 'RBRACKET'), (None, 'CONDOP'), (None, 'BOR'), (None, 'LSHIFT'), (None, 'LE'), (None, 'BXOR'), (None, 'LPAREN'), (None, 'MULT'), (None, 'NE'), (None, 'MINUSMINUS'), (None, 'AND'), (None, 'LBRACKET'), (None, 'GE'), (None, 'RPAREN'), (None, 'RSHIFT'), (None, 'ANDEQUAL'), (None, 'MINUSEQUAL'), (None, 'EQEQ'), (None, 'LBRACE'), (None, 'LT'), (None, 'COMMA'), (None, 'EQ'), (None, 'BNOT'), (None, 'RBRACE'), (None, 'DIV'), (None, 'MOD'), (None, 'SEMI'), (None, 'MINUS'), (None, 'GT'), (None, 'COLON'), (None, 'BAND'), (None, 'NOT')])]}
_lexstateignore = {'regex': ' \t', 'INITIAL': ' \t'}
_lexstateerrorf = {'regex': 't_regex_error', 'INITIAL': 't_error'}
python2/slimit/mangler.py	[[[1
51
###############################################################################
#
# Copyright (c) 2011 Ruslan Spivak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

__author__ = 'Ruslan Spivak <ruslan.spivak@gmail.com>'

from slimit.scope import SymbolTable
from slimit.visitors.scopevisitor import (
    ScopeTreeVisitor,
    fill_scope_references,
    mangle_scope_tree,
    NameManglerVisitor,
    )


def mangle(tree, toplevel=False):
    """Mangle names.

    Args:
        toplevel: defaults to False. Defines if global
        scope should be mangled or not.
    """
    sym_table = SymbolTable()
    visitor = ScopeTreeVisitor(sym_table)
    visitor.visit(tree)

    fill_scope_references(tree)
    mangle_scope_tree(sym_table.globals, toplevel)

    mangler = NameManglerVisitor()
    mangler.visit(tree)
python2/slimit/minifier.py	[[[1
70
###############################################################################
#
# Copyright (c) 2011 Ruslan Spivak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

__author__ = 'Ruslan Spivak <ruslan.spivak@gmail.com>'

import sys
import optparse
import textwrap

from slimit import mangler
from slimit.parser import Parser
from slimit.visitors.minvisitor import ECMAMinifier


def minify(text, mangle=False, mangle_toplevel=False):
    parser = Parser()
    tree = parser.parse(text)
    if mangle:
        mangler.mangle(tree, toplevel=mangle_toplevel)
    minified = ECMAMinifier().visit(tree)
    return minified


def main(argv=None, inp=sys.stdin, out=sys.stdout):
    usage = textwrap.dedent("""\
    %prog [options] [input file]

    If no input file is provided STDIN is used by default.
    Minified JavaScript code is printed to STDOUT.
    """)
    parser = optparse.OptionParser(usage=usage)
    parser.add_option('-m', '--mangle', action='store_true',
                      dest='mangle', default=False, help='mangle names')
    parser.add_option('-t', '--mangle-toplevel', action='store_true',
                      dest='mangle_toplevel', default=False,
                      help='mangle top level scope (defaults to False)')

    if argv is None:
        argv = sys.argv[1:]
    options, args = parser.parse_args(argv)

    if len(args) == 1:
        text = open(args[0]).read()
    else:
        text = inp.read()

    minified = minify(
        text, mangle=options.mangle, mangle_toplevel=options.mangle_toplevel)
    out.write(minified)
python2/slimit/parser.py	[[[1
1229
###############################################################################
#
# Copyright (c) 2011 Ruslan Spivak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

__author__ = 'Ruslan Spivak <ruslan.spivak@gmail.com>'

import ply.yacc

from slimit import ast
from slimit.lexer import Lexer

try:
    from slimit import lextab, yacctab
except ImportError:
    lextab, yacctab = 'lextab', 'yacctab'


class Parser(object):
    """JavaScript parser(ECMA-262 5th edition grammar).

    The '*noin' variants are needed to avoid confusing the `in` operator in
    a relational expression with the `in` operator in a `for` statement.

    '*nobf' stands for 'no brace or function'
    """

    def __init__(self, lex_optimize=True, lextab=lextab,
                 yacc_optimize=True, yacctab=yacctab, yacc_debug=False):
        self.lex_optimize = lex_optimize
        self.lextab = lextab
        self.yacc_optimize = yacc_optimize
        self.yacctab = yacctab
        self.yacc_debug = yacc_debug

        self.lexer = Lexer()
        self.lexer.build(optimize=lex_optimize, lextab=lextab)
        self.tokens = self.lexer.tokens

        self.parser = ply.yacc.yacc(
            module=self, optimize=yacc_optimize,
            debug=yacc_debug, tabmodule=yacctab, start='program')

        # https://github.com/rspivak/slimit/issues/29
        # lexer.auto_semi can cause a loop in a parser
        # when a parser error happens on a token right after
        # a newline.
        # We keep record of the tokens that caused p_error
        # and if the token has already been seen - we raise
        # a SyntaxError exception to avoid looping over and
        # over again.
        self._error_tokens = {}
        self._line_start = (None, None)

    def _has_been_seen_before(self, token):
        if token is None:
            return False
        key = token.type, token.value, token.lineno, token.lexpos
        return key in self._error_tokens

    def _mark_as_seen(self, token):
        if token is None:
            return
        key = token.type, token.value, token.lineno, token.lexpos
        self._error_tokens[key] = True

    def _raise_syntax_error(self, token):
        raise SyntaxError(
            'Unexpected token (%s, %r) at %s:%s between %s and %s' % (
                token.type, token.value, token.lineno, token.lexpos,
                self.lexer.prev_token, self.lexer.token())
            )

    def parse(self, text, debug=False):
        return self.parser.parse(text, lexer=self.lexer, debug=debug)

    def p_empty(self, p):
        """empty :"""
        pass

    def p_auto_semi(self, p):
        """auto_semi : error"""
        pass

    def p_error(self, token):
        # https://github.com/rspivak/slimit/issues/29
        if self._has_been_seen_before(token):
            self._raise_syntax_error(token)

        if token is None or token.type != 'SEMI':
            next_token = self.lexer.auto_semi(token)
            if next_token is not None:
                # https://github.com/rspivak/slimit/issues/29
                self._mark_as_seen(token)
                self.parser.errok()
                return next_token

        self._raise_syntax_error(token)

    # Comment rules
    # def p_single_line_comment(self, p):
    #     """single_line_comment : LINE_COMMENT"""
    #     pass

    # def p_multi_line_comment(self, p):
    #     """multi_line_comment : BLOCK_COMMENT"""
    #     pass

    # Main rules

    def p_program(self, p):
        """program : source_elements"""
        p[0] = ast.Program(p[1])

    def p_source_elements(self, p):
        """source_elements : empty
                           | source_element_list
        """
        p[0] = p[1]

    def p_source_element_list(self, p):
        """source_element_list : source_element
                               | source_element_list source_element
        """
        if len(p) == 2: # single source element
            p[0] = [p[1]]
        else:
            p[1].append(p[2])
            p[0] = p[1]

    def p_source_element(self, p):
        """source_element : statement
                          | function_declaration
        """
        p[0] = p[1]

    def p_statement(self, p):
        """statement : block
                     | variable_statement
                     | empty_statement
                     | expr_statement
                     | if_statement
                     | iteration_statement
                     | continue_statement
                     | break_statement
                     | return_statement
                     | with_statement
                     | switch_statement
                     | labelled_statement
                     | throw_statement
                     | try_statement
                     | debugger_statement
                     | function_declaration
        """
        p[0] = p[1]

    # By having source_elements in the production we support
    # also function_declaration inside blocks
    def p_block(self, p):
        """block : LBRACE source_elements RBRACE"""
        p[0] = ast.Block(p[2])

    def p_literal(self, p):
        """literal : null_literal
                   | boolean_literal
                   | numeric_literal
                   | string_literal
                   | regex_literal
        """
        p[0] = p[1]

    def p_boolean_literal(self, p):
        """boolean_literal : TRUE
                           | FALSE
        """
        p[0] = ast.Boolean(p[1])

    def p_null_literal(self, p):
        """null_literal : NULL"""
        p[0] = ast.Null(p[1])

    def p_numeric_literal(self, p):
        """numeric_literal : NUMBER"""
        p[0] = ast.Number(p[1])

    def p_string_literal(self, p):
        """string_literal : STRING"""
        p[0] = ast.String(p[1])

    def p_regex_literal(self, p):
        """regex_literal : REGEX"""
        p[0] = ast.Regex(p[1])

    def p_identifier(self, p):
        """identifier : ID"""
        line = p.lineno(1)
        if self._line_start[0] != line:
            lbegin = p.lexer.lexer.lexdata.rfind('\n', 0, p.lexpos(1))
            self._line_start = (line, lbegin)
        col = p.lexpos(1) - self._line_start[1]
        p[0] = ast.Identifier(p[1], (line, col))

    ###########################################
    # Expressions
    ###########################################
    def p_primary_expr(self, p):
        """primary_expr : primary_expr_no_brace
                        | object_literal
        """
        p[0] = p[1]

    def p_primary_expr_no_brace_1(self, p):
        """primary_expr_no_brace : identifier"""
        p[1]._mangle_candidate = True
        p[1]._in_expression = True
        p[0] = p[1]

    def p_primary_expr_no_brace_2(self, p):
        """primary_expr_no_brace : THIS"""
        p[0] = ast.This()

    def p_primary_expr_no_brace_3(self, p):
        """primary_expr_no_brace : literal
                                 | array_literal
        """
        p[0] = p[1]

    def p_primary_expr_no_brace_4(self, p):
        """primary_expr_no_brace : LPAREN expr RPAREN"""
        p[2]._parens = True
        p[0] = p[2]

    def p_array_literal_1(self, p):
        """array_literal : LBRACKET elision_opt RBRACKET"""
        p[0] = ast.Array(items=p[2])

    def p_array_literal_2(self, p):
        """array_literal : LBRACKET element_list RBRACKET
                         | LBRACKET element_list COMMA elision_opt RBRACKET
        """
        items = p[2]
        if len(p) == 6:
            items.extend(p[4])
        p[0] = ast.Array(items=items)


    def p_element_list(self, p):
        """element_list : elision_opt assignment_expr
                        | element_list COMMA elision_opt assignment_expr
        """
        if len(p) == 3:
            p[0] = p[1] + [p[2]]
        else:
            p[1].extend(p[3])
            p[1].append(p[4])
            p[0] = p[1]

    def p_elision_opt_1(self, p):
        """elision_opt : empty"""
        p[0] = []

    def p_elision_opt_2(self, p):
        """elision_opt : elision"""
        p[0] = p[1]

    def p_elision(self, p):
        """elision : COMMA
                   | elision COMMA
        """
        if len(p) == 2:
            p[0] = [ast.Elision(p[1])]
        else:
            p[1].append(ast.Elision(p[2]))
            p[0] = p[1]

    def p_object_literal(self, p):
        """object_literal : LBRACE RBRACE
                          | LBRACE property_list RBRACE
                          | LBRACE property_list COMMA RBRACE
        """
        if len(p) == 3:
            p[0] = ast.Object()
        else:
            p[0] = ast.Object(properties=p[2])

    def p_property_list(self, p):
        """property_list : property_assignment
                         | property_list COMMA property_assignment
        """
        if len(p) == 2:
            p[0] = [p[1]]
        else:
            p[1].append(p[3])
            p[0] = p[1]

    # XXX: GET / SET
    def p_property_assignment(self, p):
        """property_assignment \
             : property_name COLON assignment_expr
             | GETPROP property_name LPAREN RPAREN LBRACE function_body RBRACE
             | SETPROP property_name LPAREN formal_parameter_list RPAREN \
                   LBRACE function_body RBRACE
        """
        if len(p) == 4:
            p[0] = ast.Assign(left=p[1], op=p[2], right=p[3])
        elif len(p) == 8:
            p[0] = ast.GetPropAssign(prop_name=p[2], elements=p[6])
        else:
            p[0] = ast.SetPropAssign(
                prop_name=p[2], parameters=p[4], elements=p[7])

    def p_property_name(self, p):
        """property_name : identifier
                         | string_literal
                         | numeric_literal
        """
        p[0] = p[1]

    # 11.2 Left-Hand-Side Expressions
    def p_member_expr(self, p):
        """member_expr : primary_expr
                       | function_expr
                       | member_expr LBRACKET expr RBRACKET
                       | member_expr PERIOD identifier
                       | NEW member_expr arguments
        """
        if len(p) == 2:
            p[0] = p[1]
        elif p[1] == 'new':
            p[0] = ast.NewExpr(p[2], p[3])
        elif p[2] == '.':
            p[0] = ast.DotAccessor(p[1], p[3])
        else:
            p[0] = ast.BracketAccessor(p[1], p[3])

    def p_member_expr_nobf(self, p):
        """member_expr_nobf : primary_expr_no_brace
                            | function_expr
                            | member_expr_nobf LBRACKET expr RBRACKET
                            | member_expr_nobf PERIOD identifier
                            | NEW member_expr arguments
        """
        if len(p) == 2:
            p[0] = p[1]
        elif p[1] == 'new':
            p[0] = ast.NewExpr(p[2], p[3])
        elif p[2] == '.':
            p[0] = ast.DotAccessor(p[1], p[3])
        else:
            p[0] = ast.BracketAccessor(p[1], p[3])

    def p_new_expr(self, p):
        """new_expr : member_expr
                    | NEW new_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.NewExpr(p[2])

    def p_new_expr_nobf(self, p):
        """new_expr_nobf : member_expr_nobf
                         | NEW new_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.NewExpr(p[2])

    def p_call_expr(self, p):
        """call_expr : member_expr arguments
                     | call_expr arguments
                     | call_expr LBRACKET expr RBRACKET
                     | call_expr PERIOD identifier
        """
        if len(p) == 3:
            p[0] = ast.FunctionCall(p[1], p[2])
        elif len(p) == 4:
            p[0] = ast.DotAccessor(p[1], p[3])
        else:
            p[0] = ast.BracketAccessor(p[1], p[3])

    def p_call_expr_nobf(self, p):
        """call_expr_nobf : member_expr_nobf arguments
                          | call_expr_nobf arguments
                          | call_expr_nobf LBRACKET expr RBRACKET
                          | call_expr_nobf PERIOD identifier
        """
        if len(p) == 3:
            p[0] = ast.FunctionCall(p[1], p[2])
        elif len(p) == 4:
            p[0] = ast.DotAccessor(p[1], p[3])
        else:
            p[0] = ast.BracketAccessor(p[1], p[3])

    def p_arguments(self, p):
        """arguments : LPAREN RPAREN
                     | LPAREN argument_list RPAREN
        """
        if len(p) == 4:
            p[0] = p[2]

    def p_argument_list(self, p):
        """argument_list : assignment_expr
                         | argument_list COMMA assignment_expr
        """
        if len(p) == 2:
            p[0] = [p[1]]
        else:
            p[1].append(p[3])
            p[0] = p[1]

    def p_lef_hand_side_expr(self, p):
        """left_hand_side_expr : new_expr
                               | call_expr
        """
        p[0] = p[1]

    def p_lef_hand_side_expr_nobf(self, p):
        """left_hand_side_expr_nobf : new_expr_nobf
                                    | call_expr_nobf
        """
        p[0] = p[1]

    # 11.3 Postfix Expressions
    def p_postfix_expr(self, p):
        """postfix_expr : left_hand_side_expr
                        | left_hand_side_expr PLUSPLUS
                        | left_hand_side_expr MINUSMINUS
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.UnaryOp(op=p[2], value=p[1], postfix=True)

    def p_postfix_expr_nobf(self, p):
        """postfix_expr_nobf : left_hand_side_expr_nobf
                             | left_hand_side_expr_nobf PLUSPLUS
                             | left_hand_side_expr_nobf MINUSMINUS
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.UnaryOp(op=p[2], value=p[1], postfix=True)

    # 11.4 Unary Operators
    def p_unary_expr(self, p):
        """unary_expr : postfix_expr
                      | unary_expr_common
        """
        p[0] = p[1]

    def p_unary_expr_nobf(self, p):
        """unary_expr_nobf : postfix_expr_nobf
                           | unary_expr_common
        """
        p[0] = p[1]

    def p_unary_expr_common(self, p):
        """unary_expr_common : DELETE unary_expr
                             | VOID unary_expr
                             | TYPEOF unary_expr
                             | PLUSPLUS unary_expr
                             | MINUSMINUS unary_expr
                             | PLUS unary_expr
                             | MINUS unary_expr
                             | BNOT unary_expr
                             | NOT unary_expr
        """
        p[0] = ast.UnaryOp(p[1], p[2])

    # 11.5 Multiplicative Operators
    def p_multiplicative_expr(self, p):
        """multiplicative_expr : unary_expr
                               | multiplicative_expr MULT unary_expr
                               | multiplicative_expr DIV unary_expr
                               | multiplicative_expr MOD unary_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_multiplicative_expr_nobf(self, p):
        """multiplicative_expr_nobf : unary_expr_nobf
                                    | multiplicative_expr_nobf MULT unary_expr
                                    | multiplicative_expr_nobf DIV unary_expr
                                    | multiplicative_expr_nobf MOD unary_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    # 11.6 Additive Operators
    def p_additive_expr(self, p):
        """additive_expr : multiplicative_expr
                         | additive_expr PLUS multiplicative_expr
                         | additive_expr MINUS multiplicative_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_additive_expr_nobf(self, p):
        """additive_expr_nobf : multiplicative_expr_nobf
                              | additive_expr_nobf PLUS multiplicative_expr
                              | additive_expr_nobf MINUS multiplicative_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    # 11.7 Bitwise Shift Operators
    def p_shift_expr(self, p):
        """shift_expr : additive_expr
                      | shift_expr LSHIFT additive_expr
                      | shift_expr RSHIFT additive_expr
                      | shift_expr URSHIFT additive_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_shift_expr_nobf(self, p):
        """shift_expr_nobf : additive_expr_nobf
                           | shift_expr_nobf LSHIFT additive_expr
                           | shift_expr_nobf RSHIFT additive_expr
                           | shift_expr_nobf URSHIFT additive_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])


    # 11.8 Relational Operators
    def p_relational_expr(self, p):
        """relational_expr : shift_expr
                           | relational_expr LT shift_expr
                           | relational_expr GT shift_expr
                           | relational_expr LE shift_expr
                           | relational_expr GE shift_expr
                           | relational_expr INSTANCEOF shift_expr
                           | relational_expr IN shift_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_relational_expr_noin(self, p):
        """relational_expr_noin : shift_expr
                                | relational_expr_noin LT shift_expr
                                | relational_expr_noin GT shift_expr
                                | relational_expr_noin LE shift_expr
                                | relational_expr_noin GE shift_expr
                                | relational_expr_noin INSTANCEOF shift_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_relational_expr_nobf(self, p):
        """relational_expr_nobf : shift_expr_nobf
                                | relational_expr_nobf LT shift_expr
                                | relational_expr_nobf GT shift_expr
                                | relational_expr_nobf LE shift_expr
                                | relational_expr_nobf GE shift_expr
                                | relational_expr_nobf INSTANCEOF shift_expr
                                | relational_expr_nobf IN shift_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    # 11.9 Equality Operators
    def p_equality_expr(self, p):
        """equality_expr : relational_expr
                         | equality_expr EQEQ relational_expr
                         | equality_expr NE relational_expr
                         | equality_expr STREQ relational_expr
                         | equality_expr STRNEQ relational_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_equality_expr_noin(self, p):
        """equality_expr_noin : relational_expr_noin
                              | equality_expr_noin EQEQ relational_expr
                              | equality_expr_noin NE relational_expr
                              | equality_expr_noin STREQ relational_expr
                              | equality_expr_noin STRNEQ relational_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_equality_expr_nobf(self, p):
        """equality_expr_nobf : relational_expr_nobf
                              | equality_expr_nobf EQEQ relational_expr
                              | equality_expr_nobf NE relational_expr
                              | equality_expr_nobf STREQ relational_expr
                              | equality_expr_nobf STRNEQ relational_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    # 11.10 Binary Bitwise Operators
    def p_bitwise_and_expr(self, p):
        """bitwise_and_expr : equality_expr
                            | bitwise_and_expr BAND equality_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_bitwise_and_expr_noin(self, p):
        """bitwise_and_expr_noin \
            : equality_expr_noin
            | bitwise_and_expr_noin BAND equality_expr_noin
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_bitwise_and_expr_nobf(self, p):
        """bitwise_and_expr_nobf \
            : equality_expr_nobf
            | bitwise_and_expr_nobf BAND equality_expr_nobf
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_bitwise_xor_expr(self, p):
        """bitwise_xor_expr : bitwise_and_expr
                            | bitwise_xor_expr BXOR bitwise_and_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_bitwise_xor_expr_noin(self, p):
        """
        bitwise_xor_expr_noin \
            : bitwise_and_expr_noin
            | bitwise_xor_expr_noin BXOR bitwise_and_expr_noin
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_bitwise_xor_expr_nobf(self, p):
        """
        bitwise_xor_expr_nobf \
            : bitwise_and_expr_nobf
            | bitwise_xor_expr_nobf BXOR bitwise_and_expr_nobf
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_bitwise_or_expr(self, p):
        """bitwise_or_expr : bitwise_xor_expr
                           | bitwise_or_expr BOR bitwise_xor_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_bitwise_or_expr_noin(self, p):
        """
        bitwise_or_expr_noin \
            : bitwise_xor_expr_noin
            | bitwise_or_expr_noin BOR bitwise_xor_expr_noin
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_bitwise_or_expr_nobf(self, p):
        """
        bitwise_or_expr_nobf \
            : bitwise_xor_expr_nobf
            | bitwise_or_expr_nobf BOR bitwise_xor_expr_nobf
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    # 11.11 Binary Logical Operators
    def p_logical_and_expr(self, p):
        """logical_and_expr : bitwise_or_expr
                            | logical_and_expr AND bitwise_or_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_logical_and_expr_noin(self, p):
        """
        logical_and_expr_noin : bitwise_or_expr_noin
                              | logical_and_expr_noin AND bitwise_or_expr_noin
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_logical_and_expr_nobf(self, p):
        """
        logical_and_expr_nobf : bitwise_or_expr_nobf
                              | logical_and_expr_nobf AND bitwise_or_expr_nobf
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_logical_or_expr(self, p):
        """logical_or_expr : logical_and_expr
                           | logical_or_expr OR logical_and_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_logical_or_expr_noin(self, p):
        """logical_or_expr_noin : logical_and_expr_noin
                                | logical_or_expr_noin OR logical_and_expr_noin
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    def p_logical_or_expr_nobf(self, p):
        """logical_or_expr_nobf : logical_and_expr_nobf
                                | logical_or_expr_nobf OR logical_and_expr_nobf
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.BinOp(op=p[2], left=p[1], right=p[3])

    # 11.12 Conditional Operator ( ? : )
    def p_conditional_expr(self, p):
        """
        conditional_expr \
            : logical_or_expr
            | logical_or_expr CONDOP assignment_expr COLON assignment_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.Conditional(
                predicate=p[1], consequent=p[3], alternative=p[5])

    def p_conditional_expr_noin(self, p):
        """
        conditional_expr_noin \
            : logical_or_expr_noin
            | logical_or_expr_noin CONDOP assignment_expr_noin COLON \
                  assignment_expr_noin
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.Conditional(
                predicate=p[1], consequent=p[3], alternative=p[5])

    def p_conditional_expr_nobf(self, p):
        """
        conditional_expr_nobf \
            : logical_or_expr_nobf
            | logical_or_expr_nobf CONDOP assignment_expr COLON assignment_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.Conditional(
                predicate=p[1], consequent=p[3], alternative=p[5])

    # 11.13 Assignment Operators
    def p_assignment_expr(self, p):
        """
        assignment_expr \
            : conditional_expr
            | left_hand_side_expr assignment_operator assignment_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.Assign(left=p[1], op=p[2], right=p[3])

    def p_assignment_expr_noin(self, p):
        """
        assignment_expr_noin \
            : conditional_expr_noin
            | left_hand_side_expr assignment_operator assignment_expr_noin
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.Assign(left=p[1], op=p[2], right=p[3])

    def p_assignment_expr_nobf(self, p):
        """
        assignment_expr_nobf \
            : conditional_expr_nobf
            | left_hand_side_expr_nobf assignment_operator assignment_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.Assign(left=p[1], op=p[2], right=p[3])

    def p_assignment_operator(self, p):
        """assignment_operator : EQ
                               | MULTEQUAL
                               | DIVEQUAL
                               | MODEQUAL
                               | PLUSEQUAL
                               | MINUSEQUAL
                               | LSHIFTEQUAL
                               | RSHIFTEQUAL
                               | URSHIFTEQUAL
                               | ANDEQUAL
                               | XOREQUAL
                               | OREQUAL
        """
        p[0] = p[1]

    # 11.4 Comma Operator
    def p_expr(self, p):
        """expr : assignment_expr
                | expr COMMA assignment_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.Comma(left=p[1], right=p[3])

    def p_expr_noin(self, p):
        """expr_noin : assignment_expr_noin
                     | expr_noin COMMA assignment_expr_noin
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.Comma(left=p[1], right=p[3])

    def p_expr_nobf(self, p):
        """expr_nobf : assignment_expr_nobf
                     | expr_nobf COMMA assignment_expr
        """
        if len(p) == 2:
            p[0] = p[1]
        else:
            p[0] = ast.Comma(left=p[1], right=p[3])

    # 12.2 Variable Statement
    def p_variable_statement(self, p):
        """variable_statement : VAR variable_declaration_list SEMI
                              | VAR variable_declaration_list auto_semi
        """
        p[0] = ast.VarStatement(p[2])

    def p_variable_declaration_list(self, p):
        """
        variable_declaration_list \
            : variable_declaration
            | variable_declaration_list COMMA variable_declaration
        """
        if len(p) == 2:
            p[0] = [p[1]]
        else:
            p[1].append(p[3])
            p[0] = p[1]

    def p_variable_declaration_list_noin(self, p):
        """
        variable_declaration_list_noin \
            : variable_declaration_noin
            | variable_declaration_list_noin COMMA variable_declaration_noin
        """
        if len(p) == 2:
            p[0] = [p[1]]
        else:
            p[1].append(p[3])
            p[0] = p[1]

    def p_variable_declaration(self, p):
        """variable_declaration : identifier
                                | identifier initializer
        """
        if len(p) == 2:
            p[0] = ast.VarDecl(p[1])
        else:
            p[0] = ast.VarDecl(p[1], p[2])

    def p_variable_declaration_noin(self, p):
        """variable_declaration_noin : identifier
                                     | identifier initializer_noin
        """
        if len(p) == 2:
            p[0] = ast.VarDecl(p[1])
        else:
            p[0] = ast.VarDecl(p[1], p[2])

    def p_initializer(self, p):
        """initializer : EQ assignment_expr"""
        p[0] = p[2]

    def p_initializer_noin(self, p):
        """initializer_noin : EQ assignment_expr_noin"""
        p[0] = p[2]

    # 12.3 Empty Statement
    def p_empty_statement(self, p):
        """empty_statement : SEMI"""
        p[0] = ast.EmptyStatement(p[1])

    # 12.4 Expression Statement
    def p_expr_statement(self, p):
        """expr_statement : expr_nobf SEMI
                          | expr_nobf auto_semi
        """
        p[0] = ast.ExprStatement(p[1])

    # 12.5 The if Statement
    def p_if_statement_1(self, p):
        """if_statement : IF LPAREN expr RPAREN statement"""
        p[0] = ast.If(predicate=p[3], consequent=p[5])

    def p_if_statement_2(self, p):
        """if_statement : IF LPAREN expr RPAREN statement ELSE statement"""
        p[0] = ast.If(predicate=p[3], consequent=p[5], alternative=p[7])

    # 12.6 Iteration Statements
    def p_iteration_statement_1(self, p):
        """
        iteration_statement \
            : DO statement WHILE LPAREN expr RPAREN SEMI
            | DO statement WHILE LPAREN expr RPAREN auto_semi
        """
        p[0] = ast.DoWhile(predicate=p[5], statement=p[2])

    def p_iteration_statement_2(self, p):
        """iteration_statement : WHILE LPAREN expr RPAREN statement"""
        p[0] = ast.While(predicate=p[3], statement=p[5])

    def p_iteration_statement_3(self, p):
        """
        iteration_statement \
            : FOR LPAREN expr_noin_opt SEMI expr_opt SEMI expr_opt RPAREN \
                  statement
            | FOR LPAREN VAR variable_declaration_list_noin SEMI expr_opt SEMI\
                  expr_opt RPAREN statement
        """
        if len(p) == 10:
            p[0] = ast.For(init=p[3], cond=p[5], count=p[7], statement=p[9])
        else:
            init = ast.VarStatement(p[4])
            p[0] = ast.For(init=init, cond=p[6], count=p[8], statement=p[10])

    def p_iteration_statement_4(self, p):
        """
        iteration_statement \
            : FOR LPAREN left_hand_side_expr IN expr RPAREN statement
        """
        p[0] = ast.ForIn(item=p[3], iterable=p[5], statement=p[7])

    def p_iteration_statement_5(self, p):
        """
        iteration_statement : \
            FOR LPAREN VAR identifier IN expr RPAREN statement
        """
        p[0] = ast.ForIn(item=ast.VarDecl(p[4]), iterable=p[6], statement=p[8])

    def p_iteration_statement_6(self, p):
        """
        iteration_statement \
          : FOR LPAREN VAR identifier initializer_noin IN expr RPAREN statement
        """
        p[0] = ast.ForIn(item=ast.VarDecl(identifier=p[4], initializer=p[5]),
                         iterable=p[7], statement=p[9])

    def p_expr_opt(self, p):
        """expr_opt : empty
                    | expr
        """
        p[0] = p[1]

    def p_expr_noin_opt(self, p):
        """expr_noin_opt : empty
                         | expr_noin
        """
        p[0] = p[1]

    # 12.7 The continue Statement
    def p_continue_statement_1(self, p):
        """continue_statement : CONTINUE SEMI
                              | CONTINUE auto_semi
        """
        p[0] = ast.Continue()

    def p_continue_statement_2(self, p):
        """continue_statement : CONTINUE identifier SEMI
                              | CONTINUE identifier auto_semi
        """
        p[0] = ast.Continue(p[2])

    # 12.8 The break Statement
    def p_break_statement_1(self, p):
        """break_statement : BREAK SEMI
                           | BREAK auto_semi
        """
        p[0] = ast.Break()

    def p_break_statement_2(self, p):
        """break_statement : BREAK identifier SEMI
                           | BREAK identifier auto_semi
        """
        p[0] = ast.Break(p[2])


    # 12.9 The return Statement
    def p_return_statement_1(self, p):
        """return_statement : RETURN SEMI
                            | RETURN auto_semi
        """
        p[0] = ast.Return()

    def p_return_statement_2(self, p):
        """return_statement : RETURN expr SEMI
                            | RETURN expr auto_semi
        """
        p[0] = ast.Return(expr=p[2])

    # 12.10 The with Statement
    def p_with_statement(self, p):
        """with_statement : WITH LPAREN expr RPAREN statement"""
        p[0] = ast.With(expr=p[3], statement=p[5])

    # 12.11 The switch Statement
    def p_switch_statement(self, p):
        """switch_statement : SWITCH LPAREN expr RPAREN case_block"""
        cases = []
        default = None
        # iterate over return values from case_block
        for item in p[5]:
            if isinstance(item, ast.Default):
                default = item
            elif isinstance(item, list):
                cases.extend(item)

        p[0] = ast.Switch(expr=p[3], cases=cases, default=default)

    def p_case_block(self, p):
        """
        case_block \
            : LBRACE case_clauses_opt RBRACE
            | LBRACE case_clauses_opt default_clause case_clauses_opt RBRACE
        """
        p[0] = p[2:-1]

    def p_case_clauses_opt(self, p):
        """case_clauses_opt : empty
                            | case_clauses
        """
        p[0] = p[1]

    def p_case_clauses(self, p):
        """case_clauses : case_clause
                        | case_clauses case_clause
        """
        if len(p) == 2:
            p[0] = [p[1]]
        else:
            p[1].append(p[2])
            p[0] = p[1]

    def p_case_clause(self, p):
        """case_clause : CASE expr COLON source_elements"""
        p[0] = ast.Case(expr=p[2], elements=p[4])

    def p_default_clause(self, p):
        """default_clause : DEFAULT COLON source_elements"""
        p[0] = ast.Default(elements=p[3])

    # 12.12 Labelled Statements
    def p_labelled_statement(self, p):
        """labelled_statement : identifier COLON statement"""
        p[0] = ast.Label(identifier=p[1], statement=p[3])

    # 12.13 The throw Statement
    def p_throw_statement(self, p):
        """throw_statement : THROW expr SEMI
                           | THROW expr auto_semi
        """
        p[0] = ast.Throw(expr=p[2])

    # 12.14 The try Statement
    def p_try_statement_1(self, p):
        """try_statement : TRY block catch"""
        p[0] = ast.Try(statements=p[2], catch=p[3])

    def p_try_statement_2(self, p):
        """try_statement : TRY block finally"""
        p[0] = ast.Try(statements=p[2], fin=p[3])

    def p_try_statement_3(self, p):
        """try_statement : TRY block catch finally"""
        p[0] = ast.Try(statements=p[2], catch=p[3], fin=p[4])

    def p_catch(self, p):
        """catch : CATCH LPAREN identifier RPAREN block"""
        p[0] = ast.Catch(identifier=p[3], elements=p[5])

    def p_finally(self, p):
        """finally : FINALLY block"""
        p[0] = ast.Finally(elements=p[2])

    # 12.15 The debugger statement
    def p_debugger_statement(self, p):
        """debugger_statement : DEBUGGER SEMI
                              | DEBUGGER auto_semi
        """
        p[0] = ast.Debugger(p[1])

    # 13 Function Definition
    def p_function_declaration(self, p):
        """
        function_declaration \
            : FUNCTION identifier LPAREN RPAREN LBRACE function_body RBRACE
            | FUNCTION identifier LPAREN formal_parameter_list RPAREN LBRACE \
                 function_body RBRACE
        """
        if len(p) == 8:
            p[0] = ast.FuncDecl(
                identifier=p[2], parameters=None, elements=p[6])
        else:
            p[0] = ast.FuncDecl(
                identifier=p[2], parameters=p[4], elements=p[7])

    def p_function_expr_1(self, p):
        """
        function_expr \
            : FUNCTION LPAREN RPAREN LBRACE function_body RBRACE
            | FUNCTION LPAREN formal_parameter_list RPAREN \
                LBRACE function_body RBRACE
        """
        if len(p) == 7:
            p[0] = ast.FuncExpr(
                identifier=None, parameters=None, elements=p[5])
        else:
            p[0] = ast.FuncExpr(
                identifier=None, parameters=p[3], elements=p[6])

    def p_function_expr_2(self, p):
        """
        function_expr \
            : FUNCTION identifier LPAREN RPAREN LBRACE function_body RBRACE
            | FUNCTION identifier LPAREN formal_parameter_list RPAREN \
                LBRACE function_body RBRACE
        """
        if len(p) == 8:
            p[0] = ast.FuncExpr(
                identifier=p[2], parameters=None, elements=p[6])
        else:
            p[0] = ast.FuncExpr(
                identifier=p[2], parameters=p[4], elements=p[7])


    def p_formal_parameter_list(self, p):
        """formal_parameter_list : identifier
                                 | formal_parameter_list COMMA identifier
        """
        if len(p) == 2:
            p[0] = [p[1]]
        else:
            p[1].append(p[3])
            p[0] = p[1]

    def p_function_body(self, p):
        """function_body : source_elements"""
        p[0] = p[1]
python2/slimit/scope.py	[[[1
186
###############################################################################
#
# Copyright (c) 2011 Ruslan Spivak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

__author__ = 'Ruslan Spivak <ruslan.spivak@gmail.com>'

import itertools

try:
    from collections import OrderedDict
except ImportError:
    from odict import odict as OrderedDict

from slimit.lexer import Lexer


ID_CHARS = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'

def powerset(iterable):
    """powerset('abc') -> a b c ab ac bc abc"""
    s = list(iterable)
    for chars in itertools.chain.from_iterable(
        itertools.combinations(s, r) for r in range(1, len(s)+1)
        ):
        yield ''.join(chars)


class SymbolTable(object):
    def __init__(self):
        self.globals = GlobalScope()


class Scope(object):

    def __init__(self, enclosing_scope=None):
        self.symbols = OrderedDict()
        # {symbol.name: mangled_name}
        self.mangled = {}
        # {mangled_name: symbol.name}
        self.rev_mangled = {}
        # names referenced from this scope and all sub-scopes
        # {name: scope} key is the name, value is the scope that
        # contains referenced name
        self.refs = {}
        # set to True if this scope or any subscope contains 'eval'
        self.has_eval = False
        # set to True if this scope or any subscope contains 'wit
        self.has_with = False
        self.enclosing_scope = enclosing_scope
        # sub-scopes
        self.children = []
        # add ourselves as a child to the enclosing scope
        if enclosing_scope is not None:
            self.enclosing_scope.add_child(self)
        self.base54 = powerset(ID_CHARS)

    def __contains__(self, sym):
        return sym.name in self.symbols

    def add_child(self, scope):
        self.children.append(scope)

    def define(self, sym):
        self.symbols[sym.name] = sym
        # track scope for every symbol
        sym.scope = self

    def resolve(self, name):
        sym = self.symbols.get(name)
        if sym is not None:
            return sym
        elif self.enclosing_scope is not None:
            return self.enclosing_scope.resolve(name)

    def get_enclosing_scope(self):
        return self.enclosing_scope

    def _get_scope_with_mangled(self, name):
        """Return a scope containing passed mangled name."""
        scope = self
        while True:
            parent = scope.get_enclosing_scope()
            if parent is None:
                return

            if name in parent.rev_mangled:
                return parent

            scope = parent

    def _get_scope_with_symbol(self, name):
        """Return a scope containing passed name as a symbol name."""
        scope = self
        while True:
            parent = scope.get_enclosing_scope()
            if parent is None:
                return

            if name in parent.symbols:
                return parent

            scope = parent

    def get_next_mangled_name(self):
        """
        1. Do not shadow a mangled name from a parent scope
           if we reference the original name from that scope
           in this scope or any sub-scope.

        2. Do not shadow an original name from a parent scope
           if it's not mangled and we reference it in this scope
           or any sub-scope.

        """
        while True:
            mangled = self.base54.next()

            # case 1
            ancestor = self._get_scope_with_mangled(mangled)
            if (ancestor is not None
                and self.refs.get(ancestor.rev_mangled[mangled]) is ancestor
                ):
                continue

            # case 2
            ancestor = self._get_scope_with_symbol(mangled)
            if (ancestor is not None
                and self.refs.get(mangled) is ancestor
                and mangled not in ancestor.mangled
                ):
                continue

            # make sure a new mangled name is not a reserved word
            if mangled.upper() in Lexer.keywords:
                continue

            return mangled


class GlobalScope(Scope):
    pass


class LocalScope(Scope):
    pass


class Symbol(object):
    def __init__(self, name):
        self.name = name
        self.scope = None
        self.nodes = []


class VarSymbol(Symbol):
    pass


class FuncSymbol(Symbol, Scope):
    """Function symbol is both a symbol and a scope for arguments."""

    def __init__(self, name, enclosing_scope):
        Symbol.__init__(self, name)
        Scope.__init__(self, enclosing_scope)


python2/slimit/unicode_chars.py	[[[1
156
###############################################################################
#
# Copyright (c) 2011 Ruslan Spivak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

__author__ = 'Ruslan Spivak <ruslan.spivak@gmail.com>'

# Reference - http://xregexp.com/plugins/#unicode
# Adapted from https://github.com/mishoo/UglifyJS/blob/master/lib/parse-js.js

# 'Uppercase letter (Lu)', 'Lowercase letter (Ll)',
# 'Titlecase letter(Lt)', 'Modifier letter (Lm)', 'Other letter (Lo)'
LETTER = (
    ur'[\u0041-\u005A\u0061-\u007A\u00AA\u00B5\u00BA\u00C0-\u00D6\u00D8-\u00F6'
    ur'\u00F8-\u02C1\u02C6-\u02D1\u02E0-\u02E4\u02EC\u02EE\u0370-\u0374\u0376'
    ur'\u0377\u037A-\u037D\u0386\u0388-\u038A\u038C\u038E-\u03A1\u03A3-\u03F5'
    ur'\u03F7-\u0481\u048A-\u0523\u0531-\u0556\u0559\u0561-\u0587\u05D0-\u05EA'
    ur'\u05F0-\u05F2\u0621-\u064A\u066E\u066F\u0671-\u06D3\u06D5\u06E5\u06E6'
    ur'\u06EE\u06EF\u06FA-\u06FC\u06FF\u0710\u0712-\u072F\u074D-\u07A5\u07B1'
    ur'\u07CA-\u07EA\u07F4\u07F5\u07FA\u0904-\u0939\u093D\u0950\u0958-\u0961'
    ur'\u0971\u0972\u097B-\u097F\u0985-\u098C\u098F\u0990\u0993-\u09A8'
    ur'\u09AA-\u09B0\u09B2\u09B6-\u09B9\u09BD\u09CE\u09DC\u09DD\u09DF-\u09E1'
    ur'\u09F0\u09F1\u0A05-\u0A0A\u0A0F\u0A10\u0A13-\u0A28\u0A2A-\u0A30\u0A32'
    ur'\u0A33\u0A35\u0A36\u0A38\u0A39\u0A59-\u0A5C\u0A5E\u0A72-\u0A74'
    ur'\u0A85-\u0A8D\u0A8F-\u0A91\u0A93-\u0AA8\u0AAA-\u0AB0\u0AB2\u0AB3'
    ur'\u0AB5-\u0AB9\u0ABD\u0AD0\u0AE0\u0AE1\u0B05-\u0B0C\u0B0F\u0B10'
    ur'\u0B13-\u0B28\u0B2A-\u0B30\u0B32\u0B33\u0B35-\u0B39\u0B3D\u0B5C\u0B5D'
    ur'\u0B5F-\u0B61\u0B71\u0B83\u0B85-\u0B8A\u0B8E-\u0B90\u0B92-\u0B95\u0B99'
    ur'\u0B9A\u0B9C\u0B9E\u0B9F\u0BA3\u0BA4\u0BA8-\u0BAA\u0BAE-\u0BB9\u0BD0'
    ur'\u0C05-\u0C0C\u0C0E-\u0C10\u0C12-\u0C28\u0C2A-\u0C33\u0C35-\u0C39\u0C3D'
    ur'\u0C58\u0C59\u0C60\u0C61\u0C85-\u0C8C\u0C8E-\u0C90\u0C92-\u0CA8'
    ur'\u0CAA-\u0CB3\u0CB5-\u0CB9\u0CBD\u0CDE\u0CE0\u0CE1\u0D05-\u0D0C'
    ur'\u0D0E-\u0D10\u0D12-\u0D28\u0D2A-\u0D39\u0D3D\u0D60\u0D61\u0D7A-\u0D7F'
    ur'\u0D85-\u0D96\u0D9A-\u0DB1\u0DB3-\u0DBB\u0DBD\u0DC0-\u0DC6\u0E01-\u0E30'
    ur'\u0E32\u0E33\u0E40-\u0E46\u0E81\u0E82\u0E84\u0E87\u0E88\u0E8A\u0E8D'
    ur'\u0E94-\u0E97\u0E99-\u0E9F\u0EA1-\u0EA3\u0EA5\u0EA7\u0EAA\u0EAB'
    ur'\u0EAD-\u0EB0\u0EB2\u0EB3\u0EBD\u0EC0-\u0EC4\u0EC6\u0EDC\u0EDD\u0F00'
    ur'\u0F40-\u0F47\u0F49-\u0F6C\u0F88-\u0F8B\u1000-\u102A\u103F\u1050-\u1055'
    ur'\u105A-\u105D\u1061\u1065\u1066\u106E-\u1070\u1075-\u1081\u108E'
    ur'\u10A0-\u10C5\u10D0-\u10FA\u10FC\u1100-\u1159\u115F-\u11A2\u11A8-\u11F9'
    ur'\u1200-\u1248\u124A-\u124D\u1250-\u1256\u1258\u125A-\u125D\u1260-\u1288'
    ur'\u128A-\u128D\u1290-\u12B0\u12B2-\u12B5\u12B8-\u12BE\u12C0\u12C2-\u12C5'
    ur'\u12C8-\u12D6\u12D8-\u1310\u1312-\u1315\u1318-\u135A\u1380-\u138F'
    ur'\u13A0-\u13F4\u1401-\u166C\u166F-\u1676\u1681-\u169A\u16A0-\u16EA'
    ur'\u1700-\u170C\u170E-\u1711\u1720-\u1731\u1740-\u1751\u1760-\u176C'
    ur'\u176E-\u1770\u1780-\u17B3\u17D7\u17DC\u1820-\u1877\u1880-\u18A8\u18AA'
    ur'\u1900-\u191C\u1950-\u196D\u1970-\u1974\u1980-\u19A9\u19C1-\u19C7'
    ur'\u1A00-\u1A16\u1B05-\u1B33\u1B45-\u1B4B\u1B83-\u1BA0\u1BAE\u1BAF'
    ur'\u1C00-\u1C23\u1C4D-\u1C4F\u1C5A-\u1C7D\u1D00-\u1DBF\u1E00-\u1F15'
    ur'\u1F18-\u1F1D\u1F20-\u1F45\u1F48-\u1F4D\u1F50-\u1F57\u1F59\u1F5B\u1F5D'
    ur'\u1F5F-\u1F7D\u1F80-\u1FB4\u1FB6-\u1FBC\u1FBE\u1FC2-\u1FC4\u1FC6-\u1FCC'
    ur'\u1FD0-\u1FD3\u1FD6-\u1FDB\u1FE0-\u1FEC\u1FF2-\u1FF4\u1FF6-\u1FFC\u2071'
    ur'\u207F\u2090-\u2094\u2102\u2107\u210A-\u2113\u2115\u2119-\u211D\u2124'
    ur'\u2126\u2128\u212A-\u212D\u212F-\u2139\u213C-\u213F\u2145-\u2149\u214E'
    ur'\u2183\u2184\u2C00-\u2C2E\u2C30-\u2C5E\u2C60-\u2C6F\u2C71-\u2C7D'
    ur'\u2C80-\u2CE4\u2D00-\u2D25\u2D30-\u2D65\u2D6F\u2D80-\u2D96\u2DA0-\u2DA6'
    ur'\u2DA8-\u2DAE\u2DB0-\u2DB6\u2DB8-\u2DBE\u2DC0-\u2DC6\u2DC8-\u2DCE'
    ur'\u2DD0-\u2DD6\u2DD8-\u2DDE\u2E2F\u3005\u3006\u3031-\u3035\u303B\u303C'
    ur'\u3041-\u3096\u309D-\u309F\u30A1-\u30FA\u30FC-\u30FF\u3105-\u312D'
    ur'\u3131-\u318E\u31A0-\u31B7\u31F0-\u31FF\u3400\u4DB5\u4E00\u9FC3'
    ur'\uA000-\uA48C\uA500-\uA60C\uA610-\uA61F\uA62A\uA62B\uA640-\uA65F'
    ur'\uA662-\uA66E\uA67F-\uA697\uA717-\uA71F\uA722-\uA788\uA78B\uA78C'
    ur'\uA7FB-\uA801\uA803-\uA805\uA807-\uA80A\uA80C-\uA822\uA840-\uA873'
    ur'\uA882-\uA8B3\uA90A-\uA925\uA930-\uA946\uAA00-\uAA28\uAA40-\uAA42'
    ur'\uAA44-\uAA4B\uAC00\uD7A3\uF900-\uFA2D\uFA30-\uFA6A\uFA70-\uFAD9'
    ur'\uFB00-\uFB06\uFB13-\uFB17\uFB1D\uFB1F-\uFB28\uFB2A-\uFB36\uFB38-\uFB3C'
    ur'\uFB3E\uFB40\uFB41\uFB43\uFB44\uFB46-\uFBB1\uFBD3-\uFD3D\uFD50-\uFD8F'
    ur'\uFD92-\uFDC7\uFDF0-\uFDFB\uFE70-\uFE74\uFE76-\uFEFC\uFF21-\uFF3A'
    ur'\uFF41-\uFF5A\uFF66-\uFFBE\uFFC2-\uFFC7\uFFCA-\uFFCF\uFFD2-\uFFD7'
    ur'\uFFDA-\uFFDC]'
    )

NON_SPACING_MARK = (
    ur'[\u0300-\u036F\u0483-\u0487\u0591-\u05BD\u05BF\u05C1\u05C2\u05C4\u05C5'
    ur'\u05C7\u0610-\u061A\u064B-\u065E\u0670\u06D6-\u06DC\u06DF-\u06E4\u06E7'
    ur'\u06E8\u06EA-\u06ED\u0711\u0730-\u074A\u07A6-\u07B0\u07EB-\u07F3'
    ur'\u0816-\u0819\u081B-\u0823\u0825-\u0827\u0829-\u082D\u0900-\u0902\u093C'
    ur'\u0941-\u0948\u094D\u0951-\u0955\u0962\u0963\u0981\u09BC\u09C1-\u09C4'
    ur'\u09CD\u09E2\u09E3\u0A01\u0A02\u0A3C\u0A41\u0A42\u0A47\u0A48'
    ur'\u0A4B-\u0A4D\u0A51\u0A70\u0A71\u0A75\u0A81\u0A82\u0ABC\u0AC1-\u0AC5'
    ur'\u0AC7\u0AC8\u0ACD\u0AE2\u0AE3\u0B01\u0B3C\u0B3F\u0B41-\u0B44\u0B4D'
    ur'\u0B56\u0B62\u0B63\u0B82\u0BC0\u0BCD\u0C3E-\u0C40\u0C46-\u0C48'
    ur'\u0C4A-\u0C4D\u0C55\u0C56\u0C62\u0C63\u0CBC\u0CBF\u0CC6\u0CCC\u0CCD'
    ur'\u0CE2\u0CE3\u0D41-\u0D44\u0D4D\u0D62\u0D63\u0DCA\u0DD2-\u0DD4\u0DD6'
    ur'\u0E31\u0E34-\u0E3A\u0E47-\u0E4E\u0EB1\u0EB4-\u0EB9\u0EBB\u0EBC'
    ur'\u0EC8-\u0ECD\u0F18\u0F19\u0F35\u0F37\u0F39\u0F71-\u0F7E\u0F80-\u0F84'
    ur'\u0F86\u0F87\u0F90-\u0F97\u0F99-\u0FBC\u0FC6\u102D-\u1030\u1032-\u1037'
    ur'\u1039\u103A\u103D\u103E\u1058\u1059\u105E-\u1060\u1071-\u1074\u1082'
    ur'\u1085\u1086\u108D\u109D\u135F\u1712-\u1714\u1732-\u1734\u1752\u1753'
    ur'\u1772\u1773\u17B7-\u17BD\u17C6\u17C9-\u17D3\u17DD\u180B-\u180D\u18A9'
    ur'\u1920-\u1922\u1927\u1928\u1932\u1939-\u193B\u1A17\u1A18\u1A56'
    ur'\u1A58-\u1A5E\u1A60\u1A62\u1A65-\u1A6C\u1A73-\u1A7C\u1A7F\u1B00-\u1B03'
    ur'\u1B34\u1B36-\u1B3A\u1B3C\u1B42\u1B6B-\u1B73\u1B80\u1B81\u1BA2-\u1BA5'
    ur'\u1BA8\u1BA9\u1C2C-\u1C33\u1C36\u1C37\u1CD0-\u1CD2\u1CD4-\u1CE0'
    ur'\u1CE2-\u1CE8\u1CED\u1DC0-\u1DE6\u1DFD-\u1DFF\u20D0-\u20DC\u20E1'
    ur'\u20E5-\u20F0\u2CEF-\u2CF1\u2DE0-\u2DFF\u302A-\u302F\u3099\u309A\uA66F'
    ur'\uA67C\uA67D\uA6F0\uA6F1\uA802\uA806\uA80B\uA825\uA826\uA8C4'
    ur'\uA8E0-\uA8F1\uA926-\uA92D\uA947-\uA951\uA980-\uA982\uA9B3\uA9B6-\uA9B9'
    ur'\uA9BC\uAA29-\uAA2E\uAA31\uAA32\uAA35\uAA36\uAA43\uAA4C\uAAB0'
    ur'\uAAB2-\uAAB4\uAAB7\uAAB8\uAABE\uAABF\uAAC1\uABE5\uABE8\uABED\uFB1E'
    ur'\uFE00-\uFE0F\uFE20-\uFE26]'
    )

COMBINING_SPACING_MARK = (
    ur'[\u0903\u093E-\u0940\u0949-\u094C\u094E\u0982\u0983\u09BE-\u09C0\u09C7'
    ur'\u09C8\u09CB\u09CC\u09D7\u0A03\u0A3E-\u0A40\u0A83\u0ABE-\u0AC0\u0AC9'
    ur'\u0ACB\u0ACC\u0B02\u0B03\u0B3E\u0B40\u0B47\u0B48\u0B4B\u0B4C\u0B57'
    ur'\u0BBE\u0BBF\u0BC1\u0BC2\u0BC6-\u0BC8\u0BCA-\u0BCC\u0BD7\u0C01-\u0C03'
    ur'\u0C41-\u0C44\u0C82\u0C83\u0CBE\u0CC0-\u0CC4\u0CC7\u0CC8\u0CCA\u0CCB'
    ur'\u0CD5\u0CD6\u0D02\u0D03\u0D3E-\u0D40\u0D46-\u0D48\u0D4A-\u0D4C\u0D57'
    ur'\u0D82\u0D83\u0DCF-\u0DD1\u0DD8-\u0DDF\u0DF2\u0DF3\u0F3E\u0F3F\u0F7F'
    ur'\u102B\u102C\u1031\u1038\u103B\u103C\u1056\u1057\u1062-\u1064'
    ur'\u1067-\u106D\u1083\u1084\u1087-\u108C\u108F\u109A-\u109C\u17B6'
    ur'\u17BE-\u17C5\u17C7\u17C8\u1923-\u1926\u1929-\u192B\u1930\u1931'
    ur'\u1933-\u1938\u19B0-\u19C0\u19C8\u19C9\u1A19-\u1A1B\u1A55\u1A57\u1A61'
    ur'\u1A63\u1A64\u1A6D-\u1A72\u1B04\u1B35\u1B3B\u1B3D-\u1B41\u1B43\u1B44'
    ur'\u1B82\u1BA1\u1BA6\u1BA7\u1BAA\u1C24-\u1C2B\u1C34\u1C35\u1CE1\u1CF2'
    ur'\uA823\uA824\uA827\uA880\uA881\uA8B4-\uA8C3\uA952\uA953\uA983\uA9B4'
    ur'\uA9B5\uA9BA\uA9BB\uA9BD-\uA9C0\uAA2F\uAA30\uAA33\uAA34\uAA4D\uAA7B'
    ur'\uABE3\uABE4\uABE6\uABE7\uABE9\uABEA\uABEC]'
    )

COMBINING_MARK = ur'%s|%s' % (NON_SPACING_MARK, COMBINING_SPACING_MARK)

CONNECTOR_PUNCTUATION = (
        ur'[\u005F\u203F\u2040\u2054\uFE33\uFE34\uFE4D-\uFE4F\uFF3F]'
        )

DIGIT = (
    ur'[\u0030-\u0039\u0660-\u0669\u06F0-\u06F9\u07C0-\u07C9\u0966-\u096F'
    ur'\u09E6-\u09EF\u0A66-\u0A6F\u0AE6-\u0AEF\u0B66-\u0B6F\u0BE6-\u0BEF'
    ur'\u0C66-\u0C6F\u0CE6-\u0CEF\u0D66-\u0D6F\u0E50-\u0E59\u0ED0-\u0ED9'
    ur'\u0F20-\u0F29\u1040-\u1049\u1090-\u1099\u17E0-\u17E9\u1810-\u1819'
    ur'\u1946-\u194F\u19D0-\u19DA\u1A80-\u1A89\u1A90-\u1A99\u1B50-\u1B59'
    ur'\u1BB0-\u1BB9\u1C40-\u1C49\u1C50-\u1C59\uA620-\uA629\uA8D0-\uA8D9'
    ur'\uA900-\uA909\uA9D0-\uA9D9\uAA50-\uAA59\uABF0-\uABF9\uFF10-\uFF19]'
    )
python2/slimit/yacctab.py	[[[1
330

# yacctab.py
# This file is automatically generated. Do not edit.
_tabversion = '3.2'

_lr_method = 'LALR'

_lr_signature = ':\xbe\xd7 \xc4\xd1\xd4\x7f\xef\xac_JV{\x19\xa8'
    
_lr_action_items = {'DO':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[68,-22,-15,68,-23,-21,-13,-19,-17,-20,-16,-11,68,-9,-10,-8,-24,-12,-6,68,-244,-18,-14,-7,-292,-291,-2,68,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,68,68,-290,-288,68,68,-273,68,68,-251,-274,-247,68,68,68,68,68,68,-293,68,-254,-289,-275,-249,-250,-248,68,-294,68,-255,68,68,68,68,-256,-252,-276,-253,]),'OREQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,206,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,206,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,206,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,206,-295,-296,-297,-297,-298,-298,]),'DIVEQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,193,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,193,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,193,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,193,-295,-296,-297,-297,-298,-298,]),'RETURN':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[26,-22,-15,26,-23,-21,-13,-19,-17,-20,-16,-11,26,-9,-10,-8,-24,-12,-6,26,-244,-18,-14,-7,-292,-291,-2,26,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,26,26,-290,-288,26,26,-273,26,26,-251,-274,-247,26,26,26,26,26,26,-293,26,-254,-289,-275,-249,-250,-248,26,-294,26,-255,26,26,26,26,-256,-252,-276,-253,]),'RSHIFTEQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,194,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,194,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,194,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,194,-295,-296,-297,-297,-298,-298,]),'DEFAULT':([2,5,7,13,19,21,28,29,31,36,43,45,50,58,59,62,65,67,72,75,77,111,114,115,116,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,414,416,435,471,472,473,475,496,497,498,499,508,514,516,518,519,522,523,524,529,532,534,541,542,543,544,547,],[-22,-15,-5,-23,-21,-13,-19,-17,-20,-16,-11,-9,-10,-8,-4,-24,-12,-6,-244,-18,-14,-7,-292,-291,-2,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,-290,-288,-273,-251,-274,-1,-247,-278,521,-279,-277,-293,-254,-289,-280,-275,-249,-250,-248,-294,-255,-1,-256,-252,-281,-276,-253,]),'VOID':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[11,-22,-1,-15,11,11,11,11,-23,-21,-13,11,11,11,-19,-17,11,-20,-16,11,-11,11,-9,11,-10,-8,-24,-12,-6,11,-244,-18,-14,11,11,11,11,11,11,-53,-52,-51,-7,-292,-291,-2,11,11,11,11,11,11,-270,-269,11,-245,-246,11,11,11,11,11,11,11,-261,-262,11,11,11,11,11,-265,-266,-25,11,11,11,11,11,11,11,11,11,11,11,11,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,11,11,-1,-54,11,11,-232,-233,11,-283,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,-271,-272,11,11,11,11,11,11,11,-287,-286,-26,-263,-264,-268,-267,-284,-285,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,11,-290,-288,11,11,11,11,-273,11,11,11,11,11,-251,-274,-247,11,11,11,11,11,11,11,11,11,11,-293,11,11,-254,-289,-275,-249,-250,-248,11,-294,11,-255,11,11,11,11,-256,-252,-276,-253,]),'SETPROP':([104,349,],[231,231,]),'NUMBER':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,54,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,98,104,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,228,231,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,349,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[70,-22,-1,-15,70,70,70,70,-23,-21,-13,70,70,70,-19,-17,70,-20,-16,70,-11,70,-9,70,-10,70,-8,-24,-12,-6,70,-244,-18,-14,70,70,70,70,70,70,-53,-52,-51,70,70,-7,-292,-291,-2,70,70,70,70,70,70,-270,-269,70,-245,-246,70,70,70,70,70,70,70,-261,-262,70,70,70,70,70,-265,-266,-25,70,70,70,70,70,70,70,70,70,70,70,70,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,70,70,-1,-54,70,70,70,70,-232,-233,70,-283,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,-271,-272,70,70,70,70,70,70,70,-287,-286,-26,-263,-264,-268,-267,-284,-285,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,70,-290,-288,70,70,70,70,-273,70,70,70,70,70,-251,-274,-247,70,70,70,70,70,70,70,70,70,70,-293,70,70,-254,-289,-275,-249,-250,-248,70,-294,70,-255,70,70,70,70,-256,-252,-276,-253,]),'LBRACKET':([0,2,3,4,5,6,7,8,10,11,13,15,16,19,20,21,23,24,25,26,28,29,30,31,36,38,40,41,43,44,45,48,49,50,54,58,61,62,63,64,65,67,68,70,71,72,75,77,78,79,80,81,83,84,85,87,88,89,90,92,93,94,95,98,102,103,105,107,108,109,110,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,159,160,163,164,168,169,170,171,173,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,216,218,219,222,226,227,229,238,239,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,303,305,310,311,312,313,314,315,319,322,323,338,340,341,342,343,345,346,350,352,353,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,411,412,413,414,416,417,418,420,421,424,427,429,433,434,435,436,441,443,446,447,471,472,475,477,482,483,488,491,492,493,495,501,502,504,506,508,509,512,514,516,519,522,523,524,526,528,529,531,532,533,534,536,537,540,541,542,544,547,],[4,-22,-28,-1,-15,4,4,-72,4,4,-23,-71,-27,-21,-42,-13,4,-41,4,4,-19,-17,4,-20,-16,-30,4,158,-11,4,-9,4,168,-10,4,-8,-31,-24,-32,-33,-12,-6,4,-35,-34,-244,-18,-14,-37,-36,-43,-44,4,4,-38,-29,4,4,4,4,-53,-52,-51,4,-39,226,-40,-67,-66,238,-41,-7,-292,-291,-2,4,4,4,4,4,4,-270,-269,4,-245,-246,4,4,4,4,4,4,-85,4,-261,-262,4,-84,4,4,238,4,4,-265,-266,-25,4,4,4,4,4,4,4,4,4,4,4,4,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,4,4,-1,-47,-46,-54,238,4,-81,-55,4,-80,-232,-233,4,-283,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,-271,-272,4,4,4,4,4,4,4,-87,-88,-287,-286,-26,-263,-264,-74,-75,-268,-267,-45,-284,-285,4,4,-70,-83,-56,4,-69,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,4,-86,4,-89,-290,-288,-73,4,4,4,-48,-82,-57,-68,4,-273,4,4,4,4,4,-251,-274,-247,4,-295,4,4,4,4,4,4,4,4,4,-296,-293,4,4,-254,-289,-275,-249,-250,-248,-297,4,-294,4,-255,4,4,4,-298,4,-256,-252,-276,-253,]),'BXOR':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,53,60,61,63,64,70,71,73,74,76,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,135,136,140,142,144,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,291,292,293,294,301,303,305,315,318,319,325,326,327,328,329,330,331,332,333,334,335,336,338,345,346,350,353,357,358,359,360,361,362,363,364,365,366,368,369,370,371,372,373,374,375,377,378,382,411,413,417,424,427,429,433,448,449,450,451,452,453,454,455,456,457,458,462,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,171,-104,-31,-32,-33,-35,-34,-176,-167,-182,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-137,-115,265,-172,-129,-96,-178,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,-162,-180,-144,399,-174,-96,-87,-88,-74,-183,-75,171,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,-177,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,265,-132,-131,-130,-179,-158,-159,-161,-160,-124,-125,-173,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,-175,-181,-163,-164,-166,-165,399,-96,-295,-296,-297,-297,-298,-298,]),'WHILE':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,180,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[52,-22,-15,52,-23,-21,-13,-19,-17,-20,-16,-11,52,-9,-10,-8,-24,-12,-6,52,-244,-18,-14,-7,-292,-291,-2,52,-270,-269,-245,-246,-261,-262,-265,-266,-25,324,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,52,52,-290,-288,52,52,-273,52,52,-251,-274,-247,52,52,52,52,52,52,-293,52,-254,-289,-275,-249,-250,-248,52,-294,52,-255,52,52,52,52,-256,-252,-276,-253,]),'COLON':([3,16,20,24,38,61,63,64,70,71,78,79,80,81,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,130,131,132,134,135,136,137,139,140,141,142,144,145,156,166,209,212,216,218,221,222,223,224,227,229,232,234,235,236,239,288,290,291,292,293,294,297,298,302,305,338,345,346,350,353,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,376,377,378,379,380,381,382,413,424,427,429,433,442,448,449,450,451,452,453,454,455,456,457,458,462,464,466,467,468,480,482,506,515,517,521,526,537,],[-28,-27,-42,126,-30,-31,-32,-33,-35,-34,-37,-36,-43,-44,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-190,-196,-137,-115,-184,-172,-208,-226,-129,-202,-96,-178,-113,-109,-114,-110,342,-47,-46,-77,-76,-97,-98,-81,-55,-65,-63,352,-64,-80,-198,-162,-180,-144,-186,-174,-192,-210,-204,-88,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,-191,-132,-131,-130,-179,-158,-159,-161,-160,-227,-124,-125,434,-197,-209,-173,-89,-48,-82,-57,-68,-193,-149,-146,-145,-148,-147,-175,-181,-163,-164,-166,-165,-187,-96,-211,493,-199,-203,-295,-296,-205,534,536,-297,-298,]),'BNOT':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[30,-22,-1,-15,30,30,30,30,-23,-21,-13,30,30,30,-19,-17,30,-20,-16,30,-11,30,-9,30,-10,-8,-24,-12,-6,30,-244,-18,-14,30,30,30,30,30,30,-53,-52,-51,-7,-292,-291,-2,30,30,30,30,30,30,-270,-269,30,-245,-246,30,30,30,30,30,30,30,-261,-262,30,30,30,30,30,-265,-266,-25,30,30,30,30,30,30,30,30,30,30,30,30,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,30,30,-1,-54,30,30,-232,-233,30,-283,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,-271,-272,30,30,30,30,30,30,30,-287,-286,-26,-263,-264,-268,-267,-284,-285,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,30,-290,-288,30,30,30,30,-273,30,30,30,30,30,-251,-274,-247,30,30,30,30,30,30,30,30,30,30,-293,30,30,-254,-289,-275,-249,-250,-248,30,-294,30,-255,30,30,30,30,-256,-252,-276,-253,]),'LSHIFT':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,132,134,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,292,301,303,305,315,319,330,331,332,333,334,335,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,377,378,411,413,417,424,427,429,433,448,449,450,451,452,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,122,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,264,-115,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,264,-96,-87,-88,-74,-75,264,264,264,264,264,264,-45,-70,-83,-56,-69,-117,-118,-116,264,264,264,264,264,264,-132,-131,-130,-124,-125,-86,-89,-73,-48,-82,-57,-68,264,264,264,264,264,-96,-295,-296,-297,-297,-298,-298,]),'NEW':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,54,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,98,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[54,-22,-1,-15,98,54,98,98,-23,-21,-13,98,98,98,-19,-17,98,-20,-16,98,-11,54,-9,98,-10,98,-8,-24,-12,-6,54,-244,-18,-14,98,98,98,98,54,98,-53,-52,-51,98,-7,-292,-291,-2,98,98,98,98,98,54,-270,-269,98,-245,-246,98,98,98,98,98,98,98,-261,-262,98,98,54,54,98,-265,-266,-25,54,98,98,98,98,98,98,98,98,98,98,54,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,98,98,-1,-54,98,98,-232,-233,98,-283,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,-271,-272,98,98,98,98,98,98,98,-287,-286,-26,-263,-264,-268,-267,-284,-285,98,98,98,54,54,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,98,-290,-288,54,98,54,98,-273,54,54,98,98,98,-251,-274,-247,54,54,98,98,54,98,98,54,54,54,-293,98,54,-254,-289,-275,-249,-250,-248,54,-294,54,-255,54,54,54,54,-256,-252,-276,-253,]),'DIV':([3,8,12,15,16,20,24,27,35,38,41,46,49,60,61,63,64,70,71,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,134,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,248,249,281,282,283,301,303,305,315,319,338,345,346,350,353,357,358,359,377,378,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-119,151,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,251,-115,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,251,251,-122,-121,-120,-96,-87,-88,-74,-75,-45,-70,-83,-56,-69,-117,-118,-116,251,251,-86,-89,-73,-48,-82,-57,-68,-96,-295,-296,-297,-297,-298,-298,]),'NULL':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,54,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,98,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[71,-22,-1,-15,71,71,71,71,-23,-21,-13,71,71,71,-19,-17,71,-20,-16,71,-11,71,-9,71,-10,71,-8,-24,-12,-6,71,-244,-18,-14,71,71,71,71,71,71,-53,-52,-51,71,-7,-292,-291,-2,71,71,71,71,71,71,-270,-269,71,-245,-246,71,71,71,71,71,71,71,-261,-262,71,71,71,71,71,-265,-266,-25,71,71,71,71,71,71,71,71,71,71,71,71,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,71,71,-1,-54,71,71,-232,-233,71,-283,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,-271,-272,71,71,71,71,71,71,71,-287,-286,-26,-263,-264,-268,-267,-284,-285,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,71,-290,-288,71,71,71,71,-273,71,71,71,71,71,-251,-274,-247,71,71,71,71,71,71,71,71,71,71,-293,71,71,-254,-289,-275,-249,-250,-248,71,-294,71,-255,71,71,71,71,-256,-252,-276,-253,]),'TRUE':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,54,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,98,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[63,-22,-1,-15,63,63,63,63,-23,-21,-13,63,63,63,-19,-17,63,-20,-16,63,-11,63,-9,63,-10,63,-8,-24,-12,-6,63,-244,-18,-14,63,63,63,63,63,63,-53,-52,-51,63,-7,-292,-291,-2,63,63,63,63,63,63,-270,-269,63,-245,-246,63,63,63,63,63,63,63,-261,-262,63,63,63,63,63,-265,-266,-25,63,63,63,63,63,63,63,63,63,63,63,63,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,63,63,-1,-54,63,63,-232,-233,63,-283,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,-271,-272,63,63,63,63,63,63,63,-287,-286,-26,-263,-264,-268,-267,-284,-285,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,63,-290,-288,63,63,63,63,-273,63,63,63,63,63,-251,-274,-247,63,63,63,63,63,63,63,63,63,63,-293,63,63,-254,-289,-275,-249,-250,-248,63,-294,63,-255,63,63,63,63,-256,-252,-276,-253,]),'MINUS':([0,2,3,4,5,6,7,8,10,11,12,13,15,16,19,20,21,22,23,24,25,26,27,28,29,30,31,35,36,38,40,41,43,44,45,46,48,49,50,58,60,61,62,63,64,65,67,68,70,71,72,75,77,78,79,80,81,82,83,84,85,87,88,89,90,92,93,94,95,97,99,100,101,102,103,105,106,107,108,109,110,111,112,113,114,115,116,120,121,122,123,124,125,126,127,128,133,134,140,142,143,145,146,147,148,149,150,151,152,155,156,158,159,160,163,164,166,168,169,170,171,172,173,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,209,210,213,215,216,218,219,221,222,223,224,226,227,229,238,239,240,241,243,245,246,247,248,249,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,281,282,283,301,303,305,310,311,312,313,314,315,319,322,323,338,340,341,342,343,345,346,350,352,353,357,358,359,368,369,370,377,378,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,411,412,413,414,416,417,418,420,421,424,427,429,433,434,435,436,441,443,446,447,464,471,472,475,477,482,483,488,491,492,493,495,501,502,504,506,508,509,512,514,516,519,522,523,524,526,528,529,531,532,533,534,536,537,540,541,542,544,547,],[6,-22,-28,-1,-15,6,6,-72,6,6,-94,-23,-71,-27,-21,-42,-13,124,6,-41,6,6,-119,-19,-17,6,-20,-126,-16,-30,6,-95,-11,6,-9,-105,6,-78,-10,-8,-104,-31,-24,-32,-33,-12,-6,6,-35,-34,-244,-18,-14,-37,-36,-43,-44,-99,6,6,-38,-29,6,6,6,6,-53,-52,-51,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-7,-111,-107,-292,-291,-2,6,6,6,6,6,-108,6,-106,-123,-270,-115,274,-96,-269,-113,6,-245,-246,6,6,6,6,6,-109,6,-85,6,-261,-262,-114,6,-84,6,6,-79,-76,6,6,-265,-266,-25,6,6,6,6,6,6,6,6,6,6,6,6,-216,-221,-222,-100,-219,-217,-224,-215,-218,-220,-223,-101,-214,-225,6,-110,6,-99,-1,-47,-46,-54,-77,-76,-97,-98,6,-81,-55,6,-80,-232,-233,6,274,274,274,-127,-128,-283,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,-271,-272,6,6,6,6,6,6,6,-122,-121,-120,-96,-87,-88,-287,-286,-26,-263,-264,-74,-75,-268,-267,-45,-284,-285,6,6,-70,-83,-56,6,-69,-117,-118,-116,274,274,274,-124,-125,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,-86,6,-89,-290,-288,-73,6,6,6,-48,-82,-57,-68,6,-273,6,6,6,6,6,-96,-251,-274,-247,6,-295,6,6,6,6,6,6,6,6,6,-296,-293,6,6,-254,-289,-275,-249,-250,-248,-297,6,-294,6,-255,6,6,6,-298,6,-256,-252,-276,-253,]),'MULT':([3,8,12,15,16,20,24,27,35,38,41,46,49,60,61,63,64,70,71,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,134,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,248,249,281,282,283,301,303,305,315,319,338,345,346,350,353,357,358,359,377,378,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-119,152,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,253,-115,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,253,253,-122,-121,-120,-96,-87,-88,-74,-75,-45,-70,-83,-56,-69,-117,-118,-116,253,253,-86,-89,-73,-48,-82,-57,-68,-96,-295,-296,-297,-297,-298,-298,]),'DEBUGGER':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[14,-22,-15,14,-23,-21,-13,-19,-17,-20,-16,-11,14,-9,-10,-8,-24,-12,-6,14,-244,-18,-14,-7,-292,-291,-2,14,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,14,14,-290,-288,14,14,-273,14,14,-251,-274,-247,14,14,14,14,14,14,-293,14,-254,-289,-275,-249,-250,-248,14,-294,14,-255,14,14,14,14,-256,-252,-276,-253,]),'CASE':([2,5,7,13,19,21,28,29,31,36,43,45,50,58,59,62,65,67,72,75,77,111,114,115,116,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,414,416,435,471,472,473,475,496,498,508,514,516,518,519,520,522,523,524,529,532,534,536,541,542,543,544,545,547,],[-22,-15,-5,-23,-21,-13,-19,-17,-20,-16,-11,-9,-10,-8,-4,-24,-12,-6,-244,-18,-14,-7,-292,-291,-2,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,-290,-288,-273,-251,-274,495,-247,495,-279,-293,-254,-289,-280,-275,495,-249,-250,-248,-294,-255,-1,-1,-256,-252,-281,-276,-282,-253,]),'LE':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,74,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,292,301,303,305,315,319,326,327,328,329,330,331,332,333,334,335,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,372,373,374,375,377,378,411,413,417,424,427,429,433,448,449,450,451,452,455,456,457,458,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,190,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,258,-137,-115,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,397,-144,-96,-87,-88,-74,-75,258,258,258,258,-155,-152,-151,-154,-153,-156,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,258,258,258,258,-124,-125,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,258,258,258,258,-96,-295,-296,-297,-297,-298,-298,]),'RPAREN':([3,16,20,38,61,63,64,70,71,78,79,80,81,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,130,131,132,134,135,136,137,139,140,141,142,144,145,153,156,160,166,208,209,216,218,221,222,223,224,227,229,239,279,284,286,287,305,306,307,317,321,338,339,344,345,346,350,353,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,376,377,378,380,381,382,387,413,424,425,427,428,429,433,437,460,461,465,469,470,474,479,480,482,489,491,506,509,511,513,526,530,537,],[-28,-27,-42,-30,-31,-32,-33,-35,-34,-37,-36,-43,-44,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-190,-196,-137,-115,-184,-172,-208,-226,-129,-202,-96,-178,-113,285,-109,305,-114,338,-110,-47,-46,-77,-76,-97,-98,-81,-55,-80,383,384,-299,388,-88,413,-90,418,419,-45,421,426,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,-191,-132,-131,-130,-179,-158,-159,-161,-160,-227,-124,-125,-197,-209,-173,440,-89,-48,476,-82,478,-57,-68,-300,-257,-258,492,-91,494,500,505,-203,-295,512,-1,-296,-1,531,533,-297,540,-298,]),'URSHIFT':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,132,134,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,292,301,303,305,315,319,330,331,332,333,334,335,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,377,378,411,413,417,424,427,429,433,448,449,450,451,452,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,120,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,262,-115,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,262,-96,-87,-88,-74,-75,262,262,262,262,262,262,-45,-70,-83,-56,-69,-117,-118,-116,262,262,262,262,262,262,-132,-131,-130,-124,-125,-86,-89,-73,-48,-82,-57,-68,262,262,262,262,262,-96,-295,-296,-297,-297,-298,-298,]),'SEMI':([0,1,2,3,5,7,8,12,13,14,15,16,18,19,20,21,22,24,26,27,28,29,31,34,35,36,38,41,43,44,45,46,47,49,50,51,53,55,56,58,60,61,62,63,64,65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,125,126,127,128,129,130,131,132,133,134,135,136,137,138,139,140,141,142,143,144,145,147,148,155,156,159,163,164,165,166,169,172,173,176,177,178,179,196,204,209,211,213,214,216,218,221,222,223,224,227,229,239,240,241,244,245,246,247,248,249,250,270,271,280,281,282,283,288,290,291,292,293,294,295,296,297,298,299,300,301,302,303,305,310,311,312,313,314,315,318,319,320,322,323,325,326,327,328,329,330,331,332,333,334,335,336,337,338,340,341,345,346,350,353,355,356,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,376,377,378,380,381,382,383,386,390,391,392,404,411,413,414,416,417,418,421,422,424,427,429,433,435,436,441,442,443,445,448,449,450,451,452,453,454,455,456,457,458,459,460,461,462,463,464,466,468,471,472,475,477,480,482,483,485,486,487,490,492,500,501,502,504,506,508,510,512,514,515,516,519,522,523,524,526,528,529,531,532,533,534,536,537,540,541,542,544,547,],[72,-206,-22,-28,-15,72,-72,-94,-23,115,-71,-27,-150,-21,-42,-13,-133,-41,143,-119,-19,-17,-20,147,-126,-16,-30,-95,-11,72,-9,-105,163,-78,-10,-230,-188,-212,-200,-8,-104,-31,-24,-32,-33,-12,176,-6,72,-194,-35,-34,-244,-176,-167,-18,-182,-14,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-7,-111,-107,-292,-291,-2,240,-238,-234,-108,72,-106,-123,-157,-190,-196,-137,-270,-115,-184,-172,-208,270,-226,-129,-202,-96,-269,-178,-113,-245,-246,-1,-109,-85,-261,-262,313,-114,-84,-79,-76,-265,-266,323,-25,-100,-101,-110,340,-99,-201,-47,-46,-77,-76,-97,-98,-81,-55,-80,-232,-233,-239,-136,-135,-134,-127,-128,-283,-271,-272,-231,-122,-121,-120,-198,-162,-180,-144,-186,-174,-228,404,-192,-210,-260,-259,-96,-204,-87,-88,-287,-286,-26,-263,-264,-74,-183,-75,-195,-268,-267,-189,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,-177,-213,-45,-284,-285,-70,-83,-56,-69,-235,-242,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,-191,-132,-131,-130,-179,-158,-159,-161,-160,-227,-124,-125,-197,-209,-173,72,72,-236,443,-240,-1,-86,-89,-290,-288,-73,72,72,-207,-48,-82,-57,-68,-273,72,72,-193,-1,-241,-149,-146,-145,-148,-147,-175,-181,-163,-164,-166,-165,491,-257,-258,-187,-229,-96,-211,-199,-251,-274,-247,72,-203,-295,72,509,-237,-240,-243,72,522,72,72,72,-296,-293,-241,72,-254,-205,-289,-275,-249,-250,-248,-297,72,-294,72,-255,72,72,72,-298,72,-256,-252,-276,-253,]),'WITH':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[32,-22,-15,32,-23,-21,-13,-19,-17,-20,-16,-11,32,-9,-10,-8,-24,-12,-6,32,-244,-18,-14,-7,-292,-291,-2,32,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,32,32,-290,-288,32,32,-273,32,32,-251,-274,-247,32,32,32,32,32,32,-293,32,-254,-289,-275,-249,-250,-248,32,-294,32,-255,32,32,32,32,-256,-252,-276,-253,]),'MODEQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,198,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,198,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,198,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,198,-295,-296,-297,-297,-298,-298,]),'NE':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,73,74,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,136,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,292,294,301,303,305,315,319,326,327,328,329,330,331,332,333,334,335,336,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,372,373,374,375,377,378,382,411,413,417,424,427,429,433,448,449,450,451,452,453,455,456,457,458,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,183,-167,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-137,-115,267,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,-162,-144,401,-96,-87,-88,-74,-75,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,183,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,-158,-159,-161,-160,-124,-125,267,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,401,-163,-164,-166,-165,-96,-295,-296,-297,-297,-298,-298,]),'MULTEQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,200,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,200,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,200,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,200,-295,-296,-297,-297,-298,-298,]),'EQEQ':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,73,74,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,136,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,292,294,301,303,305,315,319,326,327,328,329,330,331,332,333,334,335,336,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,372,373,374,375,377,378,382,411,413,417,424,427,429,433,448,449,450,451,452,453,455,456,457,458,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,182,-167,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-137,-115,266,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,-162,-144,400,-96,-87,-88,-74,-75,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,182,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,-158,-159,-161,-160,-124,-125,266,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,400,-163,-164,-166,-165,-96,-295,-296,-297,-297,-298,-298,]),'SWITCH':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[57,-22,-15,57,-23,-21,-13,-19,-17,-20,-16,-11,57,-9,-10,-8,-24,-12,-6,57,-244,-18,-14,-7,-292,-291,-2,57,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,57,57,-290,-288,57,57,-273,57,57,-251,-274,-247,57,57,57,57,57,57,-293,57,-254,-289,-275,-249,-250,-248,57,-294,57,-255,57,57,57,57,-256,-252,-276,-253,]),'LSHIFTEQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,202,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,202,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,202,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,202,-295,-296,-297,-297,-298,-298,]),'PLUS':([0,2,3,4,5,6,7,8,10,11,12,13,15,16,19,20,21,22,23,24,25,26,27,28,29,30,31,35,36,38,40,41,43,44,45,46,48,49,50,58,60,61,62,63,64,65,67,68,70,71,72,75,77,78,79,80,81,82,83,84,85,87,88,89,90,92,93,94,95,97,99,100,101,102,103,105,106,107,108,109,110,111,112,113,114,115,116,120,121,122,123,124,125,126,127,128,133,134,140,142,143,145,146,147,148,149,150,151,152,155,156,158,159,160,163,164,166,168,169,170,171,172,173,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,196,197,198,199,200,201,202,203,204,205,206,207,209,210,213,215,216,218,219,221,222,223,224,226,227,229,238,239,240,241,243,245,246,247,248,249,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,281,282,283,301,303,305,310,311,312,313,314,315,319,322,323,338,340,341,342,343,345,346,350,352,353,357,358,359,368,369,370,377,378,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,411,412,413,414,416,417,418,420,421,424,427,429,433,434,435,436,441,443,446,447,464,471,472,475,477,482,483,488,491,492,493,495,501,502,504,506,508,509,512,514,516,519,522,523,524,526,528,529,531,532,533,534,536,537,540,541,542,544,547,],[10,-22,-28,-1,-15,10,10,-72,10,10,-94,-23,-71,-27,-21,-42,-13,123,10,-41,10,10,-119,-19,-17,10,-20,-126,-16,-30,10,-95,-11,10,-9,-105,10,-78,-10,-8,-104,-31,-24,-32,-33,-12,-6,10,-35,-34,-244,-18,-14,-37,-36,-43,-44,-99,10,10,-38,-29,10,10,10,10,-53,-52,-51,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-7,-111,-107,-292,-291,-2,10,10,10,10,10,-108,10,-106,-123,-270,-115,273,-96,-269,-113,10,-245,-246,10,10,10,10,10,-109,10,-85,10,-261,-262,-114,10,-84,10,10,-79,-76,10,10,-265,-266,-25,10,10,10,10,10,10,10,10,10,10,10,10,-216,-221,-222,-100,-219,-217,-224,-215,-218,-220,-223,-101,-214,-225,10,-110,10,-99,-1,-47,-46,-54,-77,-76,-97,-98,10,-81,-55,10,-80,-232,-233,10,273,273,273,-127,-128,-283,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,-271,-272,10,10,10,10,10,10,10,-122,-121,-120,-96,-87,-88,-287,-286,-26,-263,-264,-74,-75,-268,-267,-45,-284,-285,10,10,-70,-83,-56,10,-69,-117,-118,-116,273,273,273,-124,-125,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,10,-86,10,-89,-290,-288,-73,10,10,10,-48,-82,-57,-68,10,-273,10,10,10,10,10,-96,-251,-274,-247,10,-295,10,10,10,10,10,10,10,10,10,-296,-293,10,10,-254,-289,-275,-249,-250,-248,-297,10,-294,10,-255,10,10,10,-298,10,-256,-252,-276,-253,]),'CATCH':([161,312,],[309,-26,]),'COMMA':([1,3,4,8,12,15,16,18,20,22,24,27,34,35,38,41,46,49,51,53,55,56,60,61,63,64,69,70,71,73,74,76,78,79,80,81,82,85,87,91,93,94,97,99,100,101,102,103,105,106,107,108,109,110,112,113,117,118,119,125,127,128,129,130,131,132,134,135,136,137,138,139,140,141,142,144,145,156,159,166,169,172,173,196,204,208,209,211,213,214,215,216,217,218,219,221,222,223,224,227,229,230,233,239,244,245,246,247,248,249,279,280,281,282,283,284,286,288,290,291,292,293,294,295,297,298,299,301,302,303,304,305,306,307,315,316,317,318,319,320,321,325,326,327,328,329,330,331,332,333,334,335,336,337,338,339,345,346,347,350,353,354,355,356,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,376,377,378,380,381,382,387,390,391,392,411,413,417,422,423,424,425,427,429,430,432,433,437,442,445,448,449,450,451,452,453,454,455,456,457,458,461,462,463,464,465,466,468,469,474,479,480,482,486,487,489,490,506,508,510,511,515,517,526,529,537,538,546,],[-206,-28,93,-72,-94,-71,-27,-150,-42,-133,-41,-119,149,-126,-30,-95,-105,-78,-230,-188,-212,-200,-104,-31,-32,-33,-194,-35,-34,-176,-167,-182,-37,-36,-43,-44,-99,-38,-29,215,-53,219,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,242,-238,-234,-108,-106,-123,-157,-190,-196,-137,-115,-184,-172,-208,272,-226,-129,-202,-96,-178,-113,-109,-85,-114,-84,-79,-76,-100,-101,272,-110,272,-99,-201,93,-47,-49,-46,-54,-77,-76,-97,-98,-81,-55,349,-58,-80,-239,-136,-135,-134,-127,-128,272,-231,-122,-121,-120,385,-299,-198,-162,-180,-144,-186,-174,-228,-192,-210,406,-96,-204,-87,272,-88,412,-90,-74,272,272,-183,-75,-195,272,-189,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,-177,-213,-45,272,-70,-83,272,-56,-69,272,-235,-242,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,-191,-132,-131,-130,-179,-158,-159,-161,-160,-227,-124,-125,-197,-209,-173,385,-236,444,-240,-86,-89,-73,-207,-50,-48,385,-82,-57,-59,-60,-68,-300,-193,-241,-149,-146,-145,-148,-147,-175,-181,-163,-164,-166,-165,272,-187,-229,-96,272,-211,-199,-91,272,385,-203,-295,-237,-240,272,-243,-296,-297,-241,272,-205,272,-297,-298,-298,-61,-62,]),'STREQ':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,73,74,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,136,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,292,294,301,303,305,315,319,326,327,328,329,330,331,332,333,334,335,336,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,372,373,374,375,377,378,382,411,413,417,424,427,429,433,448,449,450,451,452,453,455,456,457,458,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,185,-167,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-137,-115,269,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,-162,-144,403,-96,-87,-88,-74,-75,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,185,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,-158,-159,-161,-160,-124,-125,269,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,403,-163,-164,-166,-165,-96,-295,-296,-297,-297,-298,-298,]),'BOR':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,53,60,61,63,64,69,70,71,73,74,76,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,130,132,134,135,136,140,142,144,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,291,292,293,294,297,301,303,305,315,318,319,320,325,326,327,328,329,330,331,332,333,334,335,336,338,345,346,350,353,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,377,378,382,411,413,417,424,427,429,433,442,448,449,450,451,452,453,454,455,456,457,458,462,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-188,-104,-31,-32,-33,181,-35,-34,-176,-167,-182,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,260,-137,-115,-184,-172,-129,-96,-178,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,-162,-180,-144,-186,-174,405,-96,-87,-88,-74,-183,-75,181,-189,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,-177,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,260,-132,-131,-130,-179,-158,-159,-161,-160,-124,-125,-173,-86,-89,-73,-48,-82,-57,-68,405,-149,-146,-145,-148,-147,-175,-181,-163,-164,-166,-165,-187,-96,-295,-296,-297,-297,-298,-298,]),'$end':([0,2,5,7,9,13,19,21,28,29,31,33,36,43,45,50,58,59,62,65,67,72,75,77,111,114,115,116,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,414,416,435,471,472,475,508,514,516,519,522,523,524,529,532,541,542,544,547,],[-1,-22,-15,-5,0,-23,-21,-13,-19,-17,-20,-3,-16,-11,-9,-10,-8,-4,-24,-12,-6,-244,-18,-14,-7,-292,-291,-2,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,-290,-288,-273,-251,-274,-247,-293,-254,-289,-275,-249,-250,-248,-294,-255,-256,-252,-276,-253,]),'FUNCTION':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,54,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,98,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[37,-22,-1,-15,96,37,96,96,-23,-21,-13,96,96,96,-19,-17,96,-20,-16,96,-11,37,-9,96,-10,96,-8,-24,-12,-6,37,-244,-18,-14,96,96,96,96,96,96,-53,-52,-51,96,-7,-292,-291,-2,96,96,96,96,96,37,-270,-269,96,-245,-246,96,96,96,96,96,96,96,-261,-262,96,96,96,96,96,-265,-266,-25,96,96,96,96,96,96,96,96,96,96,96,96,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,96,96,-1,-54,96,96,-232,-233,96,-283,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,-271,-272,96,96,96,96,96,96,96,-287,-286,-26,-263,-264,-268,-267,-284,-285,96,96,96,37,37,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,96,-290,-288,37,96,37,96,-273,37,37,96,96,96,-251,-274,-247,37,37,96,96,37,96,96,37,37,37,-293,96,37,-254,-289,-275,-249,-250,-248,37,-294,37,-255,37,37,37,37,-256,-252,-276,-253,]),'INSTANCEOF':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,74,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,292,301,303,305,315,319,326,327,328,329,330,331,332,333,334,335,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,372,373,374,375,377,378,411,413,417,424,427,429,433,448,449,450,451,452,455,456,457,458,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,186,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,254,-137,-115,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,393,-144,-96,-87,-88,-74,-75,254,254,254,254,-155,-152,-151,-154,-153,-156,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,254,254,254,254,-124,-125,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,254,254,254,254,-96,-295,-296,-297,-297,-298,-298,]),'GT':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,74,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,292,301,303,305,315,319,326,327,328,329,330,331,332,333,334,335,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,372,373,374,375,377,378,411,413,417,424,427,429,433,448,449,450,451,452,455,456,457,458,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,187,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,255,-137,-115,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,394,-144,-96,-87,-88,-74,-75,255,255,255,255,-155,-152,-151,-154,-153,-156,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,255,255,255,255,-124,-125,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,255,255,255,255,-96,-295,-296,-297,-297,-298,-298,]),'STRING':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,54,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,98,104,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,228,231,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,349,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[79,-22,-1,-15,79,79,79,79,-23,-21,-13,79,79,79,-19,-17,79,-20,-16,79,-11,79,-9,79,-10,79,-8,-24,-12,-6,79,-244,-18,-14,79,79,79,79,79,79,-53,-52,-51,79,79,-7,-292,-291,-2,79,79,79,79,79,79,-270,-269,79,-245,-246,79,79,79,79,79,79,79,-261,-262,79,79,79,79,79,-265,-266,-25,79,79,79,79,79,79,79,79,79,79,79,79,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,79,79,-1,-54,79,79,79,79,-232,-233,79,-283,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,-271,-272,79,79,79,79,79,79,79,-287,-286,-26,-263,-264,-268,-267,-284,-285,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,79,-290,-288,79,79,79,79,-273,79,79,79,79,79,-251,-274,-247,79,79,79,79,79,79,79,79,79,79,-293,79,79,-254,-289,-275,-249,-250,-248,79,-294,79,-255,79,79,79,79,-256,-252,-276,-253,]),'FOR':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[39,-22,-15,39,-23,-21,-13,-19,-17,-20,-16,-11,39,-9,-10,-8,-24,-12,-6,39,-244,-18,-14,-7,-292,-291,-2,39,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,39,39,-290,-288,39,39,-273,39,39,-251,-274,-247,39,39,39,39,39,39,-293,39,-254,-289,-275,-249,-250,-248,39,-294,39,-255,39,39,39,39,-256,-252,-276,-253,]),'PLUSPLUS':([0,2,3,4,5,6,7,8,10,11,12,13,15,16,19,20,21,23,24,25,26,28,29,30,31,36,38,40,41,43,44,45,48,49,50,58,61,62,63,64,65,67,68,70,71,72,75,77,78,79,80,81,82,83,84,85,87,88,89,90,92,93,94,95,99,101,102,103,105,107,108,109,110,111,114,115,116,120,121,122,123,124,126,133,142,143,146,147,148,149,150,151,152,155,158,159,160,163,164,168,169,170,171,172,173,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,213,215,216,218,219,221,222,226,227,229,238,239,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,301,303,305,310,311,312,313,314,315,319,322,323,338,340,341,342,343,345,346,350,352,353,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,411,412,413,414,416,417,418,420,421,424,427,429,433,434,435,436,441,443,446,447,464,471,472,475,477,482,483,488,491,492,493,495,501,502,504,506,508,509,512,514,516,519,522,523,524,526,528,529,531,532,533,534,536,537,540,541,542,544,547,],[40,-22,-28,-1,-15,40,40,-72,40,40,-94,-23,-71,-27,-21,-42,-13,40,-41,40,40,-19,-17,40,-20,-16,-30,40,-95,-11,40,-9,40,-78,-10,-8,-31,-24,-32,-33,-12,-6,40,-35,-34,-244,-18,-14,-37,-36,-43,-44,196,40,40,-38,-29,40,40,40,40,-53,-52,-51,223,-92,-39,-93,-40,-67,-66,-76,-41,-7,-292,-291,-2,40,40,40,40,40,40,-270,223,-269,40,-245,-246,40,40,40,40,40,40,-85,40,-261,-262,40,-84,40,40,-79,-76,40,40,-265,-266,-25,40,40,40,40,40,40,40,40,40,40,40,40,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,40,40,196,-1,-47,-46,-54,-77,-76,40,-81,-55,40,-80,-232,-233,40,-283,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,-271,-272,40,40,40,40,40,40,40,223,-87,-88,-287,-286,-26,-263,-264,-74,-75,-268,-267,-45,-284,-285,40,40,-70,-83,-56,40,-69,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,40,-86,40,-89,-290,-288,-73,40,40,40,-48,-82,-57,-68,40,-273,40,40,40,40,40,223,-251,-274,-247,40,-295,40,40,40,40,40,40,40,40,40,-296,-293,40,40,-254,-289,-275,-249,-250,-248,-297,40,-294,40,-255,40,40,40,-298,40,-256,-252,-276,-253,]),'PERIOD':([3,8,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,85,87,102,103,105,107,108,109,110,159,169,173,216,218,222,227,229,239,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,482,506,508,526,529,537,],[-28,-72,-71,-27,-42,-41,-30,157,167,-31,-32,-33,-35,-34,-37,-36,-43,-44,-38,-29,-39,225,-40,-67,-66,237,-41,-85,-84,237,-47,-46,237,-81,-55,-80,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,-295,-296,-297,-297,-298,-298,]),'RBRACE':([2,3,5,7,13,16,19,20,21,28,29,31,36,38,43,44,45,50,58,59,61,62,63,64,65,67,70,71,72,75,77,78,79,80,81,85,87,97,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,125,127,128,129,130,131,132,133,134,135,136,137,140,141,142,143,144,145,147,148,156,162,163,164,166,176,177,179,209,216,218,221,222,223,224,227,229,230,233,239,240,241,250,270,271,305,310,311,312,313,314,322,323,338,340,341,345,346,349,350,353,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,377,378,380,381,382,386,413,414,416,424,427,429,430,432,433,435,436,438,439,441,471,472,473,475,477,480,481,482,483,484,496,497,498,499,502,503,504,506,507,508,514,516,518,519,520,522,523,524,525,526,527,528,529,532,534,535,536,537,538,539,541,542,543,544,545,546,547,],[-22,-28,-15,-5,-23,-27,-21,-42,-13,-19,-17,-20,-16,-30,-11,-1,-9,-10,-8,-4,-31,-24,-32,-33,-12,-6,-35,-34,-244,-18,-14,-37,-36,-43,-44,-38,-29,-112,-96,-102,-92,-39,-93,229,-40,-103,-67,-66,-76,-41,-7,-111,-107,-292,-291,-2,-108,-106,-123,-157,-190,-196,-137,-270,-115,-184,-172,-208,-129,-202,-96,-269,-178,-113,-245,-246,-109,312,-261,-262,-114,-265,-266,-25,-110,-47,-46,-77,-76,-97,-98,-81,-55,350,-58,-80,-232,-233,-283,-271,-272,-88,-287,-286,-26,-263,-264,-268,-267,-45,-284,-285,-70,-83,429,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,-191,-132,-131,-130,-179,-158,-159,-161,-160,-124,-125,-197,-209,-173,-1,-89,-290,-288,-48,-82,-57,-59,-60,-68,-273,-1,-301,482,-1,-251,-274,-1,-247,-1,-203,506,-295,-1,508,-278,519,-279,-277,-1,526,-1,-296,529,-293,-254,-289,-280,-275,-1,-249,-250,-248,537,-297,538,-1,-294,-255,-1,544,-1,-298,-61,546,-256,-252,-281,-276,-282,-62,-253,]),'ELSE':([2,5,13,19,21,28,29,31,36,43,50,62,65,72,75,77,114,115,116,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,414,416,435,471,472,475,508,514,516,519,522,523,524,529,532,541,542,544,547,],[-22,-15,-23,-21,-13,-19,-17,-20,-16,-11,-10,-24,-12,-244,-18,-14,-292,-291,-2,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,-290,-288,-273,-251,-274,501,-293,-254,-289,-275,-249,-250,-248,-294,-255,-256,-252,-276,-253,]),'TRY':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[42,-22,-15,42,-23,-21,-13,-19,-17,-20,-16,-11,42,-9,-10,-8,-24,-12,-6,42,-244,-18,-14,-7,-292,-291,-2,42,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,42,42,-290,-288,42,42,-273,42,42,-251,-274,-247,42,42,42,42,42,42,-293,42,-254,-289,-275,-249,-250,-248,42,-294,42,-255,42,42,42,42,-256,-252,-276,-253,]),'BAND':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,73,74,76,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,136,140,142,144,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,291,292,294,301,303,305,315,318,319,326,327,328,329,330,331,332,333,334,335,336,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,371,372,373,374,375,377,378,382,411,413,417,424,427,429,433,448,449,450,451,452,453,454,455,456,457,458,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,-176,-167,192,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-137,-115,-172,-129,-96,278,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,-162,398,-144,-174,-96,-87,-88,-74,192,-75,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,-177,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,278,-158,-159,-161,-160,-124,-125,-173,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,-175,398,-163,-164,-166,-165,-96,-295,-296,-297,-297,-298,-298,]),'GE':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,74,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,292,301,303,305,315,319,326,327,328,329,330,331,332,333,334,335,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,372,373,374,375,377,378,411,413,417,424,427,429,433,448,449,450,451,452,455,456,457,458,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,189,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,257,-137,-115,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,396,-144,-96,-87,-88,-74,-75,257,257,257,257,-155,-152,-151,-154,-153,-156,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,257,257,257,257,-124,-125,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,257,257,257,257,-96,-295,-296,-297,-297,-298,-298,]),'LT':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,74,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,292,301,303,305,315,319,326,327,328,329,330,331,332,333,334,335,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,372,373,374,375,377,378,411,413,417,424,427,429,433,448,449,450,451,452,455,456,457,458,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,188,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,256,-137,-115,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,395,-144,-96,-87,-88,-74,-75,256,256,256,256,-155,-152,-151,-154,-153,-156,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,256,256,256,256,-124,-125,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,256,256,256,256,-96,-295,-296,-297,-297,-298,-298,]),'REGEX':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,54,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,98,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[78,-22,-1,-15,78,78,78,78,-23,-21,-13,78,78,78,-19,-17,78,-20,-16,78,-11,78,-9,78,-10,78,-8,-24,-12,-6,78,-244,-18,-14,78,78,78,78,78,78,-53,-52,-51,78,-7,-292,-291,-2,78,78,78,78,78,78,-270,-269,78,-245,-246,78,78,78,78,78,78,78,-261,-262,78,78,78,78,78,-265,-266,-25,78,78,78,78,78,78,78,78,78,78,78,78,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,78,78,-1,-54,78,78,-232,-233,78,-283,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,-271,-272,78,78,78,78,78,78,78,-287,-286,-26,-263,-264,-268,-267,-284,-285,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,78,-290,-288,78,78,78,78,-273,78,78,78,78,78,-251,-274,-247,78,78,78,78,78,78,78,78,78,78,-293,78,78,-254,-289,-275,-249,-250,-248,78,-294,78,-255,78,78,78,78,-256,-252,-276,-253,]),'STRNEQ':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,73,74,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,136,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,290,292,294,301,303,305,315,319,326,327,328,329,330,331,332,333,334,335,336,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,372,373,374,375,377,378,382,411,413,417,424,427,429,433,448,449,450,451,452,453,455,456,457,458,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,184,-167,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-137,-115,268,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,-162,-144,402,-96,-87,-88,-74,-75,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,184,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,-158,-159,-161,-160,-124,-125,268,-86,-89,-73,-48,-82,-57,-68,-149,-146,-145,-148,-147,402,-163,-164,-166,-165,-96,-295,-296,-297,-297,-298,-298,]),'LPAREN':([0,2,3,4,5,6,7,8,10,11,13,15,16,19,20,21,23,24,25,26,28,29,30,31,32,36,37,38,39,40,41,43,44,45,48,49,50,52,54,57,58,61,62,63,64,65,67,68,70,71,72,75,77,78,79,80,81,83,84,85,86,87,88,89,90,92,93,94,95,96,98,102,103,105,107,108,109,110,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,154,155,158,159,160,163,164,168,169,170,171,173,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,216,218,219,220,222,226,227,229,232,234,236,238,239,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,303,305,309,310,311,312,313,314,315,319,322,323,324,338,340,341,342,343,345,346,348,350,351,352,353,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,411,412,413,414,416,417,418,420,421,424,427,429,433,434,435,436,441,443,446,447,471,472,475,477,482,483,488,491,492,493,495,501,502,504,506,508,509,512,514,516,519,522,523,524,526,528,529,531,532,533,534,536,537,540,541,542,544,547,],[83,-22,-28,-1,-15,83,83,-72,83,83,-23,-71,-27,-21,-42,-13,83,-41,83,83,-19,-17,83,-20,146,-16,153,-30,155,83,160,-11,83,-9,83,160,-10,170,83,175,-8,-31,-24,-32,-33,-12,-6,83,-35,-34,-244,-18,-14,-37,-36,-43,-44,83,83,-38,210,-29,83,83,83,83,-53,-52,-51,153,83,-39,160,-40,-67,-66,160,-41,-7,-292,-291,-2,83,83,83,83,83,83,-270,-269,83,-245,-246,83,83,83,83,287,83,83,-85,83,-261,-262,83,-84,83,83,160,83,83,-265,-266,-25,83,83,83,83,83,83,83,83,83,83,83,83,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,83,83,-1,-47,-46,-54,344,160,83,-81,-55,-65,-63,-64,83,-80,-232,-233,83,-283,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,-271,-272,83,83,83,83,83,83,83,-87,-88,415,-287,-286,-26,-263,-264,-74,-75,-268,-267,420,-45,-284,-285,83,83,-70,-83,428,-56,431,83,-69,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,83,-86,83,-89,-290,-288,-73,83,83,83,-48,-82,-57,-68,83,-273,83,83,83,83,83,-251,-274,-247,83,-295,83,83,83,83,83,83,83,83,83,-296,-293,83,83,-254,-289,-275,-249,-250,-248,-297,83,-294,83,-255,83,83,83,-298,83,-256,-252,-276,-253,]),'IN':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,74,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,132,134,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,288,290,291,292,293,294,297,298,301,302,303,305,315,319,326,327,328,329,330,331,332,333,334,335,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,372,373,374,375,377,378,392,411,413,417,424,427,429,433,442,445,448,449,450,451,452,453,454,455,456,457,458,462,464,466,468,482,490,506,508,515,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,191,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,259,-137,-115,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,-198,-162,-180,-144,-186,-174,-192,-210,407,-204,-87,-88,-74,-75,259,259,259,259,-155,-152,-151,-154,-153,-156,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-132,-131,-130,259,259,259,259,-124,-125,446,-86,-89,-73,-48,-82,-57,-68,-193,488,-149,-146,-145,-148,-147,-175,-181,259,259,259,259,-187,-96,-211,-199,-295,-243,-296,-297,-205,-297,-298,-298,]),'VAR':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,155,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[17,-22,-15,17,-23,-21,-13,-19,-17,-20,-16,-11,17,-9,-10,-8,-24,-12,-6,17,-244,-18,-14,-7,-292,-291,-2,17,-270,-269,-245,-246,289,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,17,17,-290,-288,17,17,-273,17,17,-251,-274,-247,17,17,17,17,17,17,-293,17,-254,-289,-275,-249,-250,-248,17,-294,17,-255,17,17,17,17,-256,-252,-276,-253,]),'MINUSMINUS':([0,2,3,4,5,6,7,8,10,11,12,13,15,16,19,20,21,23,24,25,26,28,29,30,31,36,38,40,41,43,44,45,48,49,50,58,61,62,63,64,65,67,68,70,71,72,75,77,78,79,80,81,82,83,84,85,87,88,89,90,92,93,94,95,99,101,102,103,105,107,108,109,110,111,114,115,116,120,121,122,123,124,126,133,142,143,146,147,148,149,150,151,152,155,158,159,160,163,164,168,169,170,171,172,173,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,213,215,216,218,219,221,222,226,227,229,238,239,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,301,303,305,310,311,312,313,314,315,319,322,323,338,340,341,342,343,345,346,350,352,353,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,411,412,413,414,416,417,418,420,421,424,427,429,433,434,435,436,441,443,446,447,464,471,472,475,477,482,483,488,491,492,493,495,501,502,504,506,508,509,512,514,516,519,522,523,524,526,528,529,531,532,533,534,536,537,540,541,542,544,547,],[84,-22,-28,-1,-15,84,84,-72,84,84,-94,-23,-71,-27,-21,-42,-13,84,-41,84,84,-19,-17,84,-20,-16,-30,84,-95,-11,84,-9,84,-78,-10,-8,-31,-24,-32,-33,-12,-6,84,-35,-34,-244,-18,-14,-37,-36,-43,-44,204,84,84,-38,-29,84,84,84,84,-53,-52,-51,224,-92,-39,-93,-40,-67,-66,-76,-41,-7,-292,-291,-2,84,84,84,84,84,84,-270,224,-269,84,-245,-246,84,84,84,84,84,84,-85,84,-261,-262,84,-84,84,84,-79,-76,84,84,-265,-266,-25,84,84,84,84,84,84,84,84,84,84,84,84,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,84,84,204,-1,-47,-46,-54,-77,-76,84,-81,-55,84,-80,-232,-233,84,-283,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,-271,-272,84,84,84,84,84,84,84,224,-87,-88,-287,-286,-26,-263,-264,-74,-75,-268,-267,-45,-284,-285,84,84,-70,-83,-56,84,-69,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,84,-86,84,-89,-290,-288,-73,84,84,84,-48,-82,-57,-68,84,-273,84,84,84,84,84,224,-251,-274,-247,84,-295,84,84,84,84,84,84,84,84,84,-296,-293,84,84,-254,-289,-275,-249,-250,-248,-297,84,-294,84,-255,84,84,84,-298,84,-256,-252,-276,-253,]),'EQ':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,118,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,392,411,413,417,424,427,429,433,464,482,487,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,205,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,243,205,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,205,-87,-88,-74,-75,-45,-70,-83,-56,-69,447,-86,-89,-73,-48,-82,-57,-68,205,-295,447,-296,-297,-297,-298,-298,]),'ID':([0,2,4,5,6,7,10,11,13,17,19,21,23,25,26,28,29,30,31,36,37,40,43,44,45,47,48,50,54,58,62,65,66,67,68,72,75,77,83,84,88,89,90,92,93,94,95,96,98,104,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,153,155,157,158,160,163,164,167,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,225,226,228,231,237,238,240,241,242,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,287,289,310,311,312,313,314,322,323,340,341,342,343,344,349,352,383,385,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,415,416,418,420,421,431,434,435,436,441,443,444,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[85,-22,-1,-15,85,85,85,85,-23,85,-21,-13,85,85,85,-19,-17,85,-20,-16,85,85,-11,85,-9,85,85,-10,85,-8,-24,-12,85,-6,85,-244,-18,-14,85,85,85,85,85,85,-53,-52,-51,85,85,85,-7,-292,-291,-2,85,85,85,85,85,85,-270,-269,85,-245,-246,85,85,85,85,85,85,85,85,85,-261,-262,85,85,85,85,85,85,-265,-266,-25,85,85,85,85,85,85,85,85,85,85,85,85,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,85,85,-1,-54,85,85,85,85,85,85,-232,-233,85,85,-283,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,-271,-272,85,85,85,85,85,85,85,85,85,-287,-286,-26,-263,-264,-268,-267,-284,-285,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,85,-290,85,-288,85,85,85,85,85,-273,85,85,85,85,85,85,-251,-274,-247,85,85,85,85,85,85,85,85,85,85,-293,85,85,-254,-289,-275,-249,-250,-248,85,-294,85,-255,85,85,85,85,-256,-252,-276,-253,]),'IF':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[86,-22,-15,86,-23,-21,-13,-19,-17,-20,-16,-11,86,-9,-10,-8,-24,-12,-6,86,-244,-18,-14,-7,-292,-291,-2,86,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,86,86,-290,-288,86,86,-273,86,86,-251,-274,-247,86,86,86,86,86,86,-293,86,-254,-289,-275,-249,-250,-248,86,-294,86,-255,86,86,86,86,-256,-252,-276,-253,]),'AND':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,53,56,60,61,63,64,69,70,71,73,74,76,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,130,131,132,134,135,136,140,142,144,145,156,159,166,169,172,173,196,204,209,213,214,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,288,290,291,292,293,294,297,301,303,305,315,318,319,320,325,326,327,328,329,330,331,332,333,334,335,336,338,345,346,350,353,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,377,378,380,382,411,413,417,424,427,429,433,442,448,449,450,451,452,453,454,455,456,457,458,462,464,468,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-188,174,-104,-31,-32,-33,-194,-35,-34,-176,-167,-182,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-190,261,-137,-115,-184,-172,-129,-96,-178,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,174,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,389,-162,-180,-144,-186,-174,-192,-96,-87,-88,-74,-183,-75,-195,-189,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,-177,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,-191,-132,-131,-130,-179,-158,-159,-161,-160,-124,-125,261,-173,-86,-89,-73,-48,-82,-57,-68,-193,-149,-146,-145,-148,-147,-175,-181,-163,-164,-166,-165,-187,-96,389,-295,-296,-297,-297,-298,-298,]),'LBRACE':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,42,43,44,45,48,50,54,58,62,65,67,68,72,75,77,83,84,88,89,92,93,94,95,98,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,175,176,177,179,182,183,184,185,186,187,188,189,190,191,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,285,308,310,311,312,313,314,322,323,340,341,342,343,352,383,384,386,388,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,419,420,421,426,434,435,436,440,441,443,446,447,471,472,475,476,477,478,483,488,491,492,493,494,495,501,502,504,505,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[44,-22,-1,-15,104,44,104,104,-23,-21,-13,104,104,104,-19,-17,104,-20,-16,104,44,-11,44,-9,104,-10,104,-8,-24,-12,-6,44,-244,-18,-14,104,104,104,104,104,-53,-52,-51,104,-7,-292,-291,-2,104,104,104,104,104,44,-270,-269,104,-245,-246,104,104,104,104,104,104,104,-261,-262,104,104,104,-265,-266,-25,104,104,104,104,104,104,104,104,104,104,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,104,104,-1,-54,104,104,-232,-233,104,-283,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,-271,-272,104,104,104,104,104,104,104,386,44,-287,-286,-26,-263,-264,-268,-267,-284,-285,104,104,104,44,436,44,441,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,104,-290,-288,44,473,104,44,477,104,-273,44,483,44,104,104,104,-251,-274,-247,502,44,504,44,104,104,44,104,44,104,44,44,44,528,-293,104,44,-254,-289,-275,-249,-250,-248,44,-294,44,-255,44,44,44,44,-256,-252,-276,-253,]),'FALSE':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,54,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,98,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[64,-22,-1,-15,64,64,64,64,-23,-21,-13,64,64,64,-19,-17,64,-20,-16,64,-11,64,-9,64,-10,64,-8,-24,-12,-6,64,-244,-18,-14,64,64,64,64,64,64,-53,-52,-51,64,-7,-292,-291,-2,64,64,64,64,64,64,-270,-269,64,-245,-246,64,64,64,64,64,64,64,-261,-262,64,64,64,64,64,-265,-266,-25,64,64,64,64,64,64,64,64,64,64,64,64,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,64,64,-1,-54,64,64,-232,-233,64,-283,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,-271,-272,64,64,64,64,64,64,64,-287,-286,-26,-263,-264,-268,-267,-284,-285,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,64,-290,-288,64,64,64,64,-273,64,64,64,64,64,-251,-274,-247,64,64,64,64,64,64,64,64,64,64,-293,64,64,-254,-289,-275,-249,-250,-248,64,-294,64,-255,64,64,64,64,-256,-252,-276,-253,]),'RSHIFT':([3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,60,61,63,64,70,71,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,132,134,140,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,292,301,303,305,315,319,330,331,332,333,334,335,338,345,346,350,353,357,358,359,360,361,362,363,364,365,368,369,370,377,378,411,413,417,424,427,429,433,448,449,450,451,452,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,121,-42,-133,-41,-119,-126,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,263,-115,-129,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,263,-96,-87,-88,-74,-75,263,263,263,263,263,263,-45,-70,-83,-56,-69,-117,-118,-116,263,263,263,263,263,263,-132,-131,-130,-124,-125,-86,-89,-73,-48,-82,-57,-68,263,263,263,263,263,-96,-295,-296,-297,-297,-298,-298,]),'PLUSEQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,201,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,201,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,201,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,201,-295,-296,-297,-297,-298,-298,]),'THIS':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,54,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,98,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[20,-22,-1,-15,20,20,20,20,-23,-21,-13,20,20,20,-19,-17,20,-20,-16,20,-11,20,-9,20,-10,20,-8,-24,-12,-6,20,-244,-18,-14,20,20,20,20,20,20,-53,-52,-51,20,-7,-292,-291,-2,20,20,20,20,20,20,-270,-269,20,-245,-246,20,20,20,20,20,20,20,-261,-262,20,20,20,20,20,-265,-266,-25,20,20,20,20,20,20,20,20,20,20,20,20,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,20,20,-1,-54,20,20,-232,-233,20,-283,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,-271,-272,20,20,20,20,20,20,20,-287,-286,-26,-263,-264,-268,-267,-284,-285,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,20,-290,-288,20,20,20,20,-273,20,20,20,20,20,-251,-274,-247,20,20,20,20,20,20,20,20,20,20,-293,20,20,-254,-289,-275,-249,-250,-248,20,-294,20,-255,20,20,20,20,-256,-252,-276,-253,]),'MINUSEQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,197,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,197,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,197,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,197,-295,-296,-297,-297,-298,-298,]),'CONDOP':([1,3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,53,56,60,61,63,64,69,70,71,73,74,76,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,130,131,132,134,135,136,140,141,142,144,145,156,159,166,169,172,173,196,204,209,213,214,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,288,290,291,292,293,294,297,301,302,303,305,315,318,319,320,325,326,327,328,329,330,331,332,333,334,335,336,338,345,346,350,353,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,377,378,380,382,411,413,417,424,427,429,433,442,448,449,450,451,452,453,454,455,456,457,458,462,464,468,482,506,508,526,529,537,],[89,-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-188,-200,-104,-31,-32,-33,-194,-35,-34,-176,-167,-182,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-190,-196,-137,-115,-184,-172,-129,275,-96,-178,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-201,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,-198,-162,-180,-144,-186,-174,-192,-96,409,-87,-88,-74,-183,-75,-195,-189,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,-177,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,-191,-132,-131,-130,-179,-158,-159,-161,-160,-124,-125,-197,-173,-86,-89,-73,-48,-82,-57,-68,-193,-149,-146,-145,-148,-147,-175,-181,-163,-164,-166,-165,-187,-96,-199,-295,-296,-297,-297,-298,-298,]),'XOREQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,199,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,199,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,199,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,199,-295,-296,-297,-297,-298,-298,]),'OR':([1,3,8,12,15,16,18,20,22,24,27,35,38,41,46,49,53,56,60,61,63,64,69,70,71,73,74,76,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,130,131,132,134,135,136,140,141,142,144,145,156,159,166,169,172,173,196,204,209,213,214,216,218,221,222,223,224,227,229,239,245,246,247,248,249,281,282,283,288,290,291,292,293,294,297,301,302,303,305,315,318,319,320,325,326,327,328,329,330,331,332,333,334,335,336,338,345,346,350,353,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,377,378,380,382,411,413,417,424,427,429,433,442,448,449,450,451,452,453,454,455,456,457,458,462,464,468,482,506,508,526,529,537,],[90,-28,-72,-94,-71,-27,-150,-42,-133,-41,-119,-126,-30,-95,-105,-78,-188,-200,-104,-31,-32,-33,-194,-35,-34,-176,-167,-182,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-190,-196,-137,-115,-184,-172,-129,276,-96,-178,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-201,-47,-46,-77,-76,-97,-98,-81,-55,-80,-136,-135,-134,-127,-128,-122,-121,-120,-198,-162,-180,-144,-186,-174,-192,-96,410,-87,-88,-74,-183,-75,-195,-189,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,-177,-45,-70,-83,-56,-69,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,-191,-132,-131,-130,-179,-158,-159,-161,-160,-124,-125,-197,-173,-86,-89,-73,-48,-82,-57,-68,-193,-149,-146,-145,-148,-147,-175,-181,-163,-164,-166,-165,-187,-96,-199,-295,-296,-297,-297,-298,-298,]),'BREAK':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[66,-22,-15,66,-23,-21,-13,-19,-17,-20,-16,-11,66,-9,-10,-8,-24,-12,-6,66,-244,-18,-14,-7,-292,-291,-2,66,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,66,66,-290,-288,66,66,-273,66,66,-251,-274,-247,66,66,66,66,66,66,-293,66,-254,-289,-275,-249,-250,-248,66,-294,66,-255,66,66,66,66,-256,-252,-276,-253,]),'URSHIFTEQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,195,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,195,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,195,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,195,-295,-296,-297,-297,-298,-298,]),'CONTINUE':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[47,-22,-15,47,-23,-21,-13,-19,-17,-20,-16,-11,47,-9,-10,-8,-24,-12,-6,47,-244,-18,-14,-7,-292,-291,-2,47,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,47,47,-290,-288,47,47,-273,47,47,-251,-274,-247,47,47,47,47,47,47,-293,47,-254,-289,-275,-249,-250,-248,47,-294,47,-255,47,47,47,47,-256,-252,-276,-253,]),'FINALLY':([161,311,312,516,],[308,308,-26,-289,]),'TYPEOF':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[23,-22,-1,-15,23,23,23,23,-23,-21,-13,23,23,23,-19,-17,23,-20,-16,23,-11,23,-9,23,-10,-8,-24,-12,-6,23,-244,-18,-14,23,23,23,23,23,23,-53,-52,-51,-7,-292,-291,-2,23,23,23,23,23,23,-270,-269,23,-245,-246,23,23,23,23,23,23,23,-261,-262,23,23,23,23,23,-265,-266,-25,23,23,23,23,23,23,23,23,23,23,23,23,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,23,23,-1,-54,23,23,-232,-233,23,-283,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,-271,-272,23,23,23,23,23,23,23,-287,-286,-26,-263,-264,-268,-267,-284,-285,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,23,-290,-288,23,23,23,23,-273,23,23,23,23,23,-251,-274,-247,23,23,23,23,23,23,23,23,23,23,-293,23,23,-254,-289,-275,-249,-250,-248,23,-294,23,-255,23,23,23,23,-256,-252,-276,-253,]),'error':([1,3,8,12,14,15,16,18,20,22,24,26,27,34,35,38,41,46,47,49,51,53,55,56,60,61,63,64,66,69,70,71,73,74,76,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,117,118,119,125,127,128,129,130,131,132,134,135,136,137,138,139,140,141,142,144,145,156,159,165,166,169,172,173,178,196,204,209,211,213,214,216,218,221,222,223,224,227,229,239,244,245,246,247,248,249,280,281,282,283,303,305,315,318,319,320,325,326,327,328,329,330,331,332,333,334,335,336,337,338,345,346,350,353,355,356,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,376,377,378,380,381,382,411,413,417,422,424,427,429,433,480,482,500,506,508,526,529,537,],[-206,-28,-72,-94,116,-71,-27,-150,-42,-133,-41,116,-119,116,-126,-30,-95,-105,116,-78,-230,-188,-212,-200,-104,-31,-32,-33,116,-194,-35,-34,-176,-167,-182,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,116,-238,-234,-108,-106,-123,-157,-190,-196,-137,-115,-184,-172,-208,116,-226,-129,-202,-96,-178,-113,-109,-85,116,-114,-84,-79,-76,116,-100,-101,-110,116,-99,-201,-47,-46,-77,-76,-97,-98,-81,-55,-80,-239,-136,-135,-134,-127,-128,-231,-122,-121,-120,-87,-88,-74,-183,-75,-195,-189,-168,-169,-171,-170,-155,-152,-151,-154,-153,-156,-177,-213,-45,-70,-83,-56,-69,-235,-242,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,-191,-132,-131,-130,-179,-158,-159,-161,-160,-227,-124,-125,-197,-209,-173,-86,-89,-73,-207,-48,-82,-57,-68,-203,-295,116,-296,-297,-297,-298,-298,]),'NOT':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[48,-22,-1,-15,48,48,48,48,-23,-21,-13,48,48,48,-19,-17,48,-20,-16,48,-11,48,-9,48,-10,-8,-24,-12,-6,48,-244,-18,-14,48,48,48,48,48,48,-53,-52,-51,-7,-292,-291,-2,48,48,48,48,48,48,-270,-269,48,-245,-246,48,48,48,48,48,48,48,-261,-262,48,48,48,48,48,-265,-266,-25,48,48,48,48,48,48,48,48,48,48,48,48,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,48,48,-1,-54,48,48,-232,-233,48,-283,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,-271,-272,48,48,48,48,48,48,48,-287,-286,-26,-263,-264,-268,-267,-284,-285,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,48,-290,-288,48,48,48,48,-273,48,48,48,48,48,-251,-274,-247,48,48,48,48,48,48,48,48,48,48,-293,48,48,-254,-289,-275,-249,-250,-248,48,-294,48,-255,48,48,48,48,-256,-252,-276,-253,]),'ANDEQUAL':([3,8,12,15,16,20,24,38,41,49,61,63,64,70,71,78,79,80,81,82,85,87,101,102,103,105,107,108,109,110,142,159,169,172,173,216,218,221,222,227,229,239,301,303,305,315,319,338,345,346,350,353,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-30,-95,-78,-31,-32,-33,-35,-34,-37,-36,-43,-44,203,-38,-29,-92,-39,-93,-40,-67,-66,-76,-41,203,-85,-84,-79,-76,-47,-46,-77,-76,-81,-55,-80,203,-87,-88,-74,-75,-45,-70,-83,-56,-69,-86,-89,-73,-48,-82,-57,-68,203,-295,-296,-297,-297,-298,-298,]),'RBRACKET':([3,4,16,20,38,61,63,64,70,71,78,79,80,81,85,87,91,92,93,94,95,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,129,130,131,132,134,135,136,137,139,140,141,142,144,145,156,166,209,215,216,217,218,219,221,222,223,224,227,229,239,304,305,316,338,343,345,346,347,350,353,354,357,358,359,360,361,362,363,364,365,366,367,368,369,370,371,372,373,374,375,376,377,378,380,381,382,413,423,424,427,429,433,480,482,506,526,537,],[-28,-1,-27,-42,-30,-31,-32,-33,-35,-34,-37,-36,-43,-44,-38,-29,216,218,-53,-52,-51,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,-123,-157,-190,-196,-137,-115,-184,-172,-208,-226,-129,-202,-96,-178,-113,-109,-114,-110,-1,-47,-49,-46,-54,-77,-76,-97,-98,-81,-55,-80,411,-88,417,-45,424,-70,-83,427,-56,-69,433,-117,-118,-116,-142,-139,-138,-141,-140,-143,-185,-191,-132,-131,-130,-179,-158,-159,-161,-160,-227,-124,-125,-197,-209,-173,-89,-50,-48,-82,-57,-68,-203,-295,-296,-297,-298,]),'MOD':([3,8,12,15,16,20,24,27,35,38,41,46,49,60,61,63,64,70,71,78,79,80,81,82,85,87,97,99,100,101,102,103,105,106,107,108,109,110,112,113,125,127,128,134,142,145,156,159,166,169,172,173,196,204,209,213,216,218,221,222,223,224,227,229,239,248,249,281,282,283,301,303,305,315,319,338,345,346,350,353,357,358,359,377,378,411,413,417,424,427,429,433,464,482,506,508,526,529,537,],[-28,-72,-94,-71,-27,-42,-41,-119,150,-30,-95,-105,-78,-104,-31,-32,-33,-35,-34,-37,-36,-43,-44,-99,-38,-29,-112,-96,-102,-92,-39,-93,-40,-103,-67,-66,-76,-41,-111,-107,-108,-106,252,-115,-96,-113,-109,-85,-114,-84,-79,-76,-100,-101,-110,-99,-47,-46,-77,-76,-97,-98,-81,-55,-80,252,252,-122,-121,-120,-96,-87,-88,-74,-75,-45,-70,-83,-56,-69,-117,-118,-116,252,252,-86,-89,-73,-48,-82,-57,-68,-96,-295,-296,-297,-297,-298,-298,]),'THROW':([0,2,5,7,13,19,21,28,29,31,36,43,44,45,50,58,62,65,67,68,72,75,77,111,114,115,116,126,133,143,147,148,163,164,176,177,179,240,241,250,270,271,310,311,312,313,314,322,323,340,341,383,386,414,416,418,421,435,436,441,471,472,475,477,483,492,501,502,504,508,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[88,-22,-15,88,-23,-21,-13,-19,-17,-20,-16,-11,88,-9,-10,-8,-24,-12,-6,88,-244,-18,-14,-7,-292,-291,-2,88,-270,-269,-245,-246,-261,-262,-265,-266,-25,-232,-233,-283,-271,-272,-287,-286,-26,-263,-264,-268,-267,-284,-285,88,88,-290,-288,88,88,-273,88,88,-251,-274,-247,88,88,88,88,88,88,-293,88,-254,-289,-275,-249,-250,-248,88,-294,88,-255,88,88,88,88,-256,-252,-276,-253,]),'GETPROP':([104,349,],[228,228,]),'DELETE':([0,2,4,5,6,7,10,11,13,19,21,23,25,26,28,29,30,31,36,40,43,44,45,48,50,58,62,65,67,68,72,75,77,83,84,88,89,90,92,93,94,95,111,114,115,116,120,121,122,123,124,126,133,143,146,147,148,149,150,151,152,155,158,160,163,164,168,170,171,174,175,176,177,179,181,182,183,184,185,186,187,188,189,190,191,192,193,194,195,197,198,199,200,201,202,203,205,206,207,210,215,219,226,238,240,241,243,250,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,270,271,272,273,274,275,276,277,278,310,311,312,313,314,322,323,340,341,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,414,416,418,420,421,434,435,436,441,443,446,447,471,472,475,477,483,488,491,492,493,495,501,502,504,508,509,512,514,516,519,522,523,524,528,529,531,532,533,534,536,540,541,542,544,547,],[25,-22,-1,-15,25,25,25,25,-23,-21,-13,25,25,25,-19,-17,25,-20,-16,25,-11,25,-9,25,-10,-8,-24,-12,-6,25,-244,-18,-14,25,25,25,25,25,25,-53,-52,-51,-7,-292,-291,-2,25,25,25,25,25,25,-270,-269,25,-245,-246,25,25,25,25,25,25,25,-261,-262,25,25,25,25,25,-265,-266,-25,25,25,25,25,25,25,25,25,25,25,25,25,-216,-221,-222,-219,-217,-224,-215,-218,-220,-223,-214,-225,25,25,-1,-54,25,25,-232,-233,25,-283,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,-271,-272,25,25,25,25,25,25,25,-287,-286,-26,-263,-264,-268,-267,-284,-285,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,25,-290,-288,25,25,25,25,-273,25,25,25,25,25,-251,-274,-247,25,25,25,25,25,25,25,25,25,25,-293,25,25,-254,-289,-275,-249,-250,-248,25,-294,25,-255,25,25,25,25,-256,-252,-276,-253,]),}

_lr_action = { }
for _k, _v in _lr_action_items.items():
   for _x,_y in zip(_v[0],_v[1]):
      if not _x in _lr_action:  _lr_action[_x] = { }
      _lr_action[_x][_k] = _y
del _lr_action_items

_lr_goto_items = {'logical_or_expr_nobf':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,1,]),'throw_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,2,]),'boolean_literal':([0,6,7,10,11,23,25,26,30,40,44,48,54,68,83,84,88,89,90,92,98,120,121,122,123,124,126,146,149,150,151,152,155,158,160,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,418,420,421,434,436,441,443,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,3,]),'bitwise_or_expr':([26,83,88,89,92,146,149,158,160,168,170,175,207,210,226,238,243,261,272,275,276,277,342,343,352,404,407,412,420,434,443,446,488,491,495,509,],[130,130,130,130,130,130,130,130,130,130,130,130,130,130,130,130,130,367,130,130,130,130,130,130,130,130,130,130,130,130,130,130,130,130,130,130,]),'property_assignment':([104,349,],[233,430,]),'logical_and_expr_noin':([155,406,408,409,410,447,493,],[288,288,288,288,468,288,288,]),'iteration_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,5,]),'variable_declaration_noin':([289,444,],[390,486,]),'source_element_list':([0,44,386,436,441,477,483,502,504,528,534,536,],[7,7,7,7,7,7,7,7,7,7,7,7,]),'function_expr':([0,6,7,10,11,23,25,26,30,40,44,48,54,68,83,84,88,89,90,92,98,120,121,122,123,124,126,146,149,150,151,152,155,158,160,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,418,420,421,434,436,441,443,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[8,107,8,107,107,107,107,107,107,107,8,107,107,8,107,107,107,107,8,107,107,107,107,107,107,107,8,107,107,107,107,107,107,107,107,107,107,8,8,107,8,107,107,107,107,107,107,107,107,107,107,8,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,8,8,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,107,8,107,8,107,8,8,107,107,107,8,8,107,107,8,107,107,8,8,8,107,8,8,8,8,8,8,8,]),'multiplicative_expr':([26,83,88,89,92,120,121,122,123,124,146,149,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[128,128,128,128,128,128,128,128,248,249,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,377,378,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,128,]),'finally':([161,311,],[310,416,]),'program':([0,],[9,]),'case_block':([419,],[472,]),'formal_parameter_list':([153,287,344,431,],[284,387,425,479,]),'new_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,12,]),'try_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,13,]),'element_list':([4,],[91,]),'relational_expr':([26,83,88,89,92,146,149,158,160,168,170,175,182,183,184,185,207,210,226,238,243,260,261,265,266,267,268,269,272,275,276,277,278,342,343,352,400,401,402,403,404,407,412,420,434,443,446,488,491,495,509,],[129,129,129,129,129,129,129,129,129,129,129,129,326,327,328,329,129,129,129,129,129,129,129,129,372,373,374,375,129,129,129,129,129,129,129,129,455,456,457,458,129,129,129,129,129,129,129,129,129,129,129,]),'primary_expr_no_brace':([0,6,7,10,11,23,25,26,30,40,44,48,54,68,83,84,88,89,90,92,98,120,121,122,123,124,126,146,149,150,151,152,155,158,160,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,418,420,421,434,436,441,443,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[15,102,15,102,102,102,102,102,102,102,15,102,102,15,102,102,102,102,15,102,102,102,102,102,102,102,15,102,102,102,102,102,102,102,102,102,102,15,15,102,15,102,102,102,102,102,102,102,102,102,102,15,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,15,15,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,102,15,102,15,102,15,15,102,102,102,15,15,102,102,15,102,102,15,15,15,102,15,15,15,15,15,15,15,]),'variable_declaration_list_noin':([289,],[391,]),'null_literal':([0,6,7,10,11,23,25,26,30,40,44,48,54,68,83,84,88,89,90,92,98,120,121,122,123,124,126,146,149,150,151,152,155,158,160,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,418,420,421,434,436,441,443,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,16,]),'labelled_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,19,]),'expr_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,21,]),'logical_and_expr':([26,83,88,89,92,146,149,158,160,168,170,175,207,210,226,238,243,272,275,276,277,342,343,352,404,407,412,420,434,443,446,488,491,495,509,],[131,131,131,131,131,131,131,131,131,131,131,131,131,131,131,131,131,131,131,380,131,131,131,131,131,131,131,131,131,131,131,131,131,131,131,]),'additive_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,22,]),'primary_expr':([6,10,11,23,25,26,30,40,48,54,83,84,88,89,92,98,120,121,122,123,124,146,149,150,151,152,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,108,]),'identifier':([0,6,7,10,11,17,23,25,26,30,37,40,44,47,48,54,66,68,83,84,88,89,90,92,96,98,104,120,121,122,123,124,126,146,149,150,151,152,153,155,157,158,160,167,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,225,226,228,231,237,238,242,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,287,289,342,343,344,349,352,383,385,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,415,418,420,421,431,434,436,441,443,444,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[24,110,24,110,110,118,110,110,110,110,154,110,24,165,110,110,178,24,110,110,110,110,110,110,220,110,234,110,110,110,110,110,24,110,110,110,110,110,286,110,303,110,110,315,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,346,110,234,234,353,110,118,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,286,392,110,110,286,234,110,24,437,24,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,110,470,24,110,24,286,110,24,24,110,487,110,110,24,24,110,110,24,110,110,24,24,24,110,24,24,24,24,24,24,24,]),'bitwise_xor_expr_nobf':([0,7,44,68,90,126,174,181,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[53,53,53,53,53,53,53,325,53,53,53,53,53,53,53,53,53,53,53,53,53,53,53,53,53,53,53,]),'relational_expr_noin':([155,389,398,399,405,406,408,409,410,447,493,],[290,290,290,290,290,290,290,290,290,290,290,]),'with_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,28,]),'case_clauses_opt':([473,520,],[497,535,]),'initializer':([118,],[244,]),'break_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,29,]),'bitwise_and_expr_noin':([155,389,399,405,406,408,409,410,447,493,],[291,291,454,291,291,291,291,291,291,291,]),'switch_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,31,]),'property_list':([104,],[230,]),'postfix_expr':([6,10,11,23,25,26,30,40,48,83,84,88,89,92,120,121,122,123,124,146,149,150,151,152,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,100,]),'source_elements':([0,44,386,436,441,477,483,502,504,528,534,536,],[33,162,438,438,438,438,438,438,438,438,543,545,]),'shift_expr':([26,83,88,89,92,146,149,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,254,255,256,257,258,259,260,261,265,266,267,268,269,272,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[132,132,132,132,132,132,132,292,132,132,132,132,132,132,132,132,132,330,331,332,333,334,335,132,132,132,132,132,360,361,362,363,364,365,132,132,132,132,132,132,132,132,132,132,132,132,132,132,132,292,448,449,450,451,452,292,292,132,132,132,132,132,292,292,132,292,292,292,132,132,132,132,132,292,132,132,292,132,132,]),'expr_nobf':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,34,]),'expr_opt':([404,443,491,509,],[459,485,513,530,]),'multiplicative_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,35,]),'continue_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,36,]),'argument_list':([160,],[306,]),'expr_noin_opt':([155,],[296,]),'string_literal':([0,6,7,10,11,23,25,26,30,40,44,48,54,68,83,84,88,89,90,92,98,104,120,121,122,123,124,126,146,149,150,151,152,155,158,160,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,226,228,231,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,349,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,418,420,421,434,436,441,443,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,236,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,236,236,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,236,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,38,]),'call_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,41,]),'bitwise_xor_expr_noin':([155,389,405,406,408,409,410,447,493,],[293,293,462,293,293,293,293,293,293,]),'variable_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[43,43,43,43,43,43,43,43,43,43,43,43,43,43,43,43,43,43,43,43,43,43,43,43,]),'object_literal':([6,10,11,23,25,26,30,40,48,54,83,84,88,89,92,98,120,121,122,123,124,146,149,150,151,152,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,105,]),'function_declaration':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[45,45,45,179,179,179,45,179,179,45,45,45,45,179,179,45,45,179,45,179,179,45,45,179,]),'unary_expr_common':([0,6,7,10,11,23,25,26,30,40,44,48,68,83,84,88,89,90,92,120,121,122,123,124,126,146,149,150,151,152,155,158,160,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,418,420,421,434,436,441,443,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[46,106,46,106,106,106,106,106,106,106,46,106,46,106,106,106,106,46,106,106,106,106,106,106,46,106,106,106,106,106,106,106,106,106,106,46,46,106,46,106,106,106,106,106,106,106,106,106,106,46,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,46,46,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,106,46,106,46,106,46,46,106,106,106,46,46,106,106,46,106,106,46,46,46,106,46,46,46,46,46,46,46,]),'additive_expr':([26,83,88,89,92,120,121,122,146,149,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[140,140,140,140,140,245,246,247,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,368,369,370,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,140,]),'assignment_operator':([82,142,301,464,],[207,277,408,408,]),'case_clause':([473,496,520,],[498,518,498,]),'member_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,49,]),'numeric_literal':([0,6,7,10,11,23,25,26,30,40,44,48,54,68,83,84,88,89,90,92,98,104,120,121,122,123,124,126,146,149,150,151,152,155,158,160,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,226,228,231,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,349,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,418,420,421,434,436,441,443,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,232,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,232,232,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,232,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,87,]),'assignment_expr_nobf':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[51,51,51,51,51,51,51,51,51,51,51,51,51,51,51,51,51,51,51,51,51,51,51,51,]),'equality_expr_noin':([155,389,398,399,405,406,408,409,410,447,493,],[294,294,453,294,294,294,294,294,294,294,294,]),'unary_expr':([6,10,11,23,25,26,30,40,48,83,84,88,89,92,120,121,122,123,124,146,149,150,151,152,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[97,112,113,125,127,134,145,156,166,134,209,134,134,134,134,134,134,134,134,134,134,281,282,283,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,357,358,359,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,134,]),'unary_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,27,]),'function_body':([386,436,441,477,483,502,504,528,],[439,481,484,503,507,525,527,539,]),'variable_declaration':([17,242,],[119,355,]),'bitwise_xor_expr':([26,83,88,89,92,146,149,158,160,168,170,175,207,210,226,238,243,260,261,272,275,276,277,342,343,352,404,407,412,420,434,443,446,488,491,495,509,],[135,135,135,135,135,135,135,135,135,135,135,135,135,135,135,135,135,366,135,135,135,135,135,135,135,135,135,135,135,135,135,135,135,135,135,135,135,]),'conditional_expr_nobf':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[55,55,55,55,55,55,55,55,55,55,55,55,55,55,55,55,55,55,55,55,55,55,55,55,]),'equality_expr':([26,83,88,89,92,146,149,158,160,168,170,175,207,210,226,238,243,260,261,265,272,275,276,277,278,342,343,352,404,407,412,420,434,443,446,488,491,495,509,],[136,136,136,136,136,136,136,136,136,136,136,136,136,136,136,136,136,136,136,136,136,136,136,136,382,136,136,136,136,136,136,136,136,136,136,136,136,136,136,]),'literal':([0,6,7,10,11,23,25,26,30,40,44,48,54,68,83,84,88,89,90,92,98,120,121,122,123,124,126,146,149,150,151,152,155,158,160,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,418,420,421,434,436,441,443,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,80,]),'logical_and_expr_nobf':([0,7,44,68,90,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[56,56,56,56,214,56,56,56,56,56,56,56,56,56,56,56,56,56,56,56,56,56,56,56,56,]),'shift_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,18,]),'elision':([4,215,],[94,94,]),'statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[58,58,58,180,250,435,58,471,475,58,58,58,58,514,524,58,58,532,58,541,542,58,58,547,]),'empty':([0,4,44,155,215,386,404,436,441,443,473,477,483,491,502,504,509,520,528,534,536,],[59,95,59,300,95,59,460,59,59,460,499,59,59,460,59,59,460,499,59,59,59,]),'new_expr':([6,10,11,23,25,26,30,40,48,54,83,84,88,89,92,98,120,121,122,123,124,146,149,150,151,152,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[101,101,101,101,101,101,101,101,101,172,101,101,101,101,101,221,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,101,]),'postfix_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,60,]),'regex_literal':([0,6,7,10,11,23,25,26,30,40,44,48,54,68,83,84,88,89,90,92,98,120,121,122,123,124,126,146,149,150,151,152,155,158,160,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,418,420,421,434,436,441,443,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,61,]),'conditional_expr_noin':([155,406,408,409,447,493,],[298,298,298,298,298,298,]),'variable_declaration_list':([17,],[117,]),'catch':([161,],[311,]),'expr_noin':([155,],[299,]),'conditional_expr':([26,83,88,89,92,146,149,158,160,168,170,175,207,210,226,238,243,272,275,277,342,343,352,404,407,412,420,434,443,446,488,491,495,509,],[137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,137,]),'default_clause':([497,],[520,]),'expr':([26,83,88,146,158,168,170,175,210,226,238,404,407,420,443,446,488,491,495,509,],[138,208,211,279,304,316,317,321,339,347,354,461,465,474,461,489,511,461,517,461,]),'empty_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[65,65,65,65,65,65,65,65,65,65,65,65,65,65,65,65,65,65,65,65,65,65,65,65,]),'bitwise_or_expr_noin':([155,389,406,408,409,410,447,493,],[297,442,297,297,297,297,297,297,]),'member_expr':([6,10,11,23,25,26,30,40,48,54,83,84,88,89,92,98,120,121,122,123,124,146,149,150,151,152,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[109,109,109,109,109,109,109,109,109,173,109,109,109,109,109,222,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,109,]),'assignment_expr':([26,83,88,89,92,146,149,158,160,168,170,175,207,210,226,238,243,272,275,277,342,343,352,404,407,412,420,434,443,446,488,491,495,509,],[139,139,139,212,217,139,280,139,307,139,139,139,337,139,139,139,356,376,379,381,422,423,432,139,139,469,139,480,139,139,139,139,139,139,]),'initializer_noin':([392,487,],[445,510,]),'source_element':([0,7,44,386,436,441,477,483,502,504,528,534,536,],[67,111,67,67,67,67,67,67,67,67,67,67,67,]),'bitwise_or_expr_nobf':([0,7,44,68,90,126,174,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[69,69,69,69,69,69,320,69,69,69,69,69,69,69,69,69,69,69,69,69,69,69,69,69,69,69,]),'case_clauses':([473,520,],[496,496,]),'logical_or_expr':([26,83,88,89,92,146,149,158,160,168,170,175,207,210,226,238,243,272,275,277,342,343,352,404,407,412,420,434,443,446,488,491,495,509,],[141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,141,]),'left_hand_side_expr':([6,10,11,23,25,26,30,40,48,83,84,88,89,92,120,121,122,123,124,146,149,150,151,152,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[99,99,99,99,99,142,99,99,99,142,99,142,142,142,99,99,99,99,99,142,142,99,99,99,301,142,142,142,142,142,99,99,99,99,99,99,99,99,99,99,142,142,142,142,142,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,142,99,99,142,99,142,99,142,142,142,99,99,99,99,99,99,99,99,99,99,99,99,142,99,464,142,464,464,99,142,142,142,142,142,464,142,142,464,142,142,]),'property_name':([104,228,231,349,],[235,348,351,235,]),'equality_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[73,73,73,73,73,73,73,73,73,336,73,73,73,73,73,73,73,73,73,73,73,73,73,73,73,73,73,73,73,]),'relational_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,74,]),'return_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[75,75,75,75,75,75,75,75,75,75,75,75,75,75,75,75,75,75,75,75,75,75,75,75,]),'bitwise_and_expr_nobf':([0,7,44,68,90,126,171,174,181,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[76,76,76,76,76,76,318,76,76,76,76,76,76,76,76,76,76,76,76,76,76,76,76,76,76,76,76,76,]),'arguments':([41,49,103,109,173,222,],[159,169,227,239,319,345,]),'if_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,77,]),'logical_or_expr_noin':([155,406,408,409,447,493,],[302,302,302,302,302,302,]),'auto_semi':([14,26,34,47,66,117,138,165,178,211,500,],[114,133,148,164,177,241,271,314,322,341,523,]),'call_expr':([6,10,11,23,25,26,30,40,48,83,84,88,89,92,120,121,122,123,124,146,149,150,151,152,155,158,160,168,170,175,182,183,184,185,186,187,188,189,190,191,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,420,434,443,446,447,488,491,493,495,509,],[103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,103,]),'array_literal':([0,6,7,10,11,23,25,26,30,40,44,48,54,68,83,84,88,89,90,92,98,120,121,122,123,124,126,146,149,150,151,152,155,158,160,168,170,171,174,175,181,182,183,184,185,186,187,188,189,190,191,192,207,210,226,238,243,251,252,253,254,255,256,257,258,259,260,261,262,263,264,265,266,267,268,269,272,273,274,275,276,277,278,342,343,352,383,386,389,393,394,395,396,397,398,399,400,401,402,403,404,405,406,407,408,409,410,412,418,420,421,434,436,441,443,446,447,477,483,488,491,492,493,495,501,502,504,509,512,528,531,533,534,536,540,],[81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,81,]),'left_hand_side_expr_nobf':([0,7,44,68,90,126,171,174,181,192,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[82,82,82,82,213,82,213,213,213,213,82,82,82,82,82,82,82,82,82,82,82,82,82,82,82,82,82,82,82,]),'assignment_expr_noin':([155,406,408,409,447,493,],[295,463,466,467,490,515,]),'elision_opt':([4,215,],[92,343,]),'bitwise_and_expr':([26,83,88,89,92,146,149,158,160,168,170,175,207,210,226,238,243,260,261,265,272,275,276,277,342,343,352,404,407,412,420,434,443,446,488,491,495,509,],[144,144,144,144,144,144,144,144,144,144,144,144,144,144,144,144,144,144,144,371,144,144,144,144,144,144,144,144,144,144,144,144,144,144,144,144,144,144,]),'block':([0,7,42,44,68,126,308,383,386,418,421,436,441,477,483,492,494,501,502,504,512,528,531,533,534,536,540,],[50,50,161,50,50,50,414,50,50,50,50,50,50,50,50,50,516,50,50,50,50,50,50,50,50,50,50,]),'debugger_statement':([0,7,44,68,126,383,386,418,421,436,441,477,483,492,501,502,504,512,528,531,533,534,536,540,],[62,62,62,62,62,62,62,62,62,62,62,62,62,62,62,62,62,62,62,62,62,62,62,62,]),}

_lr_goto = { }
for _k, _v in _lr_goto_items.items():
   for _x,_y in zip(_v[0],_v[1]):
       if not _x in _lr_goto: _lr_goto[_x] = { }
       _lr_goto[_x][_k] = _y
del _lr_goto_items
_lr_productions = [
  ("S' -> program","S'",1,None,None,None),
  ('empty -> <empty>','empty',0,'p_empty','/home/alienoid/dev/python/slimit/src/slimit/parser.py',96),
  ('auto_semi -> error','auto_semi',1,'p_auto_semi','/home/alienoid/dev/python/slimit/src/slimit/parser.py',100),
  ('program -> source_elements','program',1,'p_program','/home/alienoid/dev/python/slimit/src/slimit/parser.py',130),
  ('source_elements -> empty','source_elements',1,'p_source_elements','/home/alienoid/dev/python/slimit/src/slimit/parser.py',134),
  ('source_elements -> source_element_list','source_elements',1,'p_source_elements','/home/alienoid/dev/python/slimit/src/slimit/parser.py',135),
  ('source_element_list -> source_element','source_element_list',1,'p_source_element_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',140),
  ('source_element_list -> source_element_list source_element','source_element_list',2,'p_source_element_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',141),
  ('source_element -> statement','source_element',1,'p_source_element','/home/alienoid/dev/python/slimit/src/slimit/parser.py',150),
  ('source_element -> function_declaration','source_element',1,'p_source_element','/home/alienoid/dev/python/slimit/src/slimit/parser.py',151),
  ('statement -> block','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',156),
  ('statement -> variable_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',157),
  ('statement -> empty_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',158),
  ('statement -> expr_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',159),
  ('statement -> if_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',160),
  ('statement -> iteration_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',161),
  ('statement -> continue_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',162),
  ('statement -> break_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',163),
  ('statement -> return_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',164),
  ('statement -> with_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',165),
  ('statement -> switch_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',166),
  ('statement -> labelled_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',167),
  ('statement -> throw_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',168),
  ('statement -> try_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',169),
  ('statement -> debugger_statement','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',170),
  ('statement -> function_declaration','statement',1,'p_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',171),
  ('block -> LBRACE source_elements RBRACE','block',3,'p_block','/home/alienoid/dev/python/slimit/src/slimit/parser.py',178),
  ('literal -> null_literal','literal',1,'p_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',182),
  ('literal -> boolean_literal','literal',1,'p_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',183),
  ('literal -> numeric_literal','literal',1,'p_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',184),
  ('literal -> string_literal','literal',1,'p_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',185),
  ('literal -> regex_literal','literal',1,'p_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',186),
  ('boolean_literal -> TRUE','boolean_literal',1,'p_boolean_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',191),
  ('boolean_literal -> FALSE','boolean_literal',1,'p_boolean_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',192),
  ('null_literal -> NULL','null_literal',1,'p_null_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',197),
  ('numeric_literal -> NUMBER','numeric_literal',1,'p_numeric_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',201),
  ('string_literal -> STRING','string_literal',1,'p_string_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',205),
  ('regex_literal -> REGEX','regex_literal',1,'p_regex_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',209),
  ('identifier -> ID','identifier',1,'p_identifier','/home/alienoid/dev/python/slimit/src/slimit/parser.py',213),
  ('primary_expr -> primary_expr_no_brace','primary_expr',1,'p_primary_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',220),
  ('primary_expr -> object_literal','primary_expr',1,'p_primary_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',221),
  ('primary_expr_no_brace -> identifier','primary_expr_no_brace',1,'p_primary_expr_no_brace_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',226),
  ('primary_expr_no_brace -> THIS','primary_expr_no_brace',1,'p_primary_expr_no_brace_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',232),
  ('primary_expr_no_brace -> literal','primary_expr_no_brace',1,'p_primary_expr_no_brace_3','/home/alienoid/dev/python/slimit/src/slimit/parser.py',236),
  ('primary_expr_no_brace -> array_literal','primary_expr_no_brace',1,'p_primary_expr_no_brace_3','/home/alienoid/dev/python/slimit/src/slimit/parser.py',237),
  ('primary_expr_no_brace -> LPAREN expr RPAREN','primary_expr_no_brace',3,'p_primary_expr_no_brace_4','/home/alienoid/dev/python/slimit/src/slimit/parser.py',242),
  ('array_literal -> LBRACKET elision_opt RBRACKET','array_literal',3,'p_array_literal_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',247),
  ('array_literal -> LBRACKET element_list RBRACKET','array_literal',3,'p_array_literal_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',251),
  ('array_literal -> LBRACKET element_list COMMA elision_opt RBRACKET','array_literal',5,'p_array_literal_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',252),
  ('element_list -> elision_opt assignment_expr','element_list',2,'p_element_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',261),
  ('element_list -> element_list COMMA elision_opt assignment_expr','element_list',4,'p_element_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',262),
  ('elision_opt -> empty','elision_opt',1,'p_elision_opt_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',272),
  ('elision_opt -> elision','elision_opt',1,'p_elision_opt_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',276),
  ('elision -> COMMA','elision',1,'p_elision','/home/alienoid/dev/python/slimit/src/slimit/parser.py',280),
  ('elision -> elision COMMA','elision',2,'p_elision','/home/alienoid/dev/python/slimit/src/slimit/parser.py',281),
  ('object_literal -> LBRACE RBRACE','object_literal',2,'p_object_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',290),
  ('object_literal -> LBRACE property_list RBRACE','object_literal',3,'p_object_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',291),
  ('object_literal -> LBRACE property_list COMMA RBRACE','object_literal',4,'p_object_literal','/home/alienoid/dev/python/slimit/src/slimit/parser.py',292),
  ('property_list -> property_assignment','property_list',1,'p_property_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',300),
  ('property_list -> property_list COMMA property_assignment','property_list',3,'p_property_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',301),
  ('property_assignment -> property_name COLON assignment_expr','property_assignment',3,'p_property_assignment','/home/alienoid/dev/python/slimit/src/slimit/parser.py',311),
  ('property_assignment -> GETPROP property_name LPAREN RPAREN LBRACE function_body RBRACE','property_assignment',7,'p_property_assignment','/home/alienoid/dev/python/slimit/src/slimit/parser.py',312),
  ('property_assignment -> SETPROP property_name LPAREN formal_parameter_list RPAREN LBRACE function_body RBRACE','property_assignment',8,'p_property_assignment','/home/alienoid/dev/python/slimit/src/slimit/parser.py',313),
  ('property_name -> identifier','property_name',1,'p_property_name','/home/alienoid/dev/python/slimit/src/slimit/parser.py',326),
  ('property_name -> string_literal','property_name',1,'p_property_name','/home/alienoid/dev/python/slimit/src/slimit/parser.py',327),
  ('property_name -> numeric_literal','property_name',1,'p_property_name','/home/alienoid/dev/python/slimit/src/slimit/parser.py',328),
  ('member_expr -> primary_expr','member_expr',1,'p_member_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',334),
  ('member_expr -> function_expr','member_expr',1,'p_member_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',335),
  ('member_expr -> member_expr LBRACKET expr RBRACKET','member_expr',4,'p_member_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',336),
  ('member_expr -> member_expr PERIOD identifier','member_expr',3,'p_member_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',337),
  ('member_expr -> NEW member_expr arguments','member_expr',3,'p_member_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',338),
  ('member_expr_nobf -> primary_expr_no_brace','member_expr_nobf',1,'p_member_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',350),
  ('member_expr_nobf -> function_expr','member_expr_nobf',1,'p_member_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',351),
  ('member_expr_nobf -> member_expr_nobf LBRACKET expr RBRACKET','member_expr_nobf',4,'p_member_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',352),
  ('member_expr_nobf -> member_expr_nobf PERIOD identifier','member_expr_nobf',3,'p_member_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',353),
  ('member_expr_nobf -> NEW member_expr arguments','member_expr_nobf',3,'p_member_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',354),
  ('new_expr -> member_expr','new_expr',1,'p_new_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',366),
  ('new_expr -> NEW new_expr','new_expr',2,'p_new_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',367),
  ('new_expr_nobf -> member_expr_nobf','new_expr_nobf',1,'p_new_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',375),
  ('new_expr_nobf -> NEW new_expr','new_expr_nobf',2,'p_new_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',376),
  ('call_expr -> member_expr arguments','call_expr',2,'p_call_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',384),
  ('call_expr -> call_expr arguments','call_expr',2,'p_call_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',385),
  ('call_expr -> call_expr LBRACKET expr RBRACKET','call_expr',4,'p_call_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',386),
  ('call_expr -> call_expr PERIOD identifier','call_expr',3,'p_call_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',387),
  ('call_expr_nobf -> member_expr_nobf arguments','call_expr_nobf',2,'p_call_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',397),
  ('call_expr_nobf -> call_expr_nobf arguments','call_expr_nobf',2,'p_call_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',398),
  ('call_expr_nobf -> call_expr_nobf LBRACKET expr RBRACKET','call_expr_nobf',4,'p_call_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',399),
  ('call_expr_nobf -> call_expr_nobf PERIOD identifier','call_expr_nobf',3,'p_call_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',400),
  ('arguments -> LPAREN RPAREN','arguments',2,'p_arguments','/home/alienoid/dev/python/slimit/src/slimit/parser.py',410),
  ('arguments -> LPAREN argument_list RPAREN','arguments',3,'p_arguments','/home/alienoid/dev/python/slimit/src/slimit/parser.py',411),
  ('argument_list -> assignment_expr','argument_list',1,'p_argument_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',417),
  ('argument_list -> argument_list COMMA assignment_expr','argument_list',3,'p_argument_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',418),
  ('left_hand_side_expr -> new_expr','left_hand_side_expr',1,'p_lef_hand_side_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',427),
  ('left_hand_side_expr -> call_expr','left_hand_side_expr',1,'p_lef_hand_side_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',428),
  ('left_hand_side_expr_nobf -> new_expr_nobf','left_hand_side_expr_nobf',1,'p_lef_hand_side_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',433),
  ('left_hand_side_expr_nobf -> call_expr_nobf','left_hand_side_expr_nobf',1,'p_lef_hand_side_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',434),
  ('postfix_expr -> left_hand_side_expr','postfix_expr',1,'p_postfix_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',440),
  ('postfix_expr -> left_hand_side_expr PLUSPLUS','postfix_expr',2,'p_postfix_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',441),
  ('postfix_expr -> left_hand_side_expr MINUSMINUS','postfix_expr',2,'p_postfix_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',442),
  ('postfix_expr_nobf -> left_hand_side_expr_nobf','postfix_expr_nobf',1,'p_postfix_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',450),
  ('postfix_expr_nobf -> left_hand_side_expr_nobf PLUSPLUS','postfix_expr_nobf',2,'p_postfix_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',451),
  ('postfix_expr_nobf -> left_hand_side_expr_nobf MINUSMINUS','postfix_expr_nobf',2,'p_postfix_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',452),
  ('unary_expr -> postfix_expr','unary_expr',1,'p_unary_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',461),
  ('unary_expr -> unary_expr_common','unary_expr',1,'p_unary_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',462),
  ('unary_expr_nobf -> postfix_expr_nobf','unary_expr_nobf',1,'p_unary_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',467),
  ('unary_expr_nobf -> unary_expr_common','unary_expr_nobf',1,'p_unary_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',468),
  ('unary_expr_common -> DELETE unary_expr','unary_expr_common',2,'p_unary_expr_common','/home/alienoid/dev/python/slimit/src/slimit/parser.py',473),
  ('unary_expr_common -> VOID unary_expr','unary_expr_common',2,'p_unary_expr_common','/home/alienoid/dev/python/slimit/src/slimit/parser.py',474),
  ('unary_expr_common -> TYPEOF unary_expr','unary_expr_common',2,'p_unary_expr_common','/home/alienoid/dev/python/slimit/src/slimit/parser.py',475),
  ('unary_expr_common -> PLUSPLUS unary_expr','unary_expr_common',2,'p_unary_expr_common','/home/alienoid/dev/python/slimit/src/slimit/parser.py',476),
  ('unary_expr_common -> MINUSMINUS unary_expr','unary_expr_common',2,'p_unary_expr_common','/home/alienoid/dev/python/slimit/src/slimit/parser.py',477),
  ('unary_expr_common -> PLUS unary_expr','unary_expr_common',2,'p_unary_expr_common','/home/alienoid/dev/python/slimit/src/slimit/parser.py',478),
  ('unary_expr_common -> MINUS unary_expr','unary_expr_common',2,'p_unary_expr_common','/home/alienoid/dev/python/slimit/src/slimit/parser.py',479),
  ('unary_expr_common -> BNOT unary_expr','unary_expr_common',2,'p_unary_expr_common','/home/alienoid/dev/python/slimit/src/slimit/parser.py',480),
  ('unary_expr_common -> NOT unary_expr','unary_expr_common',2,'p_unary_expr_common','/home/alienoid/dev/python/slimit/src/slimit/parser.py',481),
  ('multiplicative_expr -> unary_expr','multiplicative_expr',1,'p_multiplicative_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',487),
  ('multiplicative_expr -> multiplicative_expr MULT unary_expr','multiplicative_expr',3,'p_multiplicative_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',488),
  ('multiplicative_expr -> multiplicative_expr DIV unary_expr','multiplicative_expr',3,'p_multiplicative_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',489),
  ('multiplicative_expr -> multiplicative_expr MOD unary_expr','multiplicative_expr',3,'p_multiplicative_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',490),
  ('multiplicative_expr_nobf -> unary_expr_nobf','multiplicative_expr_nobf',1,'p_multiplicative_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',498),
  ('multiplicative_expr_nobf -> multiplicative_expr_nobf MULT unary_expr','multiplicative_expr_nobf',3,'p_multiplicative_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',499),
  ('multiplicative_expr_nobf -> multiplicative_expr_nobf DIV unary_expr','multiplicative_expr_nobf',3,'p_multiplicative_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',500),
  ('multiplicative_expr_nobf -> multiplicative_expr_nobf MOD unary_expr','multiplicative_expr_nobf',3,'p_multiplicative_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',501),
  ('additive_expr -> multiplicative_expr','additive_expr',1,'p_additive_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',510),
  ('additive_expr -> additive_expr PLUS multiplicative_expr','additive_expr',3,'p_additive_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',511),
  ('additive_expr -> additive_expr MINUS multiplicative_expr','additive_expr',3,'p_additive_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',512),
  ('additive_expr_nobf -> multiplicative_expr_nobf','additive_expr_nobf',1,'p_additive_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',520),
  ('additive_expr_nobf -> additive_expr_nobf PLUS multiplicative_expr','additive_expr_nobf',3,'p_additive_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',521),
  ('additive_expr_nobf -> additive_expr_nobf MINUS multiplicative_expr','additive_expr_nobf',3,'p_additive_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',522),
  ('shift_expr -> additive_expr','shift_expr',1,'p_shift_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',531),
  ('shift_expr -> shift_expr LSHIFT additive_expr','shift_expr',3,'p_shift_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',532),
  ('shift_expr -> shift_expr RSHIFT additive_expr','shift_expr',3,'p_shift_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',533),
  ('shift_expr -> shift_expr URSHIFT additive_expr','shift_expr',3,'p_shift_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',534),
  ('shift_expr_nobf -> additive_expr_nobf','shift_expr_nobf',1,'p_shift_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',542),
  ('shift_expr_nobf -> shift_expr_nobf LSHIFT additive_expr','shift_expr_nobf',3,'p_shift_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',543),
  ('shift_expr_nobf -> shift_expr_nobf RSHIFT additive_expr','shift_expr_nobf',3,'p_shift_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',544),
  ('shift_expr_nobf -> shift_expr_nobf URSHIFT additive_expr','shift_expr_nobf',3,'p_shift_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',545),
  ('relational_expr -> shift_expr','relational_expr',1,'p_relational_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',555),
  ('relational_expr -> relational_expr LT shift_expr','relational_expr',3,'p_relational_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',556),
  ('relational_expr -> relational_expr GT shift_expr','relational_expr',3,'p_relational_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',557),
  ('relational_expr -> relational_expr LE shift_expr','relational_expr',3,'p_relational_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',558),
  ('relational_expr -> relational_expr GE shift_expr','relational_expr',3,'p_relational_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',559),
  ('relational_expr -> relational_expr INSTANCEOF shift_expr','relational_expr',3,'p_relational_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',560),
  ('relational_expr -> relational_expr IN shift_expr','relational_expr',3,'p_relational_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',561),
  ('relational_expr_noin -> shift_expr','relational_expr_noin',1,'p_relational_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',569),
  ('relational_expr_noin -> relational_expr_noin LT shift_expr','relational_expr_noin',3,'p_relational_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',570),
  ('relational_expr_noin -> relational_expr_noin GT shift_expr','relational_expr_noin',3,'p_relational_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',571),
  ('relational_expr_noin -> relational_expr_noin LE shift_expr','relational_expr_noin',3,'p_relational_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',572),
  ('relational_expr_noin -> relational_expr_noin GE shift_expr','relational_expr_noin',3,'p_relational_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',573),
  ('relational_expr_noin -> relational_expr_noin INSTANCEOF shift_expr','relational_expr_noin',3,'p_relational_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',574),
  ('relational_expr_nobf -> shift_expr_nobf','relational_expr_nobf',1,'p_relational_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',582),
  ('relational_expr_nobf -> relational_expr_nobf LT shift_expr','relational_expr_nobf',3,'p_relational_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',583),
  ('relational_expr_nobf -> relational_expr_nobf GT shift_expr','relational_expr_nobf',3,'p_relational_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',584),
  ('relational_expr_nobf -> relational_expr_nobf LE shift_expr','relational_expr_nobf',3,'p_relational_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',585),
  ('relational_expr_nobf -> relational_expr_nobf GE shift_expr','relational_expr_nobf',3,'p_relational_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',586),
  ('relational_expr_nobf -> relational_expr_nobf INSTANCEOF shift_expr','relational_expr_nobf',3,'p_relational_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',587),
  ('relational_expr_nobf -> relational_expr_nobf IN shift_expr','relational_expr_nobf',3,'p_relational_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',588),
  ('equality_expr -> relational_expr','equality_expr',1,'p_equality_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',597),
  ('equality_expr -> equality_expr EQEQ relational_expr','equality_expr',3,'p_equality_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',598),
  ('equality_expr -> equality_expr NE relational_expr','equality_expr',3,'p_equality_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',599),
  ('equality_expr -> equality_expr STREQ relational_expr','equality_expr',3,'p_equality_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',600),
  ('equality_expr -> equality_expr STRNEQ relational_expr','equality_expr',3,'p_equality_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',601),
  ('equality_expr_noin -> relational_expr_noin','equality_expr_noin',1,'p_equality_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',609),
  ('equality_expr_noin -> equality_expr_noin EQEQ relational_expr','equality_expr_noin',3,'p_equality_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',610),
  ('equality_expr_noin -> equality_expr_noin NE relational_expr','equality_expr_noin',3,'p_equality_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',611),
  ('equality_expr_noin -> equality_expr_noin STREQ relational_expr','equality_expr_noin',3,'p_equality_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',612),
  ('equality_expr_noin -> equality_expr_noin STRNEQ relational_expr','equality_expr_noin',3,'p_equality_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',613),
  ('equality_expr_nobf -> relational_expr_nobf','equality_expr_nobf',1,'p_equality_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',621),
  ('equality_expr_nobf -> equality_expr_nobf EQEQ relational_expr','equality_expr_nobf',3,'p_equality_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',622),
  ('equality_expr_nobf -> equality_expr_nobf NE relational_expr','equality_expr_nobf',3,'p_equality_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',623),
  ('equality_expr_nobf -> equality_expr_nobf STREQ relational_expr','equality_expr_nobf',3,'p_equality_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',624),
  ('equality_expr_nobf -> equality_expr_nobf STRNEQ relational_expr','equality_expr_nobf',3,'p_equality_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',625),
  ('bitwise_and_expr -> equality_expr','bitwise_and_expr',1,'p_bitwise_and_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',634),
  ('bitwise_and_expr -> bitwise_and_expr BAND equality_expr','bitwise_and_expr',3,'p_bitwise_and_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',635),
  ('bitwise_and_expr_noin -> equality_expr_noin','bitwise_and_expr_noin',1,'p_bitwise_and_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',643),
  ('bitwise_and_expr_noin -> bitwise_and_expr_noin BAND equality_expr_noin','bitwise_and_expr_noin',3,'p_bitwise_and_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',644),
  ('bitwise_and_expr_nobf -> equality_expr_nobf','bitwise_and_expr_nobf',1,'p_bitwise_and_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',653),
  ('bitwise_and_expr_nobf -> bitwise_and_expr_nobf BAND equality_expr_nobf','bitwise_and_expr_nobf',3,'p_bitwise_and_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',654),
  ('bitwise_xor_expr -> bitwise_and_expr','bitwise_xor_expr',1,'p_bitwise_xor_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',663),
  ('bitwise_xor_expr -> bitwise_xor_expr BXOR bitwise_and_expr','bitwise_xor_expr',3,'p_bitwise_xor_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',664),
  ('bitwise_xor_expr_noin -> bitwise_and_expr_noin','bitwise_xor_expr_noin',1,'p_bitwise_xor_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',673),
  ('bitwise_xor_expr_noin -> bitwise_xor_expr_noin BXOR bitwise_and_expr_noin','bitwise_xor_expr_noin',3,'p_bitwise_xor_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',674),
  ('bitwise_xor_expr_nobf -> bitwise_and_expr_nobf','bitwise_xor_expr_nobf',1,'p_bitwise_xor_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',684),
  ('bitwise_xor_expr_nobf -> bitwise_xor_expr_nobf BXOR bitwise_and_expr_nobf','bitwise_xor_expr_nobf',3,'p_bitwise_xor_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',685),
  ('bitwise_or_expr -> bitwise_xor_expr','bitwise_or_expr',1,'p_bitwise_or_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',694),
  ('bitwise_or_expr -> bitwise_or_expr BOR bitwise_xor_expr','bitwise_or_expr',3,'p_bitwise_or_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',695),
  ('bitwise_or_expr_noin -> bitwise_xor_expr_noin','bitwise_or_expr_noin',1,'p_bitwise_or_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',704),
  ('bitwise_or_expr_noin -> bitwise_or_expr_noin BOR bitwise_xor_expr_noin','bitwise_or_expr_noin',3,'p_bitwise_or_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',705),
  ('bitwise_or_expr_nobf -> bitwise_xor_expr_nobf','bitwise_or_expr_nobf',1,'p_bitwise_or_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',715),
  ('bitwise_or_expr_nobf -> bitwise_or_expr_nobf BOR bitwise_xor_expr_nobf','bitwise_or_expr_nobf',3,'p_bitwise_or_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',716),
  ('logical_and_expr -> bitwise_or_expr','logical_and_expr',1,'p_logical_and_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',726),
  ('logical_and_expr -> logical_and_expr AND bitwise_or_expr','logical_and_expr',3,'p_logical_and_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',727),
  ('logical_and_expr_noin -> bitwise_or_expr_noin','logical_and_expr_noin',1,'p_logical_and_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',736),
  ('logical_and_expr_noin -> logical_and_expr_noin AND bitwise_or_expr_noin','logical_and_expr_noin',3,'p_logical_and_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',737),
  ('logical_and_expr_nobf -> bitwise_or_expr_nobf','logical_and_expr_nobf',1,'p_logical_and_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',746),
  ('logical_and_expr_nobf -> logical_and_expr_nobf AND bitwise_or_expr_nobf','logical_and_expr_nobf',3,'p_logical_and_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',747),
  ('logical_or_expr -> logical_and_expr','logical_or_expr',1,'p_logical_or_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',755),
  ('logical_or_expr -> logical_or_expr OR logical_and_expr','logical_or_expr',3,'p_logical_or_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',756),
  ('logical_or_expr_noin -> logical_and_expr_noin','logical_or_expr_noin',1,'p_logical_or_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',764),
  ('logical_or_expr_noin -> logical_or_expr_noin OR logical_and_expr_noin','logical_or_expr_noin',3,'p_logical_or_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',765),
  ('logical_or_expr_nobf -> logical_and_expr_nobf','logical_or_expr_nobf',1,'p_logical_or_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',773),
  ('logical_or_expr_nobf -> logical_or_expr_nobf OR logical_and_expr_nobf','logical_or_expr_nobf',3,'p_logical_or_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',774),
  ('conditional_expr -> logical_or_expr','conditional_expr',1,'p_conditional_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',784),
  ('conditional_expr -> logical_or_expr CONDOP assignment_expr COLON assignment_expr','conditional_expr',5,'p_conditional_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',785),
  ('conditional_expr_noin -> logical_or_expr_noin','conditional_expr_noin',1,'p_conditional_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',796),
  ('conditional_expr_noin -> logical_or_expr_noin CONDOP assignment_expr_noin COLON assignment_expr_noin','conditional_expr_noin',5,'p_conditional_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',797),
  ('conditional_expr_nobf -> logical_or_expr_nobf','conditional_expr_nobf',1,'p_conditional_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',809),
  ('conditional_expr_nobf -> logical_or_expr_nobf CONDOP assignment_expr COLON assignment_expr','conditional_expr_nobf',5,'p_conditional_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',810),
  ('assignment_expr -> conditional_expr','assignment_expr',1,'p_assignment_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',822),
  ('assignment_expr -> left_hand_side_expr assignment_operator assignment_expr','assignment_expr',3,'p_assignment_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',823),
  ('assignment_expr_noin -> conditional_expr_noin','assignment_expr_noin',1,'p_assignment_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',833),
  ('assignment_expr_noin -> left_hand_side_expr assignment_operator assignment_expr_noin','assignment_expr_noin',3,'p_assignment_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',834),
  ('assignment_expr_nobf -> conditional_expr_nobf','assignment_expr_nobf',1,'p_assignment_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',844),
  ('assignment_expr_nobf -> left_hand_side_expr_nobf assignment_operator assignment_expr','assignment_expr_nobf',3,'p_assignment_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',845),
  ('assignment_operator -> EQ','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',854),
  ('assignment_operator -> MULTEQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',855),
  ('assignment_operator -> DIVEQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',856),
  ('assignment_operator -> MODEQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',857),
  ('assignment_operator -> PLUSEQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',858),
  ('assignment_operator -> MINUSEQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',859),
  ('assignment_operator -> LSHIFTEQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',860),
  ('assignment_operator -> RSHIFTEQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',861),
  ('assignment_operator -> URSHIFTEQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',862),
  ('assignment_operator -> ANDEQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',863),
  ('assignment_operator -> XOREQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',864),
  ('assignment_operator -> OREQUAL','assignment_operator',1,'p_assignment_operator','/home/alienoid/dev/python/slimit/src/slimit/parser.py',865),
  ('expr -> assignment_expr','expr',1,'p_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',871),
  ('expr -> expr COMMA assignment_expr','expr',3,'p_expr','/home/alienoid/dev/python/slimit/src/slimit/parser.py',872),
  ('expr_noin -> assignment_expr_noin','expr_noin',1,'p_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',880),
  ('expr_noin -> expr_noin COMMA assignment_expr_noin','expr_noin',3,'p_expr_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',881),
  ('expr_nobf -> assignment_expr_nobf','expr_nobf',1,'p_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',889),
  ('expr_nobf -> expr_nobf COMMA assignment_expr','expr_nobf',3,'p_expr_nobf','/home/alienoid/dev/python/slimit/src/slimit/parser.py',890),
  ('variable_statement -> VAR variable_declaration_list SEMI','variable_statement',3,'p_variable_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',899),
  ('variable_statement -> VAR variable_declaration_list auto_semi','variable_statement',3,'p_variable_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',900),
  ('variable_declaration_list -> variable_declaration','variable_declaration_list',1,'p_variable_declaration_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',906),
  ('variable_declaration_list -> variable_declaration_list COMMA variable_declaration','variable_declaration_list',3,'p_variable_declaration_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',907),
  ('variable_declaration_list_noin -> variable_declaration_noin','variable_declaration_list_noin',1,'p_variable_declaration_list_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',918),
  ('variable_declaration_list_noin -> variable_declaration_list_noin COMMA variable_declaration_noin','variable_declaration_list_noin',3,'p_variable_declaration_list_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',919),
  ('variable_declaration -> identifier','variable_declaration',1,'p_variable_declaration','/home/alienoid/dev/python/slimit/src/slimit/parser.py',929),
  ('variable_declaration -> identifier initializer','variable_declaration',2,'p_variable_declaration','/home/alienoid/dev/python/slimit/src/slimit/parser.py',930),
  ('variable_declaration_noin -> identifier','variable_declaration_noin',1,'p_variable_declaration_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',938),
  ('variable_declaration_noin -> identifier initializer_noin','variable_declaration_noin',2,'p_variable_declaration_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',939),
  ('initializer -> EQ assignment_expr','initializer',2,'p_initializer','/home/alienoid/dev/python/slimit/src/slimit/parser.py',947),
  ('initializer_noin -> EQ assignment_expr_noin','initializer_noin',2,'p_initializer_noin','/home/alienoid/dev/python/slimit/src/slimit/parser.py',951),
  ('empty_statement -> SEMI','empty_statement',1,'p_empty_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',956),
  ('expr_statement -> expr_nobf SEMI','expr_statement',2,'p_expr_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',961),
  ('expr_statement -> expr_nobf auto_semi','expr_statement',2,'p_expr_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',962),
  ('if_statement -> IF LPAREN expr RPAREN statement','if_statement',5,'p_if_statement_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',968),
  ('if_statement -> IF LPAREN expr RPAREN statement ELSE statement','if_statement',7,'p_if_statement_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',972),
  ('iteration_statement -> DO statement WHILE LPAREN expr RPAREN SEMI','iteration_statement',7,'p_iteration_statement_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',978),
  ('iteration_statement -> DO statement WHILE LPAREN expr RPAREN auto_semi','iteration_statement',7,'p_iteration_statement_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',979),
  ('iteration_statement -> WHILE LPAREN expr RPAREN statement','iteration_statement',5,'p_iteration_statement_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',985),
  ('iteration_statement -> FOR LPAREN expr_noin_opt SEMI expr_opt SEMI expr_opt RPAREN statement','iteration_statement',9,'p_iteration_statement_3','/home/alienoid/dev/python/slimit/src/slimit/parser.py',990),
  ('iteration_statement -> FOR LPAREN VAR variable_declaration_list_noin SEMI expr_opt SEMI expr_opt RPAREN statement','iteration_statement',10,'p_iteration_statement_3','/home/alienoid/dev/python/slimit/src/slimit/parser.py',991),
  ('iteration_statement -> FOR LPAREN left_hand_side_expr IN expr RPAREN statement','iteration_statement',7,'p_iteration_statement_4','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1004),
  ('iteration_statement -> FOR LPAREN VAR identifier IN expr RPAREN statement','iteration_statement',8,'p_iteration_statement_5','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1011),
  ('iteration_statement -> FOR LPAREN VAR identifier initializer_noin IN expr RPAREN statement','iteration_statement',9,'p_iteration_statement_6','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1018),
  ('expr_opt -> empty','expr_opt',1,'p_expr_opt','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1025),
  ('expr_opt -> expr','expr_opt',1,'p_expr_opt','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1026),
  ('expr_noin_opt -> empty','expr_noin_opt',1,'p_expr_noin_opt','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1031),
  ('expr_noin_opt -> expr_noin','expr_noin_opt',1,'p_expr_noin_opt','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1032),
  ('continue_statement -> CONTINUE SEMI','continue_statement',2,'p_continue_statement_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1038),
  ('continue_statement -> CONTINUE auto_semi','continue_statement',2,'p_continue_statement_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1039),
  ('continue_statement -> CONTINUE identifier SEMI','continue_statement',3,'p_continue_statement_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1044),
  ('continue_statement -> CONTINUE identifier auto_semi','continue_statement',3,'p_continue_statement_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1045),
  ('break_statement -> BREAK SEMI','break_statement',2,'p_break_statement_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1051),
  ('break_statement -> BREAK auto_semi','break_statement',2,'p_break_statement_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1052),
  ('break_statement -> BREAK identifier SEMI','break_statement',3,'p_break_statement_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1057),
  ('break_statement -> BREAK identifier auto_semi','break_statement',3,'p_break_statement_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1058),
  ('return_statement -> RETURN SEMI','return_statement',2,'p_return_statement_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1065),
  ('return_statement -> RETURN auto_semi','return_statement',2,'p_return_statement_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1066),
  ('return_statement -> RETURN expr SEMI','return_statement',3,'p_return_statement_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1071),
  ('return_statement -> RETURN expr auto_semi','return_statement',3,'p_return_statement_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1072),
  ('with_statement -> WITH LPAREN expr RPAREN statement','with_statement',5,'p_with_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1078),
  ('switch_statement -> SWITCH LPAREN expr RPAREN case_block','switch_statement',5,'p_switch_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1083),
  ('case_block -> LBRACE case_clauses_opt RBRACE','case_block',3,'p_case_block','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1097),
  ('case_block -> LBRACE case_clauses_opt default_clause case_clauses_opt RBRACE','case_block',5,'p_case_block','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1098),
  ('case_clauses_opt -> empty','case_clauses_opt',1,'p_case_clauses_opt','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1104),
  ('case_clauses_opt -> case_clauses','case_clauses_opt',1,'p_case_clauses_opt','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1105),
  ('case_clauses -> case_clause','case_clauses',1,'p_case_clauses','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1110),
  ('case_clauses -> case_clauses case_clause','case_clauses',2,'p_case_clauses','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1111),
  ('case_clause -> CASE expr COLON source_elements','case_clause',4,'p_case_clause','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1120),
  ('default_clause -> DEFAULT COLON source_elements','default_clause',3,'p_default_clause','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1124),
  ('labelled_statement -> identifier COLON statement','labelled_statement',3,'p_labelled_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1129),
  ('throw_statement -> THROW expr SEMI','throw_statement',3,'p_throw_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1134),
  ('throw_statement -> THROW expr auto_semi','throw_statement',3,'p_throw_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1135),
  ('try_statement -> TRY block catch','try_statement',3,'p_try_statement_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1141),
  ('try_statement -> TRY block finally','try_statement',3,'p_try_statement_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1145),
  ('try_statement -> TRY block catch finally','try_statement',4,'p_try_statement_3','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1149),
  ('catch -> CATCH LPAREN identifier RPAREN block','catch',5,'p_catch','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1153),
  ('finally -> FINALLY block','finally',2,'p_finally','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1157),
  ('debugger_statement -> DEBUGGER SEMI','debugger_statement',2,'p_debugger_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1162),
  ('debugger_statement -> DEBUGGER auto_semi','debugger_statement',2,'p_debugger_statement','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1163),
  ('function_declaration -> FUNCTION identifier LPAREN RPAREN LBRACE function_body RBRACE','function_declaration',7,'p_function_declaration','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1170),
  ('function_declaration -> FUNCTION identifier LPAREN formal_parameter_list RPAREN LBRACE function_body RBRACE','function_declaration',8,'p_function_declaration','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1171),
  ('function_expr -> FUNCTION LPAREN RPAREN LBRACE function_body RBRACE','function_expr',6,'p_function_expr_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1184),
  ('function_expr -> FUNCTION LPAREN formal_parameter_list RPAREN LBRACE function_body RBRACE','function_expr',7,'p_function_expr_1','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1185),
  ('function_expr -> FUNCTION identifier LPAREN RPAREN LBRACE function_body RBRACE','function_expr',7,'p_function_expr_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1198),
  ('function_expr -> FUNCTION identifier LPAREN formal_parameter_list RPAREN LBRACE function_body RBRACE','function_expr',8,'p_function_expr_2','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1199),
  ('formal_parameter_list -> identifier','formal_parameter_list',1,'p_formal_parameter_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1212),
  ('formal_parameter_list -> formal_parameter_list COMMA identifier','formal_parameter_list',3,'p_formal_parameter_list','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1213),
  ('function_body -> source_elements','function_body',1,'p_function_body','/home/alienoid/dev/python/slimit/src/slimit/parser.py',1222),
]
python2/slimit/visitors/__init__.py	[[[1
1

python2/slimit/visitors/nodevisitor.py	[[[1
85
###############################################################################
#
# Copyright (c) 2011 Ruslan Spivak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

__author__ = 'Ruslan Spivak <ruslan.spivak@gmail.com>'


class ASTVisitor(object):
    """Base class for custom AST node visitors.

    Example:

    >>> from slimit.parser import Parser
    >>> from slimit.visitors.nodevisitor import ASTVisitor
    >>>
    >>> text = '''
    ... var x = {
    ...     "key1": "value1",
    ...     "key2": "value2"
    ... };
    ... '''
    >>>
    >>> class MyVisitor(ASTVisitor):
    ...     def visit_Object(self, node):
    ...         '''Visit object literal.'''
    ...         for prop in node:
    ...             left, right = prop.left, prop.right
    ...             print 'Property value: %s' % right.value
    ...             # visit all children in turn
    ...             self.visit(prop)
    ...
    >>>
    >>> parser = Parser()
    >>> tree = parser.parse(text)
    >>> visitor = MyVisitor()
    >>> visitor.visit(tree)
    Property value: "value1"
    Property value: "value2"

    """

    def visit(self, node):
        method = 'visit_%s' % node.__class__.__name__
        return getattr(self, method, self.generic_visit)(node)

    def generic_visit(self, node):
        for child in node:
            self.visit(child)


class NodeVisitor(object):
    """Simple node visitor."""

    def visit(self, node):
        """Returns a generator that walks all children recursively."""
        for child in node:
            yield child
            for subchild in self.visit(child):
                yield subchild


def visit(node):
    visitor = NodeVisitor()
    for child in visitor.visit(node):
        yield child
python2/slimit/visitors/scopevisitor.py	[[[1
199
###############################################################################
#
# Copyright (c) 2011 Ruslan Spivak
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
###############################################################################

__author__ = 'Ruslan Spivak <ruslan.spivak@gmail.com>'

from slimit import ast
from slimit.scope import VarSymbol, FuncSymbol, LocalScope, SymbolTable


class Visitor(object):
    def visit(self, node):
        method = 'visit_%s' % node.__class__.__name__
        return getattr(self, method, self.generic_visit)(node)

    def generic_visit(self, node):
        if node is None:
            return
        if isinstance(node, list):
            for child in node:
                self.visit(child)
        else:
            for child in node.children():
                self.visit(child)


class ScopeTreeVisitor(Visitor):
    """Builds scope tree."""

    def __init__(self, sym_table):
        self.sym_table = sym_table
        self.current_scope = sym_table.globals

    def visit_VarDecl(self, node):
        ident = node.identifier
        symbol = VarSymbol(name=ident.value)
        if symbol not in self.current_scope:
            self.current_scope.define(symbol)
        ident.scope = self.current_scope
        self.visit(node.initializer)

    def visit_Identifier(self, node):
        node.scope = self.current_scope

    def visit_FuncDecl(self, node):
        if node.identifier is not None:
            name = node.identifier.value
            self.visit_Identifier(node.identifier)
        else:
            name = None

        func_sym = FuncSymbol(
            name=name, enclosing_scope=self.current_scope)
        if name is not None:
            self.current_scope.define(func_sym)
            node.scope = self.current_scope

        # push function scope
        self.current_scope = func_sym
        for ident in node.parameters:
            self.current_scope.define(VarSymbol(ident.value))
            ident.scope = self.current_scope

        for element in node.elements:
            self.visit(element)

        # pop the function scope
        self.current_scope = self.current_scope.get_enclosing_scope()

    # alias
    visit_FuncExpr = visit_FuncDecl

    def visit_Catch(self, node):
        # The catch identifier actually lives in a new scope, but additional
        # variables defined in the catch statement belong to the outer scope.
        # For the sake of simplicity we just reuse any existing variables
        # from the outer scope if they exist.
        ident = node.identifier
        existing_symbol = self.current_scope.symbols.get(ident.value)
        if existing_symbol is None:
            self.current_scope.define(VarSymbol(ident.value))
        ident.scope = self.current_scope

        for element in node.elements:
            self.visit(element)

class RefVisitor(Visitor):
    """Fill 'ref' attribute in scopes."""

    def visit_Identifier(self, node):
        if self._is_id_in_expr(node):
            self._fill_scope_refs(node.value, node.scope)

    @staticmethod
    def _is_id_in_expr(node):
        """Return True if Identifier node is part of an expression."""
        return (
            getattr(node, 'scope', None) is not None and
            getattr(node, '_in_expression', False)
            )

    @staticmethod
    def _fill_scope_refs(name, scope):
        """Put referenced name in 'ref' dictionary of a scope.

        Walks up the scope tree and adds the name to 'ref' of every scope
        up in the tree until a scope that defines referenced name is reached.
        """
        symbol = scope.resolve(name)
        if symbol is None:
            return

        orig_scope = symbol.scope
        scope.refs[name] = orig_scope
        while scope is not orig_scope:
            scope = scope.get_enclosing_scope()
            scope.refs[name] = orig_scope


def mangle_scope_tree(root, toplevel):
    """Walk over a scope tree and mangle symbol names.

    Args:
        toplevel: Defines if global scope should be mangled or not.
    """
    def mangle(scope):
        # don't mangle global scope if not specified otherwise
        if scope.get_enclosing_scope() is None and not toplevel:
            return
        for name in scope.symbols:
            mangled_name = scope.get_next_mangled_name()
            scope.mangled[name] = mangled_name
            scope.rev_mangled[mangled_name] = name

    def visit(node):
        mangle(node)
        for child in node.children:
            visit(child)

    visit(root)


def fill_scope_references(tree):
    """Fill 'ref' scope attribute with values."""
    visitor = RefVisitor()
    visitor.visit(tree)


class NameManglerVisitor(Visitor):
    """Mangles names.

    Walks over a parsed tree and changes ID values to corresponding
    mangled names.
    """

    @staticmethod
    def _is_mangle_candidate(id_node):
        """Return True if Identifier node is a candidate for mangling.

        There are 5 cases when Identifier is a mangling candidate:
        1. Function declaration identifier
        2. Function expression identifier
        3. Function declaration/expression parameter
        4. Variable declaration identifier
        5. Identifier is a part of an expression (primary_expr_no_brace rule)
        """
        return getattr(id_node, '_mangle_candidate', False)

    def visit_Identifier(self, node):
        """Mangle names."""
        if not self._is_mangle_candidate(node):
            return
        name = node.value
        symbol = node.scope.resolve(node.value)
        if symbol is None:
            return
        mangled = symbol.scope.mangled.get(name)
        if mangled is not None:
            node.value = mangled
