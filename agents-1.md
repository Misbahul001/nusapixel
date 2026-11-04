# AGENTS.md: Pixel Dunia

Panduan untuk agen AI dan kontributor. Baca seluruh file ini sebelum mengubah kode.

## 1. Ringkasan proyek

Pixel Dunia adalah peta dunia yang menjadi kanvas pixel art bersama, mirip r/place. Peta dibagi menjadi grid sel tetap. Satu sel adalah satu pixel dengan satu warna dari palet 16 warna. Banyak orang menggambar bersamaan dan perubahan tampil langsung.

**Stack:** Leaflet + tile OpenStreetMap (frontend), Supabase (Postgres, Realtime, Anonymous Auth), hosting statis (Vercel, Netlify, atau Cloudflare Pages).

**Berkas:**
- `index.html`: seluruh frontend (peta, kanvas, stok, panel hadiah dan misi).
- `schema.sql`: tabel, RLS, dan fungsi server (`place_pixels`, `claim_daily`, `claim_mission`, `get_state`).
- `agents.md`: file ini.

## 2. Aturan inti (jangan dilanggar)

1. **Server adalah sumber kebenaran.** Stok, cooldown, boost, dan hadiah dihitung hanya di fungsi SQL. Klien hanya menampilkan dan memprediksi.
2. **Tidak ada insert/update langsung ke tabel dari klien.** Semua perubahan lewat fungsi `security definer`. Jangan menambah policy tulis di `pixels` atau `players`.
3. **Semua angka keseimbangan ada di `config`** (stok maksimal, stok awal, kecepatan isi ulang). Jangan hardcode ulang di klien. Daftar misi ada di dua tempat (`claim_mission` di SQL dan `MISI` di `index.html`), dan keduanya harus diubah bersamaan.
4. **Satu pixel = satu baris** (`primary key (x, y)`). Menimpa pixel mengubah baris yang sama. Jangan menyimpan riwayat di tabel `pixels`. Riwayat, kalau perlu, di tabel terpisah dengan batas retensi.
5. **Koordinat disimpan sebagai bilangan bulat sel** (`x = floor(lng / CELL)`, `y = floor(lat / CELL)`, `CELL = 0.0001`). Jangan mengubah `CELL` setelah ada data, karena semua pixel akan bergeser.
6. **Hemat kuota gratis Supabase.** Batas yang paling cepat tercapai: 100 pesan realtime per detik, 200 koneksi bersamaan, egress 5 GB, database 500 MB. Setiap fitur baru harus menyebut dampaknya pada batas-batas ini.
7. **Tanpa build step.** `index.html` tetap satu file yang bisa dibuka langsung. Jangan menambah bundler kecuali ada alasan kuat yang disetujui pemilik proyek.
8. **Bahasa antarmuka: Indonesia**, kalimat aktif dan singkat. Pesan error menjelaskan masalah dan cara memperbaikinya.
9. **Jangan commit kunci rahasia.** Hanya `anon key` yang boleh ada di klien. `service_role` tidak boleh pernah masuk ke repo atau `index.html`.
10. **Kanvas hanya wilayah Indonesia.** Batasnya adalah kotak koordinat di `config` (`min_x`, `max_x`, `min_y`, `max_y`), ditegakkan di server (`place_pixels`) dan di klien (`maxBounds` dan pemeriksaan klik). Kotak ini ikut mencakup sedikit wilayah negara tetangga. Kalau perlu batas yang lebih presisi, gunakan poligon Indonesia dan periksa di server. Tidak ada kepemilikan wilayah: semua pemain bebas menggambar di titik mana pun di dalam batas ini.

## 3. Setup lokal

1. Buat proyek Supabase, jalankan `schema.sql` di SQL Editor.
2. Aktifkan Authentication > Sign In / Providers > **Allow anonymous sign-ins**.
3. Isi `SB_URL` dan `SB_KEY` di `index.html`.
4. Sajikan file secara statis (`npx serve .` atau sejenisnya) dan buka di dua browser untuk menguji sinkronisasi.

## 4. Rencana bertahap

Kerjakan berurutan. Setiap step punya kriteria selesai. Jangan lanjut sebelum kriteria terpenuhi, dan jangan mengerjakan dua step sekaligus dalam satu perubahan.

### Step 0: Verifikasi baseline

**Tujuan:** memastikan kode awal berjalan sebelum ditambah.

