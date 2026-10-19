# Talknex - Güvenli, Uçtan Uca Şifreli Sesli, Görüntülü ve Anlık Mesajlaşma Uygulaması

<p align="center">
  <img src="https://raw.githubusercontent.com/Bahori35/flutter-Talknex-Android/main/android/app/src/main/res/mipmap-xxxhdpi/launcher_icon.png" width="100" alt="Talknex Logo" />
</p>

<p align="center">
  <b>Talknex</b>, Flutter ile geliştirilmiş; uçtan uca şifreleme (E2EE), gerçek zamanlı canlı konum takibi, WhatsApp benzeri 24 saatlik durum/hikaye yönetimi, grup sohbetleri ve WebRTC tabanlı HD sesli/görüntülü arama özelliklerine sahip yeni nesil bir mobil iletişim platformudur.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white" alt="Flutter" />
  <img src="https://img.shields.io/badge/Dart-3.x-0175C2?logo=dart&logoColor=white" alt="Dart" />
  <img src="https://img.shields.io/badge/WebRTC-P2P%20Call-333333?logo=webrtc&logoColor=white" alt="WebRTC" />
  <img src="https://img.shields.io/badge/Backend-Go%20%26%20MariaDB-00ADD8?logo=go&logoColor=white" alt="Go Backend" />
  <img src="https://img.shields.io/badge/Socket.IO-Realtime-010101?logo=socketdotio&logoColor=white" alt="Socket.io" />
  <img src="https://img.shields.io/badge/Security-AES--256--GCM-success" alt="E2EE" />
  <img src="https://img.shields.io/badge/Platform-Android-3DDC84?logo=android&logoColor=white" alt="Android" />
</p>

---

## 🌟 Öne Çıkan Özellikler

### 🛡️ 1. Uçtan Uca Şifreleme (E2EE - End-to-End Encryption)
- **AES-256-GCM & PBKDF2:** Tüm birebir mesajlar ve medya bağlantıları cihazda şifrelenir (`encryptText`), yalnızca alıcının cihazında çözülür (`decryptText`).
- **Sıfır Bilgi Mimarisi:** Sunucu ve veri tabanı sadece şifrelenmiş baytları taşır; üçüncü taraflar veya sunucu mesaj içeriklerini okuyamaz.

### 📍 2. Kesintisiz Canlı Konum Takibi (WhatsApp Benzeri)
- **Arka Plan Ön Plan Servisi (Foreground Service):** Uygulama kapansa veya simge durumuna küçülse dahi Android bildirim çubuğunda çalışan canlı konum akışı.
- **WhatsApp Tarzı Üst Bildirim Bandı:** Sohbetin üst kısmında canlı konum paylaşıldığı an çıkan dokunulabilir bildirim bandı (`"Canlı konumunuzu paylaşıyorsunuz"` / `"X kişisi canlı konumunu paylaşıyor"`). Tek dokunuşla tam ekran haritaya geçiş.
- **Akıllı Otomatik Takip Modu:** Araç sürerken veya hareket halindeyken haritayı otomatik olarak hareket eden kullanıcının merkezinde tutma, pusula yönü ve hız (km/s) göstergesi.
- **Manuel Gezinme ve Yeniden Ortala Sayacı:** Harita kaydırıldığında 4 saniye sonra otomatik olarak araca geri odaklanan sayaçlı buton.
- **Tek Dokunuşla Paylaşımı Durdurma:** Hem mesaj baloncuğundan hem de üst banttan güvenli ve kalıcı sonlandırma.

### 📸 3. WhatsApp Benzeri Durumlar ve Hikayeler (Stories / Status)
- **Zengin Hikaye Oluşturma:** Metin, Ses Kaydı, Video, Fotoğraf, Müzik, Yerleşim ve Kamera seçenekleri.
- **Galeri & Albüm Seçici:** Cihazdaki medya dosyalarını *Son Kullanılanlar, İndirilenler, Ekran Görüntüleri, Kamera, WhatsApp Medyası* gibi kategorilere göre filtreleyebilme.
- **Video Önizleme & Süre Bilgisi:** Küçük resimler (thumbnail) ve video süreleri ile kolay seçim.
- **Dahili Video Düzenleyici:** Video kırpma, filtreleme ve metin ekleme araçları.
- **24 Saat Sonra Otomatik Silinme & Görüntüleyenler Listesi.**

