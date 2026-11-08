# KumandaMac

Bluetooth kumandanın (ör. eski Xiaomi Mi TV Stick kumandası) tuşlarını Mac'te algılayıp istediğin **tuşa veya tuş kombinasyonuna** (ör. `⌘V`) çeviren küçük, tek dosyalık macOS uygulaması.

## Özellikler
- Kumandada bastığın tuşu otomatik algılar
- Yerine tek tuş veya kombinasyon (⌘ ⌥ ⌃ ⇧ + tuş) atayabilirsin
- Atamalar kalıcıdır ve listeden silinebilir
- Harici bağımlılık yok, sadece Swift ve AppKit
- Apple Silicon ve Intel Mac'lerde çalışır (evrensel derleme)

## GitHub'da derleme (kurulum gerektirmez)
Repo her `main` push'unda GitHub Actions ile otomatik derlenir.

1. Repo sayfasında **Actions** sekmesine gir, son çalışmayı aç.
2. Sayfanın altındaki **Artifacts** bölümünden `KumandaMac-macos` dosyasını indir ve zip'ten çıkar.

Kalıcı bir sürüm yayınlamak için etiket at, `.app` dosyası **Releases** sayfasına otomatik eklenir:
```bash
git tag v1.0
git push origin v1.0
```
Elle başlatmak için: Actions → Build → **Run workflow**.

## İlk açılış (Gatekeeper)
Uygulama Apple geliştirici hesabıyla imzalanmadığı için macOS ilk açılışta engelleyebilir. Şunlardan birini yap:
- Uygulamaya sağ tık → **Aç** → **Aç**, veya
- Terminal'de: `xattr -dr com.apple.quarantine KumandaMac.app`

Sonra **Sistem Ayarları → Gizlilik ve Güvenlik** altında **Erişilebilirlik** ve **Giriş İzleme** bölümlerinde *Kumanda Ayar*'ı etkinleştirip uygulamayı yeniden başlat.

## Yerelde derleme
Xcode Command Line Tools gerekir (`xcode-select --install`).
```bash
./build.sh
open build/KumandaMac.app
```

## Kullanım
1. Kumandayı Mac'e Bluetooth ile eşleştir.
2. Uygulamayı aç ve kumandada bir tuşa bas, pencerede o tuşun satırı belirir.
3. Satırdaki **ilk kutuya** tıkla ve klavyeden bir tuş bas. Tek kutu doluysa kumanda tuşu o tuş gibi çalışır.
4. **İkinci kutuya** da tıklayıp bir tuş basarsan 1. tuş basılı tutulup 2. tuşa basılır. Örnek: 1. kutu `⌘ Command`, 2. kutu `V` → **Yapıştır**.
5. Atamalar otomatik kaydedilir. Satırı **Sil** ile kaldırabilirsin.

## Nasıl çalışıyor
Kumandalar çoğu zaman tuşları klavye olarak değil HID medya/tüketici sinyali olarak gönderir. Bu uygulama IOKit HID ile doğrudan cihazı dinler, bu yüzden Mac klavyesi etkilenmez (Apple cihazları yok sayılır). Atanan tuşlar `CGEvent` ile sisteme gönderilir.

## Bilinen sınırlamalar
- Kumanda tuşunun orijinal işlevi engellenmez (ör. ses tuşu hem sesi değiştirir hem atamanı çalıştırır). Menü/ok/OK tuşlarında genelde sorun olmaz.
- Tuş basılı tutulunca tekrarlamaz, her basış tek vuruştur.
- Atamalar yalnızca uygulama açıkken çalışır.
- Harici (Apple dışı) Bluetooth klavyeler de satır olarak görünür.

## Lisans
MIT, ayrıntılar için `LICENSE` dosyasına bak.