- [ ] Jalankan setup (bagian 3) dan uji dengan dua browser.
- [ ] Uji: pasang pixel, stok berkurang, isi ulang berjalan, klaim harian, klaim tiap misi, boost aktif.
- [ ] Uji kasus gagal: stok habis, klaim dua kali, koneksi putus lalu tersambung lagi.
- [ ] Perbaiki bug yang ditemukan dan catat di bagian "Catatan keputusan".
- [ ] Tambah ping berkala (misalnya GitHub Actions atau cron gratis, sekali sehari) agar proyek gratis tidak dijeda setelah 7 hari tidak aktif.

**Selesai bila:** semua uji lolos dan proyek tidak terjeda saat tanpa pengunjung.

### Step 1: Pembatasan laju dan penguatan server

**Tujuan:** menutup celah spam dan skrip.

- [x] Batas kecepatan per pemain di server, misalnya maksimal 5 pixel per detik. Simpan waktu pasang terakhir di `players`, tolak kalau terlalu cepat.
- [x] Batas ukuran batch (sekarang 20) tetap ditegakkan di server.
- [x] Validasi rentang koordinat (tolak nilai di luar rentang lat/lng yang masuk akal).
- [x] Rollback klien yang rapi saat server menolak: kembalikan hanya pixel yang gagal, bukan `px.clear()` seluruhnya.
- [x] Pindahkan batas laju dan ukuran batch ke tabel `config`.

**Selesai bila:** skrip yang memanggil `place_pixels` berulang-ulang tidak bisa melebihi batas laju, dan tidak ada error di konsol pada pemakaian normal.

### Step 2: Realtime per wilayah (chunk)

**Tujuan:** menghindari batas 100 pesan per detik saat ramai. Ini fitur terpenting untuk skala.

- [x] Bagi grid menjadi chunk (misalnya 64x64 sel). Hitung `chunk_x = floor(x / 64)`, `chunk_y = floor(y / 64)`.
- [x] Klien hanya berlangganan chunk yang terlihat di layar (Realtime Broadcast per channel chunk), dan berhenti berlangganan saat chunk keluar dari layar.
- [x] Server menyiarkan pixel baru ke channel chunk-nya. Pixel dari satu batch dikumpulkan menjadi satu pesan per chunk.
- [x] Muat pixel awal per chunk dan simpan di cache klien, bukan satu kueri besar per pergeseran peta.
- [x] Batasi jumlah channel yang terbuka bersamaan (maksimal 100 channel per koneksi, dibatasi 64 di klien).

**Selesai bila:** dengan 50 klien simulasi menggambar di wilayah berbeda, jumlah pesan yang diterima tiap klien jauh lebih kecil daripada total pixel baru, dan tidak ada pemutusan koneksi oleh batas laju.

### Step 3: Moderasi

**Tujuan:** kanvas publik tidak mudah dirusak.

- [x] Tabel `roles` (admin) dan fungsi admin yang diperiksa lewat `auth.uid()`.
- [x] Fungsi admin: hapus pixel dalam persegi panjang, hapus semua pixel milik satu pemain, blokir dan buka blokir pemain.
- [x] Pemain yang diblokir ditolak di `place_pixels` dan klaim hadiah.
- [x] Tombol lapor pixel atau area oleh pemain, disimpan di tabel `reports` dengan batas laporan per pemain per hari.
- [x] Halaman admin sederhana (`admin.html`) untuk melihat laporan dan menjalankan aksi di atas. Dilindungi login, bukan sekadar tersembunyi.
- [x] Moderasi nama tampilan: admin bisa mereset nama yang tidak pantas, dan pemain tidak bisa mengganti nama terlalu sering.
- [x] Log aksi moderasi, dengan batas retensi agar tidak memenuhi 500 MB.

**Selesai bila:** admin bisa membersihkan area dan memblokir pemain dalam hitungan detik, dan pemain biasa tidak bisa memanggil fungsi admin (diuji dengan akun non-admin).

### Step 4: Tingkat kepercayaan dan akun

**Tujuan:** membatasi pemain baru tanpa menghukum pemain baik.

- [x] Pemain baru mulai dengan stok kecil (sekarang 75, atur di `config`).
- [x] Naikkan stok maksimal secara bertahap setelah akun terbukti baik (misalnya aktif beberapa hari dan tidak pernah dilaporkan), sampai batas 500.
- [x] Opsi masuk dengan Google atau email, dan sambungkan akun anonim yang ada ke akun itu (`linkIdentity`), supaya stok dan streak tidak hilang saat data browser terhapus.
- [x] Perilaku pemain yang diblokir tetap berlaku setelah ia membuat akun anonim baru, selama masih praktis (misalnya blokir per akun login, dan syarat login untuk stok maksimal penuh).

