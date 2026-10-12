import os
import sys
import json
import base64
import hashlib
import tempfile
import subprocess
import pymysql
import tkinter as tk
from tkinter import ttk, messagebox, filedialog
from datetime import datetime
from PIL import Image, ImageTk
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.backends import default_backend

# ----------------- CONFIGURATION & CONSTANTS -----------------
APP_SALT = "Talknex_Secure_E2EE_2026_Key"
DB_HOST = os.getenv("DB_HOST", "localhost")
DB_USER = os.getenv("DB_USER", "root")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")
DB_NAME = os.getenv("DB_NAME", "chat_app_db")
DB_PORT = int(os.getenv("DB_PORT", 3306))

CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(CURRENT_DIR)
UPLOADS_DIR = r"C:\talknex_uploads" if os.path.exists(r"C:\talknex_uploads") else os.path.join(PROJECT_ROOT, "uploads")


# ----------------- CRYPTO ENGINE (AES-256-CBC) -----------------
def get_conversation_key(user1_id, user2_id):
    """Generates the deterministic 256-bit AES key for the user pair."""
    pair = sorted([str(user1_id).strip(), str(user2_id).strip()])
    combined = f"{pair[0]}_e2ee_{pair[1]}_{APP_SALT}".encode("utf-8")
    return hashlib.sha256(combined).digest()


def decrypt_text(cipher_text: str, user1_id, user2_id) -> str:
    """Decrypts text formatted as ENC::<base64_iv>::<base64_ciphertext>."""
    if not cipher_text or not cipher_text.startswith("ENC::"):
        return cipher_text

    try:
        parts = cipher_text.split("::")
        if len(parts) < 3:
            return cipher_text
        iv = base64.b64decode(parts[1])
        ciphertext = base64.b64decode(parts[2])
        key = get_conversation_key(user1_id, user2_id)

        cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
        decryptor = cipher.decryptor()
        padded_plaintext = decryptor.update(ciphertext) + decryptor.finalize()

        # Unpad PKCS7
        pad_len = padded_plaintext[-1]
        if 1 <= pad_len <= 16:
            plaintext = padded_plaintext[:-pad_len]
        else:
            plaintext = padded_plaintext

        return plaintext.decode("utf-8", errors="replace")
    except Exception as e:
        return f"[Şifre Çözülemedi: {e}] {cipher_text}"


def decrypt_file_bytes(encrypted_bytes: bytes, user1_id, user2_id) -> bytes:
    """Decrypts binary file bytes (IV 16 bytes + AES-CBC ciphertext)."""
    if len(encrypted_bytes) <= 16:
        return encrypted_bytes

    try:
        iv = encrypted_bytes[:16]
        ciphertext = encrypted_bytes[16:]
        key = get_conversation_key(user1_id, user2_id)

        cipher = Cipher(algorithms.AES(key), modes.CBC(iv), backend=default_backend())
        decryptor = cipher.decryptor()
        padded = decryptor.update(ciphertext) + decryptor.finalize()

        pad_len = padded[-1]
        if 1 <= pad_len <= 16:
            return padded[:-pad_len]
        return padded
    except Exception:
        return encrypted_bytes


# ----------------- DATABASE HELPERS -----------------
def get_db():
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        port=DB_PORT,
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )


