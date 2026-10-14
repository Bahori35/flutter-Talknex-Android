-- ==============================================================================
-- DİĞER 3 SUNUCUNUN ANA SUNUCUDAKİ MARIADB'YE BAĞLANMASI İÇİN İZİN VERME
-- ==============================================================================
-- Bu komutu Ana Sunucu'daki MariaDB / MySQL konsolunda (HeidiSQL, phpMyAdmin, DBeaver veya CMD) çalıştırın.

-- 1. YÖNTEM: Tüm ek sunuculara izin ver (En kolayı)
CREATE USER IF NOT EXISTS 'root'@'%' IDENTIFIED BY 'guclu_veritabani_sifreniz';
GRANT ALL PRIVILEGES ON chat_app_db.* TO 'root'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;

-- 2. YÖNTEM: Yalnızca belirli sunucu IP'lerine izin ver (Daha Güvenli)
-- Örneğin Ek Sunucu 2 (192.168.1.102), Sunucu 3 (192.168.1.103), Sunucu 4 (192.168.1.104) için:
-- GRANT ALL PRIVILEGES ON chat_app_db.* TO 'talknex_user'@'192.168.1.102' IDENTIFIED BY 'sifreniz';
-- GRANT ALL PRIVILEGES ON chat_app_db.* TO 'talknex_user'@'192.168.1.103' IDENTIFIED BY 'sifreniz';
-- GRANT ALL PRIVILEGES ON chat_app_db.* TO 'talknex_user'@'192.168.1.104' IDENTIFIED BY 'sifreniz';
-- FLUSH PRIVILEGES;
