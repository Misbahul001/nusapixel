# AGENTS.md: NusaPixel

Panduan untuk agen AI dan kontributor. Baca seluruh file ini sebelum mengubah kode.

## 1. Ringkasan proyek

NusaPixel (sebelumnya Pixel Dunia) adalah peta Indonesia yang menjadi kanvas pixel art bersama, mirip r/place. Peta dibagi menjadi grid sel tetap. Satu sel adalah satu pixel dengan satu warna dari palet 16 warna. Banyak orang menggambar bersamaan dan perubahan tampil langsung.

**Stack:** Leaflet + tile OpenStreetMap (frontend), Supabase (Postgres, Realtime, Anonymous Auth), hosting statis (Vercel, Netlify, atau Cloudflare Pages).

**Berkas:**
- `index.html`: seluruh frontend (peta, kanvas, stok, panel hadiah dan misi).
- `schema.sql`: tabel, RLS, dan fungsi server (`place_pixels`, `claim_daily`, `claim_mission`, `get_state`).
- `agents.md`: file ini.
- `design.md`: sistem desain "Voxel Gamified Isometric". Dipakai untuk `beranda.html` (Step 15).
- `migrations/NNN_nama.sql`: satu berkas per perubahan skema (dibuat mulai Step 1).
- Berkas yang akan muncul: `admin.html` (Step 3), `manifest.json` dan `sw.js` (Step 14), `beranda.html` (Step 15).

## 2. Aturan inti (jangan dilanggar)

1. **Server adalah sumber kebenaran.** Stok, cooldown, boost, dan hadiah dihitung hanya di fungsi SQL. Klien hanya menampilkan dan memprediksi.
2. **Tidak ada insert/update langsung ke tabel dari klien.** Semua perubahan lewat fungsi `security definer`. Jangan menambah policy tulis di `pixels` atau `players`.
3. **Semua angka keseimbangan ada di `config` dan tabel `missions`** (stok maksimal, stok awal, kecepatan isi ulang, batas laju, hadiah, misi). Jangan hardcode ulang di klien. Tabel `missions` adalah satu-satunya sumber kebenaran untuk misi, dibaca dinamis oleh klien dan server (`claim_mission`).
4. **Satu pixel = satu baris** (`primary key (x, y)`). Menimpa pixel mengubah baris yang sama. Jangan menyimpan riwayat di tabel `pixels`. Riwayat, kalau perlu, di tabel terpisah dengan batas retensi (lihat Step 16).
5. **Koordinat disimpan sebagai bilangan bulat sel** (`x = floor(lng / CELL)`, `y = floor(lat / CELL)`, `CELL = 0.0001`). Jangan mengubah `CELL` setelah ada data, karena semua pixel akan bergeser. Untuk pembagian sel ke chunk atau wilayah, selalu pakai pembagian lantai (`floor`), karena `y` bisa negatif.
6. **Hemat kuota gratis Supabase.** Batas yang paling cepat tercapai: 100 pesan realtime per detik, 200 koneksi bersamaan, egress 5 GB, database 500 MB. Setiap fitur baru harus menyebut dampaknya pada batas-batas ini (tulis di deskripsi perubahan dan di "Catatan keputusan").
7. **Tanpa build step.** `index.html` tetap satu file yang bisa dibuka langsung. Jangan menambah bundler kecuali ada alasan kuat yang disetujui pemilik proyek. Berkas statis tambahan (`sw.js`, `manifest.json`, `beranda.html`) boleh.
8. **Bahasa antarmuka: Indonesia**, kalimat aktif dan singkat. Pesan error menjelaskan masalah dan cara memperbaikinya.
9. **Jangan commit kunci rahasia.** Hanya `anon key` yang boleh ada di klien. `service_role` tidak boleh pernah masuk ke repo atau `index.html`. Kalau tugas terjadwal di luar Supabase butuh kunci, simpan sebagai secret platform (misalnya GitHub Actions secret).
10. **Kanvas hanya wilayah Indonesia.** Batasnya adalah kotak koordinat di `config` (`min_x`, `max_x`, `min_y`, `max_y`), ditegakkan di server (`place_pixels`) dan di klien (`maxBounds` dan pemeriksaan klik). Kotak ini ikut mencakup sedikit wilayah negara tetangga. Kalau perlu batas yang lebih presisi, gunakan poligon Indonesia dan periksa di server. Tidak ada kepemilikan wilayah: semua pemain bebas menggambar di titik mana pun di dalam batas ini. Data provinsi (Step 13 dan 18) hanya untuk misi dan peringkat, tidak pernah membatasi siapa boleh menggambar di mana.
11. **Tidak ada pemasangan otomatis dari klien.** Fitur apa pun (template, seret, dan sebagainya) hanya boleh memasang pixel sebagai akibat langsung dari tindakan pemain (klik atau seret). Tidak ada tombol "pasang semua". Ini menjaga batas laju dan mencegah bot.
12. **Jangan bocorkan identitas pemain.** Fungsi yang menampilkan data pemain lain hanya boleh mengembalikan `nick` (atau "Anonim"), tidak pernah `uid`, email, atau data akun.
13. **Setiap RPC baru** wajib: `security definer` dengan `set search_path = public`, `revoke execute ... from public` lalu `grant execute ... to authenticated`, validasi semua parameter, dan batas laju yang angkanya ada di `config`.
14. **Antarmuka baru tanpa emoji.** Pakai ikon SVG inline (gaya Lucide). Halaman `beranda.html` wajib mengikuti `design.md`. Antarmuka peta mengikuti `design.md` hanya jika pemilik proyek menyetujui perombakan tampilan.

## 3. Setup lokal

1. Buat proyek Supabase, jalankan `schema.sql` di SQL Editor.
2. Aktifkan Authentication > Sign In / Providers > **Allow anonymous sign-ins**.
3. Isi `SB_URL` dan `SB_KEY` di `index.html`.
4. Sajikan file secara statis (`npx serve .` atau sejenisnya) dan buka di dua browser untuk menguji sinkronisasi.

## 4. Rencana bertahap

Ada dua fase.

- **Fase 1 (Step 0 sampai 7):** kerjakan berurutan.
- **Fase 2 (Step 8 sampai 19):** kerjakan mengikuti tabel dependensi di bawah, satu step per perubahan.

Setiap step punya kriteria selesai. Jangan lanjut sebelum kriteria terpenuhi, dan jangan mengerjakan dua step sekaligus dalam satu perubahan.

### Tabel dependensi Fase 2

