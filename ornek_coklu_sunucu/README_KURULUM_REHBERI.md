# 4 Sunuculu Talknex Yük Dengeleme ve Kümeleme Mimarisi

Bu klasör, uygulamanızı **500.000 kullanıcı** kapasitesine ulaştırmak için 1 Ana Sunucu + 3 Ek Sunucu (toplam 4 Go backend) kurulumunun birebir çalışan örnek ayarlarını içerir.

---

## 📂 Klasör İçeriği

- **`ana_sunucu/` (Sunucu 1 - Master)**:
  - `nginx.conf`: 4 sunucuya trafiği bölen Nginx Load Balancer ayarı.
  - `.env`: Ana sunucuda çalışan Go örneğinin yapılandırması.
  - `mariadb_izinler.sql`: Diğer 3 sunucunun MariaDB'ye bağlanabilmesi için çalıştırılacak SQL komutları.
  - `redis_ayar_notlari.txt`: Redis'i dış sunuculara açma ayarı.

- **`ek_sunucu_2/` (Sunucu 2)**:
  - `.env`: 2. sunucunun ayarları (Ana sunucunun DB ve Redis'ine bağlanır).
  - `BASLAT.bat`: 2. sunucuyu başlatan betik.

- **`ek_sunucu_3/` (Sunucu 3)**:
  - `.env`: 3. sunucunun ayarları.
  - `BASLAT.bat`: 3. sunucuyu başlatan betik.

- **`ek_sunucu_4/` (Sunucu 4)**:
  - `.env`: 4. sunucunun ayarları.
  - `BASLAT.bat`: 4. sunucuyu başlatan betik.

---

## 🚀 Kurulum Adımları (Özet)

### 1. Adım: Ana Sunucuda Veritabanı ve Redis İznini Açın
1. Ana sunucuda MySQL/HeidiSQL/phpMyAdmin açın ve `ana_sunucu/mariadb_izinler.sql` içindeki komutu çalıştırın.
2. Ana sunucudaki `redis.conf` dosyasında `bind 0.0.0.0` ve `protected-mode no` yapıp Redis servisini yeniden başlatın.

### 2. Adım: Ana Sunucuda Nginx'i Güncelleyin
- `ana_sunucu/nginx.conf` dosyasındaki IP adreslerini kendi sunucu IP'lerinizle değiştirin.
- Ana sunucudaki Nginx klasörüne (`nginx/conf/nginx.conf`) kopyalayıp Nginx'i yeniden başlatın:
  ```cmd
  nginx -s reload
  ```

### 3. Adım: Ek Sunucuları Başlatın
- `ek_sunucu_2`, `ek_sunucu_3` ve `ek_sunucu_4` klasörlerindeki `.env` dosyalarını yeni kiraladığınız sunuculara atın.
- Her yeni sunucunun içine `talknex_server.exe` dosyasını koyun ve `BASLAT.bat` ile çalıştırın.

Artık gelen 500 bin kullanıcı 4 sunucu arasında pürüzsüzce paylaştırılacaktır!
