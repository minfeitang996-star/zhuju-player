import sys, os
from tree_sitter import Language, Parser
import tree_sitter_swift as tss

lang = Language(tss.language())
parser = Parser(lang)

root = sys.argv[1]
problems = 0
for dirpath, _, files in os.walk(root):
    for f in files:
        if not f.endswith(".swift"):
            continue
        path = os.path.join(dirpath, f)
        src = open(path, encoding="utf-8").read()
        tree = parser.parse(src.encode("utf-8"))
        stack = [tree.root_node]
        bad = []
        while stack:
            n = stack.pop()
            if n.type == "ERROR" or n.is_missing:
                bad.append(n)
            stack.extend(n.children)
        if bad:
            problems += len(bad)
            print("== " + os.path.relpath(path, root))
            for n in bad[:6]:
                line = src[:n.start_byte].count("\n") + 1
                ctx_start = max(0, n.start_byte - 60)
                ctx_end = min(len(src), n.end_byte + 60)
                ctx = src[ctx_start:ctx_end].replace("\r", "").replace("\n", "\\n")
                print("  line %d  bytes %d-%d  type=%s parent=%s" % (
                    line, n.start_byte, n.end_byte, n.type, n.parent.type if n.parent else "-"))
                print("     ctx: ...%s..." % ctx)
        else:
            print("ok " + os.path.relpath(path, root))
print("total problems:", problems)