# ----------------- ADMIN GUI APPLICATION -----------------
class TalknexAdminApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Talknex - Güvenlik & Denetim Admin Paneli (E2EE Çözücü)")
        self.geometry("1240x800")
        self.minsize(1050, 650)
        self.configure(bg="#1E1E2F")

        self.users = []
        self.selected_user = None
        self.current_messages = []
        self.preview_image_tk = None

        self._setup_styles()
        self._build_layout()
        self.load_users()

    def _setup_styles(self):
        self.style = ttk.Style(self)
        self.style.theme_use("clam")

        # Dark theme colors
        self.style.configure(
            "TFrame", background="#1E1E2F"
        )
        self.style.configure(
            "Card.TFrame", background="#27293D", relief="flat"
        )
        self.style.configure(
            "TLabel", background="#1E1E2F", foreground="#E1E1E6", font=("Segoe UI", 10)
        )
        self.style.configure(
            "Header.TLabel", background="#27293D", foreground="#FFFFFF", font=("Segoe UI", 14, "bold")
        )
        self.style.configure(
            "SubHeader.TLabel", background="#27293D", foreground="#00D2D3", font=("Segoe UI", 11, "bold")
        )
        self.style.configure(
            "TButton", font=("Segoe UI", 10, "bold"), background="#00D2D3", foreground="#000000"
        )
        self.style.map("TButton", background=[("active", "#01A3A4")])

        # Treeview styling
        self.style.configure(
            "Treeview",
            background="#2E3047",
            foreground="#FFFFFF",
            fieldbackground="#2E3047",
            rowheight=28,
            font=("Segoe UI", 9),
        )
        self.style.configure(
            "Treeview.Heading",
            background="#1E1E2F",
            foreground="#00D2D3",
            font=("Segoe UI", 10, "bold"),
        )
        self.style.map(
            "Treeview",
            background=[("selected", "#00D2D3")],
            foreground=[("selected", "#000000")],
        )

    def _build_layout(self):
        # Top Header Bar
        header_frame = tk.Frame(self, bg="#27293D", height=60, padx=20, pady=10)
        header_frame.pack(fill=tk.X)

        title_lbl = tk.Label(
            header_frame,
            text="🛡️ Talknex Adli Bilişim & Admin Denetim Paneli",
            bg="#27293D",
            fg="#FFFFFF",
            font=("Segoe UI", 16, "bold"),
        )
        title_lbl.pack(side=tk.LEFT)

        subtitle_lbl = tk.Label(
            header_frame,
            text="Yetkili Güvenlik & Denetim Birimi (E2EE Veri Çözme Modülü)",
            bg="#27293D",
            fg="#00D2D3",
            font=("Segoe UI", 10),
        )
        subtitle_lbl.pack(side=tk.LEFT, padx=15)

        refresh_btn = tk.Button(
            header_frame,
            text="🔄 Yenile",
            bg="#00D2D3",
            fg="#000000",
            font=("Segoe UI", 9, "bold"),
            relief=tk.FLAT,
            padx=12,
            pady=4,
            command=self.load_users,
        )
        refresh_btn.pack(side=tk.RIGHT)

        # Main Paned Window (Split horizontal)
        main_paned = tk.PanedWindow(self, orient=tk.HORIZONTAL, bg="#1E1E2F", sashwidth=4)
        main_paned.pack(fill=tk.BOTH, expand=True, padx=12, pady=12)

        # LEFT PANE: Users List & Filter
        left_frame = tk.Frame(main_paned, bg="#27293D", padx=10, pady=10)
        main_paned.add(left_frame, width=380)

        user_title = tk.Label(
            left_frame,
            text="👥 Kayıtlı Kullanıcılar",
            bg="#27293D",
            fg="#FFFFFF",
            font=("Segoe UI", 12, "bold"),
        )
        user_title.pack(anchor="w", pady=(0, 6))

        # Search User Input
        search_frame = tk.Frame(left_frame, bg="#27293D")
        search_frame.pack(fill=tk.X, pady=(0, 8))

        self.user_search_var = tk.StringVar()
        self.user_search_var.trace("w", lambda *args: self._filter_users())
        search_entry = tk.Entry(
            search_frame,
            textvariable=self.user_search_var,
            bg="#1E1E2F",
            fg="#FFFFFF",
            insertbackground="#FFFFFF",
            font=("Segoe UI", 10),
            relief=tk.FLAT,
        )
        search_entry.pack(fill=tk.X, ipady=4)

        # Treeview Users
        cols = ("id", "username", "display_name", "phone")
        self.user_tree = ttk.Treeview(left_frame, columns=cols, show="headings", selectmode="browse")
        self.user_tree.heading("id", text="ID")
        self.user_tree.heading("username", text="Kullanıcı Adı")
        self.user_tree.heading("display_name", text="İsim")
        self.user_tree.heading("phone", text="Telefon")

        self.user_tree.column("id", width=45, anchor="center")
        self.user_tree.column("username", width=110)
        self.user_tree.column("display_name", width=110)
        self.user_tree.column("phone", width=100)

        user_scroll = ttk.Scrollbar(left_frame, orient="vertical", command=self.user_tree.yview)
        self.user_tree.configure(yscrollcommand=user_scroll.set)

        self.user_tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        user_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.user_tree.bind("<<TreeviewSelect>>", self._on_user_selected)

        # RIGHT PANE: Chat Messages & Media Inspector
        right_frame = tk.Frame(main_paned, bg="#27293D", padx=12, pady=10)
        main_paned.add(right_frame)

        # Right Header / Info Bar
        info_header = tk.Frame(right_frame, bg="#27293D")
        info_header.pack(fill=tk.X, pady=(0, 8))

        self.chat_title_lbl = tk.Label(
            info_header,
            text="Lütfen sol listeden bir kullanıcı seçin",
            bg="#27293D",
            fg="#00D2D3",
            font=("Segoe UI", 13, "bold"),
        )
        self.chat_title_lbl.pack(side=tk.LEFT)

        # Decrypt & Export Buttons
        export_btn = tk.Button(
            info_header,
            text="📑 Raporu Dışa Aktar (TXT)",
            bg="#3498DB",
            fg="#FFFFFF",
            font=("Segoe UI", 9, "bold"),
            relief=tk.FLAT,
            padx=10,
            pady=3,
            command=self.export_report,
        )
        export_btn.pack(side=tk.RIGHT, padx=4)

        # Message Listview
        msg_cols = ("id", "direction", "peer", "type", "content_decrypted", "media", "date")
        self.msg_tree = ttk.Treeview(right_frame, columns=msg_cols, show="headings", selectmode="browse")
        self.msg_tree.heading("id", text="#")
        self.msg_tree.heading("direction", text="Yön")
        self.msg_tree.heading("peer", text="Muhatap")
        self.msg_tree.heading("type", text="Tür")
        self.msg_tree.heading("content_decrypted", text="Çözülen Mesaj İçeriği (Plaintext)")
        self.msg_tree.heading("media", text="Medya Durumu")
        self.msg_tree.heading("date", text="Tarih")

        self.msg_tree.column("id", width=50, anchor="center")
        self.msg_tree.column("direction", width=75, anchor="center")
        self.msg_tree.column("peer", width=120)
        self.msg_tree.column("type", width=65, anchor="center")
        self.msg_tree.column("content_decrypted", width=340)
        self.msg_tree.column("media", width=110, anchor="center")
        self.msg_tree.column("date", width=130, anchor="center")

        msg_scroll = ttk.Scrollbar(right_frame, orient="vertical", command=self.msg_tree.yview)
        self.msg_tree.configure(yscrollcommand=msg_scroll.set)

        self.msg_tree.pack(fill=tk.BOTH, expand=True, pady=(0, 10))
        msg_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.msg_tree.bind("<<TreeviewSelect>>", self._on_message_selected)

        # Bottom Inspector Area (Media Viewer & Details)
        self.inspector_frame = tk.Frame(right_frame, bg="#1E1E2F", height=180, padx=12, pady=10)
        self.inspector_frame.pack(fill=tk.X)

        self.details_label = tk.Label(
            self.inspector_frame,
            text="Mesaj Detayı & Şifre Durumu: (Bir mesaj seçin)",
            bg="#1E1E2F",
            fg="#FFFFFF",
            font=("Segoe UI", 10, "bold"),
            justify=tk.LEFT,
        )
        self.details_label.pack(anchor="w")

        self.raw_cipher_text = tk.Text(
            self.inspector_frame,
            height=3,
            bg="#2E3047",
            fg="#A4B0BE",
            font=("Consolas", 9),
            relief=tk.FLAT,
        )
        self.raw_cipher_text.pack(fill=tk.X, pady=4)

        # Media Action Buttons
        self.media_btn_frame = tk.Frame(self.inspector_frame, bg="#1E1E2F")
        self.media_btn_frame.pack(anchor="w", pady=(4, 0))

        self.view_media_btn = tk.Button(
            self.media_btn_frame,
            text="🖼️ Şifreli Medyayı Çöz ve Aç",
            bg="#2ED573",
            fg="#000000",
            font=("Segoe UI", 9, "bold"),
            relief=tk.FLAT,
            padx=10,
            command=self.open_selected_media,
        )
        self.view_media_btn.pack(side=tk.LEFT, padx=(0, 8))

        self.save_media_btn = tk.Button(
            self.media_btn_frame,
            text="💾 Çözülmüş Medyayı Diske Kaydet",
            bg="#FFA502",
            fg="#000000",
            font=("Segoe UI", 9, "bold"),
            relief=tk.FLAT,
            padx=10,
            command=self.save_selected_media,
        )
        self.save_media_btn.pack(side=tk.LEFT)

    def load_users(self):
        self.user_tree.delete(*self.user_tree.get_children())
        self.users.clear()
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT id, username, display_name, phone_number, is_online, created_at FROM users ORDER BY id ASC"
                )
                self.users = cursor.fetchall()
            conn.close()

            for u in self.users:
                self.user_tree.insert(
                    "",
                    tk.END,
                    iid=str(u["id"]),
                    values=(
                        u["id"],
                        u.get("username", ""),
                        u.get("display_name", ""),
                        u.get("phone_number", ""),
                    ),
                )
        except Exception as e:
            messagebox.showerror("Veritabanı Hatası", f"Kullanıcılar alınırken hata oluştu:\n{e}")

    def _filter_users(self):
        query = self.user_search_var.get().strip().lower()
        self.user_tree.delete(*self.user_tree.get_children())
        for u in self.users:
            uname = str(u.get("username", "")).lower()
            dname = str(u.get("display_name", "")).lower()
            phone = str(u.get("phone_number", "")).lower()
            if query in uname or query in dname or query in phone:
                self.user_tree.insert(
                    "",
                    tk.END,
                    iid=str(u["id"]),
                    values=(u["id"], u.get("username", ""), u.get("display_name", ""), u.get("phone_number", "")),
                )

    def _on_user_selected(self, event):
        selected_items = self.user_tree.selection()
        if not selected_items:
            return
        user_id = selected_items[0]
        self.selected_user = next((u for u in self.users if str(u["id"]) == str(user_id)), None)
        if not self.selected_user:
            return

        uname = self.selected_user.get("display_name") or self.selected_user.get("username")
        self.chat_title_lbl.config(
            text=f"📂 Kullanıcı İnceleme: {uname} (ID: {self.selected_user['id']})"
        )
        self.load_messages_for_user(self.selected_user["id"])

    def load_messages_for_user(self, user_id):
        self.msg_tree.delete(*self.msg_tree.get_children())
        self.current_messages.clear()
        self.raw_cipher_text.delete("1.0", tk.END)

        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT m.id, m.sender_id, m.receiver_id, m.content, m.message_type, 
                           m.media_url, m.created_at,
                           u1.username AS sender_uname, u1.display_name AS sender_dname,
                           u2.username AS receiver_uname, u2.display_name AS receiver_dname
                    FROM messages m
                    JOIN users u1 ON m.sender_id = u1.id
                    JOIN users u2 ON m.receiver_id = u2.id
                    WHERE m.sender_id = %s OR m.receiver_id = %s
                    ORDER BY m.created_at DESC
                    """,
                    (user_id, user_id),
                )
                self.current_messages = cursor.fetchall()
            conn.close()

            for msg in self.current_messages:
                is_sender = (msg["sender_id"] == user_id)
                direction = "GÖNDERİLEN ➡️" if is_sender else "GELEN ⬅️"
                peer_name = (
                    f"{msg['receiver_dname'] or msg['receiver_uname']} (#{msg['receiver_id']})"
                    if is_sender
                    else f"{msg['sender_dname'] or msg['sender_uname']} (#{msg['sender_id']})"
                )

                # DECRYPT E2EE CONTENT
                raw_content = msg.get("content") or ""
                decrypted_content = decrypt_text(
                    raw_content, msg["sender_id"], msg["receiver_id"]
                )

                media_status = "Yok"
                if msg.get("media_url"):
                    media_status = "🔒 Şifreli Dosya"

                self.msg_tree.insert(
                    "",
                    tk.END,
                    iid=str(msg["id"]),
                    values=(
                        msg["id"],
                        direction,
                        peer_name,
                        msg.get("message_type", "text"),
                        decrypted_content,
                        media_status,
                        str(msg.get("created_at", ""))[:19],
                    ),
                )
        except Exception as e:
            messagebox.showerror("Hata", f"Mesajlar yüklenemedi:\n{e}")

    def _on_message_selected(self, event):
        selected_items = self.msg_tree.selection()
        if not selected_items:
            return
        msg_id = selected_items[0]
        msg = next((m for m in self.current_messages if str(m["id"]) == str(msg_id)), None)
        if not msg:
            return

        raw_content = msg.get("content") or ""
        is_encrypted = raw_content.startswith("ENC::")
        decrypted = decrypt_text(raw_content, msg["sender_id"], msg["receiver_id"])

        status_text = (
            f"Mesaj #{msg['id']} | Gönderen: #{msg['sender_id']} ➡️ Alıcı: #{msg['receiver_id']} | "
            f"Şifreleme: {'AES-256 E2EE (Korumalı)' if is_encrypted else 'Düz Metin'}"
        )
        if msg.get("media_url"):
            status_text += f" | Medya: {msg['media_url']}"

        self.details_label.config(text=status_text)
        self.raw_cipher_text.delete("1.0", tk.END)
        self.raw_cipher_text.insert(
            tk.END,
            f"[SUNUCUDA SAKLANAN HAM ŞİFRELİ VERİ (CIPHERTEXT)]:\n{raw_content}\n\n[ÇÖZÜLMÜŞ METİN]: {decrypted}",
        )

    def _get_local_media_file(self, media_url):
        if not media_url:
            return None
        filename = media_url.split("/")[-1]
        local_path = os.path.join(UPLOADS_DIR, filename)
        if os.path.exists(local_path):
            return local_path
        return None

    def open_selected_media(self):
        selected_items = self.msg_tree.selection()
        if not selected_items:
            messagebox.showinfo("Bilgi", "Lütfen bir mesaj seçin.")
            return
        msg = next((m for m in self.current_messages if str(m["id"]) == str(selected_items[0])), None)
        if not msg or not msg.get("media_url"):
            messagebox.showinfo("Bilgi", "Seçilen mesajda medya dosyası bulunmuyor.")
            return

        local_path = self._get_local_media_file(msg["media_url"])
        if not local_path:
            messagebox.showerror("Hata", f"Medya dosyası sunucu uploads klasöründe bulunamadı:\n{msg['media_url']}")
            return

        with open(local_path, "rb") as f:
            encrypted_bytes = f.read()

        # Decrypt binary file
        decrypted_bytes = decrypt_file_bytes(encrypted_bytes, msg["sender_id"], msg["receiver_id"])

        # Create temporary file to view
        ext = local_path.split(".")[-1].lower()
        with tempfile.NamedTemporaryFile(delete=False, suffix=f".{ext}") as tmp:
            tmp.write(decrypted_bytes)
            tmp_path = tmp.name

        try:
            # Open with native default Windows viewer (Photos, Media Player, etc.)
            os.startfile(tmp_path)
        except Exception as e:
            messagebox.showerror("Açma Hatası", f"Dosya açılamadı:\n{e}")

    def save_selected_media(self):
        selected_items = self.msg_tree.selection()
        if not selected_items:
            messagebox.showinfo("Bilgi", "Lütfen bir mesaj seçin.")
            return
        msg = next((m for m in self.current_messages if str(m["id"]) == str(selected_items[0])), None)
        if not msg or not msg.get("media_url"):
            messagebox.showinfo("Bilgi", "Seçilen mesajda medya bulunmuyor.")
            return

        local_path = self._get_local_media_file(msg["media_url"])
        if not local_path:
            messagebox.showerror("Hata", "Dosya sunucuda bulunamadı.")
            return

        with open(local_path, "rb") as f:
            encrypted_bytes = f.read()

        decrypted_bytes = decrypt_file_bytes(encrypted_bytes, msg["sender_id"], msg["receiver_id"])
        ext = local_path.split(".")[-1].lower()

        save_dest = filedialog.asksaveasfilename(
            title="Çözülmüş Medyayı Kaydet",
            defaultextension=f".{ext}",
            filetypes=[("Medya Dosyası", f"*.{ext}"), ("Tüm Dosyalar", "*.*")],
        )
        if save_dest:
            with open(save_dest, "wb") as f:
                f.write(decrypted_bytes)
            messagebox.showinfo("Başarılı", f"Dosya başarıyla şifresi çözülmüş olarak kaydedildi:\n{save_dest}")

    def export_report(self):
        if not self.selected_user or not self.current_messages:
            messagebox.showinfo("Bilgi", "Dışa aktarmak için mesajları olan bir kullanıcı seçin.")
            return

        uname = self.selected_user.get("username")
        dest = filedialog.asksaveasfilename(
            title="Adli Bilişim Mesaj Raporunu Kaydet",
            initialfile=f"Talknex_Rapor_{uname}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt",
            defaultextension=".txt",
            filetypes=[("Metin Dosyası", "*.txt")],
        )
        if not dest:
            return

        try:
            with open(dest, "w", encoding="utf-8") as f:
                f.write("====================================================================\n")
                f.write("      TALKNEX ADLİ BİLİŞİM & DENETİM ŞİFRESİ ÇÖZÜLMÜŞ KAYIT RAPORU   \n")
                f.write("====================================================================\n")
                f.write(f"Rapor Tarihi  : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
                f.write(f"Hedef Kullanıcı: {self.selected_user.get('display_name')} (@{uname}) (ID: {self.selected_user['id']})\n")
                f.write(f"Telefon       : {self.selected_user.get('phone_number', '')}\n")
                f.write(f"Toplam Mesaj  : {len(self.current_messages)}\n")
                f.write("====================================================================\n\n")

                for msg in self.current_messages:
                    raw = msg.get("content") or ""
                    dec = decrypt_text(raw, msg["sender_id"], msg["receiver_id"])
                    f.write(f"[{msg.get('created_at')}] Mesaj #{msg['id']}\n")
                    f.write(f"  Gönderen : #{msg['sender_id']} ({msg.get('sender_uname')})\n")
                    f.write(f"  Alıcı    : #{msg['receiver_id']} ({msg.get('receiver_uname')})\n")
                    f.write(f"  Tür      : {msg.get('message_type')}\n")
                    f.write(f"  Medya URL: {msg.get('media_url') or 'Yok'}\n")
                    f.write(f"  Ham Veri : {raw}\n")
                    f.write(f"  ÇÖZÜLEN  : {dec}\n")
                    f.write("-" * 65 + "\n")

            messagebox.showinfo("Başarılı", f"Rapor başarıyla kaydedildi:\n{dest}")
        except Exception as e:
            messagebox.showerror("Hata", f"Rapor kaydedilemedi:\n{e}")


if __name__ == "__main__":
    app = TalknexAdminApp()
    app.mainloop()
