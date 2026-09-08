"""Editable source copies. No shell, credentials, symlinks or live-service writes."""
import difflib
from pathlib import Path
from engine.tools import ToolSpec, ToolError, _obj, _s

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = ('engine','prompts','supabase','tst','docs')
EXTENSIONS = {'.py','.sql','.md','.txt','.json','.toml','.yaml','.yml'}

class Workspace:
    def __init__(self, root=ROOT):
        self.original = {}
        for directory in ALLOWED:
            for path in (root/directory).rglob('*'):
                if path.is_symlink() or not path.is_file() or path.suffix not in EXTENSIONS: continue
                if any(p.startswith('.') or p=='__pycache__' for p in path.relative_to(root).parts): continue
                if path.stat().st_size > 200000: continue
                if not path.resolve().is_relative_to(root.resolve()): continue
                self.original[path.relative_to(root).as_posix()] = path.read_text()
        self.files = dict(self.original)

    def path(self, value):
        p = Path(value)
        if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0] not in ALLOWED or p.suffix not in EXTENSIONS or any(v.startswith('.') for v in p.parts):
            raise ToolError('Use a source file inside engine, prompts, supabase, tst or docs.')
        return p.as_posix()

    async def read(self, args):
        if not args.get('path'):
            return {'files':sorted(self.files)}
        name = self.path(args['path'])
        if name not in self.files: raise ToolError('File not found.')
        offset = args.get('offset',0)
        return {'path':name, 'text':self.files[name][offset:offset+20000], 'length':len(self.files[name])}

    async def write(self, args):
        name = self.path(args['path'])
        self.files[name] = args['content']
        if len(self.patch()) > 300000:
            if name in self.original: self.files[name] = self.original[name]
            else: del self.files[name]
            raise ToolError('Patch is too large. Keep this job focused.')
        return {'saved_in_draft':True, 'path':name, 'deployed':False}

    def patch(self):
        return ''.join(''.join(difflib.unified_diff(self.original.get(p,'').splitlines(True), self.files[p].splitlines(True),
                       fromfile='a/'+p if p in self.original else '/dev/null', tofile='b/'+p))
                       for p in sorted(self.files) if self.original.get(p) != self.files[p])

    def specs(self):
        from engine.tools import _i
        return [ToolSpec('workspace_read','Read the deployed assistant source snapshot or list its files.',
                _obj({'path':_s('source path'),'offset':_i('character offset',minimum=0)},[]), self.read),
                ToolSpec('workspace_write','Save a complete source file in this isolated draft. Does not deploy or execute it.',
                _obj({'path':_s('source path'),'content':_s('complete file',maxLength=200000)},['path','content']),self.write)]
