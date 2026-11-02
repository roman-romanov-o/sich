import json, statistics as st, sys
from datetime import datetime, timezone
now=datetime(2026,10,25,tzinfo=timezone.utc)
P=lambda s: datetime.fromisoformat(s.replace('Z','+00:00'))
owners={'jaywcjlove_awesome-mac.json':'jaywcjlove','Uzaaft_awesome-libghostty.json':'Uzaaft','bradAGI_awesome-cli-coding-agents.json':'bradAGI','hesreallyhim_awesome-claude-code.json':'hesreallyhim'}
def q(xs,p): xs=sorted(xs); return xs[int(p*(len(xs)-1))] if xs else None
for f,o in owners.items():
    d=[x for x in json.load(open(f)) if (x['author'] or {}).get('login') not in (o,'github-actions','dependabot','app/github-actions','app/dependabot')]
    print(f"\n=== {f}  (external PRs: {len(d)}, oldest fetched {min(x['createdAt'] for x in d)[:10]})")
    for lo,hi,label in [(0,30,'last 30d'),(30,90,'30-90d ago'),(90,180,'90-180d ago'),(180,400,'180-400d ago')]:
        c=[x for x in d if lo<=(now-P(x['createdAt'])).days<hi]
        if not c: continue
        m=[x for x in c if x['mergedAt']]; cl=[x for x in c if x['state']=='CLOSED']; op=[x for x in c if x['state']=='OPEN']
        days=[(P(x['mergedAt'])-P(x['createdAt'])).total_seconds()/86400 for x in m]
        cdays=[(P(x['closedAt'])-P(x['createdAt'])).total_seconds()/86400 for x in cl]
        print(f"  {label:13} n={len(c):4}  merged {len(m)/len(c):5.0%}  closed-unmerged {len(cl)/len(c):5.0%}  still open {len(op)/len(c):5.0%}  | merge time median {q(days,.5) and round(q(days,.5),1)}d p90 {q(days,.9) and round(q(days,.9),1)}d | close median {q(cdays,.5) and round(q(cdays,.5),1)}d")
    m=[x for x in d if x['mergedAt']]
    if m: print("  last merged external PR:", max(x['mergedAt'] for x in m)[:10])