### 💬 4. Güçlü Birebir ve Grup Sohbetleri
- **Anlık Mesajlaşma:** Go Socket.io tabanlı ultra düşük gecikmeli mesaj iletimi.
- **İletildi ve Okundu Bilgisi:** Gri çift tık (iletildi) ve mavi çift tık (okundu) mekanizması.
- **Sesli Mesaj Kaydı:** Mikrofon genlik dalgası (waveform) ve canlı sayaç eşliğinde ses kaydı gönderme.
- **Medya & Dosya Paylaşımı:** Fotoğraf, video, ses dosyası, PDF/doküman, GIF ve sticker desteği.
- **Grup Sohbetleri:** Çoklu katılımcılı grup odaları, grup yöneticisi atama, grup resmi ve bilgileri yönetimi.

### 📞 5. WebRTC Destekli HD Sesli ve Görüntülü Görüşme
- **P2P Doğrudan Bağlantı:** WebRTC STUN/TURN üzerinden düşük gecikmeli, yüksek kaliteli ses ve video görüşmesi.
- **Kullanışlı Kontroller:** Ön/arka kamera değiştirme, mikrofon susturma (mute), video açma/kapatma.
- **PIP (Picture-in-Picture):** Kendi görüntünüzü hareketli küçük pencerede izlerken karşı tarafı tam ekranda görme.
- **Gelen Çağrı Ekranı:** Uygulama içi ve sistem bildirimli arama cevaplama / reddetme arayüzü.

### 🎨 6. Modern Neo-Dark Tasarım (UI/UX)
- Modern koyu tema, özel neon vurgular ve yumuşak geçiş efektleri.
- WhatsApp ve Telegram'ın en sevilen ergonomik kullanım alışkanlıklarını bir araya getiren sezgisel arayüz.

---

## 📁 Proje Dizin Yapısı

```
lib/
├── constants/
│   └── app_colors.dart             # Talknex renk paleti, degradeler ve tasarım sabitleri
├── models/
│   ├── user_model.dart             # Kullanıcı modeli (çevrimiçi durum, avatar, bio)
│   ├── message_model.dart          # Mesaj modeli (metin, medya, konum, türler)
│   ├── call_model.dart             # Sesli/görüntülü çağrı sinyal modeli
│   └── story_model.dart            # Hikaye ve durum veri modelleri
├── services/
│   ├── custom_auth_service.dart    # Kullanıcı kimlik doğrulama & oturum servisi
│   ├── custom_chat_service.dart    # MariaDB REST API mesajlaşma & hikaye servisi
│   ├── socket_service.dart         # Go Socket.io anlık mesajlaşma & sinyalleşme
│   ├── encryption_service.dart     # AES-256-GCM Uçtan Uca Şifreleme (E2EE)
│   ├── live_location_service.dart  # Arka plan Foreground canlı GPS servisi
│   ├── custom_signaling_service.dart # WebRTC çağrı sinyalleşme motoru
│   ├── voice_record_service.dart   # Dalga formlu ses kayıt servisi
│   └── notification_service.dart   # Yerel ve FCM anlık bildirim servisi
├── screens/
│   ├── auth/
│   │   ├── login_screen.dart       # Giriş Yap ekranı
│   │   └── register_screen.dart    # Kayıt Ol ekranı
│   ├── home/
│   │   └── home_screen.dart        # Ana Sekmeler (Sohbetler, Durumlar, Aramalar)
│   ├── chat/
│   │   ├── chat_screen.dart        # Birebir sohbet odası ve canlı konum kontrolü
│   │   ├── live_location_screen.dart # Tam ekran interaktif canlı GPS haritası
│   │   ├── location_picker_screen.dart # Konum ve Canlı Konum paylaşım seçici
│   │   ├── camera_screen.dart      # Dahili kamera (Fotoğraf / Video çekimi)
│   │   ├── video_editor_screen.dart # Video düzenleme ve kırpma arayüzü
│   │   └── video_player_screen.dart # Tam ekran video oynatıcı
│   ├── group/
│   │   ├── group_chat_screen.dart  # Grup mesajlaşma odası
│   │   ├── create_group_screen.dart# Yeni grup oluşturma ve üye seçimi
│   │   └── group_info_screen.dart  # Grup ayarları, medya galerisi ve üyeler
│   ├── story/
│   │   ├── add_story_screen.dart   # WhatsApp tarzı 6 modlu durum ekleme ekranı
│   │   └── story_view_screen.dart  # Hikaye izleme ve ilerleme çubuğu ekranı
│   ├── call/
│   │   ├── call_screen.dart        # WebRTC Görüntülü ve Sesli arama odası
│   │   └── incoming_call_dialog.dart # Gelen arama kabul/ret modalı
│   └── profile/
│       └── profile_screen.dart     # Profil düzenleme, durum ve hesap ayarları
└── main.dart                       # Uygulama başlangıcı ve servis başlatıcıları
```

