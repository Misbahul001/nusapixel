import urllib.request
import json
import os
import re
import html
import subprocess
from datetime import datetime, timezone

SB_URL = "https://npmfiituiionyapoipyd.supabase.co"
SB_KEY = "sb_publishable_MaXyb37-4s4iIi0N2AgB4w_bDmPGsq7"
ROOT_DIR = os.path.dirname(os.path.realpath(__file__))
BACA_DIR = os.path.join(ROOT_DIR, "baca")
OUTPUT_SITEMAP = os.path.join(ROOT_DIR, "sitemap.xml")
OUTPUT_RSS = os.path.join(ROOT_DIR, "rss.xml")
INDEXNOW_KEY = "8f4a9b2c1d6e7f3a5b8c9d0e1f2a3b4c"
INDEXNOW_FILE = os.path.join(ROOT_DIR, f"{INDEXNOW_KEY}.txt")


def build_toc_and_ids(content_html: str):
    """Sisipkan id='section-N' pada tag h2/h3 dan hasilkan HTML daftar isi statis."""
    toc_items = []
    counter = [0]

    def repl(match):
        tag = match.group(1).lower()
        attrs = match.group(2) or ""
        inner = match.group(3)
        clean_text = re.sub(r"<[^>]+>", "", inner).strip()
        sec_id = f"section-{counter[0]}"
        counter[0] += 1
        cls = ' class="toc-h3"' if tag == "h3" else ""
        toc_items.append(f'<li{cls}><a href="#{sec_id}">{html.escape(clean_text)}</a></li>')
        return f"<{tag}{attrs} id=\"{sec_id}\">{inner}</{tag}>"

    modified_html = re.sub(r"<(h[23])([^>]*)>(.*?)</\1>", repl, content_html, flags=re.IGNORECASE | re.DOTALL)
    return modified_html, toc_items


