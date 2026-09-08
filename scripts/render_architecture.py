"""Render the README architecture and a fictional, traceable memory-update example."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs/assets'
OUT.mkdir(exist_ok=True)
BG, INK, MUTED = '#F3F1E9', '#24352B', '#667168'
GREEN, PALE, LINE, RED = '#48784C', '#E2EADA', '#B7C2B2', '#AD6553'
FONT = next(p for p in ('/System/Library/Fonts/Supplemental/Arial.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf') if Path(p).exists())
BOLD = next(p for p in ('/System/Library/Fonts/Supplemental/Arial Bold.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf') if Path(p).exists())

def font(size, bold=False):
    return ImageFont.truetype(BOLD if bold else FONT, size)

def canvas(height):
    im = Image.new('RGB', (1200, height), BG)
    return im, ImageDraw.Draw(im)

def text(d, xy, value, size=22, color=INK, bold=False):
    d.text(xy, value, font=font(size, bold), fill=color, spacing=8)

def box(d, rect, title, lines=(), fill='white', accent=GREEN):
    x,y,r,b=rect
    d.rounded_rectangle(rect, 15, fill=fill, outline=LINE, width=2)
    d.rounded_rectangle((x+16,y+20,x+21,y+43),2,fill=accent)
    size=23
    while d.textlength(title,font=font(size,True)) > r-x-52: size-=1
    text(d,(x+34,y+18),title,size,bold=True)
    for i,line in enumerate(lines): text(d,(x+22,y+61+31*i),line,19,MUTED)

def arrow(d, points, color=GREEN, width=3):
    d.line(points,fill=color,width=width)
    x,y=points[-1];px,py=points[-2]
    if abs(x-px)>abs(y-py):
        s=1 if x>px else -1;tri=[(x,y),(x-10*s,y-6),(x-10*s,y+6)]
    else:
        s=1 if y>py else -1;tri=[(x,y),(x-6,y-10*s),(x+6,y-10*s)]
    d.polygon(tri,fill=color)

im,d=canvas(1020)
text(d,(42,28),'BUNNY MAN',18,GREEN,True)
text(d,(42,58),'One memory system. Multiple model sessions.',34,bold=True)
text(d,(42,103),'Supabase Auth + command relay    /    Python runtimes    /    Pocket TTS streaming    /    APNs',16,MUTED)
for x,title,body in [(40,'iPhone',['Voice + text','Authenticated relay / replay']), (433,'Mac',['Voice + text','Local session engine']), (826,'Terminal',['Morning + conversation','Same tools and knowledge'])]:
    box(d,(x,128,x+334,256),title,body)
    arrow(d,[(x+167,256),(x+167,295)])
box(d,(40,296,1160,424),'SESSION ENGINE  ·  Railway host or Mac',[
    'Claude Agent SDK / Codex adapters     ·     persistent sessions     ·     streamed text and tool results',
    'Context preparation: current snapshot + recent conversation + changed sections + targeted retrieval'],PALE)
arrow(d,[(280,424),(280,475)])
arrow(d,[(260,475),(260,424)])
text(d,(303,436),'read current state / validated writes',17,GREEN)
box(d,(40,476,797,717),'SUPABASE / POSTGRES  ·  shared source of truth',[
    'Entities + aliases       Time-bounded facts       Typed relationships',
    'Standing rules           Plans + outcomes            Contextual reminders',
    'Source observations + conversations + immutable revisions',
    'Validity intervals / provenance / constraints / atomic corrections',
    'Current views exclude superseded, false and archived knowledge'],PALE)
box(d,(830,476,1160,717),'CONNECTED DATA',[
    'Calendar / Gmail / web',
    'Other service adapters',
    'Incremental sync cursors',
    'No model call on empty',
    'mail polls'])
arrow(d,[(830,598),(797,598)])
for x,title,body in [(40,'EXTRACTION',['Durable job per message','Small subscription model','Validated atomic fact batches']), (433,'NIGHTLY REVIEW',['Evidence-linked inferences','Conflicts → question queue','User clarification → correction']), (826,'PROACTIVE ATTENTION',['Reminders + emerging needs','Evidence + deduplication','Paced push notifications'])]:
    box(d,(x,780,x+334,954),title,body)
arrow(d,[(205,717),(205,780)])
arrow(d,[(225,780),(225,717)])
arrow(d,[(600,717),(600,780)])
arrow(d,[(620,780),(620,717)])
arrow(d,[(754,717),(754,752),(995,752),(995,780)])
text(d,(42,981),'Model judgment proposes meaning. Database rules enforce how knowledge changes.',19,MUTED)
im.save(OUT/'architecture.png',optimize=True)

scenes=[
 ('01  CAPTURE','A conversation becomes structured knowledge.',
  'MAC / USER', '“The project review is Friday.”',
  [('OBSERVATION  o104',['Source: user message m88','Recorded: Sep 8, 08:20','Original words retained']),
   ('ASSERTION  r17',['Entity: project review','Attribute: scheduled_date','Value: Sep 11  ·  current']),
   ('WRITE CONTRACT',['Registered single-value field','Observation linked to fact','Committed in one transaction'])],
  'The transcript is evidence. The assertion is the queryable state.'),
 ('02  DERIVE','New relationships carry their supporting evidence.',
  'NIGHTLY REVIEW', 'Review date + preparation time → a proposed preparation plan.',
  [('CURRENT EVIDENCE',['r17: review is Friday','r09: preparation takes 2 hours','Both sources still current']),
   ('INFERRED KNOWLEDGE',['Candidate: prepare Thursday','Supports: r17 + r09','Level: inferred, not confirmed']),
   ('TRUTH BOUNDARY',['Cannot replace stated facts','Evidence required for inference','User questions stay separate'])],
  'An inference has a lineage. It is not silently promoted to a user instruction.'),
 ('03  REVISE','A change updates state and invalidates its consequences.',
  'IPHONE / USER', '“The review moved to Monday.”',
  [('NEW OBSERVATION  o105',['Source: user message m92','New assertion r18: Sep 14','Recorded: Sep 8, 08:23']),
   ('ATOMIC TRANSITION',['r17: validity interval closed','r18: current value is Monday','Old Friday value stays in history']),
   ('DEPENDENCY INVALIDATION',['r17 changed → check dependents','Thursday preparation inference','Invalidated by database trigger'])],
  'A changed fact closes history. A fact that was never true is deprecated instead.'),
 ('04  RESUME','A fresh model session picks up the same life.',
  'NEW CLAUDE / CODEX SESSION', '“When is the review?”',
  [('CURRENT VIEW',['scheduled_date = Sep 14','Friday excluded from current','Historical queries still available']),
   ('CONTEXT PREPARATION',['Relevant facts + standing rules','Recent conversation continuity','On-demand entity/history tools']),
   ('ASSISTANT REPLY',['“Monday. It moved from Friday.”','Current answer from shared map','History explains the transition'])],
  'Continuity belongs to the system, not the lifetime of one model process.'),
 ('05  RECONCILE','Uncertainty becomes an explicit question to resolve.',
  'REVIEW → USER CLARIFICATION', '“The trip was cancelled. Keep Monday’s review.”',
  [('CONFLICT DETECTED',['Travel and review overlap','Evidence attached to question','No guessed resolution']),
   ('AUTHORITATIVE CORRECTION',['User statement is the source','Close the affected trip state','Record why it stopped being true']),
   ('ONE TRANSACTION',['Update affected knowledge','Preserve transition + evidence','Close the clarification question'])],
  'The next session sees the correction. The reason remains auditable.'),
]
frames=[];durations=[]
for index,(step,title,source,quote,cards,foot) in enumerate(scenes):
    im,d=canvas(650)
    text(d,(38,26),'MEMORY IN MOTION',17,GREEN,True)
    text(d,(960,26),step,17,GREEN,True)
    text(d,(38,66),title,29,bold=True)
    d.rounded_rectangle((38,121,1162,217),12,fill=PALE)
    text(d,(57,136),source,16,GREEN,True)
    text(d,(57,168),quote,22)
    for i,(heading,lines) in enumerate(cards):
        x=38+i*390
        box(d,(x,266,x+343,453),heading,lines,accent=RED if index==2 and i==2 else GREEN)
        if i<2:arrow(d,[(x+346,356),(x+383,356)])
    text(d,(38,494),foot,21,MUTED)
    text(d,(38,532),'Illustrative records · implemented write, provenance and correction paths',16,MUTED)
    for i in range(5):
        x=38+i*228
        d.rounded_rectangle((x,602,x+210,608),3,fill=GREEN if i<=index else LINE)
    for tick in range(8):
        frame=im.copy(); motion=ImageDraw.Draw(frame)
        for edge in (384,774):
            x=edge+int(tick/7*36)
            motion.ellipse((x-4,352,x+4,360),fill=GREEN)
        frames.append(frame);durations.append(350 if tick<7 else 2750)
frames[0].save(OUT/'memory.gif',save_all=True,append_images=frames[1:],duration=durations,loop=0,optimize=True)
