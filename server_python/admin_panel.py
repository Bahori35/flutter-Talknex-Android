import os
import sys
import io
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
UPLOADS_DIR = os.path.join(CURRENT_DIR, "uploads")


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
        padded = decryptor.update(ciphertext) + decryptor.finalize()

        pad_len = padded[-1]
        if 1 <= pad_len <= 16:
            plaintext = padded[:-pad_len]
        else:
            plaintext = padded
        return plaintext.decode("utf-8", errors="replace")
    except Exception:
        return cipher_text


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


# ----------------- DATABASE -----------------
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


# ----------------- TALKNEX WHATSAPP-LIKE ADMIN GUI -----------------
class TalknexChatAdminApp(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title("Talknex - WhatsApp Canlı Sohbet ve Medya Denetim Paneli")
        self.geometry("1260x860")
        self.minsize(1080, 700)
        self.configure(bg="#0B141A")

        self.users = []
        self.active_user = None
        self.active_peer = None
        self.cached_images = {}  # Keep references to avoid GC

        self._setup_styles()
        self._build_ui()
        self.load_users()

    def _setup_styles(self):
        self.style = ttk.Style(self)
        self.style.theme_use("clam")

        self.style.configure(
            "Treeview",
            background="#111B21",
            foreground="#E9EDEF",
            fieldbackground="#111B21",
            rowheight=48,
            font=("Segoe UI", 10),
        )
        self.style.configure(
            "Treeview.Heading",
            background="#202C33",
            foreground="#00A884",
            font=("Segoe UI", 10, "bold"),
        )
        self.style.map(
            "Treeview",
            background=[("selected", "#00A884")],
            foreground=[("selected", "#FFFFFF")],
        )

    def _build_ui(self):
        # 1. TOP STATUS / TITLE BAR (WhatsApp Dark Theme: #202C33)
        top_bar = tk.Frame(self, bg="#202C33", height=58, padx=16)
        top_bar.pack(fill=tk.X)

        logo_lbl = tk.Label(
            top_bar,
            text="📱 Talknex Denetim Arayüzü",
            bg="#202C33",
            fg="#00A884",
            font=("Segoe UI", 14, "bold"),
        )
        logo_lbl.pack(side=tk.LEFT, pady=12)

        desc_lbl = tk.Label(
            top_bar,
            text="(Uçtan Uca Şifre Çözücü Aktif • Emniyet & Güvenlik Birimi)",
            bg="#202C33",
            fg="#8696A0",
            font=("Segoe UI", 9),
        )
        desc_lbl.pack(side=tk.LEFT, padx=12, pady=12)

        refresh_btn = tk.Button(
            top_bar,
            text="🔄 Yenile",
            bg="#00A884",
            fg="#FFFFFF",
            font=("Segoe UI", 9, "bold"),
            relief=tk.FLAT,
            padx=12,
            pady=4,
            command=self.load_users,
        )
        refresh_btn.pack(side=tk.RIGHT, pady=12)

        # 2. MAIN 3-COLUMN SPLIT
        # Column 1: Primary Users list (Sender / Target User)
        # Column 2: Peer Users list (Conversations)
        # Column 3: Chat Screen (Real WhatsApp-like UI)
        main_container = tk.Frame(self, bg="#0B141A")
        main_container.pack(fill=tk.BOTH, expand=True)

        # --- LEFT PANEL: HEDEF KULLANICI SEÇİMİ (300px) ---
        left_panel = tk.Frame(main_container, bg="#111B21", width=320, padx=8, pady=8)
        left_panel.pack(side=tk.LEFT, fill=tk.Y)
        left_panel.pack_propagate(False)

        tk.Label(
            left_panel,
            text="👤 İNCELENECEK KİŞİ",
            bg="#111B21",
            fg="#00A884",
            font=("Segoe UI", 10, "bold"),
        ).pack(anchor="w", pady=(4, 6))

        # Search bar
        self.search_user_var = tk.StringVar()
        self.search_user_var.trace("w", lambda *args: self._filter_users())
        search_box = tk.Entry(
            left_panel,
            textvariable=self.search_user_var,
            bg="#202C33",
            fg="#FFFFFF",
            insertbackground="#00A884",
            font=("Segoe UI", 10),
            relief=tk.FLAT,
        )
        search_box.pack(fill=tk.X, ipady=4, pady=(0, 8))

        self.user_tree = ttk.Treeview(left_panel, columns=("id", "info"), show="headings", selectmode="browse")
        self.user_tree.heading("id", text="ID")
        self.user_tree.heading("info", text="Kullanıcı / Numara")
        self.user_tree.column("id", width=45, anchor="center")
        self.user_tree.column("info", width=240)
        self.user_tree.pack(fill=tk.BOTH, expand=True)
        self.user_tree.bind("<<TreeviewSelect>>", self._on_user_selected)

        # --- MIDDLE PANEL: SOHBET ETTİĞİ KİŞİLER (260px) ---
        middle_panel = tk.Frame(main_container, bg="#111B21", width=280, padx=8, pady=8)
        middle_panel.pack(side=tk.LEFT, fill=tk.Y)
        middle_panel.pack_propagate(False)

        tk.Label(
            middle_panel,
            text="💬 KONUŞTUĞU KİŞİLER",
            bg="#111B21",
            fg="#00A884",
            font=("Segoe UI", 10, "bold"),
        ).pack(anchor="w", pady=(4, 6))

        self.peer_tree = ttk.Treeview(middle_panel, columns=("id", "info"), show="headings", selectmode="browse")
        self.peer_tree.heading("id", text="ID")
        self.peer_tree.heading("info", text="Sohbet Edilen Kişi")
        self.peer_tree.column("id", width=40, anchor="center")
        self.peer_tree.column("info", width=220)
        self.peer_tree.pack(fill=tk.BOTH, expand=True)
        self.peer_tree.bind("<<TreeviewSelect>>", self._on_peer_selected)

        # --- RIGHT PANEL: WHATSAPP CANLI SOHBET EKRANI ---
        right_panel = tk.Frame(main_container, bg="#0B141A")
        right_panel.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        # Chat Top Bar (WhatsApp Style Header)
        self.chat_header = tk.Frame(right_panel, bg="#202C33", height=56, padx=16)
        self.chat_header.pack(fill=tk.X)

        self.chat_header_title = tk.Label(
            self.chat_header,
            text="İncelemek istediğiniz sohbeti seçin",
            bg="#202C33",
            fg="#E9EDEF",
            font=("Segoe UI", 12, "bold"),
        )
        self.chat_header_title.pack(side=tk.LEFT, pady=10)

        self.chat_header_sub = tk.Label(
            self.chat_header,
            text="",
            bg="#202C33",
            fg="#8696A0",
            font=("Segoe UI", 9),
        )
        self.chat_header_sub.pack(side=tk.LEFT, padx=10, pady=10)

        export_btn = tk.Button(
            self.chat_header,
            text="📑 Raporu İndir",
            bg="#00A884",
            fg="#FFFFFF",
            font=("Segoe UI", 9, "bold"),
            relief=tk.FLAT,
            padx=10,
            command=self.export_report,
        )
        export_btn.pack(side=tk.RIGHT, pady=10)

        # Chat Scrollable Canvas
        self.canvas_container = tk.Frame(right_panel, bg="#0B141A")
        self.canvas_container.pack(fill=tk.BOTH, expand=True)

        self.canvas = tk.Canvas(self.canvas_container, bg="#0B141A", highlightthickness=0)
        self.scrollbar = ttk.Scrollbar(self.canvas_container, orient="vertical", command=self.canvas.yview)
        self.canvas.configure(yscrollcommand=self.scrollbar.set)

        self.scrollable_chat_frame = tk.Frame(self.canvas, bg="#0B141A")
        self.canvas_window = self.canvas.create_window((0, 0), window=self.scrollable_chat_frame, anchor="nw")

        self.scrollable_chat_frame.bind(
            "<Configure>", lambda e: self.canvas.configure(scrollregion=self.canvas.bbox("all"))
        )
        self.canvas.bind(
            "<Configure>", lambda e: self.canvas.itemconfig(self.canvas_window, width=e.width)
        )
        self.canvas.bind_all("<MouseWheel>", self._on_mousewheel)

        self.canvas.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)
        self.scrollbar.pack(side=tk.RIGHT, fill=tk.Y)

    def _on_mousewheel(self, event):
        self.canvas.yview_scroll(int(-1 * (event.delta / 120)), "units")

    def load_users(self):
        self.user_tree.delete(*self.user_tree.get_children())
        self.peer_tree.delete(*self.peer_tree.get_children())
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
                name = u.get("display_name") or u.get("username")
                phone = f" • {u['phone_number']}" if u.get("phone_number") else ""
                online_dot = "🟢 " if u.get("is_online") else "⚪ "
                self.user_tree.insert(
                    "",
                    tk.END,
                    iid=str(u["id"]),
                    values=(u["id"], f"{online_dot}{name}{phone}"),
                )
        except Exception as e:
            messagebox.showerror("Hata", f"Kullanıcılar alınamadı: {e}")

    def _filter_users(self):
        q = self.search_user_var.get().strip().lower()
        self.user_tree.delete(*self.user_tree.get_children())
        for u in self.users:
            name = (u.get("display_name") or u.get("username") or "").lower()
            phone = str(u.get("phone_number") or "").lower()
            if q in name or q in phone:
                dname = u.get("display_name") or u.get("username")
                online_dot = "🟢 " if u.get("is_online") else "⚪ "
                self.user_tree.insert(
                    "",
                    tk.END,
                    iid=str(u["id"]),
                    values=(u["id"], f"{online_dot}{dname}"),
                )

    def _on_user_selected(self, event):
        sel = self.user_tree.selection()
        if not sel:
            return
        user_id = int(sel[0])
        self.active_user = next((u for u in self.users if u["id"] == user_id), None)
        if not self.active_user:
            return

        self.load_peers_for_user(user_id)

    def load_peers_for_user(self, user_id):
        self.peer_tree.delete(*self.peer_tree.get_children())
        try:
            conn = get_db()
            with conn.cursor() as cursor:
                # Find all users who exchanged messages with user_id
                cursor.execute(
                    """
                    SELECT DISTINCT 
                        CASE WHEN sender_id = %s THEN receiver_id ELSE sender_id END AS peer_id
                    FROM messages
                    WHERE sender_id = %s OR receiver_id = %s
                    """,
                    (user_id, user_id, user_id),
                )
                peer_rows = cursor.fetchall()
            conn.close()

            peer_ids = [r["peer_id"] for r in peer_rows]
            for pid in peer_ids:
                p_user = next((u for u in self.users if u["id"] == pid), None)
                if p_user:
                    pname = p_user.get("display_name") or p_user.get("username")
                    self.peer_tree.insert(
                        "",
                        tk.END,
                        iid=str(pid),
                        values=(pid, f"💬 {pname}"),
                    )
        except Exception as e:
            messagebox.showerror("Hata", f"Sohbetler alınamadı: {e}")

    def _on_peer_selected(self, event):
        sel = self.peer_tree.selection()
        if not sel or not self.active_user:
            return
        peer_id = int(sel[0])
        self.active_peer = next((u for u in self.users if u["id"] == peer_id), None)
        if not self.active_peer:
            return

        # Update Chat Header
        active_name = self.active_user.get("display_name") or self.active_user.get("username")
        peer_name = self.active_peer.get("display_name") or self.active_peer.get("username")
        self.chat_header_title.config(text=f"{active_name} ↔ {peer_name}")
        self.chat_header_sub.config(text=f"(ID #{self.active_user['id']} ile ID #{self.active_peer['id']} arasındaki sohbet)")

        self.render_chat_messages(self.active_user["id"], peer_id)

    def render_chat_messages(self, user1_id, user2_id):
        # Clear existing bubbles
        for child in self.scrollable_chat_frame.winfo_children():
            child.destroy()
        self.cached_images.clear()

        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT id, sender_id, receiver_id, content, message_type, media_url, 
                           is_deleted, is_edited, original_content, updated_at, created_at
                    FROM messages
                    WHERE (sender_id = %s AND receiver_id = %s) OR (sender_id = %s AND receiver_id = %s)
                    ORDER BY created_at ASC
                    """,
                    (user1_id, user2_id, user2_id, user1_id),
                )
                messages = cursor.fetchall()
            conn.close()

            if not messages:
                no_msg = tk.Label(
                    self.scrollable_chat_frame,
                    text="Bu iki kullanıcı arasında henüz mesaj bulunmuyor.",
                    bg="#0B141A",
                    fg="#8696A0",
                    font=("Segoe UI", 11),
                )
                no_msg.pack(pady=40)
                return

            for msg in messages:
                is_sender = (msg["sender_id"] == user1_id)
                self._create_message_bubble(msg, is_sender, user1_id, user2_id)

            # Auto scroll to bottom
            self.after(100, lambda: self.canvas.yview_moveto(1.0))
        except Exception as e:
            messagebox.showerror("Hata", f"Mesajlar yüklenemedi: {e}")

    def _create_message_bubble(self, msg, is_sender, user1_id, user2_id):
        # WhatsApp bubble colors:
        # Sender (right): #005C4B
        # Receiver (left): #202C33
        bubble_bg = "#005C4B" if is_sender else "#202C33"
        align = tk.RIGHT if is_sender else tk.LEFT
        outer_padx = (80, 16) if is_sender else (16, 80)

        raw_content = msg.get("content") or ""
        decrypted_text = decrypt_text(raw_content, msg["sender_id"], msg["receiver_id"])
        media_url = msg.get("media_url")
        msg_type = msg.get("message_type") or "text"
        time_str = str(msg.get("created_at") or "")[11:16]

        # Row Frame
        row_frame = tk.Frame(self.scrollable_chat_frame, bg="#0B141A")
        row_frame.pack(fill=tk.X, pady=4, padx=12)

        # Bubble Container
        bubble = tk.Frame(row_frame, bg=bubble_bg, padx=10, pady=8)
        bubble.pack(side=align, padx=outer_padx)

        # 1. SENDER NAME (Small header) with Status Badges
        header_row = tk.Frame(bubble, bg=bubble_bg)
        header_row.pack(fill=tk.X, pady=(0, 2))

        sender_lbl = tk.Label(
            header_row,
            text=f"Kullanıcı #{msg['sender_id']}",
            bg=bubble_bg,
            fg="#25D366" if is_sender else "#53BDEB",
            font=("Segoe UI", 8, "bold"),
        )
        sender_lbl.pack(side=tk.LEFT)

        if msg.get("is_deleted"):
            del_badge = tk.Label(
                header_row,
                text=" ⚠️ KULLANICI BU MESAJI SİLDİ! ",
                bg="#E74C3C",
                fg="#FFFFFF",
                font=("Segoe UI", 8, "bold"),
            )
            del_badge.pack(side=tk.RIGHT, padx=4)

        if msg.get("is_edited"):
            edit_badge = tk.Label(
                header_row,
                text=" ✏️ DÜZENLENDİ ",
                bg="#E67E22",
                fg="#FFFFFF",
                font=("Segoe UI", 8, "bold"),
            )
            edit_badge.pack(side=tk.RIGHT, padx=4)

        # 2. MEDIA DISPLAY (If Photo or Video)
        if media_url:
            self._render_media_inside_bubble(bubble, media_url, msg_type, msg["sender_id"], msg["receiver_id"], bubble_bg)

        # 3. TEXT CONTENT (Show Current Decrypted Text)
        if decrypted_text and decrypted_text != "📷 Fotoğraf" and decrypted_text != "🎥 Video":
            text_lbl = tk.Label(
                bubble,
                text=f"✏️ Güncel Mesaj: {decrypted_text}" if msg.get("is_edited") else decrypted_text,
                bg=bubble_bg,
                fg="#E9EDEF",
                font=("Segoe UI", 10, "bold" if msg.get("is_edited") else "normal"),
                wraplength=480,
                justify=tk.LEFT,
            )
            text_lbl.pack(anchor="w", pady=(2, 2))

        # 4. IF EDITED: SHOW ORIGINAL CONTENT (FORENSIC AUDIT)
        if msg.get("is_edited") and msg.get("original_content"):
            orig_raw = msg["original_content"]
            orig_dec = decrypt_text(orig_raw, msg["sender_id"], msg["receiver_id"])
            orig_box = tk.Frame(bubble, bg="#111B21", padx=8, pady=6, highlightbackground="#E67E22", highlightthickness=1)
            orig_box.pack(fill=tk.X, pady=(4, 4))
            tk.Label(
                orig_box,
                text="🔍 ADLİ DENETİM (DÜZENLEME GEÇMİŞİ):",
                bg="#111B21",
                fg="#E67E22",
                font=("Segoe UI", 8, "bold"),
            ).pack(anchor="w")
            tk.Label(
                orig_box,
                text=f"1️⃣ Orijinal İlk Hali :  \"{orig_dec}\"",
                bg="#111B21",
                fg="#F39C12",
                font=("Segoe UI", 9, "bold"),
                wraplength=460,
                justify=tk.LEFT,
            ).pack(anchor="w", pady=(2, 1))
            tk.Label(
                orig_box,
                text=f"2️⃣ Düzenlenmiş Hali:  \"{decrypted_text}\"",
                bg="#111B21",
                fg="#2ECC71",
                font=("Segoe UI", 9, "bold"),
                wraplength=460,
                justify=tk.LEFT,
            ).pack(anchor="w", pady=(1, 2))

        # 5. TIMESTAMP & E2EE SHIELD
        footer_frame = tk.Frame(bubble, bg=bubble_bg)
        footer_frame.pack(anchor="e", pady=(2, 0))

        shield_lbl = tk.Label(
            footer_frame,
            text="🔒 Çözüldü",
            bg=bubble_bg,
            fg="#00D2D3",
            font=("Segoe UI", 7),
        )
        shield_lbl.pack(side=tk.LEFT, padx=(0, 4))

        time_lbl = tk.Label(
            footer_frame,
            text=time_str,
            bg=bubble_bg,
            fg="#8696A0",
            font=("Segoe UI", 8),
        )
        time_lbl.pack(side=tk.LEFT)

    def _render_media_inside_bubble(self, bubble, media_url, msg_type, sender_id, receiver_id, bubble_bg):
        filename = media_url.split("/")[-1]
        local_path = os.path.join(UPLOADS_DIR, filename)

        if not os.path.exists(local_path):
            missing_lbl = tk.Label(
                bubble,
                text=f"⚠️ Dosya Bulunamadı ({filename})",
                bg=bubble_bg,
                fg="#E74C3C",
                font=("Segoe UI", 9, "italic"),
            )
            missing_lbl.pack(pady=4)
            return

        with open(local_path, "rb") as f:
            encrypted_bytes = f.read()

        # Decrypt binary file in memory
        decrypted_bytes = decrypt_file_bytes(encrypted_bytes, sender_id, receiver_id)

        # Case A: IMAGE PREVIEW
        if msg_type == "image" or filename.lower().endswith((".jpg", ".jpeg", ".png", ".webp")):
            try:
                pil_img = Image.open(io.BytesIO(decrypted_bytes))
                pil_img.thumbnail((320, 240))
                tk_img = ImageTk.PhotoImage(pil_img)
                self.cached_images[media_url] = tk_img

                img_label = tk.Label(bubble, image=tk_img, bg=bubble_bg, cursor="hand2")
                img_label.pack(pady=4)
                # Click to open full screen native
                img_label.bind("<Button-1>", lambda e: self._launch_native_viewer(decrypted_bytes, "jpg"))
            except Exception as e:
                err_lbl = tk.Label(bubble, text="🖼️ [Fotoğraf Önizleme Hatası]", bg=bubble_bg, fg="#FFA502")
                err_lbl.pack()

        # Case B: VIDEO / DOCUMENT
        else:
            is_video = msg_type == "video" or filename.lower().endswith((".mp4", ".mov", ".mkv"))
            icon_text = "🎥 VİDEO MESAJI" if is_video else "📄 BELGE / DOSYA"
            
            media_card = tk.Frame(bubble, bg="#111B21", padx=12, pady=10)
            media_card.pack(fill=tk.X, pady=4)

            tk.Label(
                media_card,
                text=icon_text,
                bg="#111B21",
                fg="#00D2D3",
                font=("Segoe UI", 9, "bold"),
            ).pack(anchor="w")

            tk.Label(
                media_card,
                text=filename,
                bg="#111B21",
                fg="#8696A0",
                font=("Segoe UI", 8),
            ).pack(anchor="w", pady=(2, 6))

            play_btn = tk.Button(
                media_card,
                text="▶️ Çöz ve Oynat" if is_video else "📂 Çöz ve Aç",
                bg="#00A884",
                fg="#FFFFFF",
                font=("Segoe UI", 8, "bold"),
                relief=tk.FLAT,
                command=lambda: self._launch_native_viewer(decrypted_bytes, "mp4" if is_video else "dat"),
            )
            play_btn.pack(side=tk.LEFT)

    def _launch_native_viewer(self, decrypted_bytes, ext):
        with tempfile.NamedTemporaryFile(delete=False, suffix=f".{ext}") as tmp:
            tmp.write(decrypted_bytes)
            tmp_path = tmp.name
        try:
            os.startfile(tmp_path)
        except Exception as e:
            messagebox.showerror("Hata", f"Dosya açılamadı: {e}")

    def export_report(self):
        if not self.active_user or not self.active_peer:
            messagebox.showinfo("Bilgi", "Lütfen bir sohbet seçin.")
            return

        u1 = self.active_user
        u2 = self.active_peer
        dest = filedialog.asksaveasfilename(
            title="Sohbet Raporunu Kaydet",
            initialfile=f"Talknex_Sohbet_{u1['id']}_{u2['id']}.txt",
            defaultextension=".txt",
            filetypes=[("Metin Dosyası", "*.txt")],
        )
        if not dest:
            return

        try:
            conn = get_db()
            with conn.cursor() as cursor:
                cursor.execute(
                    """
                    SELECT id, sender_id, receiver_id, content, message_type, media_url, created_at
                    FROM messages
                    WHERE (sender_id = %s AND receiver_id = %s) OR (sender_id = %s AND receiver_id = %s)
                    ORDER BY created_at ASC
                    """,
                    (u1["id"], u2["id"], u2["id"], u1["id"]),
                )
                msgs = cursor.fetchall()
            conn.close()

            with open(dest, "w", encoding="utf-8") as f:
                f.write("TALKNEX SOHBET DENETİM RAPORU\n")
                f.write(f"Tarih: {datetime.now()}\n")
                f.write(f"Kullanıcı 1: {u1.get('display_name')} (ID #{u1['id']})\n")
                f.write(f"Kullanıcı 2: {u2.get('display_name')} (ID #{u2['id']})\n")
                f.write("=" * 60 + "\n\n")

                for m in msgs:
                    raw = m.get("content") or ""
                    dec = decrypt_text(raw, m["sender_id"], m["receiver_id"])
                    f.write(f"[{m.get('created_at')}] ID #{m['sender_id']} ➡️ ID #{m['receiver_id']}\n")
                    f.write(f"  Tür: {m.get('message_type')}\n")
                    f.write(f"  Mesaj: {dec}\n")
                    if m.get("media_url"):
                        f.write(f"  Medya: {m.get('media_url')}\n")
                    f.write("-" * 40 + "\n")

            messagebox.showinfo("Başarılı", f"Rapor kaydedildi:\n{dest}")
        except Exception as e:
            messagebox.showerror("Hata", f"Rapor oluşturulamadı: {e}")


if __name__ == "__main__":
    app = TalknexChatAdminApp()
    app.mainloop()