def render_static_article_page(article: dict, all_articles: list) -> str:
    slug = article.get("slug", "")
    title = article.get("title", "Artikel NusaPixel")
    meta_desc = article.get("meta_description") or f"Panduan lengkap dan ulasan teknis: {title}"
    category = article.get("category") or "Tutorial"
    read_time = article.get("reading_time") or 5
    views = (article.get("views") or 0) + 1
    pub_raw = article.get("published_at") or datetime.now(timezone.utc).isoformat()
    pub_iso = pub_raw[:10]
    try:
        dt = datetime.fromisoformat(pub_raw.replace("Z", "+00:00"))
        months_id = ["", "Jan", "Feb", "Mar", "Apr", "Mei", "Jun", "Jul", "Agu", "Sep", "Okt", "Nov", "Des"]
        date_display = f"{dt.day} {months_id[dt.month]} {dt.year}"
    except Exception:
        date_display = pub_iso

    canonical_url = f"https://www.nusapixel.xyz/baca/{slug}"
    og_image = article.get("featured_image") or "https://www.nusapixel.xyz/icon-512.png"

    body_html, toc_items = build_toc_and_ids(article.get("content_html", ""))
    toc_block = ""
    if len(toc_items) >= 2:
        toc_list_html = "\n          ".join(toc_items)
        toc_block = f"""
      <details id="tocBox" class="toc-box" open>
        <summary class="toc-summary">Daftar Isi Artikel</summary>
        <ul id="tocList" class="toc-list">
          {toc_list_html}
        </ul>
      </details>"""

    # Related articles (up to 3)
    related_cards = []
    for rel in all_articles:
        if rel.get("slug") and rel.get("slug") != slug:
            r_slug = rel["slug"]
            r_cat = html.escape(rel.get("category") or "Tutorial")
            r_title = html.escape(rel.get("title") or "")
            r_time = rel.get("reading_time") or 4
            r_views = rel.get("views") or 1
            related_cards.append(f"""
          <a href="/baca/{r_slug}" class="related-card">
            <div>
              <div class="related-card-cat">{r_cat}</div>
              <div class="related-card-title">{r_title}</div>
            </div>
            <div class="related-card-meta">
              <span>⏱️ {r_time} mnt</span>
              <span>•</span>
              <span>👁️ {r_views}x dibaca</span>
            </div>
          </a>""")
            if len(related_cards) >= 3:
                break

    related_html = "\n".join(related_cards)

    article_schema = {
        "@context": "https://schema.org",
        "@graph": [
            {
                "@type": "Article",
                "headline": title,
                "description": meta_desc,
                "image": [og_image],
                "datePublished": pub_raw,
                "dateModified": pub_raw,
                "author": {
                    "@type": "Organization",
                    "name": "Redaksi NusaPixel",
                    "url": "https://www.nusapixel.xyz"
                },
                "publisher": {
                    "@type": "Organization",
                    "name": "NusaPixel",
                    "logo": {
                        "@type": "ImageObject",
                        "url": "https://www.nusapixel.xyz/icon-512.png"
                    }
                },
                "mainEntityOfPage": {
                    "@type": "WebPage",
                    "@id": canonical_url
                }
            },
            {
                "@type": "BreadcrumbList",
                "itemListElement": [
                    {"@type": "ListItem", "position": 1, "name": "Beranda", "item": "https://www.nusapixel.xyz/"},
                    {"@type": "ListItem", "position": 2, "name": "Jurnal", "item": "https://www.nusapixel.xyz/blog"},
                    {"@type": "ListItem", "position": 3, "name": title, "item": canonical_url}
                ]
            }
        ]
    }

    esc_title = html.escape(title)
    esc_desc = html.escape(meta_desc)
    esc_cat = html.escape(category)

    return f"""<!doctype html>
<html lang="id">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
  <title>{esc_title} — NusaPixel</title>
  <meta name="description" content="{esc_desc}">
  <link rel="icon" type="image/png" sizes="192x192" href="/icon-192.png">

  <meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1">
  <link rel="canonical" href="{canonical_url}">
  <link rel="alternate" type="application/rss+xml" title="NusaPixel Jurnal RSS" href="https://www.nusapixel.xyz/rss.xml">

  <!-- Open Graph / WhatsApp / Social Preview -->
  <meta property="og:title" content="{esc_title}">
  <meta property="og:description" content="{esc_desc}">
  <meta property="og:type" content="article">
  <meta property="og:url" content="{canonical_url}">
  <meta property="og:image" content="{html.escape(og_image)}">
  <meta property="og:site_name" content="NusaPixel Jurnal">
  <meta name="twitter:card" content="summary_large_image">
  <meta name="twitter:title" content="{esc_title}">
  <meta name="twitter:description" content="{esc_desc}">

  <link rel="dns-prefetch" href="https://npmfiituiionyapoipyd.supabase.co">
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Newsreader:ital,opsz,wght@0,6..72,600;0,6..72,700;1,6..72,400&family=JetBrains+Mono:wght@500&display=swap" rel="stylesheet">

  <script type="application/ld+json">
  {json.dumps(article_schema, ensure_ascii=False)}
  </script>

  <style>
    :root {{
      --bg: #FFFFFF;
      --surface-subtle: #F8FAFC;
      --border: #E2E8F0;
      --border-dark: #CBD5E1;
      --text-main: #0F172A;
      --text-body: #334155;
      --text-muted: #64748B;
      --text-subtle: #94A3B8;
      --accent: #2563EB;
      --accent-light: #EFF6FF;
      --radius-sm: 6px;
      --radius-md: 10px;
      --font-sans: 'Inter', -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
      --font-serif: 'Newsreader', Georgia, serif;
      --font-mono: 'JetBrains Mono', monospace;
    }}
    *, *::before, *::after {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      font-family: var(--font-sans);
      background-color: var(--bg);
      color: var(--text-body);
      line-height: 1.75;
      -webkit-font-smoothing: antialiased;
      min-height: 100vh;
      display: flex;
      flex-direction: column;
    }}
    .container {{ width: 100%; max-width: 760px; margin: 0 auto; padding: 0 1rem; }}
    .site-header {{
      background: rgba(255, 255, 255, 0.95);
      backdrop-filter: blur(8px);
      border-bottom: 1px solid var(--border);
      position: sticky;
      top: 0;
      z-index: 100;
      height: 52px;
      display: flex;
      align-items: center;
    }}
    .nav-inner {{ width: 100%; display: flex; align-items: center; justify-content: space-between; }}
    .nav-back {{
      display: inline-flex; align-items: center; gap: 6px;
      color: var(--text-muted); text-decoration: none; font-size: 0.825rem; font-weight: 600;
    }}
    .nav-back:hover {{ color: var(--accent); }}
    .btn-canvas-nav {{
      display: inline-flex; align-items: center; gap: 6px;
      font-size: 0.775rem; font-weight: 700; color: #0b2918;
      background: #69F0AE; border: 1px solid #2ecc71;
      padding: 4px 10px; border-radius: var(--radius-sm); text-decoration: none;
    }}
    .article-header {{ padding: 1.25rem 0 1rem; border-bottom: 1px solid var(--border); }}
    .article-meta-top {{
      display: flex; align-items: center; flex-wrap: wrap; gap: 8px;
      font-size: 0.8rem; color: var(--text-muted); margin-bottom: 0.65rem;
    }}
    .article-category {{
      font-size: 0.75rem; font-weight: 700; color: var(--accent);
      background: var(--accent-light); padding: 2px 8px; border-radius: var(--radius-sm);
    }}
    .article-title {{
      font-family: var(--font-serif);
      font-size: clamp(1.45rem, 3.2vw, 2.15rem);
      font-weight: 700; letter-spacing: -0.015em; line-height: 1.25;
      color: var(--text-main); margin-bottom: 0.85rem;
    }}
    .article-meta-row {{
      display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between;
      gap: 0.75rem; font-size: 0.8rem; color: var(--text-muted); padding-top: 0.4rem;
    }}
    .meta-author-box {{ display: flex; align-items: center; gap: 8px; }}
    .author-avatar {{
      width: 28px; height: 28px; border-radius: 50%;
      background: var(--text-main); color: #fff;
      display: flex; align-items: center; justify-content: center;
      font-weight: 700; font-size: 0.7rem;
    }}
    .share-row {{ display: flex; align-items: center; gap: 6px; }}
    .btn-share {{
      padding: 4px 10px; background: var(--surface-subtle);
      border: 1px solid var(--border); border-radius: var(--radius-sm);
      font-size: 0.75rem; font-weight: 600; color: var(--text-muted); cursor: pointer;
    }}
    .btn-share:hover {{ background: #FFFFFF; border-color: var(--border-dark); color: var(--text-main); }}
    .toc-box {{
      background: var(--surface-subtle); border: 1px solid var(--border);
      border-radius: var(--radius-sm); margin: 1.25rem 0 1.5rem; font-size: 0.85rem;
    }}
    .toc-summary {{
      padding: 0.65rem 1rem; font-weight: 700; color: var(--text-main);
      cursor: pointer; user-select: none; display: flex; align-items: center; justify-content: space-between;
    }}
    .toc-list {{ list-style: none; padding: 0 1rem 0.85rem; display: flex; flex-direction: column; gap: 5px; }}
    .toc-list a {{ color: var(--text-muted); text-decoration: none; }}
    .toc-list a:hover {{ color: var(--accent); }}
    .toc-list .toc-h3 {{ padding-left: 1rem; font-size: 0.8rem; }}
    .article-content {{ padding: 1.25rem 0 2.5rem; font-size: 1.05rem; color: var(--text-body); }}
    .article-content h2 {{
      font-family: var(--font-serif); font-size: 1.55rem; font-weight: 700;
      color: var(--text-main); margin: 2rem 0 0.85rem; line-height: 1.3;
    }}
    .article-content h3 {{
      font-size: 1.2rem; font-weight: 700; color: var(--text-main);
      margin: 1.5rem 0 0.65rem; line-height: 1.35;
    }}
    .article-content p {{ margin-bottom: 1.25rem; }}
    .article-content ul, .article-content ol {{ margin-bottom: 1.25rem; padding-left: 1.5rem; }}
    .article-content li {{ margin-bottom: 0.45rem; }}
    .article-content code {{
      font-family: var(--font-mono); font-size: 0.9em;
      background: #F1F5F9; color: #0F172A; padding: 2px 6px; border-radius: 4px;
    }}
    .article-content table {{
      width: 100%; border-collapse: collapse; margin: 1.5rem 0;
      font-size: 0.9rem; background: #FFFFFF; border: 1px solid var(--border);
      border-radius: var(--radius-sm); overflow-x: auto; display: block;
    }}
    .article-content th, .article-content td {{ padding: 9px 12px; border: 1px solid var(--border); text-align: left; }}
    .article-content th {{ background: var(--surface-subtle); font-weight: 700; color: var(--text-main); }}
    .article-content tr:nth-child(even) {{ background: #FAFAFA; }}
    .promo-banner {{
      background: var(--surface-subtle); border: 1px solid var(--border);
      border-radius: var(--radius-md); padding: 1.25rem; margin: 2rem 0;
      display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 0.75rem;
    }}
    .promo-text h3 {{ font-size: 0.975rem; font-weight: 700; color: var(--text-main); margin-bottom: 2px; }}
    .promo-text p {{ font-size: 0.825rem; color: var(--text-muted); margin: 0; }}
    .btn-promo {{
      padding: 7px 14px; background: #0F172A; color: #FFFFFF;
      font-size: 0.8rem; font-weight: 600; border-radius: var(--radius-sm); text-decoration: none;
    }}
    #readingProgressBar {{
      position: fixed; top: 0; left: 0; height: 3px;
      background: linear-gradient(90deg, #10B981, #06B6D4); width: 0%; z-index: 101;
    }}
    .related-section {{ margin-top: 2rem; padding-top: 2rem; border-top: 2px dashed var(--border); }}
    .related-title {{ font-size: 1.15rem; font-weight: 700; color: var(--text-main); margin-bottom: 1.25rem; }}
    .related-grid {{ display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 1.15rem; }}
    .related-card {{
      background: var(--surface-subtle); border: 1px solid var(--border);
      border-radius: var(--radius-md); padding: 1.15rem; text-decoration: none;
      color: inherit; display: flex; flex-direction: column; justify-content: space-between;
    }}
    .related-card:hover {{ border-color: var(--accent); }}
    .related-card-cat {{ font-size: 0.72rem; font-weight: 700; color: var(--accent); text-transform: uppercase; margin-bottom: 6px; }}
    .related-card-title {{ font-size: 0.95rem; font-weight: 700; color: var(--text-main); line-height: 1.35; margin-bottom: 8px; }}
    .related-card-meta {{ font-size: 0.75rem; color: var(--text-muted); display: flex; align-items: center; gap: 6px; }}
    footer {{
      background: var(--surface-subtle); border-top: 1px solid var(--border);
      padding: 2rem 0; margin-top: auto; font-size: 0.8rem; color: var(--text-subtle); text-align: center;
    }}
  </style>
</head>
<body>
  <div id="readingProgressBar"></div>

  <header class="site-header">
    <div class="container">
      <div class="nav-inner">
        <a href="/blog" class="nav-back">
          <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="19" y1="12" x2="5" y2="12"></line><polyline points="12 19 5 12 12 5"></polyline></svg>
          Kembali ke Jurnal
        </a>
        <a href="/game" class="btn-canvas-nav">
          <svg width="13" height="13" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5"><rect x="3" y="3" width="7" height="7"></rect><rect x="14" y="3" width="7" height="7"></rect><rect x="14" y="14" width="7" height="7"></rect><rect x="3" y="14" width="7" height="7"></rect></svg>
          Kanvas Game
        </a>
      </div>
    </div>
  </header>

  <main class="container">
    <article id="articleWrapper">
      <div class="article-header">
        <div class="article-meta-top">
          <span class="article-category">{esc_cat}</span>
          <span>•</span>
          <span>{date_display}</span>
          <span>•</span>
          <span>{read_time} mnt baca</span>
          <span>•</span>
          <span id="articleViews">{views}x dibaca</span>
        </div>

        <h1 id="articleTitle" class="article-title">{esc_title}</h1>

        <div class="article-meta-row">
          <div class="meta-author-box">
            <div class="author-avatar">NP</div>
            <span style="font-weight:600; color:var(--text-main);">Redaksi NusaPixel</span>
          </div>
          <div class="share-row">
            <button class="btn-share" onclick="shareWhatsApp()">Bagikan ke WA</button>
            <button class="btn-share" onclick="shareTwitter()">Share X</button>
            <button class="btn-share" onclick="copyLink()">Salin Link</button>
          </div>
        </div>
      </div>
      {toc_block}
      <div id="articleBody" class="article-content">
        {body_html}
      </div>

      <section class="related-section">
        <h3 class="related-title">📖 Panduan &amp; Wawasan Terkait</h3>
        <div class="related-grid">
          {related_html}
        </div>
      </section>

      <section class="promo-banner">
        <div class="promo-text">
          <h3>Kanvas Voxel Multiplayer 38 Provinsi Indonesia</h3>
          <p>Ikut mewarnai peta Indonesia secara real-time langsung dari browser HP tanpa download aplikasi.</p>
        </div>
        <a href="/game" class="btn-promo">Buka Kanvas Sekarang</a>
      </section>
    </article>
  </main>

  <footer>
    <div class="container">
      <p>© 2026 NusaPixel. Hak cipta dilindungi undang-undang.</p>
    </div>
  </footer>

  <script>
    window.addEventListener('scroll', () => {{
      const winScroll = document.documentElement.scrollTop || document.body.scrollTop;
      const height = document.documentElement.scrollHeight - document.documentElement.clientHeight;
      const scrolled = height > 0 ? (winScroll / height) * 100 : 0;
      const bar = document.getElementById('readingProgressBar');
      if (bar) bar.style.width = scrolled + '%';
    }}, {{ passive: true }});

    function shareWhatsApp() {{
      const title = document.getElementById('articleTitle').innerText;
      const text = encodeURIComponent(`💡 Panduan Penting: "${{title}}"\\n\\nBaca langkah lengkapnya di NusaPixel:\\n${{window.location.href}}`);
      window.open(`https://api.whatsapp.com/send?text=${{text}}`, '_blank');
    }}
    function shareTwitter() {{
      const title = document.getElementById('articleTitle').innerText;
      const text = encodeURIComponent(`💡 "${{title}}"\\n\\n${{window.location.href}}`);
      window.open(`https://twitter.com/intent/tweet?text=${{text}}`, '_blank');
    }}
    function copyLink() {{
      navigator.clipboard.writeText(window.location.href).then(() => {{
        alert('Tautan artikel berhasil disalin!');
      }});
    }}

    // Increment real-time view count via lightweight REST RPC
    (function() {{
      try {{
        fetch('{SB_URL}/rest/v1/rpc/increment_article_views', {{
          method: 'POST',
          headers: {{
            'apikey': '{SB_KEY}',
            'Authorization': 'Bearer {SB_KEY}',
            'Content-Type': 'application/json'
          }},
          body: JSON.stringify({{ article_slug: '{slug}' }})
        }});
      }} catch (e) {{}}
    }})();
  </script>
</body>
</html>"""


