"""Render the README's mechanical memory model. Requires Pillow and ffmpeg."""
from pathlib import Path
import math
import subprocess
from PIL import Image, ImageDraw, ImageFont, ImageColor

OUT = Path(__file__).resolve().parents[1] / 'docs/assets'
OUT.mkdir(exist_ok=True)
W, H, FPS, SECONDS = 1100, 740, 50, 28
BG, INK, MUTED = '#F2F0E8', '#283C35', '#738178'
GREEN, GOLD, CORAL = '#6A946E', '#E1B76D', '#C68570'
FONT = next(p for p in ['/System/Library/Fonts/Supplemental/Arial.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'] if Path(p).exists())
BOLD = next(p for p in ['/System/Library/Fonts/Supplemental/Arial Bold.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf'] if Path(p).exists())

def shade(c, f):
    return tuple(min(255, int(v*f)) for v in ImageColor.getrgb(c))

def ease(t):
    t = max(0, min(1, t))
    return t*t*(3-2*t)

def lerp(a,b,t):
    return tuple(x+(y-x)*t for x,y in zip(a,b))

def frame(t):
    t = t * 22 / SECONDS
    im = Image.new('RGB', (W,H), BG)
    d = ImageDraw.Draw(im)
    def text(x,y,s,size=15,color=INK,bold=False,anchor=None):
        d.text((x,y),s,font=ImageFont.truetype(BOLD if bold else FONT,size),fill=color,anchor=anchor)
    def cube(x,y,w=38,depth=26,h=25,c=GREEN):
        # A solid object with three independently lit faces.
        a=(x,y-h); b=(x+w,y+w*.35-h); cc=(x+w-depth,y+(w+depth)*.35-h); e=(x-depth,y+depth*.35-h)
        d.polygon([e,cc,(cc[0],cc[1]+h),(e[0],e[1]+h)],fill=shade(c,.77))
        d.polygon([b,cc,(cc[0],cc[1]+h),(b[0],b[1]+h)],fill=shade(c,.59))
        d.polygon([a,b,cc,e],fill=c)
        d.line([a,b,cc,e,a],fill=shade(c,1.08),width=1)
    def ticket(x,y,c='#FFFCF4',w=38):
        cube(x,y,w,19,4,c)
        for k in range(3): d.line([(x+4-k*3,y-1+k*3),(x+21-k*3,y+5+k*3)],fill='#A8B1A6',width=1)
    def plaque(x,y,label):
        text(x,y,label,12,MUTED,True,anchor='mm')
    def point(i):
        x,y=nodes[i]
        return (x+7,y-21)
    text(48,35,'BUNNY MAN  /  MEMORY IN MOTION',13,GREEN,True)
    text(48,66,'Living knowledge. Connected across sessions.',32,INK,True)
    text(1050,45,'ILLUSTRATIVE RECORDS',12,MUTED,anchor='ra')
    text(48,111,'Live conversation + connected apps → current facts, relationships and learned rules',16,MUTED)
    # Ground plane and a solid map table.
    d.ellipse((270,342,860,491),fill='#E4E5DA')
    for x in [395,680]: cube(x,457,15,15,74,'#C5CBBE')
    cube(523,320,300,235,15,'#D6DDCB')
    # Recessed tiles make the map a place objects occupy, not a text diagram.
    for a in range(7):
        for b in range(5):
            cube(525+a*39-b*40,322+a*13.65+b*14,30,30,16,'#DBE2D2')
    nodes=[(525,320),(610,350),(440,350),(525,382),(690,379),(610,411),(445,407)]
    # Evidence conveyor and its retained paper spool.
    cube(135,347,150,32,13,'#C4CABF')
    for i in range(7):
        x=138+i*20
        d.line([(x,334),(x-26,344)],fill='#A3AE9D',width=2)
    for i in range(6): ticket(94+i*1.5,327-i*4)
    plaque(145,403,'LIVE INPUT')
    # Distinct objects feed the same write path throughout the conversation.
    cube(88,249,36,20,43,'#637C74')
    d.rounded_rectangle((89,208,110,230),3,fill='#DBE7CD')
    text(70,270,'Chat',12,MUTED)
    cube(157,249,36,20,6,'#F0DEC2')
    d.line([(153,239),(165,251),(189,251)],fill='#9F8E70',width=2)
    text(145,270,'Email',12,MUTED)
    cube(218,249,36,20,9,'#CBD8BF')
    for a in range(3):
        for b in range(2): d.rectangle((218+a*7-b*4,239+a*2+b*4,221+a*7-b*4,241+a*2+b*4),fill=GREEN)
    text(208,270,'Calendar',12,MUTED)
    # Validation arch: packets must fit through it.
    cube(292,340,12,23,71,INK)
    cube(330,353,12,23,71,INK)
    cube(292,281,50,23,13,GREEN)
    plaque(313,207,'TYPED WRITES')
    text(313,225,'Extract · resolve · validate',12,MUTED,anchor='mm')
    d.ellipse((298,272,304,278),fill=GOLD)
    # A separate evidence rail runs underneath the map.
    cube(324,487,203,65,18,'#BCC6B5')
    for i in range(8): ticket(329+i*21,477+i*7.35,w=17)
    plaque(393,554,'EVIDENCE + FULL CONVERSATIONS')
    text(393,572,'Every fact can point back to its source.',12,MUTED,anchor='mm')
    # Current relationships, including an inferred one that loses its support.
    edges=[(0,1),(0,2),(1,3),(2,3),(1,4),(3,5),(3,6)]
    # Raised cables remain visible above the table, with packets moving along them.
    def cable(a,b,color,start,dashed=False):
        if t<start:return
        u=ease((t-start)/.8)
        points=[]
        for j in range(41):
            f=j/40*u
            x,y=lerp(a,b,f)
            points.append((x,y-26*math.sin(math.pi*f)))
        if dashed:
            for j in range(0,len(points)-2,4):d.line(points[j:j+3],fill=color,width=4)
        else:
            d.line(points,fill=shade(color,.65),width=6)
            d.line([(x,y-1) for x,y in points],fill=color,width=3)
        if u==1:
            f=((t-start)*.35)%1
            x,y=lerp(a,b,f);y-=26*math.sin(math.pi*f)
            d.ellipse((x-3,y-3,x+3,y+3),fill='#F7E5A8')
    for n,(a,b) in enumerate(edges):
        if (a,b)==(1,4) and t>=11.7:continue
        cable(point(a),point(b),'#527D67',3.4+n*.18)
    if 6<t<11.7:
        cable(point(4),point(5),GOLD,6,True)
    # Facts arrive as blocks. Their source pins remain visible.
    for i,(x,y) in enumerate(nodes):
        born=3+i*.22
        if t<born: continue
        if i==4 and t>=11.7: continue
        rise=ease((t-born)/.6)
        color=GOLD if i==4 else GREEN
        if i==1 and t>=10:
            color=CORAL if t<12 else '#8AAA87'
        cube(x,y,35,25,28*rise,color)
        d.ellipse((x+5,y-24,x+11,y-18),fill='#F0F0DC')
    plaque(590,181,'SHARED KNOWLEDGE MAP · POSTGRES')
    text(590,200,'Entities + attributes + typed relationships',13,MUTED,anchor='mm')
    if t>=4.7:
        labels=[('You',525,264),('Home: Seattle' if t<10 else 'Home: Tacoma',633,299),('Alex',412,305),('Project',523,341),('Nearby?',721,328),('Office',638,375),('Morning rule',428,371)]
        for i,(label,x,y) in enumerate(labels):
            if i==4 and t>=11.7:continue
            text(x,y,label,12,INK,True,anchor='mm')
    if 5<t<10:
        text(559,316,'lives at',11,INK,anchor='mm')
        text(475,332,'works on',11,INK,anchor='mm')
    if 6<t<11.7:
        text(740,397,'inferred',12,'#997534',True,anchor='mm')
    # A new observation comes down the belt, once for learning and once for revision.
    for begin in [0.2,3,6,9,12.5,16,19]:
        u=(t-begin)/2.4
        if 0<u<1:
            source=[(110,235),(170,242),(230,242)][int(begin)%3]
            if u<.35: x,y=lerp(source,(150,328),ease(u/.35))
            else: x,y=lerp((150,328),(520,298),ease((u-.35)/.65))
            ticket(x,y,c='#F9E7C9' if begin==9 else '#FFFCF4')
    # Superseded state physically moves into a lower archive; it is not erased.
    cube(637,496,134,64,17,'#B2BEAD')
    for i in range(3): cube(646+i*32,488+i*11,23,23,12,'#C5CCBE')
    plaque(715,565,'SUPERSEDED / INVALIDATED')
    text(715,583,'Valid time + recorded time retained',12,MUTED,anchor='mm')
    if t>=10:
        u=ease((t-10)/2)
        x,y=lerp(nodes[1],(743,521),u)
        cube(x,y,30,23,24,CORAL)
    if t>=11.7:
        x,y=lerp(nodes[4],(709,511),ease((t-11.7)/2))
        cube(x,y,25,23,20,GOLD)
    # A fresh process replaces the previous plug-in unit; the table persists.
    base=(925,350)
    cube(*base,86,57,17,'#BDC7B5')
    if t<15: sx,sy=925,326
    elif t<16.5: sx,sy=925+ease((t-15)/1.5)*220,326
    else: sx,sy=925+(1-ease((t-16.5)/1.5))*220,326
    if sx<1080:
        cube(sx,sy,64,43,72,'#506B61')
        d.rounded_rectangle((sx-7,sy-65,sx+37,sy-33),5,fill='#CDE0B9')
        # Minimal rabbit mark in the display.
        d.ellipse((sx+4,sy-57,sx+11,sy-41),fill=GREEN)
        d.ellipse((sx+15,sy-59,sx+23,sy-42),fill=GREEN)
        d.rectangle((sx+5,sy-44,sx+23,sy-36),fill=GREEN)
    plaque(943,429,'SESSION B' if t>=16.5 else 'SESSION A')
    text(943,449,'Claude / ChatGPT',12,MUTED,anchor='mm')
    # Only a few selected blocks travel on the context tray, not the whole map.
    cube(806,374,55,36,6,'#DDD3B6')
    plaque(811,469,'BOUNDED CONTEXT')
    text(811,486,'Current slice + deeper retrieval',12,MUTED,anchor='mm')
    if t>=18:
        for j in range(3):
            u=ease((t-18-j*.35)/1.5)
            x,y=lerp(point([0,3,5][j]),(807+j*13,355+j*4.55),u)
            cube(x,y,10,9,11,GREEN)
        if t>=20:
            for j in range(4):
                x,y=lerp((848,355),(921,322),((t-20)*.6+j*.25)%1)
                d.ellipse((x-2,y-2,x+2,y+2),fill=GREEN)
    # Evidence threads anchor facts to retained observations.
    if t>=5:
        d.line([(point(2)[0]-10,point(2)[1]+40),(355,478)],fill='#A8B8A0',width=1)
    phases=[(0,'01   Learn continuously',
             'Today’s chat, email and calendar feed the same shared memory—not just imported history.',
             'Messages are retained; extraction runs asynchronously. Rules can be written during the turn.'),
            (5,'02   Connect meaning',
             'Named entities, attributes and typed relationships form a queryable knowledge map.',
             'Nightly review proposes evidence-linked inferences and questions; it cannot overwrite stated facts.'),
            (10,'03   Update what is true',
             '“I moved.” The current home changes. Its prior value stays in history with both clocks.',
             'A dependent inference is invalidated when its support changes. Corrections keep an audit trail.'),
            (15,'04   Carry understanding forward',
             'The agent process changes; the shared map and conversation record remain.',
             'A bounded current snapshot, updates and retrieval tools keep the whole store out of every prompt.')]
    _,title,caption,detail=next(p for p in reversed(phases) if t>=p[0])
    d.line((48,611,1052,611),fill='#D8DDCF',width=1)
    text(48,628,title,20,INK,True)
    text(48,662,caption,16,INK)
    text(48,690,detail,14,MUTED)
    d.line((48,727,48+1004*t/22,727),fill=GREEN,width=3)
    return im

if __name__=='__main__':
    video=OUT/'memory.mp4'
    cmd=['ffmpeg','-y','-loglevel','error','-f','rawvideo','-pix_fmt','rgb24','-s',f'{W}x{H}','-r',str(FPS),'-i','-','-an','-c:v','libx264','-crf','21','-pix_fmt','yuv420p','-movflags','+faststart',str(video)]
    process=subprocess.Popen(cmd,stdin=subprocess.PIPE)
    for i in range(FPS*SECONDS):process.stdin.write(frame(i/FPS).tobytes())
    process.stdin.close()
    if process.wait():raise RuntimeError('Video encoding failed')
    frame(25).save(OUT/'architecture.png')
    subprocess.run(['ffmpeg','-y','-loglevel','error','-i',str(video),'-filter_complex','fps=25,scale=990:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=96[p];[b][p]paletteuse=dither=bayer:bayer_scale=4','-loop','0',str(OUT/'memory.gif')],check=True)
    print('Rendered memory.mp4, memory.gif and architecture.png')
