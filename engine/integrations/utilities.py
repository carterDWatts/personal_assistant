"""Small deterministic tools. No interpreter or model-generated arithmetic."""
import ast
from decimal import Decimal, localcontext
from datetime import datetime
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError
from engine.tools import ToolError
from engine.integrations.results import tool

UNITS = {
    'm': ('length','1','0'), 'km': ('length','1000','0'), 'mi': ('length','1609.344','0'),
    'ft': ('length','0.3048','0'), 'in': ('length','0.0254','0'), 'cm': ('length','0.01','0'),
    'kg': ('mass','1','0'), 'g': ('mass','0.001','0'), 'lb': ('mass','0.45359237','0'), 'oz': ('mass','0.028349523125','0'),
    'l': ('volume','1','0'), 'ml': ('volume','0.001','0'), 'us_gal': ('volume','3.785411784','0'),
    's': ('time','1','0'), 'min': ('time','60','0'), 'h': ('time','3600','0'),
    'c': ('temperature','1','273.15'), 'k': ('temperature','1','0'),
}


def calculate(args):
    expression=args['expression']
    if len(expression)>300: raise ToolError('Use an expression under 300 characters.')
    try:
        tree=ast.parse(expression,mode='eval')
        if len(list(ast.walk(tree)))>80: raise ValueError()
        def number(node):
            if isinstance(node,ast.Constant) and type(node.value) in (int,float):
                return Decimal(ast.get_source_segment(expression,node).replace('_',''))
            if isinstance(node,ast.UnaryOp) and isinstance(node.op,(ast.USub,ast.UAdd)):
                value=number(node.operand);return -value if isinstance(node.op,ast.USub) else value
            if isinstance(node,ast.BinOp):
                a,b=number(node.left),number(node.right)
                if isinstance(node.op,ast.Add):return a+b
                if isinstance(node.op,ast.Sub):return a-b
                if isinstance(node.op,ast.Mult):return a*b
                if isinstance(node.op,ast.Div):return a/b
                if isinstance(node.op,ast.Mod):return a%b
                if isinstance(node.op,ast.Pow) and abs(b)<=100 and b==int(b):return a**int(b)
            raise ValueError()
        with localcontext() as ctx:
            ctx.prec=28;ctx.Emax=1000;ctx.Emin=-1000
            value=number(tree.body)
            if not value.is_finite():raise ValueError()
        return {'expression':expression,'result':str(value),'precision_digits':28}
    except (SyntaxError,ValueError,ArithmeticError,RecursionError):
        raise ToolError('Use finite numbers, parentheses and + - * / % ** only; integer powers must be between -100 and 100.') from None


def convert(args):
    try:
        value=Decimal(args['value']);a=args['from_unit'];b=args['to_unit']
        if not value.is_finite() or abs(value.adjusted())>100:raise ValueError()
        if a=='f': value=(value-32)*Decimal(5)/9;a='c'
        target='c' if b=='f' else b
        source=UNITS[a];dest=UNITS[target]
        if source[0]!=dest[0]:raise ValueError()
        result=(value*Decimal(source[1])+Decimal(source[2])-Decimal(dest[2]))/Decimal(dest[1])
        if b=='f':result=result*9/5+32
        return {'value':str(result),'unit':b}
    except (KeyError,ValueError,ArithmeticError):raise ToolError('Use compatible supported units and a finite decimal value.') from None


def time_at(args):
    try:
        value=datetime.fromisoformat(args['at'].replace('Z','+00:00'))
        if value.tzinfo is None:raise ValueError()
        return {'times':{zone:value.astimezone(ZoneInfo(zone)).isoformat() for zone in args['zones']}}
    except (ValueError,ZoneInfoNotFoundError):raise ToolError('Supply a timestamp with its UTC offset and valid IANA zones, such as America/Los_Angeles.') from None


def currency(args):
    import json,re
    from engine.integrations.web import open_public
    base=args['from_currency'].lower();quote=args['to_currency'].lower()
    if not all(re.fullmatch('[a-z]{3}',x) for x in (base,quote)):raise ToolError('Use three-letter currency codes.')
    try:amount=Decimal(args['amount'])
    except ArithmeticError:raise ToolError('Use a decimal amount.') from None
    if not amount.is_finite() or abs(amount.adjusted())>100:raise ToolError('Use a finite amount.')
    if base==quote:return {'amount':str(amount),'currency':quote.upper(),'rate':'1'}
    with open_public(f'https://api.frankfurter.dev/v2/rate/{base}/{quote}',https_only=True) as (_,response):
        if response.status!=200:raise ToolError('The reference exchange rate is unavailable.')
        raw=response.read(16001)
        if len(raw)>16000:raise ToolError('Unexpected exchange-rate response.')
        data=json.loads(raw,parse_float=Decimal)
    rate=Decimal(str(data['rate']))
    if not rate.is_finite() or rate<=0:raise ToolError('Invalid exchange rate.')
    return {'amount':str(amount*rate),'currency':quote.upper(),'rate':str(rate),'rate_date':data['date'],
            'source':'https://frankfurter.dev','note':'Reference rate, not a live or guaranteed transaction quote. Bank fees and spreads are excluded.'}


def specs():
    s={'type':'string','minLength':1,'maxLength':300};unit={'type':'string','enum':[*UNITS,'f']}
    return [tool('currency_convert','Convert using dated reference exchange rates, excluding bank fees. Not a live market quote.',currency,{'amount':s,'from_currency':s,'to_currency':s},['amount','from_currency','to_currency']),tool('calculate','Evaluate arithmetic deterministically. Decimal results use 28 significant digits. No code execution.',calculate,{'expression':s},['expression']),
        tool('convert_units','Convert length, mass, volume, duration or temperature. f/c/k are Fahrenheit/Celsius/Kelvin; us_gal is a US gallon.',convert,{'value':s,'from_unit':unit,'to_unit':unit},['value','from_unit','to_unit']),
        tool('time_in_zones','Compare the same instant across time zones, including daylight saving. Input must include a UTC offset.',time_at,{'at':s,'zones':{'type':'array','items':s,'minItems':1,'maxItems':12}},['at','zones'])]
