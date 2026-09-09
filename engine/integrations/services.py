"""Account lifecycle and explicit provider tools."""
from engine.integrations.accounts import connect, disconnect, status, CONNECTION_ACTIONS


def specs(spotify_control=None):
    from engine.integrations import github, supabase, todoist, notion, spotify
    return [*github.specs(), *supabase.specs(), *todoist.specs(), *notion.specs(), *spotify.specs(spotify_control)]