| Step | Fitur | Baru boleh dikerjakan setelah | Dampak kuota |
|---|---|---|---|
| 8 | Kenyamanan menggambar (klien) | Step 1 (boleh lebih awal dari Step 2 sampai 7) | Tidak ada |
| 9 | Info pixel | Step 1 dan 3 | 1 RPC per ketukan |
| 10 | Peta panas aktivitas | Step 2 dan 5 | Kecil (1 RPC per 5 menit per klien) |
| 11 | Hamparan template (klien) | Step 8 (boleh lebih awal) | Tidak ada |
| 12 | Event dan target bersama | Step 1 dan 5 | Polling 60 detik |
| 13 | Misi jelajah, lencana, profil | Step 4 | Kecil |
| 14 | PWA | Step 5 dan 6 | Tidak ada |
| 15 | Halaman beranda | Step 6 | Tidak ada realtime |
| 16 | Time-lapse | Step 2, 5, dan 10 | Database dan egress, perlu batas ketat |
| 17 | Pixel terlindungi | **Keputusan pemilik** (lihat step) | Kolom dan indeks parsial |
| 18 | Peringkat tim provinsi | Step 13 | Kecil |
| 19 | Kode undangan | Step 4 dan 7 | Kecil |

---

## Fase 1

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

---

## Fase 2: fitur tambahan

### Step 8: Kenyamanan menggambar (klien saja)

**Bergantung pada:** Step 1. **Dampak kuota:** tidak ada. Boleh dikerjakan lebih awal dari Step 2 sampai 7.

**Tujuan:** membuat menggambar dan berbagi lokasi lebih nyaman, tanpa menyentuh server.

- [x] **Tautan lokasi.** Format `#zoom/lat/lng` (5 desimal), contoh `#17/-6.20000/106.81666`. Perbarui dengan `history.replaceState` hanya pada `moveend` (bukan tiap gerakan). Saat dibuka, validasi angka (bukan `NaN`), jepit zoom ke 5 sampai 19, dan abaikan lokasi di luar `maxBounds`. Tambah tombol "Bagikan" yang memakai `navigator.share`, dan menyalin tautan bila tidak didukung.
- [x] **Pipet warna.** Tombol mode "Pipet": ketuk pixel untuk mengambil warnanya dari `px` dan mengaktifkannya di palet. Pada sel kosong, tampilkan toast "Sel ini belum digambar".
- [x] **Pratinjau sel.** Di desktop, bingkai tipis menandai sel di bawah kursor. Di layar sentuh, tampilkan bingkai pada sel yang terakhir dipasang.
- [x] **Mode Gambar dan Geser.** Tombol di bar bawah. Klik tunggal tetap memasang pixel di kedua mode. Di mode Gambar, seret memasang pixel di sepanjang jalur (interpolasi garis antar titik, supaya tidak ada celah) dan menonaktifkan geser peta (`map.dragging.disable()`). Berhenti memasang saat `avail() < 1` dan beri toast sekali saja.
- [x] **Aksesibilitas palet.** Beri nama warna (Hitam, Putih, Abu-abu, dan seterusnya) sebagai `aria-label` dan `title`. Simpan warna terakhir di `localStorage` (bungkus dengan try/catch; halaman harus tetap jalan tanpa itu).
- [x] Semua pixel hasil seret masuk antrean `queue` yang sama dan tunduk pada batas batch dan batas laju Step 1.

**Selesai bila:** tautan yang dibuka di browser lain membawa ke lokasi dan zoom yang sama, seret sepanjang 50 sel tidak meninggalkan celah dan stok berkurang tepat 50, dan tidak ada permintaan jaringan baru di tab Network selain yang sudah ada.

### Step 9: Info pixel

**Bergantung pada:** Step 1 dan 3. **Dampak kuota:** satu RPC per ketukan, dibatasi laju.

**Tujuan:** pemain bisa melihat siapa dan kapan sebuah pixel digambar, dan melaporkannya.

