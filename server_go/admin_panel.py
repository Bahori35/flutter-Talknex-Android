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
    pair = sorted([str(user1_id).strip(), str(user2_id).strip()])
    combined = f"{pair[0]}_e2ee_{pair[1]}_{APP_SALT}".encode("utf-8")
    return hashlib.sha256(combined).digest()


def decrypt_text(cipher_text: str, user1_id, user2_id) -> str:
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

        pad_len = padded_plaintext[-1]
        if 1 <= pad_len <= 16:
            plaintext = padded_plaintext[:-pad_len]
        else:
            plaintext = padded_plaintext

        return plaintext.decode("utf-8", errors="replace")
    except Exception as e:
        return f"[Çözülemedi: {e}] {cipher_text}"


def decrypt_file_bytes(encrypted_bytes: bytes, user1_id, user2_id) -> bytes:
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


# ----------------- TALKNEX WHATSAPP-LIKE ADMIN FORENSIC APP -----------------
class TalknexAdminApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Talknex Adli Bilişim & Canlı Sohbet İzleme Paneli (WhatsApp Arayüzü) 🛡️")
        self.geometry("1400x860")
        self.minsize(1150, 720)
        self.configure(bg="#0B141A")

        self.users = []
        self.selected_user = None
        self.conversations = []
        self.active_peer_id = None
        self.current_messages = []
        self.preview_photo_cache = []

        self._setup_styles()
        self._build_layout()
        self.load_users()

    def _setup_styles(self):
        self.style = ttk.Style(self)
        self.style.theme_use("clam")

        self.style.configure("TFrame", background="#111B21")
        self.style.configure("Treeview",
            background="#111B21",
            foreground="#E9EDEF",
            fieldbackground="#111B21",
            rowheight=32,
            font=("Segoe UI", 10),
        )
        self.style.configure("Treeview.Heading",
            background="#202C33",
            foreground="#00A884",
            font=("Segoe UI", 10, "bold"),
        )
        self.style.map("Treeview",
            background=[("selected", "#00A884")],
            foreground=[("selected", "#FFFFFF")],
        )

    def _build_layout(self):
        # 1. Top WhatsApp Style Bar
        top_bar = tk.Frame(self, bg="#202C33", height=65, padx=20, pady=10)
        top_bar.pack(fill=tk.X, side=tk.TOP)
        top_bar.pack_propagate(False)

        logo_lbl = tk.Label(top_bar, text="🟢 TALKNEX ADLİ BİLİŞİM & CANLI SOHBET İZLEME PANELİ",
                            bg="#202C33", fg="#00A884", font=("Segoe UI", 15, "bold"))
        logo_lbl.pack(side=tk.LEFT, pady=4)

        tag_lbl = tk.Label(top_bar, text="WhatsApp / Telegram Tipi Adli Denetim (AES-256 E2EE Otomatik Çözücü)",
                           bg="#202C33", fg="#8696A0", font=("Segoe UI", 10))
        tag_lbl.pack(side=tk.LEFT, padx=15, pady=6)

        refresh_btn = tk.Button(top_bar, text="🔄 Yenile", bg="#00A884", fg="#FFFFFF",
                                font=("Segoe UI", 10, "bold"), relief=tk.FLAT, padx=14, pady=5,
                                cursor="hand2", command=self.load_users)
        refresh_btn.pack(side=tk.RIGHT, padx=5)

        export_btn = tk.Button(top_bar, text="📄 Resmi Rapor Al (TXT)", bg="#2A3942", fg="#00A884",
                               font=("Segoe UI", 10, "bold"), relief=tk.FLAT, padx=14, pady=5,
                               cursor="hand2", command=self.export_report)
        export_btn.pack(side=tk.RIGHT, padx=5)

        # 2. Main Horizontal Container (3 Columns: Users, Chats, Chat View)
        main_box = tk.PanedWindow(self, orient=tk.HORIZONTAL, bg="#0B141A", sashwidth=4)
        main_box.pack(fill=tk.BOTH, expand=True, padx=10, pady=10)

        # COLUMN 1: USERS LIST (Left)
        col1 = tk.Frame(main_box, bg="#111B21", width=340)
        main_box.add(col1, width=340)

        col1_header = tk.Frame(col1, bg="#202C33", height=45, padx=12, pady=8)
        col1_header.pack(fill=tk.X)
        tk.Label(col1_header, text="👤 Tüm Kullanıcılar", bg="#202C33", fg="#E9EDEF",
                 font=("Segoe UI", 11, "bold")).pack(side=tk.LEFT)

        # Search Bar
        search_box = tk.Frame(col1, bg="#111B21", padx=10, pady=8)
        search_box.pack(fill=tk.X)
        self.search_var = tk.StringVar()
        self.search_var.trace("w", lambda *args: self._filter_users())
        search_entry = tk.Entry(search_box, textvariable=self.search_var, bg="#202C33", fg="#E9EDEF",
                                insertbackground="#00A884", font=("Segoe UI", 10), relief=tk.FLAT)
        search_entry.pack(fill=tk.X, ipady=5)

        # Users Treeview
        u_cols = ("id", "user", "phone")
        self.user_tree = ttk.Treeview(col1, columns=u_cols, show="headings", selectmode="browse")
        self.user_tree.heading("id", text="#")
        self.user_tree.heading("user", text="Kullanıcı / İsim")
        self.user_tree.heading("phone", text="Telefon")
        self.user_tree.column("id", width=40, anchor="center")
        self.user_tree.column("user", width=160)
        self.user_tree.column("phone", width=120)

        u_scroll = ttk.Scrollbar(col1, orient="vertical", command=self.user_tree.yview)
        self.user_tree.configure(yscrollcommand=u_scroll.set)
        self.user_tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        u_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.user_tree.bind("<<TreeviewSelect>>", self._on_user_selected)

        # COLUMN 2: CONVERSATIONS LIST (Middle)
        col2 = tk.Frame(main_box, bg="#111B21", width=300)
        main_box.add(col2, width=300)

        col2_header = tk.Frame(col2, bg="#202C33", height=45, padx=12, pady=8)
        col2_header.pack(fill=tk.X)
        self.col2_title = tk.Label(col2_header, text="💬 Sohbet Ettiği Kişiler", bg="#202C33", fg="#E9EDEF",
                                   font=("Segoe UI", 11, "bold"))
        self.col2_title.pack(side=tk.LEFT)

        c_cols = ("peer_id", "peer_name", "count")
        self.chat_tree = ttk.Treeview(col2, columns=c_cols, show="headings", selectmode="browse")
        self.chat_tree.heading("peer_id", text="#")
        self.chat_tree.heading("peer_name", text="Konuşulan Kişi")
        self.chat_tree.heading("count", text="Mesaj")
        self.chat_tree.column("peer_id", width=45, anchor="center")
        self.chat_tree.column("peer_name", width=170)
        self.chat_tree.column("count", width=65, anchor="center")

        c_scroll = ttk.Scrollbar(col2, orient="vertical", command=self.chat_tree.yview)
        self.chat_tree.configure(yscrollcommand=c_scroll.set)
        self.chat_tree.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        c_scroll.pack(side=tk.RIGHT, fill=tk.Y)
        self.chat_tree.bind("<<TreeviewSelect>>", self._on_chat_selected)

        # COLUMN 3: WHATSAPP CHAT FEED (Right)
        col3 = tk.Frame(main_box, bg="#0B141A")
        main_box.add(col3)

        # Chat Room Header
        self.chat_header = tk.Frame(col3, bg="#202C33", height=55, padx=15, pady=8)
        self.chat_header.pack(fill=tk.X)
        self.chat_header.pack_propagate(False)

        self.chat_peer_label = tk.Label(self.chat_header, text="Görüntülemek için bir konuşma seçin",
                                        bg="#202C33", fg="#E9EDEF", font=("Segoe UI", 12, "bold"))
        self.chat_peer_label.pack(side=tk.LEFT, pady=6)

        self.chat_detail_label = tk.Label(self.chat_header, text="", bg="#202C33", fg="#00A884",
                                          font=("Segoe UI", 9))
        self.chat_detail_label.pack(side=tk.LEFT, padx=12, pady=8)

        # WhatsApp Message Canvas with Scrollbar
        chat_container = tk.Frame(col3, bg="#0B141A")
        chat_container.pack(fill=tk.BOTH, expand=True)

        self.canvas = tk.Canvas(chat_container, bg="#0B141A", highlightthickness=0)
        self.scrollbar = ttk.Scrollbar(chat_container, orient="vertical", command=self.canvas.yview)
        self.msg_frame = tk.Frame(self.canvas, bg="#0B141A")

        self.msg_frame.bind(
            "<Configure>",
            lambda e: self.canvas.configure(scrollregion=self.canvas.bbox("all"))
        )
        self.canvas_window = self.canvas.create_window((0, 0), window=self.msg_frame, anchor="nw")
        self.canvas.configure(yscrollcommand=self.scrollbar.set)

        self.canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=8, pady=8)
        self.scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

        self.canvas.bind(
            "<Configure>",
            lambda event: self.canvas.itemconfig(self.canvas_window, width=event.width)
        )
        # Mousewheel scroll
        self.canvas.bind_all("<MouseWheel>", self._on_mousewheel)

    def _on_mousewheel(self, event):
        try:
            self.canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")
        except Exception:
            pass

    def load_users(self):
        self.user_tree.delete(*self.user_tree.get_children())
        self.users.clear()
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute(
                    "SELECT id, username, display_name, phone_number, is_online FROM users ORDER BY id ASC"
                )
                self.users = cursor.fetchall()
            conn.close()

            for u in self.users:
                display = u.get("display_name") or u.get("username")
                self.user_tree.insert(
                    "",
                    tk.END,
                    iid=str(u["id"]),
                    values=(u["id"], display, u.get("phone_number", "-")),
                )
        except Exception as e:
            messagebox.showerror("Hata", f"Kullanıcılar alınamadı:\n{e}")

    def _filter_users(self):
        q = self.search_var.get().strip().lower()
        self.user_tree.delete(*self.user_tree.get_children())
        for u in self.users:
            uname = str(u.get("username", "")).lower()
            dname = str(u.get("display_name", "")).lower()
            phone = str(u.get("phone_number", "")).lower()
            if q in uname or q in dname or q in phone:
                display = u.get("display_name") or u.get("username")
                self.user_tree.insert(
                    "",
                    tk.END,
                    iid=str(u["id"]),
                    values=(u["id"], display, u.get("phone_number", "-")),
                )

    def _on_user_selected(self, event):
        selected = self.user_tree.selection()
        if not selected:
            return
        uid = int(selected[0])
        self.selected_user = next((u for u in self.users if u["id"] == uid), None)
        if not self.selected_user:
            return

        name = self.selected_user.get("display_name") or self.selected_user.get("username")
        self.col2_title.config(text=f"💬 {name} Sohbetleri")
        self.load_conversations_for_user(uid)

    def load_conversations_for_user(self, user_id):
        self.chat_tree.delete(*self.chat_tree.get_children())
        self.conversations.clear()
        self._clear_chat_view()

        try:
            conn = get_db()
            with conn.cursor() as cursor:
                # Find all peer users this user has messaged with
                cursor.execute(
                    """
                    SELECT 
                        CASE WHEN sender_id = %s THEN receiver_id ELSE sender_id END AS peer_id,
                        COUNT(*) as msg_count
                    FROM messages
                    WHERE sender_id = %s OR receiver_id = %s
                    GROUP BY peer_id
                    ORDER BY msg_count DESC
                    """,
                    (user_id, user_id, user_id),
                )
                rows = cursor.fetchall()
            conn.close()

            for r in rows:
                peer_id = r["peer_id"]
                peer_user = next((u for u in self.users if u["id"] == peer_id), None)
                peer_name = (
                    f"{peer_user.get('display_name') or peer_user.get('username')}"
                    if peer_user
                    else f"Kullanıcı #{peer_id}"
                )
                self.conversations.append(r)
                self.chat_tree.insert(
                    "",
                    tk.END,
                    iid=str(peer_id),
                    values=(peer_id, peer_name, f"{r['msg_count']} msj"),
                )

            # Auto-select first conversation if exists
            if rows:
                first_peer_id = str(rows[0]["peer_id"])
                self.chat_tree.selection_set(first_peer_id)
                self.load_chat(user_id, rows[0]["peer_id"])
        except Exception as e:
            messagebox.showerror("Hata", f"Sohbetler alınamadı:\n{e}")

    def _on_chat_selected(self, event):
        selected = self.chat_tree.selection()
        if not selected or not self.selected_user:
            return
        peer_id = int(selected[0])
        self.load_chat(self.selected_user["id"], peer_id)

    def _clear_chat_view(self):
        for widget in self.msg_frame.winfo_children():
            widget.destroy()
        self.preview_photo_cache.clear()

    def _get_local_media_file(self, media_url):
        if not media_url:
            return None
        filename = media_url.split("/")[-1]
        local_path = os.path.join(UPLOADS_DIR, filename)
        if os.path.exists(local_path):
            return local_path
        return None

    def load_chat(self, user1_id, user2_id):
        self._clear_chat_view()
        self.active_peer_id = user2_id
        self.current_messages.clear()

        peer_user = next((u for u in self.users if u["id"] == user2_id), None)
        peer_name = (
            f"{peer_user.get('display_name') or peer_user.get('username')}"
            if peer_user
            else f"Kullanıcı #{user2_id}"
        )
        self.chat_peer_label.config(text=f"💬 {peer_name}")
        self.chat_detail_label.config(text=f"(ID: {user2_id} | Uçtan Uca Şifreli Sohbet)")

        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT id, sender_id, receiver_id, content, message_type, media_url, created_at
                    FROM messages
                    WHERE (sender_id = %s AND receiver_id = %s)
                       OR (sender_id = %s AND receiver_id = %s)
                    ORDER BY created_at ASC
                    """,
                    (user1_id, user2_id, user2_id, user1_id),
                )
                self.current_messages = cursor.fetchall()
            conn.close()

            if not self.current_messages:
                empty_lbl = tk.Label(self.msg_frame, text="Bu kullanıcı ile henüz bir mesajlaşma bulunmuyor.",
                                     bg="#0B141A", fg="#8696A0", font=("Segoe UI", 11, "italic"))
                empty_lbl.pack(pady=40)
                return

            # Render WhatsApp Style Bubbles
            for msg in self.current_messages:
                self._render_message_bubble(msg, user1_id)

            # Auto-scroll to bottom
            self.canvas.update_idletasks()
            self.canvas.yview_moveto(1.0)

        except Exception as e:
            messagebox.showerror("Hata", f"Mesajlar yüklenemedi:\n{e}")

    def _render_message_bubble(self, msg, focused_user_id):
        is_me = (msg["sender_id"] == focused_user_id)
        # WhatsApp Green: #005C4B for outgoing, Slate: #202C33 for incoming
        bubble_bg = "#005C4B" if is_me else "#202C33"
        align = "e" if is_me else "w"
        side = tk.RIGHT if is_me else tk.LEFT

        row = tk.Frame(self.msg_frame, bg="#0B141A")
        row.pack(fill=tk.X, padx=15, pady=4)

        bubble = tk.Frame(row, bg=bubble_bg, padx=12, pady=8, relief=tk.FLAT)
        bubble.pack(side=side, anchor=align)

        # Decrypt text
        raw_content = msg.get("content") or ""
        decrypted = decrypt_text(raw_content, msg["sender_id"], msg["receiver_id"])
        msg_type = msg.get("message_type", "text")
        media_url = msg.get("media_url") or ""
        date_str = str(msg.get("created_at", ""))[:16]

        # 1. Media Preview (Image / Video / Audio)
        if media_url:
            local_path = self._get_local_media_file(media_url)
            if local_path and os.path.exists(local_path):
                # Try to decrypt and preview if image
                ext = local_path.split(".")[-1].lower()
                if ext in ("jpg", "jpeg", "png", "webp", "gif"):
                    try:
                        with open(local_path, "rb") as f:
                            enc_bytes = f.read()
                        dec_bytes = decrypt_file_bytes(enc_bytes, msg["sender_id"], msg["receiver_id"])
                        with tempfile.NamedTemporaryFile(delete=False, suffix=f".{ext}") as tmp:
                            tmp.write(dec_bytes)
                            tmp_img = tmp.name

                        img = Image.open(tmp_img)
                        img.thumbnail((260, 260))
                        photo = ImageTk.PhotoImage(img)
                        self.preview_photo_cache.append(photo)

                        img_lbl = tk.Label(bubble, image=photo, bg=bubble_bg, cursor="hand2")
                        img_lbl.pack(anchor="w", pady=(2, 6))
                        # Click opens fullscreen
                        img_lbl.bind("<Button-1>", lambda e, p=tmp_img: os.startfile(p))
                    except Exception:
                        pass
                elif ext in ("mp4", "mov", "avi", "mkv"):
                    # Video Indicator Card
                    vid_card = tk.Frame(bubble, bg="#111B21", padx=10, pady=8, cursor="hand2")
                    vid_card.pack(fill=tk.X, pady=(2, 6))
                    tk.Label(vid_card, text="🎥 VİDEO KAYDI", bg="#111B21", fg="#00A884", font=("Segoe UI", 10, "bold")).pack(anchor="w")
                    tk.Label(vid_card, text=f"Dosya: {os.path.basename(local_path)} (Oynatmak için tıkla)", bg="#111B21", fg="#8696A0", font=("Segoe UI", 8)).pack(anchor="w")
                    vid_card.bind("<Button-1>", lambda e, p=local_path, s=msg["sender_id"], r=msg["receiver_id"]: self._play_video(p, s, r))

            # Media Action Buttons
            btn_frame = tk.Frame(bubble, bg=bubble_bg)
            btn_frame.pack(anchor="w", pady=(2, 4))
            open_btn = tk.Button(btn_frame, text="👁️ Medyayı Aç", bg="#00A884", fg="#FFFFFF",
                                 font=("Segoe UI", 8, "bold"), relief=tk.FLAT, padx=6, pady=2,
                                 command=lambda m=msg: self._open_media(m))
            open_btn.pack(side=tk.LEFT, padx=(0, 6))

            save_btn = tk.Button(btn_frame, text="💾 Kaydet", bg="#2A3942", fg="#00A884",
                                 font=("Segoe UI", 8, "bold"), relief=tk.FLAT, padx=6, pady=2,
                                 command=lambda m=msg: self._save_media(m))
            save_btn.pack(side=tk.LEFT)

        # 2. Text Message Content
        if decrypted:
            txt_lbl = tk.Label(bubble, text=decrypted, bg=bubble_bg, fg="#E9EDEF",
                               font=("Segoe UI", 10), wraplength=480, justify=tk.LEFT)
            txt_lbl.pack(anchor="w", pady=(2, 2))

        # 3. Footer (Timestamp + Encryption Checkmark)
        foot_frame = tk.Frame(bubble, bg=bubble_bg)
        foot_frame.pack(anchor="e", pady=(2, 0))
        tk.Label(foot_frame, text=f"🔒 {date_str}", bg=bubble_bg, fg="#8696A0",
                 font=("Segoe UI", 8)).pack(side=tk.RIGHT)

    def _play_video(self, local_path, sender_id, receiver_id):
        try:
            with open(local_path, "rb") as f:
                enc = f.read()
            dec = decrypt_file_bytes(enc, sender_id, receiver_id)
            ext = local_path.split(".")[-1].lower()
            with tempfile.NamedTemporaryFile(delete=False, suffix=f".{ext}") as tmp:
                tmp.write(dec)
                tmp_path = tmp.name
            os.startfile(tmp_path)
        except Exception as e:
            messagebox.showerror("Hata", f"Video açılamadı: {e}")

    def _open_media(self, msg):
        local_path = self._get_local_media_file(msg.get("media_url"))
        if not local_path:
            messagebox.showerror("Hata", "Dosya sunucuda bulunamadı.")
            return

        with open(local_path, "rb") as f:
            enc = f.read()
        dec = decrypt_file_bytes(enc, msg["sender_id"], msg["receiver_id"])
        ext = local_path.split(".")[-1].lower()
        with tempfile.NamedTemporaryFile(delete=False, suffix=f".{ext}") as tmp:
            tmp.write(dec)
            tmp_path = tmp.name

        try:
            os.startfile(tmp_path)
        except Exception as e:
            messagebox.showerror("Hata", f"Medya açılamadı:\n{e}")

    def _save_media(self, msg):
        local_path = self._get_local_media_file(msg.get("media_url"))
        if not local_path:
            messagebox.showerror("Hata", "Dosya bulunamadı.")
            return

        with open(local_path, "rb") as f:
            enc = f.read()
        dec = decrypt_file_bytes(enc, msg["sender_id"], msg["receiver_id"])
        ext = local_path.split(".")[-1].lower()

        dest = filedialog.asksaveasfilename(
            title="Çözülmüş Medyayı Kaydet",
            defaultextension=f".{ext}",
            filetypes=[("Medya Dosyası", f"*.{ext}"), ("Tüm Dosyalar", "*.*")],
        )
        if dest:
            with open(dest, "wb") as f:
                f.write(dec)
            messagebox.showinfo("Başarılı", f"Dosya kaydedildi:\n{dest}")

    def export_report(self):
        if not self.selected_user or not self.active_peer_id or not self.current_messages:
            messagebox.showinfo("Bilgi", "Lütfen önce mesajları olan bir sohbet seçin.")
            return

        u1 = self.selected_user
        u2 = next((u for u in self.users if u["id"] == self.active_peer_id), None)
        u1_name = u1.get("display_name") or u1.get("username")
        u2_name = (u2.get("display_name") or u2.get("username")) if u2 else f"ID_{self.active_peer_id}"

        dest = filedialog.asksaveasfilename(
            title="Adli Bilişim Sohbet Raporunu Kaydet",
            initialfile=f"Talknex_Sohbet_{u1_name}_ve_{u2_name}_{datetime.now().strftime('%Y%m%d_%H%M%S')}.txt",
            defaultextension=".txt",
            filetypes=[("Metin Dosyası", "*.txt")],
        )
        if not dest:
            return

        try:
            with open(dest, "w", encoding="utf-8") as f:
                f.write("====================================================================\n")
                f.write("      TALKNEX ADLİ BİLİŞİM & DENETİM ŞİFRESİ ÇÖZÜLMÜŞ SOHBET RAPORU   \n")
                f.write("====================================================================\n")
                f.write(f"Rapor Tarihi  : {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
                f.write(f"1. Taraf       : {u1_name} (ID: {u1['id']}) | Tel: {u1.get('phone_number', '-')}\n")
                f.write(f"2. Taraf       : {u2_name} (ID: {self.active_peer_id})\n")
                f.write(f"Toplam Mesaj  : {len(self.current_messages)}\n")
                f.write("====================================================================\n\n")

                for msg in self.current_messages:
                    raw = msg.get("content") or ""
                    dec = decrypt_text(raw, msg["sender_id"], msg["receiver_id"])
                    sender_lbl = u1_name if msg["sender_id"] == u1["id"] else u2_name
                    f.write(f"[{msg.get('created_at')}] {sender_lbl}:\n")
                    f.write(f"  Mesaj Metni: {dec}\n")
                    if msg.get("media_url"):
                        f.write(f"  Medya Dosyası ({msg.get('message_type')}): {msg.get('media_url')}\n")
                    f.write("-" * 65 + "\n")

            messagebox.showinfo("Başarılı", f"Rapor başarıyla kaydedildi:\n{dest}")
        except Exception as e:
            messagebox.showerror("Hata", f"Rapor kaydedilemedi:\n{e}")


if __name__ == "__main__":
    app = TalknexAdminApp()
    app.mainloop()
