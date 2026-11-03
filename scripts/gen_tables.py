# emits Swift literals for the reference's constant tables, so they are copied exactly
# Usage: python3 scripts/gen_tables.py Sources/LeokaniG2P/Tables.swift <dir with leokani_g2p.py>
import sys, json, os
here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, sys.argv[2])
import leokani_g2p as L
def s(x): return json.dumps(x, ensure_ascii=False)
def sset(name, v): return f"let {name}: Set<String> = [{', '.join(s(x) for x in sorted(v))}]"
def sdict(name, v):
    items=', '.join(f"{s(k)}: {s(x)}" for k,x in v.items())
    return f"let {name}: [String: String] = [{items}]"
def pdict(name, v):
    items=', '.join(f"{s(k)}: ({s(a)}, {s(b)})" for k,(a,b) in v.items())
    return f"let {name}: [String: (String, String)] = [{items}]"
def idict(name, v):
    items=', '.join(f"{s(k)}: {x}" for k,x in v.items())
    return f"let {name}: [String: Int] = [{items}]"
out=["// SPDX-License-Identifier: MIT","// Leokani G2P by Milliwatt Labs (milliwattlabs.com)","// Generated from leokani_g2p.py's tables (scripts/gen_tables.py). Do not edit by hand.","// swiftlint:disable all",""]
out.append(f"let ONES: [String] = {s(L.ONES)}")
out.append(f"let TENS: [String] = {s(L.TENS)}")
out.append(f"let MONTHS: [String] = {s(list(L.MONTHS))}")
for n in ['ORDINAL_WORDS','DAY_ABBR','TITLE_ABBR','STREET_ABBR','WORD_ABBR','SCALES','PER_UNIT','SHORTHAND','SHORTHAND_CASED','ZONES','DIRECTIONS','STATES','TLD_SAY','SEP_WORDS','SAY_AS','SAY_AS_CASED','ADJ_FORMS','VERB_FORMS','NAMES','PRONOUN']:
    out.append(sdict(n, getattr(L,n)))
out.append(idict('MONTH_ABBR', L.MONTH_ABBR))
out.append(pdict('UNITS', L.UNITS))
out.append("let CURRENCY: [String: (String, String, String, String)] = [" + ', '.join(f"{s(k)}: ({', '.join(s(x) for x in v)})" for k,v in L.CURRENCY.items()) + "]")
for n in ['SCALE_WORDS','ATTRIBUTIVE','VERSION_CUE','ACRONYM_WORDS','LETTER_CUE','NUMBER_WORDS','MINUTE_NOUNS','STREET_WORDS','TLDS','REGNAL','ROMAN_CUE','ROMAN_AMBIGUOUS','VERB_BEFORE','SUBJECTS','OBJECTS','TITLES','DROPPED','ABBREV','READ_PAST_BEFORE','READ_PAST_AFTER','LEAD_METAL','WIND_VERB_BEFORE','WIND_OBJECT','LIVES_SUBJECT','LIVES_OWNER','YEAR_BEFORE','PRONOUN_AFTER','PUNCT']:
    out.append(sset(n, getattr(L,n)))
# v1.2: letters, codes and homographs
out.append(sdict('CASED_SAY', L.CASED_SAY))
out.append(sdict('HG_CLASSES', L.HG_CLASSES))
for n in ['CODE_CUE','ONSETS','CODAS','SENTENCE_START','LETTER_PLURAL_ES','LETTER_PLURAL_S','HG_STOP','SIBILANT_END','VOICELESS_END']:
    out.append(sset(n, getattr(L,n)))
out.append("let HOMOGRAPHS: [String: [(String, [String])]] = [\n" + ',\n'.join(
    f"  {s(w)}: [" + ', '.join(f"({s(a)}, {s(list(t))})" for a, t in rules) + "]" for w, rules in L.HOMOGRAPHS.items()) + "\n]")
out.append(f"let OPEN = {s(L.OPEN)}")
out.append(f"let CLOSE = {s(L.CLOSE)}")
out.append("let VULGAR: [(String, String)] = [" + ', '.join(f"({s(k)}, {s(v)})" for k,v in L.Normalizer.VULGAR.items()) + "]")
out.append("let VULGAR_WORDS: [String: String] = [" + ', '.join(f"{s(k)}: {s(v)}" for k,v in L.Normalizer.VULGAR_WORDS.items()) + "]")
out.append(f"let UNIT_GLUED_PATTERN = {s(L.UNIT_GLUED.pattern)}")
out.append(f"let ROMAN_PATTERN = {s(L.ROMAN.pattern)}")
out.append(f"let NAMED_RANGE_PATTERN = {s(L.Normalizer.NAMED_RANGE.pattern)}")
for n in ['TIME','TIME_AMPM','EMAIL','URL','MONEY','CENTS','PHONE','PHONE7','TOLLWORD','IPV4','VERSION','VERSION_DASH','DECADE','DATE_MDY','DATE_ISO','FRACTION','RANGE','TIMES_X','MULT','RATIO','DIGITS','LEADING_POINT','DEGREES']:
    r=getattr(L.Normalizer,n); out.append(f"let P_{n} = Re({s(r.pattern)}, {'true' if r.flags & 2 else 'false'})")
out.append(f"let NUM_SEG = Re({s(L.Numbers.SEG.pattern)})")
out.append(f"let SILENT: [(UInt32, UInt32)] = {s([list(x) for x in L.SILENT]).replace('[','(').replace(']',')').replace('((','[(').replace('))',')]')}")
out.append(f"let VOWELS: Set<String> = [{', '.join(s(x) for x in sorted(L.VOWELS))}]")
out.append(f"let STRESS_OPS: [String] = {s(list(L.STRESS_OPS))}")
out.append(f"let EDGE_OPS: [String] = {s(list(L.EDGE_OPS))}")
out.append(f"let SRC: [String] = {s(list(L.SRC))}")
out.append(f"let SHAPES: [String] = {s(list(L.SHAPES))}")
out.append(f"let N_VARIANTS = {L.N_VARIANTS}")
out.append(f"let LONG_WORD = {L.LONG_WORD}")
out.append(f"let PART = {L.PART}")
open(sys.argv[1],'w').write('\n'.join(out)+'\n')
