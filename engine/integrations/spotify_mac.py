"""Spotify's installed AppleScript interface. Arguments never become executable code."""
import asyncio
import json
from engine.tools import ToolError

SCRIPT = """function run(args) {
    const app = Application('Spotify');
    if (!app.running() && !['play','resume'].includes(args[0])) return JSON.stringify(['stopped','','','0','']);
    let before = '';
    if (['next','previous'].includes(args[0])) { try { before = app.currentTrack().id(); } catch (_) {} }
    switch (args[0]) {
    case 'play': app.playTrack(args[1]); break;
    case 'resume': app.play(); break;
    case 'pause': app.pause(); break;
    case 'next': app.nextTrack(); break;
    case 'previous': app.previousTrack(); break;
    case 'seek': app.playerPosition = Number(args[1]); break;
    }
    const state = app.playerState();
    let uri = '', title = '', position = '0';
    try { uri = app.currentTrack().id(); title = app.currentTrack().name(); position = String(app.playerPosition()); } catch (_) {}
    return JSON.stringify([state, uri, title, position, before]);
}"""


async def control(args):
    from pathlib import Path
    if not (Path('/Applications/Spotify.app').exists() or (Path.home() / 'Applications/Spotify.app').exists()):
        raise ToolError('Install Spotify on this Mac and sign in first.')
    value = str(args.get('position_ms', 0) / 1000) if args['action'] == 'seek' else args.get('uri', '')
    process = await asyncio.create_subprocess_exec('/usr/bin/osascript', '-l', 'JavaScript', '-e', SCRIPT, args['action'], value,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, _ = await asyncio.wait_for(process.communicate(), 15)
    except TimeoutError:
        if process.returncode is None: process.kill()
        await process.wait()
        raise ToolError('Spotify did not respond. Allow Automation access for this app in System Settings, then retry.') from None
    except BaseException:
        if process.returncode is None: process.kill()
        await process.wait()
        raise
    if process.returncode:
        raise ToolError('Spotify could not accept the command. Check that it is signed in and allow Automation access in System Settings.')
    state, uri, title, position, before = json.loads(out)
    verified = (state == 'playing') if args['action'] != 'pause' else state != 'playing'
    if args['action'] == 'play' and args['uri'].split(':')[1] in ('track', 'episode'):
        verified = verified and uri == args['uri']
    elif args['action'] == 'play':
        verified = False  # Spotify's scripting interface does not expose the context URI.
    elif args['action'] == 'seek':
        verified = abs(float(position) * 1000 - args['position_ms']) < 2000
    elif args['action'] in ('next', 'previous'):
        verified = verified and uri != before
    elif args['action'] == 'state':
        verified = True
    return {'accepted': True, 'verified': verified, 'is_playing': state == 'playing', 'uri': uri, 'title': title, 'position_ms': round(float(position) * 1000)}
