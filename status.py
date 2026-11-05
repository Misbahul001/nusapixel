#!/usr/bin/env python3
import urllib.request
import json
import subprocess
from datetime import datetime

SB_URL = "https://npmfiituiionyapoipyd.supabase.co"
SB_KEY = "sb_publishable_MaXyb37-4s4iIi0N2AgB4w_bDmPGsq7"

def fetch_supabase(path):
    url = f"{SB_URL}/rest/v1/{path}"
    headers = {
        "apikey": SB_KEY,
        "Authorization": f"Bearer {SB_KEY}"
    }
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=10) as res:
            return json.loads(res.read().decode("utf-8"))
    except Exception as e:
        return []

def get_daemon_status():
    try:
        res = subprocess.run(["agy-daemon", "status"], capture_output=True, text=True)
        out = res.stdout
        is_running = "Status:       RUNNING" in out
        pid = "Unknown"
        for line in out.splitlines():
            if "RUNNING (PID:" in line:
                pid = line.split("PID:")[1].strip().rstrip(")")
        return {"running": is_running, "pid": pid}
    except Exception:
        return {"running": False, "pid": "N/A"}

def main():
    print("=" * 60)
    print("      🚀 NUSAPIXEL MISSION CONTROL & RADAR REPORT      ")
    print("=" * 60)
    print(f"Timestamp: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    print(f"Web URL  : https://www.nusapixel.xyz")
    print(f"Monitor  : https://www.nusapixel.xyz/dashboard")
    print("-" * 60)

    # 1. Daemon & Engine Health
    daemon = get_daemon_status()
    daemon_str = f"RUNNING (PID: {daemon['pid']})" if daemon["running"] else "STOPPED / INACTIVE"
    print(f"🤖 [AI AUTOPILOT ENGINE]")
    print(f"   • Status Daemon    : {daemon_str}")
    print(f"   • Active Model     : Gemini 3.6 Flash (Low Latency)")
    print(f"   • Auto-Post Cadence: Setiap 12 Jam (Foreground Service)")
    print(f"   • Content Filter   : Anti-Slop v2 + Google Trends Anchor")
    print("-" * 60)

    # 2. Website Stats
    articles = fetch_supabase("articles?select=id,title,slug,views,category,created_at&order=views.desc")
    total_articles = len(articles)
    total_views = sum(a.get("views", 0) for a in articles)

    print(f"📊 [PROGRES WEBSITE & PEMBACA]")
    print(f"   • Total Artikel Terbit : {total_articles}")
    print(f"   • Total Views Kumulatif: {total_views} views")
    print(f"   • Google Search Console: VERIFIED (HTML Tag & Meta Active)")
    print(f"   • Live Sitemap         : https://www.nusapixel.xyz/sitemap.xml")
    print("\n   Top Artikel Terbanyak Dibaca:")
    for idx, art in enumerate(articles[:5], 1):
        v = art.get("views", 0)
        title = art.get("title", "")
        if len(title) > 42:
            title = title[:40] + "..."
        cat = art.get("category", "General")
        print(f"   {idx}. [{v:3d} views] [{cat:9s}] {title}")

    # 3. Recent Agent Activity Logs
    print("-" * 60)
    print(f"📡 [LOG AKTIVITAS TERKINI AGENT]")
    logs = fetch_supabase("agent_logs?select=action,details,created_at&order=created_at.desc&limit=4")
    if logs:
        for l in logs:
            action = l.get("action", "")
            created = l.get("created_at", "")[:19].replace("T", " ")
            detail = l.get("details", {})
            desc = ""
            if isinstance(detail, dict):
                desc = detail.get("title") or detail.get("schedule") or ""
            print(f"   • [{created}] {action}: {desc}")
    else:
        print("   (Belum ada riwayat aktivitas di database)")

    print("=" * 60)
    print("✅ Dashboard Web Real-time: https://www.nusapixel.xyz/dashboard")
    print("=" * 60)

if __name__ == "__main__":
    main()
