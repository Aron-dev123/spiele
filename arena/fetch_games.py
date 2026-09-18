"""Liest die Arena-Spiele der Accounts aus config.json und pflegt ein Spiele-Log.

Aufruf:  python arena/fetch_games.py <pfad/zu/games.json>

Quellen:
  - op.gg (immer; die Aktualisierung wird vorher angestossen)
  - Riot API (nur wenn die Umgebungsvariable RIOT_API_KEY gesetzt ist)

Die Seiten sind unterschiedlich verzoegert. Deshalb wird jede Quelle bei jedem Lauf
komplett gelesen und alles ins bestehende Log gemischt: Ein Spiel, das eine Quelle
erst spaeter liefert, landet trotzdem noch an der richtigen Stelle. Dasselbe Spiel aus
zwei Quellen wird ueber Account + Startzeit (+-3 min) erkannt und nur einmal gezaehlt.
Die Tokens selbst rechnet arena.html aus dem Log aus.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0 Safari/537.36"
OPGG = "https://lol-api-summoner.op.gg/api"
SAME_GAME_SECONDS = 180


def http_json(url, method="GET", headers=None):
    req = urllib.request.Request(url, method=method, headers={"User-Agent": UA, **(headers or {})})
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.load(r)


def iso(ts):
    return ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


# ---------------------------------------------------------------- op.gg

def opgg_games(region, riot_id):
    name, tag = riot_id.split("#")
    q = urllib.parse.quote(f"{name}#{tag}")
    hits = http_json(f"{OPGG}/v3/{region}/summoners?riot_id={q}")["data"]
    me = next((h for h in hits if h["game_name"].lower() == name.lower() and h["tagline"].lower() == tag.lower()), None)
    if not me:
        raise RuntimeError(f"{riot_id} bei op.gg nicht gefunden")
    sid = me["summoner_id"]

    # Entspricht dem "Aktualisieren"-Knopf auf op.gg; ohne das hinkt op.gg oft Stunden hinterher.
    for _ in range(15):
        try:
            r = http_json(f"{OPGG}/{region}/summoners/{sid}/renewal", method="POST").get("data")
        except urllib.error.HTTPError:
            break
        if not r or r.get("finish"):
            break
        time.sleep(min(r.get("delay", 1000), 5000) / 1000)

    games = http_json(f"{OPGG}/{region}/summoners/{sid}/games?limit=20&game_type=ARENA")["data"]
    out = []
    for g in games:
        if g.get("game_type") != "ARENA" or g.get("is_remake"):
            continue
        p = next(x for x in g["participants"] if x["summoner"]["summoner_id"] == sid)
        mates = [x["summoner"]["game_name"] for x in g["participants"]
                 if x["team_key"] == p["team_key"] and x is not p]
        out.append({
            "start": iso(parse_iso(g["created_at"])),
            "duration": g["game_length_second"],
            "placement": p["stats"]["subteam_placement"],
            "championId": p["champion_id"],
            "teammates": mates,
            "ids": {"opgg": g["id"]},
        })
    return out


# ---------------------------------------------------------------- Riot API (optional)

def riot_games(riot_id, queues, key):
    name, tag = riot_id.split("#")
    h = {"X-Riot-Token": key}
    base = "https://europe.api.riotgames.com"
    puuid = http_json(f"{base}/riot/account/v1/accounts/by-riot-id/{urllib.parse.quote(name)}/{urllib.parse.quote(tag)}", headers=h)["puuid"]
    ids = []
    for q in queues:
        ids += http_json(f"{base}/lol/match/v5/matches/by-puuid/{puuid}/ids?queue={q}&count=20", headers=h)
    out = []
    for mid in ids:
        info = http_json(f"{base}/lol/match/v5/matches/{mid}", headers=h)["info"]
        p = next(x for x in info["participants"] if x["puuid"] == puuid)
        team = p.get("playerSubteamId")
        mates = [f'{x.get("riotIdGameName") or x.get("summonerName")}' for x in info["participants"]
                 if x is not p and team is not None and x.get("playerSubteamId") == team]
        out.append({
            "start": iso(datetime.fromtimestamp(info["gameStartTimestamp"] / 1000, timezone.utc)),
            "duration": info["gameDuration"],
            "placement": p.get("subteamPlacement") or p.get("placement"),
            "championId": p["championId"],
            "teammates": mates,
            "ids": {"riot": mid},
        })
    return out


# ---------------------------------------------------------------- Log mischen

def merge(log_games, new, player):
    """Neue Spiele ins Log mischen. Gibt die Anzahl wirklich neuer Spiele zurueck."""
    added = 0
    mine = [g for g in log_games if g["player"] == player]
    for n in new:
        t = parse_iso(n["start"]).timestamp()
        hit = next((g for g in mine if abs(parse_iso(g["start"]).timestamp() - t) <= SAME_GAME_SECONDS), None)
        if hit:
            hit["ids"].update(n["ids"])
            for k in ("placement", "championId", "duration"):
                if hit.get(k) is None and n.get(k) is not None:
                    hit[k] = n[k]
            if not hit.get("teammates"):
                hit["teammates"] = n["teammates"]
        else:
            g = {"player": player, **n}
            log_games.append(g)
            mine.append(g)
            added += 1
    return added


def main():
    out_path = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "games.json")
    cfg = json.load(open(os.path.join(HERE, "config.json"), encoding="utf-8"))
    try:
        data = json.load(open(out_path, encoding="utf-8"))
    except FileNotFoundError:
        data = {"games": [], "sources": {}}

    sources = [("opgg", lambda p: opgg_games(cfg["region"], p["riotId"]))]
    key = os.environ.get("RIOT_API_KEY")
    if key:
        sources.append(("riot", lambda p: riot_games(p["riotId"], cfg["arenaQueues"], key)))

    now = iso(datetime.now(timezone.utc))
    total_new = 0
    for src, fetch in sources:
        status = data["sources"].setdefault(src, {})
        errors = []
        for p in cfg["players"]:
            try:
                n = merge(data["games"], fetch(p), p["name"])
                total_new += n
                print(f"[{src}] {p['name']}: {n} neu")
            except Exception as e:  # eine kaputte Quelle soll die anderen nicht aufhalten
                errors.append(f"{p['name']}: {e}")
                print(f"[{src}] {p['name']}: FEHLER {e}", file=sys.stderr)
        status["checkedAt"] = now
        status["error"] = "; ".join(errors) or None
        if not errors:
            status["okAt"] = now

    data["games"].sort(key=lambda g: (g["start"], g["player"]))
    data["checkedAt"] = now
    if total_new:
        data["updatedAt"] = now
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    print(f"{total_new} neue Spiele, {len(data['games'])} insgesamt")


if __name__ == "__main__":
    main()
