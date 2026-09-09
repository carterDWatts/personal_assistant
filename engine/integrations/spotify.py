"""Find Spotify content and control the user's player, never stream audio here."""
import asyncio
import re
import time

from engine.integrations.accounts import _request
from engine.integrations.results import snapshot, tool
from engine.tools import ToolError, ToolSpec

URI = r'^spotify:(track|episode|album|playlist):[A-Za-z0-9]{22}$'
ACTIONS = ['play', 'pause', 'resume', 'next', 'previous', 'seek', 'state']


def request(path, **kwargs):
    return _request('spotify', path, **kwargs)


def item(value):
    return {k: value[k] for k in ('id', 'name', 'uri', 'type', 'release_date', 'duration_ms', 'is_playable') if k in value} | {
        'by': ', '.join(a['name'] for a in value.get('artists', [])) or value.get('publisher') or value.get('show', {}).get('name'),
        'description': value.get('description', '')[:500]}


def search(args):
    data = request('search', params={'q': args['query'], 'type': args['type'], 'limit': 5})
    return snapshot(items=[item(v) for v in data.get(args['type'] + 's', {}).get('items', []) if v])


def episodes(args):
    data = request('shows/' + args['show_id'] + '/episodes', params={'limit': 10, 'offset': args.get('offset', 0)})
    return snapshot(items=[item(v) for v in data.get('items', []) if v],
                    next_offset=args.get('offset', 0) + 10 if data.get('next') else None)


def playback(args):
    action, device = args['action'], args.get('device_id')
    if action == 'state':
        data = request('me/player', params={'additional_types': 'track,episode'}) or {}
        return snapshot(is_playing=data.get('is_playing', False), item=item(data.get('item') or {}),
                        device=data.get('device'), position_ms=data.get('progress_ms'), context_uri=(data.get('context') or {}).get('uri'))
    if not device:
        raise ToolError('No local Spotify controller is available. List Spotify devices and choose the intended device first.')
    params = {'device_id': device}
    before = playback({'action': 'state'}) if action in ('next', 'previous') else None
    if action == 'play':
        uri = args['uri']
        body = {'uris': [uri]} if uri.split(':')[1] in ('track', 'episode') else {'context_uri': uri}
        request('me/player/play', method='PUT', params=params, body=body)
    elif action == 'seek':
        request('me/player/seek', method='PUT', params={**params, 'position_ms': args['position_ms']})
    else:
        request('me/player/' + {'resume': 'play'}.get(action, action),
                method='POST' if action in ('next', 'previous') else 'PUT', params=params)
    # A 204 means accepted. It is not evidence that sound started on the requested device.
    state = playback({'action': 'state'})
    expected = action != 'pause'
    observed = state.get('device') or {}
    verified = observed.get('id') == device and state['is_playing'] == expected
    if action == 'play' and args['uri'].split(':')[1] in ('track', 'episode'):
        verified = verified and state['item'].get('uri') == args['uri']
    elif action == 'play':
        verified = verified and state['context_uri'] == args['uri']
    elif action == 'seek':
        verified = observed.get('id') == device and abs((state['position_ms'] or 0) - args['position_ms']) < 2000
    elif before is not None:
        verified = verified and state['item'].get('uri') != before['item'].get('uri')
    return {**state, 'accepted': True, 'verified': verified}


def specs(local_control=None):
    async def control(args):
        action = args['action']
        if action == 'play' and not re.fullmatch(URI, args.get('uri', '')):
            raise ToolError('Play needs a track, episode, album or playlist URI returned by Spotify search.')
        if action == 'seek' and 'position_ms' not in args:
            raise ToolError('Seeking needs a position in milliseconds.')
        if local_control and not args.get('device_id'):
            # Check the shared account first so the normal connection card appears in chat.
            await asyncio.to_thread(request, 'me')
            return await local_control(args)
        return await asyncio.to_thread(playback, args)
    return [
        tool('spotify_search', 'Find music or podcasts in Spotify. Use show for podcasts, episode for a specific episode. Resolve the requested content before playing; ask if the match is ambiguous.', search,
             {'query': {'type': 'string', 'minLength': 1, 'maxLength': 300}, 'type': {'enum': ['track', 'album', 'playlist', 'show', 'episode']}}, ['query', 'type']),
        tool('spotify_episodes', 'Read podcast episodes and release dates from a Spotify show. Use the episode URI to play a particular episode. Follow next_offset for older episodes.', episodes,
             {'show_id': {'type': 'string', 'pattern': '^[A-Za-z0-9]{22}$'}, 'offset': {'type': 'integer', 'minimum': 0, 'maximum': 10000}}, ['show_id']),
        tool('spotify_devices', 'List Spotify Connect players when the user wants playback on a different device. Local playback defaults to the phone or Mac they are using.',
             lambda _: snapshot(devices=request('me/player/devices').get('devices', [])), {}),
        ToolSpec('spotify_control', 'Control playback in the Spotify app when requested. Defaults to the current phone or Mac; device_id explicitly targets another Spotify Connect player. Acknowledged is not necessarily playing: report success only if verified is true, otherwise describe the actual state. Never retry next/previous after an uncertain result.',
                 {'type': 'object', 'properties': {'action': {'enum': ACTIONS}, 'uri': {'type': 'string', 'pattern': URI},
                  'position_ms': {'type': 'integer', 'minimum': 0, 'maximum': 86400000},
                  'device_id': {'type': 'string', 'minLength': 1, 'maxLength': 200}},
                  'required': ['action'], 'additionalProperties': False}, control)]


async def phone_control(host, args):
    from engine.db import jsonb
    from uuid import uuid4
    command = uuid4()
    def submit():
        with host.relay.map.conn.transaction():
            host.relay.owner_lock()
            host.relay.check()
            row = host.relay.map.row("insert into assistant.spotify_commands(id,user_id,device_id,turn_id,command)"
                " select %s,user_id,device_id,id,%s from assistant.turns where id=%s and worker_id=%s"
                " and status='running' and not cancel_requested returning user_id,device_id",
                (command, jsonb(args), host.active, host.relay.worker_id))
            if not row:
                raise ToolError('This playback request is no longer active.')
            host.relay.emit(row['user_id'], host.active, {'type': 'spotify_command', 'command_id': str(command), 'device_id': str(row['device_id'])})
    await host.call(submit)
    deadline = time.monotonic() + 100
    try:
        while time.monotonic() < deadline:
            result = await host.call(host.relay.map.value, 'select result from assistant.spotify_commands where id=%s', (command,))
            if result is not None:
                if result.get('error'):
                    raise ToolError(result['error'])
                return result
            await asyncio.sleep(.2)
        raise ToolError('The phone did not confirm Spotify playback. Check Spotify before trying again.')
    finally:
        await host.call(host.relay.map.execute, 'update assistant.spotify_commands set expires_at=least(expires_at,clock_timestamp()) where id=%s', (command,))
