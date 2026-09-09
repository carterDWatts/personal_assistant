"""Account lifecycle and explicit provider tools."""
from engine.integrations.accounts import connect, disconnect, status, CONNECTION_ACTIONS


def specs():
    from engine.integrations import github, supabase, todoist, notion
    return [*github.specs(), *supabase.specs(), *todoist.specs(), *notion.specs()]