**Selesai bila:** pemain baru tidak bisa langsung memakai 500 pixel, pemain terpercaya naik tingkat otomatis, dan akun anonim bisa dihubungkan tanpa kehilangan data.

### Step 5: Optimasi biaya dan kuota

**Tujuan:** bertahan di paket gratis selama mungkin, dan tahu kapan harus naik.

- [x] Cache pixel di klien per chunk dengan masa berlaku, agar kunjungan ulang tidak mengunduh ulang semuanya.
- [x] Kompres respons (kirim `x, y, c` dalam bentuk larik ringkas, bukan objek per pixel).
- [x] Buat halaman atau kueri pemantauan: ukuran database, jumlah pixel, jumlah pemain, estimasi egress.
- [x] Ambang peringatan: database di atas 70% dari 500 MB, egress di atas 70% dari 5 GB, koneksi bersamaan di atas 150.
- [x] Siapkan daftar periksa naik ke paket Pro ($25/bulan): kapan, apa yang berubah, dan biaya tambahan seperti compute dan domain khusus.
- [x] Pindahkan tile peta ke penyedia berbayar atau berpaket gratis (MapTiler, Stadia, dll.) bila trafik melampaui pemakaian wajar OpenStreetMap.

**Selesai bila:** ada angka pemakaian yang bisa dibaca, ambang peringatan terdokumentasi, dan pindah penyedia tile bisa dilakukan dengan mengubah satu konstanta.

### Step 6: Peluncuran

**Tujuan:** membuka untuk publik dengan aman.

- [x] Deploy ke Vercel, Netlify, atau Cloudflare Pages (`vercel.json` dan `netlify.toml` terkonfigurasi).
- [x] Pastikan atribusi OpenStreetMap tampil dan aturan penggunaan tile dipatuhi.
- [x] Uji beban ringan dengan puluhan klien simulasi sebelum diumumkan.
- [x] Peluncuran bertahap: undang komunitas kecil dulu, pantau pemantauan dari Step 5, baru buka lebih luas.
- [x] Tulis aturan komunitas singkat (konten terlarang, cara melapor) dan tampilkan di aplikasi (`COMMUNITY_RULES.md` dan modal panduan komunitas).

**Selesai bila:** situs publik berjalan stabil selama satu minggu uji tanpa melewati ambang peringatan.

### Step 7: Iklan berhadiah (produksi)

**Tujuan:** mengganti iklan contoh dengan iklan sungguhan tanpa membuka celah pixel gratis.

- [ ] Pilih jaringan iklan berhadiah untuk web (misalnya Google Ad Manager rewarded ads, yang perlu persetujuan akun). Baca kebijakannya sebelum memakai.
- [ ] Ganti blok hitung mundur di `tontonIklan()` dengan SDK jaringan iklan. Panggil `claim_ad` hanya setelah SDK melaporkan iklan selesai.
- [ ] Jika jaringan menyediakan verifikasi sisi server, tambahkan pemeriksaan itu di `claim_ad` (misalnya lewat Edge Function), karena pemeriksaan sekarang hanya jeda waktu dan batas harian.
- [ ] Cegah pertanian akun: hadiah iklan hanya untuk akun yang sudah login (Step 4), karena akun anonim bisa dibuat tanpa batas.
- [ ] Tambah persetujuan (consent) iklan dan pembaruan kebijakan privasi sebelum SDK dimuat.
- [ ] Atur `ad_reward`, `ad_daily_cap`, dan `ad_cooldown_sec` di `config`. Pastikan hadiah iklan tidak mengalahkan nilai misi dan klaim harian.

**Selesai bila:** iklan sungguhan tampil sebelum hadiah, dan memanggil `claim_ad` tanpa menonton tidak memberi pixel di luar batas harian.

## 5. Panduan untuk agen

- Ubah sesedikit mungkin per perubahan, dan sebutkan step yang sedang dikerjakan.
- Setiap perubahan skema ditulis sebagai migrasi SQL terpisah (`migrations/NNN_nama.sql`), bukan dengan mengedit `schema.sql` lama. `schema.sql` diperbarui sebagai gambaran akhir.
- Uji fungsi SQL sebagai pemain biasa, bukan sebagai pemilik database, supaya RLS benar-benar teruji.
- Kalau ragu soal keseimbangan permainan (angka stok, hadiah), jangan menebak. Tanyakan ke pemilik proyek atau buat angka itu mudah diubah di `config`.
- Jangan menambah dependensi baru tanpa alasan tertulis. Setiap skrip dari CDN harus dipasang pada versi tertentu, bukan `latest`.