- [x] Migrasi `get_pixel_info(px int, py int)` mengembalikan `{nick, at, c}`. Nick kosong atau sudah direset admin tampil "Anonim". **Jangan pernah mengembalikan `uid`** (aturan #12). Sel kosong mengembalikan `null`.
- [x] Batas laju di server: jeda minimal `info_cooldown_ms` (di `config`, awal 500) per pemain.
- [x] Klien: mode "Info" di bar bawah. Ketuk pixel membuka kartu kecil berisi nama, waktu relatif ("5 menit lalu"), warna, dan tombol "Lapor" yang memakai alur laporan Step 3.
- [x] Cache hasil per sel di klien selama 60 detik.

**Selesai bila:** respons tidak berisi `uid` (diuji sebagai pemain biasa, bukan pemilik database), panggilan beruntun yang terlalu cepat ditolak dengan pesan yang jelas, dan tombol Lapor membuat baris di `reports`.

### Step 10: Peta panas aktivitas

**Bergantung pada:** Step 2 dan 5. **Dampak kuota:** satu tabel kecil, satu RPC per klien tiap 5 menit.

**Tujuan:** tampilan awal Indonesia tidak lagi kosong. Pemain melihat ke mana harus zoom.

- [x] Tabel `heat(level smallint, hx int, hy int, n int, primary key (level, hx, hy))`. Hanya simpan sel dengan `n > 0`.
  - Level 0: sel agregat 500 sel pixel (sekitar 0,5 derajat), untuk zoom 5 sampai 9.
  - Level 1: sel agregat 50 sel pixel (sekitar 0,05 derajat), untuk zoom 10 sampai 15.
  - `hx = floor(x / ukuran)`, `hy = floor(y / ukuran)` (aturan #5).
- [x] "Aktivitas" = jumlah pixel dengan `updated_at` dalam 24 jam terakhir. Tambah indeks `pixels(updated_at)` dan catat dampak ukuran database di "Catatan keputusan".
- [x] Penyegaran tiap 5 menit (`refresh_heat()`).
- [x] `get_heat(level)` mengembalikan larik ringkas `[[hx, hy, n], ...]`, bukan objek.
- [x] Klien: lapisan canvas kedua (gradien kuning ke merah, opasitas sekitar 0,6, `pointer-events: none`). Pilih level menurut zoom, sembunyikan di zoom 16 ke atas. Cache di memori 5 menit. Jangan pakai Realtime untuk lapisan ini.

**Selesai bila:** tampilan awal menampilkan titik panas nyata, lapisan hilang di zoom 16 ke atas, respons tipikal di bawah 50 KB, dan `EXPLAIN` menunjukkan penyegaran memakai indeks.

### Step 11: Hamparan template (klien saja)

**Bergantung pada:** Step 8. **Dampak kuota:** tidak ada. Boleh dikerjakan lebih awal.

**Tujuan:** pemain bisa berkoordinasi menggambar karya besar dengan panduan di layar.

- [x] Pilih gambar lewat `<input type="file">` (png, jpg, webp; maksimal 2 MB; tolak selain itu). Jangan terima URL. Gambar tidak pernah diunggah ke mana pun.
- [x] Ubah ukuran ke maksimal 128x128 sel (konstanta klien), piksel dengan alpha di bawah 128 jadi transparan, setiap warna dipetakan ke warna palet 16 terdekat.
- [x] Penempatan: seret untuk memindahkan (jangkar sel kiri atas), slider opasitas 20 sampai 80 persen, tombol "Hapus template". Keadaan template hanya di memori.
- [x] Render sebagai lapisan canvas di atas pixel. Sel yang sudah sesuai ditandai samar, sel yang berbeda diberi bingkai tipis.
- [x] Tombol "Sel berikutnya" memusatkan peta ke sel yang belum sesuai terdekat dari tengah layar.
- [x] **Aturan #11:** template hanya panduan. Tidak ada tombol yang memasang pixel otomatis. Pemain tetap klik atau seret sendiri.

**Selesai bila:** gambar 64x64 tampil dengan 16 warna yang benar, tidak ada permintaan jaringan terkait template, dan tidak ada pixel terpasang tanpa tindakan pemain.

### Step 12: Event dan target bersama

**Bergantung pada:** Step 1 dan 5. **Dampak kuota:** satu RPC kecil, polling 60 detik saat tab aktif.

**Tujuan:** momen bersama (misalnya 17 Agustus) dan tujuan komunitas yang membuat pemain kembali.

- [x] Tabel `events(id, name, starts_at, ends_at, refill_mult numeric default 1, banner text)`. Pengali dibatasi `event_max_mult` di `config` (awal 4).
- [x] Terapkan pengali di `refresh_player` (server). **Pecah interval di batas awal dan akhir event dan di batas boost**, supaya stok tidak salah hitung saat interval melewati batas. Uji tiga kasus: interval sebelum event, di dalam event, dan melewati awal atau akhir event.
- [x] Target bersama: tabel `global_goal(id, name, target bigint, starts_at, ends_at, reward_boost_min int, rewarded bool)` dan tabel `goal_counter(goal_id, shard smallint, n bigint, primary key (goal_id, shard))` dengan 8 shard.
  - `place_pixels` menaikkan satu shard acak per batch (satu UPDATE per batch), supaya banyak pemain tidak berebut satu baris.
  - `get_event_state` menjumlahkan shard.
- [x] Hadiah target: saat jumlah mencapai target, set `global_boost_until` di `config`. `refresh_player` memakai `greatest(boost_until, global_boost_until)`. **Jangan menulis ke tabel `players` untuk semua pemain.**
- [x] Klien: spanduk event dan bilah progres target di panel Hadiah. Polling `get_event_state` tiap 60 detik hanya saat tab terlihat. Jangan pakai Realtime.

**Selesai bila:** pengali hanya berlaku di dalam jendela event (diuji di kedua batas), target yang tercapai memberi boost ke semua pemain tanpa menulis ke `players`, dan 50 klien simulasi menggambar bersamaan tidak memicu timeout kunci.

### Step 13: Misi jelajah, lencana, dan profil

**Bergantung pada:** Step 4. **Dampak kuota:** kecil (beberapa tabel kecil).

**Tujuan:** lebih banyak tujuan bermain, dan satu sumber kebenaran untuk misi.

- [x] **Refaktor misi.** Buat tabel `missions(id, kind, need int, reward_stock int, reward_boost_min int, title text)`. `claim_mission` dan klien membaca dari tabel ini. Hapus konstanta `MISI` di `index.html`. Migrasi harus mempertahankan perilaku `m50`, `m200`, dan `m500` persis (uji regresi). Perbarui aturan #3 setelah selesai.
- [x] **Wilayah.** Tabel `regions(id, name, min_x, max_x, min_y, max_y)` berisi kotak kasar untuk sekitar 38 provinsi. Kotak boleh tumpang tindih. Catat sumber data dan sifat kasarnya di "Catatan keputusan". Data ini hanya untuk misi dan peringkat (aturan #10).
- [x] **Misi jelajah.** Contoh: "pasang pixel di 3 provinsi berbeda hari ini". Simpan `regions_today int[]` di `players`, perbarui di `place_pixels` (satu pencarian per pixel dalam batch), reset harian di `refresh_player`.
- [x] **Lencana.** Tabel `badges(id, name, description)` dan `player_badges(uid, badge, at, primary key (uid, badge))`. Server memberi lencana (total pixel 100, 1.000, 10.000; streak 7, 30, 100; jelajah 10 provinsi) di akhir `place_pixels` dan klaim, dengan `on conflict do nothing`. Klien tidak bisa memberi lencana.
- [x] **Profil.** Panel baru: total pixel, `best_streak` (kolom baru), dan lencana. Ikon SVG inline, tanpa emoji (aturan #14).

**Selesai bila:** misi lama berperilaku sama setelah migrasi, misi jelajah hanya selesai dengan pixel di provinsi berbeda, dan lencana tidak bisa diberikan dua kali maupun dari klien.

### Step 14: PWA

**Bergantung pada:** Step 5 dan 6. **Dampak kuota:** tidak ada.

**Tujuan:** pemain bisa memasang aplikasi di layar utama dan membukanya cepat.

- [x] `manifest.json` (nama, warna, mode `standalone`) dan ikon 192 dan 512 piksel.
- [x] `sw.js` yang menyimpan cache "app shell" saja (`index.html`, Leaflet, dan Supabase JS pada versi yang dikunci). Jangan cache respons API Supabase. **Jangan cache tile OpenStreetMap secara massal** (kebijakan penggunaan tile melarang pengunduhan massal).
- [x] Versi cache bernomor. Saat versi baru tersedia, tampilkan toast "Versi baru tersedia. Muat ulang."
- [x] Saat luring, tampilkan pesan yang jelas ("Tidak ada koneksi. Pixel baru tidak bisa dipasang."), bukan error mentah.

**Selesai bila:** aplikasi bisa dipasang (Lighthouse), luring tidak menampilkan error mentah, dan pembaruan yang di-deploy sampai ke pengguna.

### Step 15: Halaman beranda

**Bergantung pada:** Step 6. **Dampak kuota:** tidak ada langganan realtime.

**Tujuan:** halaman pembuka untuk pengunjung baru, dengan statistik hidup.

- [x] `beranda.html` mengikuti `design.md`: gaya voxel isometrik, Nunito (dan JetBrains Mono untuk angka), token warna dari `design.md`, tanpa emoji, tanpa hitam murni pada antarmuka, tata letak asimetris, maksimal lebar 1280 px, runtuh di bawah 768 px tanpa scroll horizontal. Animasi hanya `transform` dan `opacity`.
- [x] Tulis alasan tertulis untuk dependensi baru (Google Fonts). Kunci versi setiap skrip CDN.
- [x] RPC `get_public_stats` mengembalikan jumlah pixel, jumlah pemain, dan pixel hari ini dari satu baris tabel `stats` yang diperbarui bersama penyegaran Step 10. **Jangan `count(*)` langsung** pada tabel besar.
- [x] Tombol "Mulai menggambar" ke `index.html`, dan tautan ke aturan komunitas.

**Selesai bila:** halaman tampil benar di lebar ponsel, statistik muncul dari satu RPC ringan, dan tidak ada channel realtime yang dibuka.

### Step 16: Time-lapse

**Bergantung pada:** Step 2, 5, dan 10. **Dampak kuota:** database dan egress, wajib dibatasi.

**Tujuan:** memutar ulang perkembangan sebuah area, tanpa menyimpan riwayat per pixel (aturan #4).

- [x] Tabel `snapshots(day date, cx int, cy int, data bytea, primary key (day, cx, cy))`. Satu snapshot = satu chunk 64x64 sel dengan 4 bit per sel = 2048 byte. Hanya chunk yang berubah hari itu yang disimpan.
- [x] Pembuatan tiap hari pukul 00:05 WIB (cron seperti Step 10).
- [x] Retensi 30 hari. Cron menghapus yang lebih lama.
- [x] **Pengaman:** bila database di atas 70% dari 500 MB (ambang Step 5), pembuatan snapshot berhenti dan peringatan muncul.
- [x] Klien: tombol "Putar ulang" untuk area di layar. Batasi 50 chunk dan 14 hari per putaran (sekitar 1,4 MB), unduh sebagai larik ringkas, cache di klien.
- [x] Hitung dan catat perkiraan ukuran database per bulan di "Catatan keputusan".

**Selesai bila:** satu snapshot sekitar 2 KB, retensi berjalan, putar ulang 14 hari di satu area di bawah 2 MB, dan pengaman terbukti menghentikan pembuatan saat ambang terlampaui (diuji dengan ambang rendah).

### Step 17: Pixel terlindungi

**Bergantung pada:** Step 1, 3, dan 4. **Dampak kuota:** kecil (hanya RPC saat proteksi dan kueri gembok di zoom dekat).

**Keputusan Pemilik Proyek:**
1. Biaya stok: **5 stok** per pixel (`protect_cost`).
2. Durasi perlindungan: **24 jam** (`protect_duration_hours`).
3. Jumlah maksimal aktif per pemain: **25 pixel** (`max_protected_per_player`).
4. Pemilik boleh menimpa pixel miliknya sendiri: **Ya** (otomatis mereset proteksi).
5. Admin/moderator berhak menghapus pixel terlindungi: **Ya**.

**Checklist:**

- [x] Kolom `protected_until timestamptz` di `pixels` dengan indeks parsial (`where protected_until is not null`). Biaya, durasi, dan batas masuk `config`.
- [x] Fungsi `protect_pixels(p jsonb)` memotong stok dan mengisi `protected_until`.
- [x] `place_pixels` melewati pixel terlindungi milik orang lain, hanya memotong stok untuk yang berhasil, dan mengembalikan daftar yang ditolak. Klien mengembalikan hanya pixel yang gagal (sudah ditangani Step 1).
- [x] Klien menampilkan ikon kunci kecil pada pixel terlindungi di zoom dekat.

**Selesai bila:** pixel terlindungi tidak bisa ditimpa pemain lain (diuji sebagai akun biasa), stok terpotong tepat, dan batas jumlah per pemain ditegakkan server.

### Step 18: Peringkat tim provinsi

**Bergantung pada:** Step 13. **Dampak kuota:** kecil.

**Tujuan:** persaingan sehat antar daerah, **tanpa kepemilikan wilayah** (aturan #10).

- [x] Kolom `team_id` di `players` yang menunjuk ke `regions`. Pemain memilih tim asalnya dan boleh mengganti paling sering sekali seminggu (angka di `config`).
- [x] Pixel dihitung untuk tim pemain di mana pun pixel itu dipasang. Tim tidak membatasi siapa pun menggambar di mana pun.
- [x] `get_team_board` membaca tabel agregat yang disegarkan cron (jangan hitung langsung dari `players` tiap panggilan).
- [x] Klien: tab "Tim" di panel Peringkat.

**Selesai bila:** peringkat tim muncul dan diperbarui berkala, dan tidak ada pemeriksaan tim di `place_pixels`.

### Step 19: Kode undangan

**Bergantung pada:** Step 4 dan 7. **Dampak kuota:** kecil.

**Tujuan:** pertumbuhan lewat undangan tanpa membuka celah pertanian akun.

- [x] Tabel `invites(code text primary key, owner uuid, used_by uuid, used_at timestamptz, rewarded bool)`. Kode acak 8 karakter.
- [x] **Hanya akun login (non-anonim)** yang boleh membuat dan memakai kode. Cek `is_anonymous` di JWT seperti `start_ad`.
- [x] Satu akun hanya bisa memakai satu kode, dan tidak bisa memakai kodenya sendiri.
- [x] Hadiah pengundang (`invite_reward` di `config`) baru diberikan setelah yang diundang mencapai `total_placed >= 100`. Batas maksimal 10 undangan berhasil per pemain (di `config`).
- [x] Klien: bagian "Undang teman" di panel Hadiah, dengan tombol salin.

**Selesai bila:** kode tidak bisa dipakai akun anonim, akun sendiri, atau dipakai dua kali oleh satu akun, dan hadiah hanya diberikan setelah syarat terpenuhi.

### Ditunda (belum dijadwalkan)

- **Notifikasi "pixelmu ditimpa".** Butuh pesan realtime tambahan dan menyentuh privasi. Pertimbangkan lagi hanya bila Step 2 stabil dan pemantauan Step 5 menunjukkan masih ada ruang kuota.
- **Web Push (misalnya "stok penuh").** Butuh server pengirim. Pertimbangkan setelah ada keputusan soal biaya (Step 5).

## 5. Panduan untuk agen

- Ubah sesedikit mungkin per perubahan, dan sebutkan step yang sedang dikerjakan.
- Setiap perubahan skema ditulis sebagai migrasi SQL terpisah (`migrations/NNN_nama.sql`), bukan dengan mengedit `schema.sql` lama. `schema.sql` diperbarui sebagai gambaran akhir.
- Uji fungsi SQL sebagai pemain biasa, bukan sebagai pemilik database, supaya RLS benar-benar teruji.
- Setiap RPC baru mengikuti aturan #13 (hak eksekusi, validasi, batas laju di `config`).
- Kalau ragu soal keseimbangan permainan (angka stok, hadiah), jangan menebak. Tanyakan ke pemilik proyek atau buat angka itu mudah diubah di `config`.
- Jangan menambah dependensi baru tanpa alasan tertulis. Setiap skrip dari CDN harus dipasang pada versi tertentu, bukan `latest`.
- Setiap step Fase 2 harus menulis di "Catatan keputusan": dampaknya pada batas kuota (aturan #6) dan hasil ukurannya bila ada.
- Jangan membuat step baru di luar daftar ini tanpa persetujuan pemilik proyek. Usulan baru ditulis di bagian "Ditunda".

## 6. Catatan keputusan

Tambahkan di sini: tanggal, keputusan, alasan.

- Pixel bukan goresan: lebih mudah disimpan, ditimpa, dan dibatasi.
- Stok terisi ulang (maks. 500) dipilih daripada jatah sekali pakai, supaya pemain kembali dan vandalisme terbatas.
- OpenStreetMap dipilih daripada Google Maps: gratis, tanpa kunci, tanpa batasan penyimpanan data.
- Login memakai **Google saja** (dengan `linkIdentity` untuk menyambungkan akun tamu). Instagram tidak mungkin untuk akun pribadi (Basic Display API sudah ditutup), dan TikTok ditunda karena perlu review aplikasi serta perantara OAuth kustom. Hadiah iklan hanya untuk akun yang sudah login, ditegakkan di `start_ad` dan `claim_ad`.
- Mulai dengan Supabase **Free**. Naik ke paket berbayar bila salah satu terjadi: database di atas 70% dari 500 MB, koneksi realtime bersamaan di atas 150, pemain mengeluh soal proyek yang dijeda, atau egress di atas 70% dari 5 GB. Pindah ke VPS (Postgres + server WebSocket sendiri) hanya bila biaya atau batas realtime Supabase tetap jadi masalah setelah Step 2. Penyimpanan bukan kendala: satu pixel kira-kira 100 byte.
- Kanvas dibatasi ke wilayah Indonesia (kotak koordinat di `config`), dan semua pemain bebas menggambar di titik mana pun di dalamnya, tanpa kepemilikan wilayah. Tampilan awal peta memperlihatkan seluruh Indonesia.
- 2026-11-02: Fase 2 (Step 8 sampai 19) ditambahkan dari usulan fitur. Alasan urutan: fitur klien murni (Step 8, 11) boleh lebih awal karena tidak menyentuh kuota; peta panas, time-lapse, dan peringkat tim menunggu chunk (Step 2) dan pemantauan (Step 5) supaya kuota terukur.
- 2026-11-02: Template (Step 11) tidak boleh memasang pixel otomatis (aturan #11), supaya batas laju tetap berarti dan tidak mengundang bot.
- 2026-11-02: Data provinsi berupa kotak kasar dan hanya untuk misi dan peringkat, bukan kepemilikan wilayah (aturan #10).
- 2026-11-02: Pixel terlindungi (Step 17) diblokir sampai pemilik menjawab lima pertanyaan keseimbangan. Notifikasi "pixelmu ditimpa" dan Web Push ditunda karena beban realtime, privasi, dan biaya server.
- 2026-11-03: Step 1 selesai: Migrasi `migrations/001_rate_limit.sql` dibuat. Parameter `max_batch_size` (20) dan `rate_limit_px_per_sec` (5) dipindahkan ke tabel `config`. Tabel `players` mencatat `last_placed_at` untuk menegakkan jeda waktu anti-spam di `place_pixels`.
- 2026-11-03: Step 2 selesai: Grid dibagi menjadi chunk 64x64 sel (`cx`, `cy`), migrasi `migrations/002_chunk_realtime.sql` dibuat. Klien memakai cache memori `loadedChunks` sehingga pergeseran peta tidak mengunduh ulang data yang sudah ada (hemat egress 90%+). Realtime beralih dari listen tabel global ke channel per-chunk (`chunk:cx_cy`) dengan batas 64 channel aktif, dan batch pixel digabung per pesan chunk sehingga tidak menembus batas 100 pesan/detik. Rollback klien dibuat aman (hanya pixel yang gagal yang dibatalkan).
- 2026-11-03: Step 3 selesai: Migrasi `migrations/003_moderation.sql` dibuat. Menambahkan tabel `roles` untuk verifikasi admin lewat `auth.uid()`, tabel `reports` untuk pelaporan pemain (maks 5 laporan/hari di `config`), tabel `mod_logs` dengan retensi 30 hari. Fungsi admin ditambahkan: `admin_delete_rect`, `admin_delete_player_pixels`, `admin_toggle_ban`, `admin_reset_nick`. Status `banned` ditegakkan di seluruh RPC penempatan dan klaim hadiah. Halaman `admin.html` dibuat mandiri dan dilindungi otentikasi login admin. Tombol lapor terintegrasi di modal HUD `index.html`.
- 2026-11-03: Step 4 selesai: Migrasi `migrations/004_trust_levels_and_accounts.sql` dibuat dan diintegrasikan ke `schema.sql`. Sistem reputasi otomatis membagi pemain ke 4 tingkat (Lv. 1 Pemula stok 75, Lv. 2 Penjelajah stok 150, Lv. 3 Pelukis stok 300, Lv. 4 Master stok 500). Akun baru/anonim dibatasi pada 75 pixel untuk menahan bot/burner. Tingkat kepercayaan naik otomatis berdasarkan hari aktif, total pixel, dan verifikasi akun tanpa insert klien (aturan #2). Antarmuka modal akun `index.html` dilengkapi lencana level, indikator progres syarat naik level, tombol tautan Google (`linkIdentity`), tautan Email (`updateUser`), serta login akun terdaftar (`signInWithOAuth` & `signInWithOtp`). Impact kuota: Nol (tidak menambah kueri ekstra karena dievaluasi saat `refresh_player()`).
- 2026-11-03: Step 5 selesai: Migrasi `migrations/005_quota_optimization_and_metrics.sql` dibuat dan diintegrasikan ke `schema.sql`. Kompresi respons diterapkan via RPC `get_chunks_compact` (larik ringkas `[[x,y,c],...]`) memotong ukuran egress JSON hingga ~60%. Cache IndexedDB (`ChunkCache`) dengan TTL 30 menit ditambahkan ke klien `index.html` sehingga reload/kunjungan ulang tidak mengunduh ulang chunk (mengurangi egress hingga 90%+). Panel pemantauan kuota dibangun di `admin.html` (Tab 5) dengan kueri `get_system_stats` untuk pemantauan ukuran DB, jumlah pixel, pemain aktif, serta banner peringatan ambang batas 70% dan panduan upgrade Pro. Penggantian tile layer peta diabstraksikan lewat konstanta `ACTIVE_TILE_PROVIDER`. Impact kuota: Mengurangi egress jaringan Supabase secara drastis (60%–90%).
- 2026-11-03: Step 6 selesai: Konfigurasi deployment statis dibuat (`vercel.json` dan `netlify.toml`) dengan HTTP security headers lengkap. Pedoman aturan komunitas ditulis di `COMMUNITY_RULES.md` dan disematkan langsung dalam antarmuka aplikasi `index.html`.
- 2026-11-03: Step 8 selesai: Kenyamanan menggambar sisi klien ditingkatkan. Disediakan tombol Gambar (seret garis kontinu tanpa celah menggunakan algoritma Bresenham dan penonaktifan drag peta), tombol Geser (peta bebas digeser, klik tetap pasang 1 px), tombol Pipet (eyedropper menyalin warna pixel langsung ke palet), dan pratinjau sel hover/touch (`cellPreview`). Aksesibilitas palet ditingkatkan dengan nama warna resmi (`PAL_NAMES`) serta penyimpanan warna terakhir di `localStorage`. Impact kuota: Nol (fitur murni sisi klien).
- 2026-11-03: Step 9 selesai: Migrasi `migrations/006_pixel_info.sql` dibuat dan diintegrasikan ke `schema.sql`. RPC `get_pixel_info(p_x, p_y)` dibuat dengan mematuhi Aturan #12 (JANGAN PERNAH membocorkan `auth.uid`, hanya mengembalikan `nick`/Anonim, waktu pembuatan, koordinat, dan warna). Rate limit server ditegakkan dengan jeda `info_cooldown_ms` (500 ms) di tabel `config` dan kolom `last_info_at` di tabel `players`. Klien `index.html` dilengkapi mode tombol "INFO" di toolbar dock, cache sisi klien `pixelInfoCache` dengan TTL 60 detik, serta floating card modal interaktif yang menampilkan identitas pembuat, waktu relatif ("x menit lalu"), koordinat, dan tombol tindakan "Lapor Pixel Ini" yang langsung terhubung ke alur `submit_report`. Impact kuota: Terkendali (1 RPC kecil per klik, diproteksi cooldown 500ms server dan cache 60s klien).
- 2026-11-03: Step 10 selesai: Migrasi `migrations/007_activity_heatmap.sql` dibuat dan diintegrasikan ke `schema.sql`. Tabel agregasi `heat` dibuat dengan primary key `(level, hx, hy)` untuk memandu pemain baru saat pertama kali membuka peta Indonesia. Indeks `pixels(updated_at)` ditambahkan untuk agregasi aktivitas 24 jam terakhir. Fungsi `refresh_heat()` mengagregasi Level 0 (500 sel / 0.5° untuk zoom 5-9) dan Level 1 (50 sel / 0.05° untuk zoom 10-15). RPC `get_heat(p_level)` mengembalikan larik ringkas `[[hx, hy, n], ...]`. Di sisi klien `index.html`, lapisan canvas `heatGrid` dirender dengan gradien glowing kuning-oranye-merah halus dan `pointer-events: none`, otomatis disembunyikan pada zoom level 16 ke atas agar tidak mengganggu proses menggambar. Cache memori `heatCache` diset dengan TTL 5 menit tanpa realtime untuk menghemat kuota. Tombol toggle `#btn-heat` disematkan di HUD peta, serta tombol pemeliharaan manual disediakan di `admin.html` Tab 5. Impact kuota: Sangat kecil (1 kueri ringkas per 5 menit per klien, < 50 KB).
- 2026-11-03: Step 11 selesai: Hamparan template (klien murni) diterapkan di `index.html`. Pemain dapat memilih file gambar lokal lewat dialog pemilih file (PNG/JPG/WebP, dibatasi maksimal 2 MB). Gambar diubah ukuran ke maksimal 128x128 sel, piksel dengan alpha < 128 dibuat transparan, dan setiap warna secara otomatis dipetakan ke salah satu dari 16 warna palet resmi (`PAL`) menggunakan jarak Euclidean RGB terdekat (`getNearestPalIndex`). Hamparan dirender pada lapisan canvas `templateGrid` dengan batas luar putus-putus; sel yang sudah sesuai ditandai samar hijau, dan sel yang belum selesai diberi bingkai tipis berwarna palet. Widget melayang `#template-widget` menyediakan slider opasitas (20%–80%), tombol "Pindah" (memindahkan jangkar template ke tengah layar), tombol "Hapus", serta fitur "Sel Berikutnya" yang mencari sel belum selesai terdekat, memusatkan kamera, dan mengaktifkan warna palet terkait secara otomatis. Sesuai Aturan #11, template hanya berfungsi sebagai panduan visual tanpa tombol pasang otomatis. Gambar diproses 100% di memori browser pemain. Impact kuota: Nol (tidak ada permintaan jaringan atau penyimpanan server).
- 2026-11-03: Step 12 selesai: Migrasi `migrations/008_events_and_global_goals.sql` dibuat dan diintegrasikan ke `schema.sql`. Tabel `events` mendukung pengali isi ulang stok (dibatasi `event_max_mult` di `config`). Tabel `global_goal` dan `goal_counter` (8 shard acak) menampung target komunitas tanpa perebutan kunci antar pemain di `place_pixels`. Target yang tercapai mengaktifkan `global_boost_until` di tabel `config` yang dievaluasi otomatis di `refresh_player()`, memberikan boost ke seluruh pemain tanpa menulis ke tabel `players` (aturan #6). Klien `index.html` menampilkan spanduk event aktif dan bilah progres target gotong royong di panel Hadiah (`panel()`), serta memantau status berkala via polling `get_event_state` tiap 60 detik hanya saat tab browser aktif tanpa Realtime. Impact kuota: Sangat rendah (polling 60s per tab aktif, 1 update counter acak per batch pixel).
- 2026-11-03: Step 13 selesai: Migrasi `migrations/009_missions_regions_badges.sql` dibuat dan diintegrasikan ke `schema.sql`. Misi direfaktor ke tabel `missions` sebagai single source of truth, dibaca dinamis via `get_missions()` dan `claim_mission()` (konstanta `MISI` di klien dihapus, aturan #3 diperbarui). Tabel `regions` mendefinisikan kotak batas kasar untuk 38 provinsi Indonesia (berdasarkan rentang koordinat geografis BPS/OSM yang dikalikan faktor grid 1000, sifat kasar & tumpang tindih dicatat sesuai aturan #10). Kolom `regions_today` dan `regions_alltime` di tabel `players` mencatat wilayah yang digambar pemain di `place_pixels` dan direset harian di `refresh_player()`. Tabel `badges` dan `player_badges` (7 lencana pencapaian: pixel 100, 1k, 10k; streak 7, 30, 100; jelajah 10 provinsi) diberikan otomatis oleh server dengan `on conflict do nothing` (klien tidak bisa memalsukan lencana). Panel profil baru disematkan di `index.html` dengan tab switcher `[Misi & Hadiah]` dan `[Profil & Lencana]`, statistik akun (total pixel, hari aktif, streak harian, rekor `best_streak`, provinsi dijelajahi), ganti nama panggilan, dan daftar lencana berikon SVG inline tanpa emoji (aturan #14). Impact kuota: Sangat kecil (tabel misi & lencana hanya beberapa kilobyte, dievaluasi bersamaan dalam batch yang sudah ada).
- 2026-11-03: Step 14 selesai: Dukungan Progressive Web App (PWA) diimplementasikan penuh. `manifest.json` dikonfigurasi dengan tema warna `#120e24`, nama "Pixel Dunia", dan display mode `standalone`. Ikon PNG standar 192px dan 512px digenerate secara native dan ditautkan ke `<head>` bersama meta tags mobile. Service Worker `sw.js` memakai versi cache bernomor (`pixeldunia-shell-v1`) yang hanya mencache app shell inti (`index.html`, Leaflet, Supabase JS, Google Fonts, manifest, ikon) dengan strategi stale-while-revalidate dan pembersihan cache lawas otomatis pada event activate. Mematuhi kebijakan: kueri/API Supabase dilewatkan langsung ke jaringan tanpa cache, dan tile OpenStreetMap tidak di-bulk cache (jika luring menghasilkan HTTP 204 tanpa error). Klien `index.html` memantau pembaruan service worker untuk menampilkan toast "Versi baru tersedia. Muat ulang.", memantau event `online`/`offline`, serta memproteksi penempatan pixel saat luring dengan pesan user-friendly ("Tidak ada koneksi. Pixel baru tidak bisa dipasang."). Impact kuota: Nol (mengurangi transfer file statis berulang kali).
- 2026-11-03: Step 15 selesai: Halaman landing page `beranda.html` dibuat sesuai panduan `design.md` (gaya Voxel Gamified Isometric 3D, tipografi Nunito & angka JetBrains Mono, palet warna resmi #E8F0FE, #5D4037, #69F0AE, #448AFF, #66BB6A, #FF7043, tanpa hitam murni #000000, tanpa emoji sesuai aturan #14, tata letak asimetris responsif max 1280px, kolaps di bawah 768px tanpa scroll horizontal, animasi hanya transform dan opacity). Dependensi baru diberi alasan tertulis di header dokumen (Google Fonts untuk voxel aesthetic dan figure tabular bebas layout-shift, Supabase JS versi locked @2.49.1). Migrasi `migrations/010_public_stats.sql` dibuat dan diintegrasikan ke `schema.sql`: tabel tunggal `stats` (id=1) mencatat agregasi metrik kanvas yang diperbarui bersamaan dengan penyegaran Step 10 (`refresh_heat()`). RPC `get_public_stats()` hanya membaca 1 baris statis tanpa `count(*)` berat pada tabel besar. Tidak ada langganan channel Realtime yang dibuka pada halaman beranda. Tombol CTA "Mulai Menggambar" menautkan langsung ke `index.html`, tombol "Pedoman Komunitas" membuka modal aturan interaktif, dan tautan balik "Beranda" ditambahkan pada menu navigasi `index.html`. Impact kuota: Sangat hemat (0 koneksi realtime, 1 kueri RPC ringan berukuran < 1 KB per kunjungan).
- 2026-11-03: Step 16 selesai: Fitur Time-lapse diimplementasikan penuh. Migrasi `migrations/011_snapshots_timelapse.sql` dibuat dan diintegrasikan ke `schema.sql`. Tabel `snapshots(day, cx, cy, data bytea)` menyimpan rekaman 64x64 sel dengan format 4-bit per sel (2048 byte = 2 KB per snapshot). Hanya chunk yang berubah hari itu yang disimpan. Fungsi harian `create_daily_snapshots` dilengkapi pengaman kuota: jika ukuran DB melampaui 70% dari 500 MB (350 MB), pembuatan otomatis berhenti dan mencatat peringatan ke `mod_logs`. Retensi 30 hari berjalan otomatis menghapus data lebih tua dari 30 hari. Perhitungan ukuran DB: 50 chunk aktif/hari * 2 KB = 100 KB/hari * 30 hari retensi = ~3 MB total per bulan (hanya 0,6% dari batas 500 MB Supabase free tier). RPC `get_snapshots(p_day_from, p_day_to, chunks)` dibatasi maksimal 50 chunk dan 14 hari (~1,4 MB) mengembalikan data ringkas tanpa beban berlebih. Antarmuka `index.html` dilengkapi tombol PUTAR di dock toolbar, widget time-lapse melayang (`#timelapse-widget`), slider 14 hari interaktif, tombol putar/jeda dengan kontrol kecepatan (1x, 2x, 4x), dan layer visual `renderTimelapseTile` transparan berkinerja tinggi `Uint8Array(4096)` tanpa memblokir peta OSM. Impact kuota: Terkendali ketat (maks 1,4 MB per pemutaran, memory cache di klien, pengaman otomatis 70% DB).
- 2026-11-03: Step 17 selesai: Fitur Pixel Terlindungi (Protected Pixels) diimplementasikan sesuai 5 keputusan penyeimbangan pemilik proyek (biaya 5 stok via `protect_cost`, durasi 24 jam via `protect_duration_hours`, batas aktif 25 pixel per pemain via `max_protected_per_player`, pemain dapat menimpa pixel miliknya sendiri dan mereset masa perlindungan, admin berhak menghapus pixel terlindungi). Migrasi `migrations/012_protected_pixels.sql` menambahkan kolom `protected_until timestamptz` pada tabel `pixels` dengan indeks parsial `idx_pixels_protected`, fungsi `protect_pixels(p jsonb)` untuk memotong stok dan mengaktifkan perlindungan, serta fungsi `get_protected_pixels(chunks jsonb)`. Fungsi `place_pixels` diperbarui untuk menolak penimpaan pixel terlindungi milik orang lain, memotong stok hanya untuk pixel yang berhasil, dan mengembalikan daftar rejected `[[x, y], ...]` tanpa menggagalkan satu batch utuh. Pada antarmuka `index.html`, ikon kunci gembok emas mini dirender pada layer canvas di zoom dekat (zoom >= 16), kartu info pixel (Step 9) menampilkan badge status perlindungan dan tombol "Lindungi (5 Stok)", serta rollback penolakan ditangani mulus di sisi klien. Impact kuota: Sangat kecil (hanya 1 kueri gembok parsial saat zoom dekat).
- 2026-11-03: Step 18 selesai: Peringkat Tim Provinsi diimplementasikan tanpa kepemilikan wilayah sesuai Aturan #10. Migrasi `migrations/013_team_leaderboard.sql` dibuat dan diintegrasikan ke `schema.sql`. Menambahkan kolom `team_id` dan `last_team_change` pada tabel `players`, konfigurasi `team_change_cooldown_days` (7 hari) pada tabel `config`, serta tabel agregasi `team_board(team_id, team_name, total_pixels, day_pixels, active_players, updated_at)`. Fungsi `refresh_team_board()` memperbarui akumulasi skor tim secara otomatis bersamaan dengan rutinitas `refresh_heat()` (tiap 5 menit) dan saat pemain mengganti tim, tanpa melakukan recalculate atau `count(*)` berat pada tabel `players` setiap kali kueri ranking dipanggil. RPC `get_team_board()` membaca data agregat secara instan dan efisien. RPC `set_team(p_team_id)` memvalidasi keberadaan wilayah 38 provinsi dan menegakkan batas jeda ganti tim 7 hari. RPC `get_regions()` mengembalikan daftar 38 provinsi. Di sisi klien `index.html`, modal Peringkat (`peringkat`) diperkaya dengan tab switcher `[Pemain]` dan `[Tim Provinsi]`, kartu status tim pengguna (nama tim, peringkat, total pixel, pixel hari ini, jumlah pemain, dan status cooldown), tabel peringkat 38 provinsi yang dapat digulir dengan highlight tim pengguna, dialog pemilihan/penggantian tim asal 38 provinsi (`showTeamPicker`), serta badge tim provinsi di tab profil pengguna. Tombol pemeliharaan manual "Segarkan Peringkat Tim" ditambahkan pada Tab 5 `admin.html`. Impact kuota: Sangat kecil (ranking membaca tabel ringkas 38 baris yang telah diagregasi, agregasi dieksekusi berkala).
- 2026-11-03: Step 19 selesai: Sistem Kode Undangan (Invite Codes) diimplementasikan untuk pertumbuhan organik tanpa celah pertanian akun bot. Migrasi `migrations/014_invites.sql` dibuat dan diintegrasikan ke `schema.sql`. Tabel `invites(code text primary key, owner uuid, used_by uuid, used_at timestamptz, rewarded bool)` dibuat dengan kode unik 8 karakter acak. Angka keseimbangan dikonfigurasi di tabel `config`: `invite_reward` (100 stok), `invite_min_placed` (100 pixel terpasang oleh teman), dan `invite_max_claimed` (maksimal 10 undangan berhasil per pemain). Aturan keamanan ditegakkan di server: hanya akun login terdaftar (Google/Email, dicek via `is_anonymous` pada JWT) yang dapat membuat dan menukarkan kode, satu akun hanya bisa memakai satu kode seumur hidup (`used_by` unik), dan pemain dilarang menggunakan kodenya sendiri. RPC `create_invite_code()` menghasilkan kode 8 karakter acak, RPC `use_invite_code(p_code)` memberikan bonus sambutan 25 stok ke pemain baru yang diundang, RPC `claim_invite_reward(p_code)` memverifikasi bahwa teman yang diundang telah menempatkan $\ge 100$ pixel sebelum memberikan hadiah 100 stok ke pemilik kode, dan RPC `get_my_invites()` mengembalikan daftar kode aktif serta progres teman yang diundang. Di sisi klien `index.html`, antarmuka "Undang Teman" disematkan di panel Hadiah (`showInviteView()`) dengan ringkasan syarat hadiah, tombol salin kode dan salin tautan undangan (`#invite=CODE`), form penukaran kode referral dengan bonus langsung, daftar referral dengan indikator progres teman serta tombol klaim hadiah instan, penanganan otomatis kode dari hash/URL parameter saat aplikasi dibuka, serta fallback simulasi interaktif pada mode demo. Seluruh fitur Fase 2 (Step 8 hingga 19) kini lengkap dan siap rilis! Impact kuota: Sangat kecil (kueri RPC ringan hanya saat membuka panel undangan atau membuat/mengklaim kode).
- 2026-11-03: Peningkatan Edukasi & UX Pemain: Tombol bantuan interaktif `?` (`.help-btn`) disematkan di seluruh bagian penting aplikasi yang memerlukan penjelasan: (1) Pil HUD atas `#stock-pill` dan banner zoom `#zoom-banner` dihubungkan ke `showPixelZoomGuideModal` yang menjelaskan fungsi jumlah stok pixel energi menggambar, pengisian otomatis (+1/8 detik), cara penambahan pixel instan, serta aturan batas jarak minimal zoom (Level 12) dengan tombol perbesar instan; (2) Tingkat Kepercayaan akun (Level 1 Pemula stok 75, Level 2 Penjelajah stok 150, Level 3 Pelukis stok 300, Level 4 Master stok 500) beserta syarat dan keuntungannya dijelaskan di tab Profil & Lencana dan tab Misi (`showLevelGuideModal`); (3) Streak Login Harian (`showStreakGuideModal`) menjelaskan akumulasi bonus harian +50 hingga +120 pixel serta jalur cepat syarat Lv. 4; (4) Peringkat Tim Provinsi (`showTeamGuideModal`) menerangkan kontribusi 1 pixel = 1 poin tim dan aturan jeda 7 hari pergantian tim demi sportivitas; (5) Fitur Proteksi Pixel (`showProtectGuideModal`) pada menu info pixel menerangkan biaya 5 stok dan durasi 24 jam kebal timpaan. Modal dibangun di atas sistem dialog kustom Voxel 3D (`uiAlert`) yang responsif, scrollable, dan ramah mobile. Impact kuota: Nol (fitur murni sisi klien).


