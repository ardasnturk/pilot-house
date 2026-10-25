# Raspberry Pi'ye Pilothouse kurulumu: Claude Code için prompt

Raspberry Pi'de (SSH ile bağlanıp) `claude` çalıştır ve aşağıdaki metnin tamamını
yapıştır.

---

Bu Raspberry Pi'ye **Pilothouse**'u kurmanı istiyorum. Pilothouse, iPhone'umdaki
Pilothouse uygulamasından bu makinedeki Claude Code'u kullanmamı sağlıyor. Sunucu
Docker içinde çalışacak ve Node.js, Expo ve web projeleri geliştirebilecek. Kodu ve
kurulum betiği şu depoda: https://github.com/ardasnturk/pilot-house (branch:
`raspberry-pi-linux-server`; bu branch main'e birleştirildiyse `main`).
Ayrıntılı belge: depodaki `linux/README.md`.

Adım adım ilerle. Her adımdan sonra kısaca ne olduğunu söyle. Bir şey ters
giderse önce nedenini bul, sonra düzelt; tahminle ilerleme.

1. **Ön kontrol.** `uname -m`, `/etc/os-release`, `free -h`, `df -h ~`, `id` ve
   `hostname -I` çıktılarına bak. Sistem 64 bit olmalı (`aarch64` veya `x86_64`).
   32 bit ise (`armv7l`) dur ve bana söyle. En az 8 GB boş disk gerekli. Bellek
   4 GB'tan azsa 4 GB swap ekle. Komutları root olarak değil, kendi kullanıcımla
   çalıştır; gerektiğinde `sudo` kullan.

2. **Kodu indir.** `git` yoksa kur. Depoyu `~/pilot-house` klasörüne
   `raspberry-pi-linux-server` branch'iyle klonla. Klasör zaten varsa o branch'e
   geç ve `git pull --ff-only` yap. Depo erişilemiyorsa (özel depo), bana
   `gh auth login` veya bir token sor.

3. **Kurulum betiğini çalıştır:** `~/pilot-house/linux/install.sh`. Betik
   şunları yapar: Docker'ı ve Compose eklentisini kurar, `linux/.env` dosyasını
   oluşturur, `~/projects` ve `~/.pilothouse` klasörlerini açar, imajı derler,
   konteyneri başlatır ve Avahi ile Bonjour yayını açar. İlk derleme Pi'de
   15-40 dakika sürer. Bu yüzden betiği arka planda çalıştır, çıktısını
   `~/pilothouse-install.log` dosyasına yaz ve bitene kadar birkaç dakikada bir
   bak. Betik beni docker grubuna eklediyse grup bir sonraki girişte geçerli
   olur; o zamana kadar `docker` komutlarını `sudo` ile çalıştır.
   - Derleme "Killed" veya bellek hatasıyla durursa 4 GB swap ekle
     (`/swapfile`, `/etc/fstab` kaydıyla) ve betiği tekrar çalıştır.
   - Docker Hub "429 Too Many Requests" verirse birkaç dakika bekleyip tekrar dene.
   - Başka bir hata olursa log'un ilgili kısmını göster ve düzelt. Betikte bir
     hata bulursan nedenini açıklayarak düzelt.

4. **Doğrula.** `docker exec pilothouse pilothouse-server status` çıktısında:
   - **Addresses** satırında Pi'nin yerel ağ adresi olmalı (ör. `192.168.x.x`).
     Docker'ın `172.x` adresi olmamalı. Adres yanlışsa `~/pilot-house/linux/.env`
     dosyasına `PILOTHOUSE_ADDRESSES=<Pi'nin LAN IP'si>` ekle ve
     `docker compose -f ~/pilot-house/linux/docker-compose.yml up -d` çalıştır.
   - `ufw` etkinse 47823/tcp açık olmalı. Expo (8081), Vite (5173) ve Next.js
     (3000) portlarını yalnızca yerel ağa açmayı bana öner, onayımla yap.
   - `docker logs pilothouse` çıktısında hata olmamalı.
   - Konteynerde `node --version` ve `claude --version` çalışmalı
     (`docker exec pilothouse …`).
   Ayrıca Pi'nin IP adresinin değişmemesi için router'da DHCP rezervasyonu
   yapmamı hatırlat.

5. **Claude girişi (benim yapmam gerekiyor).** Konteynerdeki Claude Code'a bir
   kez giriş yapılmalı. Senin terminalin etkileşimli olmadığı için bunu ben
   yapacağım. Bana şu iki yolu açıkla:
   - a) Kendi terminalimde `docker exec -it pilothouse claude` çalıştırıp
     tarayıcıdaki bağlantıdan giriş yapmak, sonra `/exit` yazmak.
   - b) `claude setup-token` ile uzun ömürlü bir token alıp
     `~/pilot-house/linux/.env` dosyasına `CLAUDE_CODE_OAUTH_TOKEN=...` olarak
     eklemek, sonra konteyneri yeniden başlatmak. Token'ı benden sohbete
     yapıştırmamı isteme; dosyaya kendim yazacağım.
   Hangisini seçtiğimi söyleyince `pilothouse-server status` ile Claude'un
   "signed in" göründüğünü doğrula. Host'taki kendi `~/.claude` giriş
   bilgilerini konteynere kopyalama.

6. **Telefonu eşleştir (benim yapmam gerekiyor).** Bana kendi terminalimde
   `docker exec -it pilothouse pilothouse-server pair` çalıştırmamı söyle. Bu
   komut QR kodu gösterir. iPhone'da Pilothouse → **Pair with Your Mac** →
   **Scan the Pairing Code** ile kodu tarayacağım; Yerel Ağ izni istenirse
   vereceğim. İstersen `pilothouse-server pair --no-wait` ile bağlantı metnini
   de göster; onu telefonda **Paste a Pairing Link Instead** ile
   yapıştırabilirim. Eşleştirdikten sonra `pilothouse-server devices` ile
   doğrula.

7. **İsteğe bağlı: evin dışından erişim.** Tailscale kurmak isteyip istemediğimi
   sor. İstersem Pi'ye kur (`curl -fsSL https://tailscale.com/install.sh | sh`,
   `sudo tailscale up`; giriş bağlantısını bana ver), sonra `status` çıktısında
   100.x adresinin göründüğünü kontrol et ve konteyneri yeniden başlat.
   Telefonda Tailscale uygulamasını kurup uygulamanın ayarlarında **Use
   Tailscale when away** seçeneğini açmamı söyle.

8. **Son kontrol ve özet.** Şunları yazarak bitir:
   - Pi'nin adresi ve portu
   - Projelerin klasörü (`~/projects`)
   - Günlük komutlar: log'lar, yeniden başlatma,
     `~/pilot-house/linux/install.sh update` ile güncelleme, `status`, `pair`
   - Telefondan ilk deneme için örnek bir istek, ör. *"~/projects/deneme
     klasöründe Vite + React ile bir sayaç sayfası yap ve telefonumdan
     açabileceğim şekilde başlat"*.

Kurallar: `PILOTHOUSE_ALLOW_BYPASS_PERMISSIONS` ayarını ben istemedikçe açma.
Pilothouse'un portunu internete açma (router'da port yönlendirme yapma). Sırları
(token'lar, API anahtarları) ekrana yazdırma.
