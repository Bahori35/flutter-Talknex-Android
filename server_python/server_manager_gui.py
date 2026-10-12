"""
Talknex Server Control Center (GUI)
Modern dark-themed server control panel for Windows.
Controls:
- Nginx Web Proxy (Port 3000)
- Uvicorn Backend (Port 3001)
- Thread / Worker / CPU Affinity Configuration
- Live CPU & RAM Usage Monitor
- Live Server Output Logs
- Start, Stop, Restart Controls
"""

import os
import sys
import time
import subprocess
import threading
import tkinter as tk
from tkinter import ttk, messagebox
import psutil

# Colors & Theme
BG_MAIN = "#0F172A"       # Slate 900
BG_CARD = "#1E293B"       # Slate 800
BG_LOG = "#0B0F19"        # Dark terminal
FG_TEXT = "#F8FAFC"       # Slate 50
FG_MUTED = "#94A3B8"      # Slate 400
ACCENT_BLUE = "#3B82F6"   # Blue
ACCENT_GREEN = "#10B981"  # Emerald
ACCENT_RED = "#EF4444"    # Red
ACCENT_AMBER = "#F59E0B"  # Amber
BORDER_COLOR = "#334155"  # Slate 700

CURRENT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(CURRENT_DIR)
NGINX_C_DIR = r"C:\nginx"
NGINX_LOCAL_DIR = os.path.join(PROJECT_ROOT, "nginx")