def inject_static_cards_into_blog_and_index(articles: list):
    """Pre-render static article cards into blog.html and index.html for instant Googlebot crawling."""
    # 1. Update index.html static fallback cards (top 6)
    index_path = os.path.join(ROOT_DIR, "index.html")
    if os.path.exists(index_path) and articles:
        with open(index_path, "r", encoding="utf-8") as f:
            idx_html = f.read()

        cards_html = []
        for art in articles[:6]:
            slug = art.get("slug", "")
            cat = html.escape(art.get("category") or "Tutorial")
            title = html.escape(art.get("title") or "")
            desc = html.escape(art.get("meta_description") or "")
            rtime = art.get("reading_time") or 5
            cards_html.append(f"""        <a href="/baca/{slug}" class="home-art-card">
          <div>
            <div class="home-art-tag">{cat}</div>
            <h3 class="home-art-title">{title}</h3>
            <p class="home-art-excerpt">{desc}</p>
          </div>
          <div class="home-art-meta">
            <span>⏱️ {rtime} menit baca</span> &bull; <span>Baca Selengkapnya &rarr;</span>
          </div>
        </a>""")

        replacement_block = (
            '<div id="homepageArticlesGrid" class="home-articles-grid">\n'
            '        <!-- Static Pre-rendered Cards for Instant SEO Crawling -->\n'
            + "\n".join(cards_html)
            + "\n      </div>"
        )
        new_idx_html = re.sub(
            r'<div id="homepageArticlesGrid" class="home-articles-grid">.*?</div>\s*(?=<div style="text-align: center; margin-top: 2.5rem;">)',
            replacement_block + "\n\n      ",
            idx_html,
            flags=re.DOTALL
        )
        if new_idx_html != idx_html:
            with open(index_path, "w", encoding="utf-8") as f:
                f.write(new_idx_html)

    # 2. Update blog.html static pre-rendered cards
    blog_path = os.path.join(ROOT_DIR, "blog.html")
    if os.path.exists(blog_path) and articles:
        with open(blog_path, "r", encoding="utf-8") as f:
            b_html = f.read()

        b_cards = []
        for item in articles:
            slug = item.get("slug", "")
            cat = html.escape(item.get("category") or "Tutorial")
            title = html.escape(item.get("title") or "")
            desc = html.escape(item.get("meta_description") or "")
            rtime = item.get("reading_time") or 5
            views = item.get("views") or 1
            cover = html.escape(item.get("featured_image") or "https://images.unsplash.com/photo-1518770660439-4636190af475?w=600&auto=format&fit=crop&q=80")
            pub_date = (item.get("published_at") or "")[:10]
            b_cards.append(f"""      <a href="/baca/{slug}" class="article-card">
        <img src="{cover}" alt="{title}" class="card-cover" loading="lazy">
        <div class="card-body">
          <div class="card-meta-top">
            <span class="card-category">{cat}</span>
            <span class="card-readtime">{rtime} mnt baca</span>
          </div>
          <h2 class="card-title">{title}</h2>
          <p class="card-excerpt">{desc}</p>
          <div class="card-footer">
            <span>{pub_date} • {views} dibaca</span>
            <span>Baca Selengkapnya →</span>
          </div>
        </div>
      </a>""")

        new_b_grid = '<div id="articlesGrid" class="articles-grid">\n' + "\n".join(b_cards) + "\n    </div>"
        new_b_html = re.sub(
            r'<div id="articlesGrid" class="articles-grid">.*?</div>\s*</main>',
            new_b_grid + "\n  </main>",
            b_html,
            flags=re.DOTALL
        )
        if new_b_html != b_html:
            with open(blog_path, "w", encoding="utf-8") as f:
                f.write(new_b_html)


