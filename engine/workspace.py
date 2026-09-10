"""Editable source copies. No shell, credentials, symlinks or live-service writes."""
import difflib
import asyncio
import base64
from pathlib import Path
from engine.tools import ToolSpec, ToolError, _obj, _s

ROOT = Path(__file__).resolve().parents[1]
ALLOWED = ('engine','prompts','supabase','tst','docs','ios','desktop','scripts','shared')
ROOT_FILES={'Dockerfile','requirements-host.txt','requirements.txt','identity.json'}
EXTENSIONS = {'.py','.sql','.md','.txt','.json','.toml','.yaml','.yml','.swift','.ts','.sh'}

class Workspace:
    def __init__(self, root=ROOT):
        self.remote = None
        self.base_sha = None
        self.original = {}
        for directory in ALLOWED:
            for path in (root/directory).rglob('*'):
                if path.is_symlink() or not path.is_file() or path.suffix not in EXTENSIONS: continue
                if any(p.startswith('.') or p=='__pycache__' for p in path.relative_to(root).parts): continue
                if path.stat().st_size > 200000: continue
                if not path.resolve().is_relative_to(root.resolve()): continue
                self.original[path.relative_to(root).as_posix()] = path.read_text()
        for name in ROOT_FILES:
            path=root/name
            if path.is_file() and not path.is_symlink():self.original[name]=path.read_text()
        self.files = dict(self.original)

    async def checkout(self, development, saved=None):
        self.remote = development
        self.base_sha = (await development.status({}))['base_sha']
        if saved and saved.get('base_sha') != self.base_sha:
            raise ToolError('Main changed since this draft. Rebase the saved patch before publishing.')
        self.original = dict((saved or {}).get('original', {}))
        self.files = dict((saved or {}).get('files', {}))
        tree=await asyncio.to_thread(development.github,'git/trees/'+self.base_sha+'?recursive=1')
        if tree.get('truncated'):raise ToolError('Repository listing is incomplete.')
        self.tracked={item['path'] for item in tree['tree'] if item['type']=='blob'}

    def checkpoint(self):
        return {'base_sha':self.base_sha, 'original':self.original, 'files':self.files}

    def path(self, value):
        if value in ROOT_FILES:return value
        p = Path(value)
        if p.is_absolute() or '..' in p.parts or not p.parts or p.parts[0] not in ALLOWED or p.suffix not in EXTENSIONS or any(v.startswith('.') for v in p.parts):
            raise ToolError('Use a supported source file inside the assistant repository.')
        return p.as_posix()

    async def read(self, args):
        if not args.get('path'):
            if self.remote:
                tree=await asyncio.to_thread(self.remote.github,'git/trees/'+self.base_sha+'?recursive=1')
                files=[]
                for item in tree.get('tree',[]):
                    if item['type']!='blob':continue
                    try: files.append(self.path(item['path']))
                    except ToolError: pass
                return {'files':files,'base_sha':self.base_sha,'truncated':tree.get('truncated',False)}
            return {'files':sorted(self.files)}
        name = self.path(args['path'])
        if self.remote and name not in self.files:
            data=await asyncio.to_thread(self.remote.github,'contents/'+name+'?ref='+self.base_sha)
            if data.get('encoding')!='base64':raise ToolError('Source is not an editable text file.')
            content=base64.b64decode(data['content']).decode()
            if len(content)>200000:raise ToolError('Source file exceeds the editing limit.')
            self.original[name]=self.files[name]=content
        if name not in self.files: raise ToolError('File not found.')
        offset = args.get('offset',0)
        return {'path':name, 'text':self.files[name][offset:offset+20000], 'length':len(self.files[name]),
                'next_offset':offset+20000 if offset+20000<len(self.files[name]) else None,'base_sha':self.base_sha}

    async def edit(self,args):
        name=self.path(args['path'])
        if name not in self.files:await self.read({'path':name})
        old=args['old_text']
        if not old or self.files[name].count(old)!=1:
            raise ToolError('The old text must match exactly once. Read the relevant source and retry.')
        return await self.write({'path':name,'content':self.files[name].replace(old,args['new_text'],1)})

    async def write(self, args):
        name = self.path(args['path'])
        if self.remote and name in self.tracked and name not in self.original:
            await self.read({'path':name})
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
        return [ToolSpec('workspace_read','Read source at the pinned repository revision or list its files. Follow next_offset for more text; workspace_edit preserves the complete file.',
                _obj({'path':_s('source path'),'offset':_i('character offset',minimum=0)},[]), self.read),
                ToolSpec('workspace_edit','Replace one exact source snippet in the draft. The server preserves the rest of the full file, even when the read response was paginated.',
                _obj({'path':_s('source path'),'old_text':_s('unique exact text',minLength=1),'new_text':_s('replacement text')},['path','old_text','new_text']),self.edit),
                ToolSpec('workspace_write','Save a complete source file in this isolated draft. Does not deploy or execute it.',
                _obj({'path':_s('source path'),'content':_s('complete file',maxLength=200000)},['path','content']),self.write)]