---

## 🛠️ Teknoloji Yığını

| Alan | Kullanılan Teknolojiler |
|---|---|
| **Mobil İstemci** | Flutter 3.x, Dart 3.x |
| **Harita & Konum** | Flutter Map (OpenStreetMap), LatLong2, Geolocator |
| **Gerçek Zamanlı İletişim** | Socket.IO Client, WebRTC (`flutter_webrtc`) |
| **Şifreleme & Güvenlik** | AES-256-GCM, PBKDF2 (`encrypt`), Biometrics |
| **Arka Plan Servisi** | Android Foreground Service (`GeolocatorLocationService`) |
| **Medya & Kamera** | Camera, Video Player, Chewie, Easy Video Editor, AudioPlayers |
| **Backend & Veritabanı** | Go (Golang) Socket Sunucusu, MariaDB SQL REST API |
| **Sürekli Entegrasyon (CI)** | GitHub Actions (Otomatik Release APK derleme) |

---

## 🚀 Başlangıç ve Kurulum

### Gereksinimler
- Flutter SDK (>= 3.0.0)
- Android Studio / VS Code
- Android Cihaz veya Emülatör (API 26+)

### Adımlar

1. **Depoyu Klonlayın:**
   ```bash
   git clone https://github.com/Bahori35/flutter-Talknex-Android.git
   cd flutter-Talknex-Android
   ```

2. **Bağımlılıkları Yükleyin:**
   ```bash
   flutter pub get
   ```

3. **Uygulamayı Çalıştırın:**
   ```bash
   flutter run
   ```

4. **Release APK Üretimi:**
   ```bash
   flutter build apk --release
   ```

---

## 🔒 İzinler (Android Manifest)

Uygulamanın eksiksiz çalışabilmesi için `android/app/src/main/AndroidManifest.xml` dosyasında aşağıdaki temel izinler yapılandırılmıştır:
- `ACCESS_FINE_LOCATION` & `ACCESS_COARSE_LOCATION`: Anlık ve canlı GPS konumu için
- `ACCESS_BACKGROUND_LOCATION`: Arka planda kesintisiz canlı konum yayını için
- `FOREGROUND_SERVICE_LOCATION`: Android 14+ ön plan servis bildirimi için
- `CAMERA` & `RECORD_AUDIO`: WebRTC aramaları, hikaye ve kamera çekimleri için
- `READ_MEDIA_IMAGES` & `READ_MEDIA_VIDEO`: Galeri ve durum seçimi için

---

## 📄 Lisans

Bu proje özel olarak geliştirilmiş olup tüm hakları saklıdır.