def ping_indexnow(urls: list):
    """Kirim Instant Indexing Ping ke protokol IndexNow (Bing, Yandex, Naver, Seznam)."""
    if not os.path.exists(INDEXNOW_FILE):
        with open(INDEXNOW_FILE, "w", encoding="utf-8") as f:
            f.write(INDEXNOW_KEY)

    payload = {
        "host": "www.nusapixel.xyz",
        "key": INDEXNOW_KEY,
        "keyLocation": f"https://www.nusapixel.xyz/{INDEXNOW_KEY}.txt",
        "urlList": urls[:50]
    }
    try:
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(
            "https://api.indexnow.org/indexnow",
            data=data,
            headers={"Content-Type": "application/json; charset=utf-8"},
            method="POST"
        )
        with urllib.request.urlopen(req, timeout=10) as res:
            print(f"✅ IndexNow Instant Ping terkirim untuk {len(urls)} URL (HTTP {res.status})!")
    except Exception as e:
        print(f"[INFO] IndexNow ping status: {e}")


def auto_push_to_vercel():
    """Otomatis commit & push halaman statis baru dan sitemap.xml ke produksi GitHub/Vercel."""
    env = os.environ.copy()
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    try:
        subprocess.run(["git", "-C", ROOT_DIR, "config", "--global", "--add", "safe.directory", ROOT_DIR], env=env, check=False)
        subprocess.run(["git", "-C", ROOT_DIR, "add", "baca/", "sitemap.xml", "rss.xml", "index.html", "blog.html", "article.html", "vercel.json", "generate_sitemap.py", f"{INDEXNOW_KEY}.txt"], env=env, check=False)
        status = subprocess.run(["git", "-C", ROOT_DIR, "status", "--porcelain"], env=env, stdout=subprocess.PIPE, text=True).stdout.strip()
        if status:
            subprocess.run(["git", "-C", ROOT_DIR, "commit", "-m", "feat(seo): pre-render static HTML articles (/baca/*), update sitemap & rss"], env=env, check=False)
            push_res = subprocess.run(["git", "-C", ROOT_DIR, "push", "origin", "main"], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
            if push_res.returncode == 0:
                print("🚀 Berhasil git push ke GitHub/Vercel! Halaman statis langsung aktif di produksi.")
            else:
                print(f"[WARN] Git push output: {push_res.stdout[:200]}")
    except Exception as e:
        print(f"[WARN] Auto git push dilewati: {e}")


def generate_sitemap():
    now_iso = datetime.now(timezone.utc).strftime("%Y-%m-%d")
    os.makedirs(BACA_DIR, exist_ok=True)

    pages = [
        {"loc": "https://www.nusapixel.xyz/", "changefreq": "daily", "priority": "1.0", "lastmod": now_iso},
        {"loc": "https://www.nusapixel.xyz/blog", "changefreq": "daily", "priority": "0.9", "lastmod": now_iso},
        {"loc": "https://www.nusapixel.xyz/game", "changefreq": "weekly", "priority": "0.8", "lastmod": now_iso},
    ]

    url = f"{SB_URL}/rest/v1/articles?select=id,slug,title,meta_description,focus_keyword,category,tags,content_html,featured_image,reading_time,views,published_at&is_published=eq.true&order=published_at.desc"
    headers = {
        "apikey": SB_KEY,
        "Authorization": f"Bearer {SB_KEY}"
    }

    articles = []
    req = urllib.request.Request(url, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=15) as res:
            articles = json.loads(res.read().decode("utf-8"))
    except Exception as e:
        print(f"[WARN] Gagal mengambil artikel dari Supabase: {e}")

    static_count = 0
    for a in articles:
        slug = a.get("slug")
        if not slug:
            continue
        pub_date = (a.get("published_at") or now_iso)[:10]
        clean_loc = f"https://www.nusapixel.xyz/baca/{slug}"
        pages.append({
            "loc": clean_loc,
            "changefreq": "weekly",
            "priority": "0.9",
            "lastmod": pub_date
        })

        # Render static HTML file /baca/<slug>.html
        static_html = render_static_article_page(a, articles)
        out_file = os.path.join(BACA_DIR, f"{slug}.html")
        with open(out_file, "w", encoding="utf-8") as f:
            f.write(static_html)
        static_count += 1

    # Update index.html & blog.html with static pre-rendered cards
    inject_static_cards_into_blog_and_index(articles)

    # Build sitemap.xml
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

    with open(OUTPUT_SITEMAP, "w", encoding="utf-8") as f:
        f.write("\n".join(xml_lines))

    # Build rss.xml for Google News / Feed readers
    rss_items = []
    for a in articles[:20]:
        slug = a.get("slug", "")
        title = html.escape(a.get("title") or "")
        desc = html.escape(a.get("meta_description") or "")
        link = f"https://www.nusapixel.xyz/baca/{slug}"
        rss_items.append(f"""    <item>
      <title>{title}</title>
      <link>{link}</link>
      <guid>{link}</guid>
      <description>{desc}</description>
    </item>""")

    rss_xml = f"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0">
  <channel>
    <title>NusaPixel Jurnal — Tutorial &amp; Wawasan Teknologi Indonesia</title>
    <link>https://www.nusapixel.xyz/blog</link>
    <description>Panduan praktis How-To smartphone, keamanan digital, dan kanvas kolaborasi piksel 38 provinsi Indonesia.</description>
    <language>id-ID</language>
{chr(10).join(rss_items)}
  </channel>
</rss>"""
    with open(OUTPUT_RSS, "w", encoding="utf-8") as f:
        f.write(rss_xml)

    if not os.path.exists(INDEXNOW_FILE):
        with open(INDEXNOW_FILE, "w", encoding="utf-8") as f:
            f.write(INDEXNOW_KEY)

    print(f"✅ SSG selesai: {static_count} halaman artikel HTML statis (/baca/*) + sitemap.xml ({len(pages)} URL) + rss.xml dibuat!")

    # Auto-push to GitHub/Vercel and ping IndexNow
    auto_push_to_vercel()
    ping_indexnow([p["loc"] for p in pages])


if __name__ == "__main__":
    generate_sitemap()
