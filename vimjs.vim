" Copyright 2015 Deomid 'rojer' Ryabkov
"
" Licensed under Apache License, Version 2.0.
" See the accompanying LICENSE file.

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
import sys
sys.path.append('/home/rojer/vimjs/slimit/src')

from slimit import ast
from slimit import scope
from slimit import parser
from slimit.visitors import nodevisitor
from slimit.visitors import scopevisitor

import vim

# buffer name -> State
buffer_state = {}
enabled = True

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
    print 'bad syntax:', str(e), dir(e)
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

print 'VimJS loaded'

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
