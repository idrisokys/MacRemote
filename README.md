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
Uygulama menü çubuğunda bir kumanda ikonuyla çalışır. Pencereyi kapatsan da arka planda çalışmaya devam eder (kapatmak için menü çubuğu ikonu → **Çıkış**).

1. Kumandayı Mac'e Bluetooth ile eşleştir.
2. **Atamayı başlat**'a bas (pencereden veya menü çubuğu ikonundan). Atama sırasında ikonun yanında ● görünür.
3. Kumandada bir tuşa bas, pencerede o tuşun satırı belirir.
4. Satırdaki **ilk kutuya** tıkla ve klavyeden bir tuş bas. Tek kutu doluysa kumanda tuşu o tuş gibi çalışır.
5. **İkinci kutuya** da tıklayıp bir tuş basarsan 1. tuş basılı tutulup 2. tuşa basılır. Örnek: 1. kutu `⌘ Command`, 2. kutu `V` → **Yapıştır**.
6. İşin bitince **Atamayı bitir**'e bas. Boş satırlar silinir ve bundan sonra yalnızca atanan tuşlar çalışır, başka tuşlar listede görünmez.

Atama modundayken kumandadaki tuşlar atamalarını çalıştırmaz, böylece kutuları doldururken yanlışlıkla işlem tetiklenmez.

## Fare modu
Her satırdaki açılır menüden klavye tuşu yerine bir **fare eylemi** seçebilirsin:
sol tık, sağ tık, orta tık, çift tık, tekerlek yukarı/aşağı ve imleci yukarı/aşağı/sola/sağa hareket ettirme.

**Uygulama kısayolu:** menüden **🚀 Uygulama aç**'ı seçip bir `.app` dosyası seç. O kumanda tuşu uygulamayı açar (zaten açıksa öne getirir). Uygulamayı değiştirmek için satırdaki uygulama düğmesine tıkla.

- **İmleç hızı** ve **Tekerlek hızı** çubuklarıyla hızı ayarlarsın (imleç için piksel/kare değeridir).
- Hareket ve tekerlek tuşu basılı tutulduğu sürece devam eder ve ilk 0,7 saniyede yavaştan hızlıya kademeli hızlanır, böylece küçük hareketler de yapabilirsin.
- Tekerlek yönü ters çalışıyorsa (macOS'un "Doğal kaydırma" ayarı yüzünden) yukarı/aşağı atamalarını yer değiştir.
- Kumanda tuşu bırakma sinyali göndermezse hareket en geç 3 saniye sonra durur.

## Nasıl çalışıyor
Kumandalar çoğu zaman tuşları klavye olarak değil HID medya/tüketici sinyali olarak gönderir. Bu uygulama IOKit HID ile doğrudan cihazı dinler, bu yüzden Mac klavyesi etkilenmez (Apple cihazları yok sayılır). Atanan tuşlar `CGEvent` ile sisteme gönderilir.

## Bilinen sınırlamalar
- Kumanda tuşunun orijinal işlevi engellenmez (ör. ses tuşu hem sesi değiştirir hem atamanı çalıştırır). Menü/ok/OK tuşlarında genelde sorun olmaz.
- Tuş basılı tutulunca tekrarlamaz, her basış tek vuruştur.
- Atamalar yalnızca uygulama çalışırken (menü çubuğunda göründüğü sürece) geçerlidir.
- Harici (Apple dışı) Bluetooth klavyeler de satır olarak görünür.

## Lisans
MIT, ayrıntılar için `LICENSE` dosyasına bak.

## İkon
`icon/make_icon.py` ile (Pillow + numpy) `icon/icon_1024.png` yeniden üretilebilir. `build.sh` bu dosyadan `AppIcon.icns` oluşturur.