class ServerManagerGUI:
    def __init__(self, root):
        self.root = root
        self.root.title("Talknex Server Control Center ⚡")
        self.root.geometry("980x680")
        self.root.minsize(860, 600)
        self.root.configure(bg=BG_MAIN)

        self.server_process = None
        self.log_reader_thread = None
        self.is_running = False
        self.total_cores = os.cpu_count() or 4

        self.setup_ui()
        self.start_system_monitor()

    def setup_ui(self):
        # Header Frame
        header = tk.Frame(self.root, bg=BG_CARD, height=70, bd=0, highlightbackground=BORDER_COLOR, highlightthickness=1)
        header.pack(fill=tk.X, side=tk.TOP)
        header.pack_propagate(False)

        title_lbl = tk.Label(header, text="TALKNEX SERVER CONTROL CENTER", font=("Segoe UI", 16, "bold"), fg=FG_TEXT, bg=BG_CARD)
        title_lbl.pack(side=tk.LEFT, padx=20, pady=10)

        # Right-side stats container in header
        hdr_right = tk.Frame(header, bg=BG_CARD)
        hdr_right.pack(side=tk.RIGHT, padx=20)

        self.users_badge = tk.Label(hdr_right, text="👥 Çevrimiçi: 0  |  Toplam: 0", font=("Segoe UI", 11, "bold"),
                                    fg="#38BDF8", bg=BG_MAIN, padx=12, pady=4, relief=tk.SOLID, bd=1)
        self.users_badge.pack(side=tk.LEFT, padx=(0, 15))

        self.status_badge = tk.Label(hdr_right, text="● DURDURULDU", font=("Segoe UI", 11, "bold"), fg=ACCENT_RED, bg=BG_CARD)
        self.status_badge.pack(side=tk.LEFT)

        # Main Body Container
        body = tk.Frame(self.root, bg=BG_MAIN)
        body.pack(fill=tk.BOTH, expand=True, padx=20, pady=15)

        # Top Grid: Controls + Hardware Stats
        top_grid = tk.Frame(body, bg=BG_MAIN)
        top_grid.pack(fill=tk.X, pady=(0, 15))

        # --- LEFT CARD: Controls & Settings ---
        ctrl_card = tk.LabelFrame(top_grid, text=" Sunucu Yapılandırması ", font=("Segoe UI", 11, "bold"),
                                  fg=FG_TEXT, bg=BG_CARD, bd=1, relief=tk.SOLID, highlightbackground=BORDER_COLOR)
        ctrl_card.pack(side=tk.LEFT, fill=tk.BOTH, expand=True, padx=(0, 10))

        # Worker & Thread Selector (Custom Input + Presets)
        thread_frame = tk.Frame(ctrl_card, bg=BG_CARD)
        thread_frame.pack(fill=tk.X, padx=15, pady=12)

        tk.Label(thread_frame, text=f"Kullanılacak İşlemci Thread / Çekirdek Sayısı (Sistemde Toplam: {self.total_cores} Çekirdek):",
                 font=("Segoe UI", 10, "bold"), fg=FG_TEXT, bg=BG_CARD).pack(anchor="w")

        opts_frame = tk.Frame(thread_frame, bg=BG_CARD)
        opts_frame.pack(fill=tk.X, pady=(6, 4))

        tk.Label(opts_frame, text="Thread Sayısı (Elle Yazılabilir):", font=("Segoe UI", 9), fg=FG_MUTED, bg=BG_CARD).pack(side=tk.LEFT, padx=(0, 8))

        self.thread_var = tk.StringVar(value=str(self.total_cores))
        self.thread_entry = tk.Spinbox(opts_frame, from_=1, to=256, textvariable=self.thread_var,
                                       font=("Segoe UI", 11, "bold"), width=6, bg=BG_MAIN, fg="#38BDF8",
                                       insertbackground=FG_TEXT, relief=tk.SOLID, bd=1, justify=tk.CENTER)
        self.thread_entry.pack(side=tk.LEFT, padx=(0, 15))

        # Quick preset buttons
        tk.Label(opts_frame, text="Hızlı Seçim:", font=("Segoe UI", 9), fg=FG_MUTED, bg=BG_CARD).pack(side=tk.LEFT, padx=(0, 5))

        def set_preset(val):
            self.thread_var.set(str(val))

        for p_val in [2, 4, 8, 12, 16, 24, self.total_cores]:
            if p_val <= max(self.total_cores, 24):
                btn_p = tk.Button(opts_frame, text=str(p_val) if p_val != self.total_cores else f"{p_val} (Tümü)",
                                  font=("Segoe UI", 8, "bold"), bg=BORDER_COLOR, fg=FG_TEXT,
                                  relief=tk.FLAT, padx=6, pady=1, cursor="hand2",
                                  command=lambda v=p_val: set_preset(v))
                btn_p.pack(side=tk.LEFT, padx=2)

        # Buttons (Start, Stop, Restart)
        btn_frame = tk.Frame(ctrl_card, bg=BG_CARD)
        btn_frame.pack(fill=tk.X, padx=15, pady=(5, 15))

        self.btn_start = tk.Button(btn_frame, text="▶ BAŞLAT", font=("Segoe UI", 11, "bold"),
                                   bg=ACCENT_GREEN, fg="#FFFFFF", relief=tk.FLAT, padx=18, pady=8, cursor="hand2", command=self.start_server)
        self.btn_start.pack(side=tk.LEFT, padx=(0, 10))

        self.btn_stop = tk.Button(btn_frame, text="⏹ DURDUR", font=("Segoe UI", 11, "bold"),
                                  bg=ACCENT_RED, fg="#FFFFFF", relief=tk.FLAT, padx=18, pady=8, cursor="hand2", state=tk.DISABLED, command=self.stop_server)
        self.btn_stop.pack(side=tk.LEFT, padx=(0, 10))

        self.btn_restart = tk.Button(btn_frame, text="🔄 YENİDEN BAŞLAT", font=("Segoe UI", 11, "bold"),
                                     bg=ACCENT_BLUE, fg="#FFFFFF", relief=tk.FLAT, padx=18, pady=8, cursor="hand2", command=self.restart_server)
        self.btn_restart.pack(side=tk.LEFT)

        # --- RIGHT CARD: Hardware & Network Monitor ---
        hw_card = tk.LabelFrame(top_grid, text=" Donanım & Servis Durumu ", font=("Segoe UI", 11, "bold"),
                                fg=FG_TEXT, bg=BG_CARD, bd=1, relief=tk.SOLID, highlightbackground=BORDER_COLOR)
        hw_card.pack(side=tk.RIGHT, fill=tk.BOTH, expand=True, padx=(10, 0))

        hw_grid = tk.Frame(hw_card, bg=BG_CARD)
        hw_grid.pack(fill=tk.BOTH, expand=True, padx=15, pady=10)

        # Hardware & Network Grid
        # CPU Usage & Speed
        self.cpu_lbl = tk.Label(hw_grid, text="İşlemci (CPU): %0 (0.0 GHz)", font=("Segoe UI", 10, "bold"), fg=FG_TEXT, bg=BG_CARD)
        self.cpu_lbl.grid(row=0, column=0, sticky="w", pady=3)
        self.cpu_bar = ttk.Progressbar(hw_grid, orient="horizontal", length=180, mode="determinate")
        self.cpu_bar.grid(row=0, column=1, padx=10, pady=3)

        # RAM Usage & Speed
        self.ram_lbl = tk.Label(hw_grid, text="Bellek (RAM): %0 (0 MHz)", font=("Segoe UI", 10, "bold"), fg=FG_TEXT, bg=BG_CARD)
        self.ram_lbl.grid(row=1, column=0, sticky="w", pady=3)
        self.ram_bar = ttk.Progressbar(hw_grid, orient="horizontal", length=180, mode="determinate")
        self.ram_bar.grid(row=1, column=1, padx=10, pady=3)

        # Ports & Hardware Specs Details
        self.specs_lbl = tk.Label(hw_grid, text="• Nginx Proxy: Port 3000 | Uvicorn: Port 3001\n• Toplam: " + str(self.total_cores) + " Thread | RAM: 0 GB",
                                  font=("Segoe UI", 9), fg=FG_MUTED, bg=BG_CARD, justify=tk.LEFT)
        self.specs_lbl.grid(row=2, column=0, columnspan=2, sticky="w", pady=(8, 0))

        # --- BOTTOM: Live Console Logs ---
        log_frame = tk.LabelFrame(body, text=" Canlı Sunucu Logları ", font=("Segoe UI", 11, "bold"),
                                  fg=FG_TEXT, bg=BG_CARD, bd=1, relief=tk.SOLID, highlightbackground=BORDER_COLOR)
        log_frame.pack(fill=tk.BOTH, expand=True)

        self.log_text = tk.Text(log_frame, bg=BG_LOG, fg="#38BDF8", insertbackground=FG_TEXT,
                                font=("Consolas", 10), wrap=tk.WORD, bd=0, padx=10, pady=10)
        self.log_text.pack(side=tk.LEFT, fill=tk.BOTH, expand=True)

        scrollbar = tk.Scrollbar(log_frame, command=self.log_text.yview)
        scrollbar.pack(side=tk.RIGHT, fill=tk.Y)
        self.log_text.config(yscrollcommand=scrollbar.set)

        # Clear Log Button on corner
        btn_clear = tk.Button(log_frame, text="Logları Temizle", font=("Segoe UI", 8), bg=BORDER_COLOR, fg=FG_TEXT,
                              relief=tk.FLAT, padx=6, pady=2, command=lambda: self.log_text.delete('1.0', tk.END))
        btn_clear.place(relx=1.0, rely=0.0, anchor="ne", x=-25, y=5)

        self.log("[SİSTEM] Talknex Sunucu Kontrol Merkezi hazır. Başlat butonuna basabilirsiniz.")

    def log(self, text):
        self.root.after(0, self._append_log, text)

    def _append_log(self, text):
        self.log_text.insert(tk.END, text + "\n")
        self.log_text.see(tk.END)

    def _detect_ram_speed(self):
        try:
            out = subprocess.check_output(['wmic', 'memorychip', 'get', 'speed'], text=True, stderr=subprocess.DEVNULL)
            speeds = [int(s) for s in out.split() if s.isdigit() and int(s) > 0]
            if speeds:
                return f"{max(speeds)} MHz"
        except Exception:
            pass
        return ""

    def start_system_monitor(self):
        ram_speed_str = self._detect_ram_speed()
        total_ram_gb = round(psutil.virtual_memory().total / (1024**3), 1)

        def monitor_loop():
            user_check_counter = 0
            online_users = 0
            total_users = 0

            while True:
                try:
                    cpu_pct = psutil.cpu_percent(interval=1)
                    vmem = psutil.virtual_memory()
                    ram_pct = vmem.percent
                    ram_used_gb = round(vmem.used / (1024**3), 1)

                    # CPU GHz
                    freq = psutil.cpu_freq()
                    ghz_str = f"{(freq.current / 1000):.2f} GHz" if freq and freq.current else ""

                    # User count check every 3 seconds
                    user_check_counter += 1
                    if user_check_counter >= 3:
                        user_check_counter = 0
                        try:
                            import pymysql
                            conn = pymysql.connect(host='localhost', user='root', password='', database='chat_app_db', autocommit=True)
                            with conn.cursor() as cur:
                                cur.execute("SELECT COUNT(*) FROM users")
                                total_users = cur.fetchone()[0]
                                cur.execute("SELECT COUNT(*) FROM users WHERE is_online = 1")
                                online_users = cur.fetchone()[0]
                            conn.close()
                        except Exception:
                            pass

                    self.root.after(0, self._update_stats, cpu_pct, ghz_str, ram_pct, ram_used_gb, total_ram_gb, ram_speed_str, online_users, total_users)
                except Exception:
                    time.sleep(1)

        t = threading.Thread(target=monitor_loop, daemon=True)
        t.start()

    def _update_stats(self, cpu, ghz, ram, ram_used, total_ram, ram_speed, online, total):
        # Update CPU label & bar
        ghz_part = f" ({ghz})" if ghz else ""
        self.cpu_lbl.config(text=f"İşlemci (CPU): %{cpu:.1f}{ghz_part}")
        self.cpu_bar["value"] = cpu

        # Update RAM label & bar
        mhz_part = f" - {ram_speed}" if ram_speed else ""
        self.ram_lbl.config(text=f"Bellek (RAM): %{ram:.1f} ({ram_used}/{total_ram} GB{mhz_part})")
        self.ram_bar["value"] = ram

        # Update Specs Label
        self.specs_lbl.config(text=f"• Nginx: Port 3000 | Uvicorn: Port 3001\n• Toplam: {self.total_cores} Thread | Toplam Bellek: {total_ram} GB {ram_speed}")

        # Update Users Badge
        self.users_badge.config(text=f"👥 Çevrimiçi: {online}  |  Toplam Kayıtlı: {total}")

    def get_nginx_exe(self):
        if os.path.exists(os.path.join(NGINX_C_DIR, "nginx.exe")):
            return NGINX_C_DIR
        if os.path.exists(os.path.join(NGINX_LOCAL_DIR, "nginx.exe")):
            return NGINX_LOCAL_DIR
        return None

    def kill_ports_and_processes(self):
        # Kill nginx
        subprocess.run(["taskkill", "/F", "/IM", "nginx.exe"], capture_output=True)
        # Kill whatever uses port 3001
        for proc in psutil.process_iter(['pid', 'name']):
            try:
                for conn in proc.connections(kind='inet'):
                    if conn.laddr.port in (3001, 3000):
                        if proc.name().lower() not in ("nginx.exe", "system"):
                            proc.kill()
            except (psutil.NoSuchProcess, psutil.AccessDenied):
                pass

    def start_server(self):
        if self.is_running:
            return

        self.log("=" * 60)
        self.log("[1/3] Önceki servisler ve portlar temizleniyor...")
        self.kill_ports_and_processes()
        time.sleep(0.5)

        # 1. Start Nginx
        # Ensure C:\talknex_uploads junction exists to avoid Windows Unicode path issues
        uploads_source = os.path.join(CURRENT_DIR, "uploads")
        junction_path = r"C:\talknex_uploads"
        if not os.path.exists(junction_path):
            try:
                subprocess.run(["powershell", "-Command", f"New-Item -ItemType Junction -Path '{junction_path}' -Target '{uploads_source}'"], capture_output=True)
            except Exception:
                pass

        nginx_dir = self.get_nginx_exe()
        if nginx_dir:
            nginx_exe = os.path.join(nginx_dir, "nginx.exe")
            self.log(f"[2/3] Nginx Web Hızlandırıcı başlatılıyor ({nginx_exe})...")
            try:
                subprocess.Popen([nginx_exe], cwd=nginx_dir, creationflags=subprocess.CREATE_NO_WINDOW)
                self.log("[OK] Nginx Port 3000 üzerinde devrede (Video / Medya / Proxy).")
            except Exception as e:
                self.log(f"[UYARI] Nginx başlatılamadı: {e}")
        else:
            self.log("[UYARI] Nginx bulunamadı, doğrudan Uvicorn çalışacak.")

        # 2. Start Uvicorn Backend with thread count
        try:
            raw_val = self.thread_var.get().strip()
            assigned_threads = int(raw_val) if raw_val.isdigit() else self.total_cores
            if assigned_threads < 1:
                assigned_threads = 1
        except Exception:
            assigned_threads = self.total_cores

        self.log(f"[3/3] Python Uvicorn Backend başlatılıyor -> Hedef: {assigned_threads} CPU Thread...")

        env = os.environ.copy()
        env["PORT"] = "3001"
        env["PYTHONUNBUFFERED"] = "1"

        try:
            self.server_process = subprocess.Popen(
                [sys.executable, "main.py"],
                cwd=CURRENT_DIR,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
                env=env,
                creationflags=subprocess.CREATE_NO_WINDOW
            )

            # Set CPU Affinity to assign exact number of threads
            try:
                p = psutil.Process(self.server_process.pid)
                # If requested threads exceed physical cores, clamp to total_cores
                affinity_count = min(assigned_threads, self.total_cores)
                affinity = list(range(affinity_count))
                p.cpu_affinity(affinity)
                self.log(f"[OK] CPU Affinity tanımlandı: Çekirdek 0..{affinity_count - 1} ({assigned_threads} thread hedefi) tahsis edildi.")
            except Exception as aff_err:
                self.log(f"[BİLGİ] CPU Affinity: {aff_err}")

            self.is_running = True
            self.status_badge.config(text="● ÇALIŞIYOR", fg=ACCENT_GREEN)
            self.btn_start.config(state=tk.DISABLED)
            self.btn_stop.config(state=tk.NORMAL)

            # Start reading logs
            def stream_logs():
                for line in iter(self.server_process.stdout.readline, ''):
                    if line:
                        self.log(line.strip())
                self.server_process.stdout.close()
                self.is_running = False
                self.root.after(0, self._on_process_exit)

            self.log_reader_thread = threading.Thread(target=stream_logs, daemon=True)
            self.log_reader_thread.start()

        except Exception as e:
            self.log(f"[HATA] Sunucu başlatılamadı: {e}")
            messagebox.showerror("Hata", f"Sunucu başlatılamadı:\n{e}")

    def _on_process_exit(self):
        self.status_badge.config(text="● DURDURULDU", fg=ACCENT_RED)
        self.btn_start.config(state=tk.NORMAL)
        self.btn_stop.config(state=tk.DISABLED)
        self.log("[BİLGİ] Sunucu süreci kapandı.")

    def stop_server(self):
        if not self.is_running and not self.server_process:
            return

        self.log("[SİSTEM] Sunucu durduruluyor...")
        if self.server_process:
            try:
                self.server_process.terminate()
            except Exception:
                pass
            self.server_process = None

        self.kill_ports_and_processes()
        self.is_running = False
        self.status_badge.config(text="● DURDURULDU", fg=ACCENT_RED)
        self.btn_start.config(state=tk.NORMAL)
        self.btn_stop.config(state=tk.DISABLED)
        self.log("[OK] Nginx ve Python Uvicorn tamamen durduruldu.")

    def restart_server(self):
        self.log("[SİSTEM] Sunucu yeniden başlatılıyor...")
        self.stop_server()
        self.root.after(1000, self.start_server)


def main():
    root = tk.Tk()
    # Set app icon if available
    app = ServerManagerGUI(root)
    # Handle window close
    def on_closing():
        if app.is_running:
            if messagebox.askyesno("Çıkış", "Sunucu çalışıyor. Kapatmak istediğinize emin misiniz?"):
                app.stop_server()
                root.destroy()
        else:
            root.destroy()

    root.protocol("WM_DELETE_WINDOW", on_closing)
    root.mainloop()

if __name__ == "__main__":
    main()