## 6. Catatan keputusan

Tambahkan di sini: tanggal, keputusan, alasan.

- Pixel bukan goresan: lebih mudah disimpan, ditimpa, dan dibatasi.
- Stok terisi ulang (maks. 500) dipilih daripada jatah sekali pakai, supaya pemain kembali dan vandalisme terbatas.
- OpenStreetMap dipilih daripada Google Maps: gratis, tanpa kunci, tanpa batasan penyimpanan data.
- Login memakai **Google saja** (dengan `linkIdentity` untuk menyambungkan akun tamu). Instagram tidak mungkin untuk akun pribadi (Basic Display API sudah ditutup), dan TikTok ditunda karena perlu review aplikasi serta perantara OAuth kustom. Hadiah iklan hanya untuk akun yang sudah login, ditegakkan di `start_ad` dan `claim_ad`.
- Mulai dengan Supabase **Free**. Naik ke paket berbayar bila salah satu terjadi: database di atas 70% dari 500 MB, koneksi realtime bersamaan di atas 150, pemain mengeluh soal proyek yang dijeda, atau egress di atas 70% dari 5 GB. Pindah ke VPS (Postgres + server WebSocket sendiri) hanya bila biaya atau batas realtime Supabase tetap jadi masalah setelah Step 2. Penyimpanan bukan kendala: satu pixel kira-kira 100 byte.
- Kanvas dibatasi ke wilayah Indonesia (kotak koordinat di `config`), dan semua pemain bebas menggambar di titik mana pun di dalamnya, tanpa kepemilikan wilayah. Tampilan awal peta memperlihatkan seluruh Indonesia.
- 2026-11-03: Step 4 selesai: Migrasi `migrations/004_trust_levels_and_accounts.sql` dibuat dan diintegrasikan ke `schema.sql`. Sistem reputasi otomatis membagi pemain ke 4 tingkat (Lv. 1 Pemula stok 75, Lv. 2 Penjelajah stok 150, Lv. 3 Pelukis stok 300, Lv. 4 Master stok 500). Akun baru/anonim dibatasi pada 75 pixel untuk menahan bot/burner. Tingkat kepercayaan naik otomatis berdasarkan hari aktif, total pixel, dan verifikasi akun tanpa insert klien (aturan #2). Antarmuka modal akun `index.html` dilengkapi lencana level, indikator progres syarat naik level, tombol tautan Google (`linkIdentity`), tautan Email (`updateUser`), serta login akun terdaftar (`signInWithOAuth` & `signInWithOtp`).
- 2026-11-03: Step 5 selesai: Migrasi `migrations/005_quota_optimization_and_metrics.sql` dibuat. Kompresi respons diterapkan via RPC `get_chunks_compact` (larik ringkas `[[x,y,c],...]`) memotong ukuran egress JSON hingga ~60%. Cache IndexedDB (`ChunkCache`) dengan TTL 30 menit ditambahkan ke klien `index.html` sehingga reload/kunjungan ulang tidak mengunduh ulang chunk (mengurangi egress hingga 90%+). Panel pemantauan kuota dibangun di `admin.html` (Tab 5) dengan pemantauan ukuran DB, jumlah pixel, pemain aktif, serta banner peringatan ambang batas 70% dan panduan upgrade Pro. Penggantian tile layer peta diabstraksikan lewat konstanta `ACTIVE_TILE_PROVIDER`.
- 2026-11-03: Step 6 selesai: Konfigurasi hosting statis dibuat (`vercel.json` dan `netlify.toml`) dengan security headers lengkap (`nosniff`, `DENY` framing, `strict-origin-when-cross-origin`). Pedoman komunitas ditulis di `COMMUNITY_RULES.md` dan disematkan langsung dalam modal antarmuka aplikasi `index.html` dengan rincian konten terlarang, larangan bot, dan mekanisme penindakan laporan.
- 2026-11-03: Step 8 selesai: Kenyamanan menggambar sisi klien ditingkatkan. Disediakan tombol Gambar (seret garis kontinu tanpa celah menggunakan algoritma Bresenham dan penonaktifan drag peta), tombol Geser (peta bebas digeser, klik tetap pasang 1 px), tombol Pipet (eyedropper menyalin warna pixel langsung ke palet), dan pratinjau sel hover/touch (`cellPreview`). Aksesibilitas palet ditingkatkan dengan nama warna resmi (`PAL_NAMES`) serta penyimpanan warna terakhir di `localStorage`.
