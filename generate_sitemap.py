import urllib.request
import json
import os
from datetime import datetime

SB_URL = "https://npmfiituiionyapoipyd.supabase.co"
SB_KEY = "sb_publishable_MaXyb37-4s4iIi0N2AgB4w_bDmPGsq7"
OUTPUT_PATH = os.path.join(os.path.dirname(__file__), "sitemap.xml")

def generate_sitemap():
    now_iso = datetime.utcnow().strftime("%Y-%m-%d")
    
    # Static pages
    pages = [
        {"loc": "https://www.nusapixel.xyz/", "changefreq": "daily", "priority": "1.0", "lastmod": now_iso},
        {"loc": "https://www.nusapixel.xyz/blog", "changefreq": "daily", "priority": "0.9", "lastmod": now_iso},
        {"loc": "https://www.nusapixel.xyz/game", "changefreq": "weekly", "priority": "0.8", "lastmod": now_iso},
    ]

    # Fetch articles from Supabase
    url = f"{SB_URL}/rest/v1/articles?select=slug,published_at&is_published=eq.true&order=published_at.desc"
    headers = {
        "apikey": SB_KEY,
        "Authorization": f"Bearer {SB_KEY}"
    }

    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            articles = json.loads(res.read().decode("utf-8"))
            for a in articles:
                slug = a.get("slug")
                pub_date = a.get("published_at", now_iso)[:10]
                pages.append({
                    "loc": f"https://www.nusapixel.xyz/article?slug={slug}",
                    "changefreq": "monthly",
                    "priority": "0.8",
                    "lastmod": pub_date
                })
    except Exception as e:
        print(f"[WARN] Gagal mengambil artikel dari Supabase: {e}")

    # Build XML
    xml_lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">'
    ]

    for p in pages:
        xml_lines.append("  <url>")
        xml_lines.append(f"    <loc>{p['loc']}</loc>")
        xml_lines.append(f"    <lastmod>{p['lastmod']}</lastmod>")
        xml_lines.append(f"    <changefreq>{p['changefreq']}</changefreq>")
        xml_lines.append(f"    <priority>{p['priority']}</priority>")
        xml_lines.append("  </url>")

    xml_lines.append("</urlset>")

    sitemap_content = "\n".join(xml_lines)
    with open(OUTPUT_PATH, "w", encoding="utf-8") as f:
        f.write(sitemap_content)

    print(f"✅ sitemap.xml berhasil digenerate dengan {len(pages)} URL!")

if __name__ == "__main__":
    generate_sitemap()
