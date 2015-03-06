import sys

from slimit import ast
from slimit import mangler
from slimit import scope
from slimit import parser
from slimit.visitors import nodevisitor
from slimit.visitors import scopevisitor

p = parser.Parser()
tree = p.parse(open(sys.argv[1]).read())
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
  node.symbol = symbol
  symbol.nodes.append(node)

print

#mangler.mangle(tree, toplevel=True)

#print tree.to_ecma()

for node in visitor.visit(tree):
  if (not isinstance(node, ast.Identifier) or
      not getattr(node, '_mangle_candidate', False)):
    continue
  print node, node.symbol.nodes
