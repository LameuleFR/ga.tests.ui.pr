"""Pack the campaigns of a PrestaShop version into jobs of N parallel lanes.

Usage: plan.py <campaigns JSON array> <campaigns.json> <lanes per job> <target minutes or 0>
Prints the GitHub matrix: {"include": [{"job": 1, "lanes": "a,b;c;d,e", "keycloak": false}, ...]}
';' separates the lanes of a job (lane 0 first), ',' chains campaigns run one after another.
"""
import json
import math
import sys


def main():
    available = json.loads(sys.argv[1])
    conf = json.load(open(sys.argv[2], encoding='utf-8'))
    n_lanes = int(sys.argv[3])
    target = float(sys.argv[4])

    items = []
    for campaign in available:
        items += list(conf['splits'].get(campaign, {campaign: None}).keys())
    minutes = {c: conf['minutes'].get(c, conf['default_minutes']) for c in items}
    # Lanes share 4 vCPU: assume campaigns run a bit slower than alone.
    factor = 1.0 if n_lanes == 1 else 1.05 if n_lanes == 2 else 1.15 if n_lanes == 3 else 1.3
    longest = max(minutes.values()) * factor
    if target <= 0:
        target = max(longest, 27.0)

    # Campaigns whose requests come closest to the 30 s test timeouts get a runner with no other
    # lane: one lane per job, chained while they fit in the target.
    solo = [c for c in items if n_lanes > 1 and c in conf.get('solo', [])]
    solo_jobs = math.ceil(sum(minutes[c] for c in solo) / target)
    solo_lanes = [[] for _ in range(solo_jobs)]
    solo_load = [0.0] * solo_jobs
    for c in sorted(solo, key=lambda c: -minutes[c]):
        j = min(range(solo_jobs), key=lambda j: solo_load[j])
        solo_lanes[j].append(c)
        solo_load[j] += minutes[c]

    rest = [c for c in items if c not in solo]
    slot0 = [c for c in rest if c in conf['slot0']]
    others = [c for c in rest if c not in conf['slot0']]
    total = sum(minutes[c] for c in rest) * factor
    jobs = max(1, math.ceil(total / (n_lanes * target))) if rest else 0
    # Lane 0 is the only one bound to localhost:8002 / :3306 and the runner's keycloak.
    jobs = max(jobs, math.ceil(sum(minutes[c] for c in slot0) * factor / target))

    lanes = [[[] for _ in range(n_lanes)] for _ in range(jobs)]
    load = [[0.0] * n_lanes for _ in range(jobs)]

    def put(j, k, c):
        lanes[j][k].append(c)
        load[j][k] += minutes[c] * factor

    for c in sorted(slot0, key=lambda c: -minutes[c]):
        j = min(range(jobs), key=lambda j: load[j][0])
        put(j, 0, c)
    for c in sorted(others, key=lambda c: -minutes[c]):
        j, k = min(((j, k) for j in range(jobs) for k in range(n_lanes)), key=lambda jk: load[jk[0]][jk[1]])
        put(j, k, c)

    include = []
    for j in range(solo_jobs):
        include.append({
            'job': len(include) + 1,
            'lanes': ','.join(solo_lanes[j]),
            'keycloak': any(c in conf['needs_keycloak'] for c in solo_lanes[j]),
            'estimate': round(solo_load[j]),
        })
    for j in range(jobs):
        used = [l for l in lanes[j] if l]
        if not used:
            continue
        # Keep lane 0 in first position even when it is empty, the others can be dropped.
        kept = [lanes[j][0]] + [l for l in lanes[j][1:] if l]
        include.append({
            'job': len(include) + 1,
            'lanes': ';'.join(','.join(l) for l in kept),
            'keycloak': any(c in conf['needs_keycloak'] for c in lanes[j][0]),
            'estimate': round(max(load[j])),
        })
    print(json.dumps({'include': include}))
    est = max(i['estimate'] for i in include)
    print(f'{len(items)} campaigns, {jobs} jobs x {n_lanes} lanes + {solo_jobs} solo jobs, '
          f'longest lane ~{est} min, test work ~{round(total + sum(solo_load))} min', file=sys.stderr)


if __name__ == '__main__':
    main()
