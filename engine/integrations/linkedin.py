"""Read only the LinkedIn material the installation can actually access."""
import asyncio
from urllib.parse import urlsplit
from engine.tools import ToolError, ToolSpec, _obj, _s
from engine.integrations import google, web

LIMITS={
    'available':['public pages that LinkedIn serves without sign-in','LinkedIn notification emails in connected Gmail','user-shared text and screenshots'],
    'unavailable':['live personal feed','private LinkedIn inbox','saved posts behind sign-in'],
    'reason':'Standard LinkedIn OAuth grants identity, not feed or inbox access. Member portability is limited to EU/EEA and Switzerland.',
    'sources':['https://learn.microsoft.com/en-us/linkedin/shared/authentication/getting-access','https://www.linkedin.com/help/linkedin/answer/a6214075'],
    'next_step':'Read a public LinkedIn URL, search notification emails, or ask the user to share/export the missing material. Do not offer an identity-only sign-in as if it enabled their feed or inbox.'}


async def read(args):
    host=(urlsplit(args['url']).hostname or '').lower()
    if host!='linkedin.com' and not host.endswith('.linkedin.com'):raise ToolError('Use a LinkedIn URL.')
    result=await web.read(args)
    return {**result,'access':'public_only','limitations':LIMITS}


async def notifications(args):
    query='{from:linkedin.com from:linkedinmail.com} ('+args.get('query','newer_than:7d')+')'
    result=await google.mail_search({'query':query})
    return {**result,'access':'email_excerpts_only','notice':'These are email notifications, not direct access to LinkedIn conversations. Read full emails for their available content. A missing email does not mean there is no LinkedIn message.'}


def specs():
    return [ToolSpec('linkedin_read','Read a public LinkedIn profile, company, post, or job URL. Cannot read signed-in feeds or inboxes. Never claim that a blocked page was read.',_obj({'url':_s('LinkedIn URL',maxLength=4096),'offset':{'type':'integer','minimum':0,'maximum':2000000}},['url']),read),
            ToolSpec('linkedin_notifications','Find LinkedIn notification emails in connected Gmail. This can reveal recruiting messages and job alerts that were emailed; it is not a complete LinkedIn inbox.',_obj({'query':_s('Gmail search within LinkedIn notifications',maxLength=400)},[]),notifications)]
