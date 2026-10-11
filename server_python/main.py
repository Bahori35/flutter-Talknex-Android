import os
import uuid
import pymysql
import socketio
import uvicorn
import bcrypt
import firebase_admin
from firebase_admin import credentials, messaging
from fastapi import FastAPI, HTTPException, File, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import Optional
from jose import jwt
from datetime import datetime, timedelta

# DB Configuration
DB_HOST = os.getenv("DB_HOST", "localhost")
DB_USER = os.getenv("DB_USER", "root")
DB_PASSWORD = os.getenv("DB_PASSWORD", "")
DB_NAME = os.getenv("DB_NAME", "chat_app_db")
DB_PORT = int(os.getenv("DB_PORT", 3306))
SECRET_KEY = os.getenv("JWT_SECRET", "super_secret_jwt_key_talknex_2026")

# --- FIREBASE ADMIN INITIALIZATION ---
firebase_initialized = False
try:
    current_dir = os.path.dirname(__file__)
    key_files = [f for f in os.listdir(current_dir) if f.startswith("safechet-bildirim-firebase-adminsdk") and f.endswith(".json")]
    if key_files:
        key_path = os.path.join(current_dir, key_files[0])
        if not firebase_admin._apps:
            cred = credentials.Certificate(key_path)
            firebase_admin.initialize_app(cred)
            firebase_initialized = True
            print(f"[OK] Firebase Admin SDK yuklendi: {key_files[0]}")
        else:
            firebase_initialized = True
            print("[OK] Firebase Admin SDK zaten calisiyor!")
    else:
        print(f"[UYARI] Firebase key dosyasi bulunamadi (safechet-bildirim-firebase-adminsdk-*.json)")
except Exception as e:
    print(f"[HATA] Firebase Admin baslatilamadi: {e}")

def send_fcm_push(user_id: int, title: str, body: str, data_payload: dict = None):
    if not firebase_initialized:
        return
    try:
        conn = get_db_connection()
        with conn.cursor() as cursor:
            cursor.execute("SELECT fcm_token FROM users WHERE id = %s", (user_id,))
            row = cursor.fetchone()
        conn.close()

        if not row or not row.get("fcm_token"):
            print(f"[FCM UYARI] Kullanici #{user_id} icin veritabaninda fcm_token bulunamadi (NULL)! Bildirim atilamadi.")
            return

        fcm_token = row["fcm_token"]
        msg_data = {k: str(v) for k, v in (data_payload or {}).items()}
        
        # High priority Android DATA-ONLY payload (prevent duplicate notification from Android OS)
        msg_data["title"] = str(title)
        msg_data["body"] = str(body)
        
        message = messaging.Message(
            data=msg_data,
            android=messaging.AndroidConfig(
                priority="high",
                ttl=timedelta(seconds=60) if msg_data.get("type") == "call" else timedelta(hours=24),
            ),
            token=fcm_token,
        )
        response = messaging.send(message)
        print(f"[FCM] Push bildirimi basariyla gonderildi (Kullanici ID: {user_id}): {response}")
    except Exception as e:
        print(f"[FCM HATA] Bildirim gonderilemedi (Kullanici ID: {user_id}): {e}")


def hash_password(password: str) -> str:
    salt = bcrypt.gensalt()
    return bcrypt.hashpw(password.encode('utf-8'), salt).decode('utf-8')

def verify_password(plain_password: str, hashed_password: str) -> bool:
    try:
        return bcrypt.checkpw(plain_password.encode('utf-8'), hashed_password.encode('utf-8'))
    except Exception:
        return False

def get_db_connection():
    return pymysql.connect(
        host=DB_HOST,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        port=DB_PORT,
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True
    )

def init_db():
    try:
        # First connect without db to create database if not exists
        conn = pymysql.connect(host=DB_HOST, user=DB_USER, password=DB_PASSWORD, port=DB_PORT, autocommit=True)
        with conn.cursor() as cursor:
            cursor.execute(f"CREATE DATABASE IF NOT EXISTS {DB_NAME} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;")
        conn.close()

        # Connect to chat_app_db and create tables
        conn = get_db_connection()
        with conn.cursor() as cursor:
            cursor.execute("""
            CREATE TABLE IF NOT EXISTS users (
                id INT AUTO_INCREMENT PRIMARY KEY,
                username VARCHAR(50) UNIQUE NOT NULL,
                display_name VARCHAR(100) NOT NULL,
                password_hash VARCHAR(255) NOT NULL,
                photo_url VARCHAR(255) DEFAULT '',
                phone_number VARCHAR(30) DEFAULT '',
                status VARCHAR(255) DEFAULT 'Hey there! I am using this app.',
                fcm_token TEXT NULL,
                is_online BOOLEAN DEFAULT FALSE,
                last_seen TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            );
            """)

            try:
                cursor.execute("ALTER TABLE users ADD COLUMN phone_number VARCHAR(30) DEFAULT '';")
            except Exception:
                pass

            try:
                cursor.execute("ALTER TABLE users ADD COLUMN fcm_token TEXT NULL;")
            except Exception:
                pass

            cursor.execute("""
            CREATE TABLE IF NOT EXISTS messages (
                id INT AUTO_INCREMENT PRIMARY KEY,
                sender_id INT NOT NULL,
                receiver_id INT NOT NULL,
                content TEXT NOT NULL,
                message_type ENUM('text', 'image', 'audio', 'call') DEFAULT 'text',
                is_delivered BOOLEAN DEFAULT FALSE,
                is_read BOOLEAN DEFAULT FALSE,
                media_url VARCHAR(255) NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (sender_id) REFERENCES users(id) ON DELETE CASCADE,
                FOREIGN KEY (receiver_id) REFERENCES users(id) ON DELETE CASCADE
            );
            """)

            try:
                cursor.execute("ALTER TABLE messages ADD COLUMN is_delivered BOOLEAN DEFAULT FALSE;")
            except Exception:
                pass

            try:
                cursor.execute("ALTER TABLE messages MODIFY COLUMN message_type VARCHAR(50) DEFAULT 'text';")
            except Exception:
                pass

            try:
                cursor.execute("ALTER TABLE messages MODIFY COLUMN media_url TEXT NULL;")
            except Exception:
                pass

            try:
                cursor.execute("ALTER TABLE messages ADD COLUMN is_deleted BOOLEAN DEFAULT FALSE;")
            except Exception:
                pass

            try:
                cursor.execute("ALTER TABLE messages ADD COLUMN is_edited BOOLEAN DEFAULT FALSE;")
            except Exception:
                pass

            try:
                cursor.execute("ALTER TABLE messages ADD COLUMN original_content TEXT NULL;")
            except Exception:
                pass

            try:
                cursor.execute("ALTER TABLE messages ADD COLUMN updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP;")
            except Exception:
                pass

            cursor.execute("""
            CREATE TABLE IF NOT EXISTS call_logs (
                id INT AUTO_INCREMENT PRIMARY KEY,
                caller_id INT NOT NULL,
                receiver_id INT NOT NULL,
                call_type ENUM('audio', 'video') NOT NULL,
                call_status ENUM('missed', 'accepted', 'rejected', 'ended') NOT NULL,
                duration_seconds INT DEFAULT 0,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                FOREIGN KEY (caller_id) REFERENCES users(id) ON DELETE CASCADE,
                FOREIGN KEY (receiver_id) REFERENCES users(id) ON DELETE CASCADE
            );
            """)

            cursor.execute("""
            CREATE TABLE IF NOT EXISTS stories (
                id INT AUTO_INCREMENT PRIMARY KEY,
                user_id INT NOT NULL,
                media_url TEXT NOT NULL,
                caption TEXT NULL,
                media_type ENUM('image', 'video', 'text') DEFAULT 'image',
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                expires_at TIMESTAMP NULL,
                FOREIGN KEY (user_id) REFERENCES users(id) ON DELETE CASCADE
            );
            """)

            cursor.execute("""
            CREATE TABLE IF NOT EXISTS story_views (
                id INT AUTO_INCREMENT PRIMARY KEY,
                story_id INT NOT NULL,
                viewer_id INT NOT NULL,
                viewed_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                UNIQUE KEY unique_story_viewer (story_id, viewer_id),
                FOREIGN KEY (story_id) REFERENCES stories(id) ON DELETE CASCADE,
                FOREIGN KEY (viewer_id) REFERENCES users(id) ON DELETE CASCADE
            );
            """)
        conn.close()
        print("[OK] MariaDB baglantisi ve tablolar hazir!")
    except Exception as e:
        print(f"[UYARI] MariaDB baslatma uyarisi: {e}")

init_db()

def normalize_phone(phone_str: str) -> str:
    if not phone_str:
        return ""
    digits = "".join(c for c in phone_str if c.isdigit())
    if len(digits) >= 10:
        return digits[-10:]
    return digits

# Socket.IO & FastAPI App
sio = socketio.AsyncServer(async_mode="asgi", cors_allowed_origins="*")
app = FastAPI(title="Chat & Call MariaDB Backend")
socket_app = socketio.ASGIApp(sio, app)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Active sockets: user_id -> sid
active_sockets = {}
# Active pending calls: receiver_id (str) -> callData (dict)
active_pending_calls = {}

class RegisterRequest(BaseModel):
    username: str
    password: str
    displayName: Optional[str] = ""
    phoneNumber: Optional[str] = ""

class LoginRequest(BaseModel):
    username: str
    password: str

class FcmTokenRequest(BaseModel):
    userId: int
    fcmToken: str

class MessageDeliveredRequest(BaseModel):
    receiverId: int
    senderId: Optional[int] = None
    messageId: Optional[int] = None

class ProfileUpdateRequest(BaseModel):
    userId: int
    displayName: str
    photoUrl: str
    status: str
    phoneNumber: Optional[str] = ""

# Static file serving for uploads
os.makedirs("uploads", exist_ok=True)
app.mount("/uploads", StaticFiles(directory="uploads"), name="uploads")

# --- AUTH & USER ENDPOINTS ---

@app.post("/api/auth/register")
def register(req: RegisterRequest):
    if not req.username or not req.password:
        raise HTTPException(status_code=400, detail="Kullanıcı adı ve şifre zorunludur.")

    clean_username = req.username.strip().lower()
    conn = get_db_connection()
    with conn.cursor() as cursor:
        cursor.execute("SELECT id FROM users WHERE username = %s", (clean_username,))
        if cursor.fetchone():
            conn.close()
            raise HTTPException(status_code=400, detail="Bu kullanıcı adı zaten alınmış.")

        pwd_hash = hash_password(req.password)
        name = req.displayName.strip() if req.displayName and req.displayName.strip() else clean_username
        photo_url = f"https://ui-avatars.com/api/?name={name}&background=075E54&color=fff"
        phone = req.phoneNumber.strip() if req.phoneNumber else ""

        cursor.execute(
            """INSERT INTO users (username, display_name, password_hash, photo_url, phone_number, is_online)
               VALUES (%s, %s, %s, %s, %s, 1)""",
            (clean_username, name, pwd_hash, photo_url, phone)
        )
        user_id = cursor.lastrowid

    conn.close()

    token = jwt.encode({"id": user_id, "username": clean_username}, SECRET_KEY, algorithm="HS256")

    return {
        "message": "Kayıt başarılı.",
        "token": token,
        "user": {
            "id": user_id,
            "username": clean_username,
            "displayName": name,
            "photoUrl": photo_url,
            "phoneNumber": phone,
            "isOnline": True
        }
    }

@app.post("/api/auth/login")
def login(req: LoginRequest):
    if not req.username or not req.password:
        raise HTTPException(status_code=400, detail="Kullanıcı adı ve şifre zorunludur.")

    clean_username = req.username.strip().lower()
    conn = get_db_connection()
    with conn.cursor() as cursor:
        cursor.execute("SELECT * FROM users WHERE username = %s", (clean_username,))
        user = cursor.fetchone()

        if not user or not verify_password(req.password, user["password_hash"]):
            conn.close()
            raise HTTPException(status_code=400, detail="Kullanıcı adı veya şifre hatalı.")

        cursor.execute("UPDATE users SET is_online = 1 WHERE id = %s", (user["id"],))

    conn.close()

    token = jwt.encode({"id": user["id"], "username": clean_username}, SECRET_KEY, algorithm="HS256")

    return {
        "message": "Giriş başarılı.",
        "token": token,
        "user": {
            "id": user["id"],
            "username": user["username"],
            "displayName": user["display_name"],
            "photoUrl": user["photo_url"] or "",
            "phoneNumber": user.get("phone_number") or "",
            "status": user.get("status") or "Hey there! I am using this app.",
            "isOnline": True
        }
    }

@app.post("/api/users/profile")
def update_profile(req: ProfileUpdateRequest):
    conn = get_db_connection()
    with conn.cursor() as cursor:
        cursor.execute(
            """UPDATE users 
               SET display_name = %s, photo_url = %s, status = %s, phone_number = %s 
               WHERE id = %s""",
            (req.displayName, req.photoUrl, req.status, req.phoneNumber or "", req.userId)
        )
        cursor.execute("SELECT id, username, display_name AS displayName, photo_url AS photoUrl, phone_number AS phoneNumber, status FROM users WHERE id = %s", (req.userId,))
        updated_user = cursor.fetchone()
    conn.close()

    if not updated_user:
        raise HTTPException(status_code=404, detail="Kullanıcı bulunamadı.")

    return {"status": "success", "user": updated_user}

@app.post("/api/users/fcm-token")
def update_fcm_token(req: FcmTokenRequest):
    conn = get_db_connection()
    with conn.cursor() as cursor:
        cursor.execute("UPDATE users SET fcm_token = %s WHERE id = %s", (req.fcmToken, req.userId))
    conn.close()
    return {"status": "success"}

@app.post("/api/upload")
async def upload_file(file: UploadFile = File(...)):
    os.makedirs("uploads", exist_ok=True)
    ext = file.filename.split(".")[-1] if "." in file.filename else "jpg"
    filename = f"{uuid.uuid4().hex}.{ext}"
    file_path = os.path.join("uploads", filename)

    with open(file_path, "wb") as f:
        content = await file.read()
        f.write(content)

    return {"status": "success", "url": f"http://46.197.188.20:3000/uploads/{filename}"}

@app.get("/api/calls/pending/{userId}")
def get_pending_call(userId: str):
    if userId in active_pending_calls:
        return {"hasPendingCall": True, "callData": active_pending_calls[userId]}
    return {"hasPendingCall": False, "callData": None}

class ContactEntry(BaseModel):
    phone: str
    name: Optional[str] = ""

class SyncContactsRequest(BaseModel):
    userId: int
    contacts: list[ContactEntry]

@app.post("/api/users/sync-contacts")
def sync_contacts(req: SyncContactsRequest):
    # Map normalized phone number -> local contact name
    normalized_map = {}
    if req.contacts:
        for entry in req.contacts:
            norm = normalize_phone(entry.phone)
            if norm:
                normalized_map[norm] = entry.name.strip() if entry.name and entry.name.strip() else ""

    conn = get_db_connection()
    with conn.cursor() as cursor:
        cursor.execute(
            "SELECT id, username, display_name AS displayName, photo_url AS photoUrl, phone_number AS phoneNumber, status, is_online AS isOnline, last_seen AS lastSeen FROM users WHERE id != %s",
            (req.userId,)
        )
        all_users = cursor.fetchall()

        # Find user IDs of everyone req.userId has exchanged messages with
        cursor.execute(
            """SELECT DISTINCT CASE 
                   WHEN sender_id = %s THEN receiver_id 
                   ELSE sender_id 
               END AS partner_id 
               FROM messages 
               WHERE sender_id = %s OR receiver_id = %s""",
            (req.userId, req.userId, req.userId)
        )
        chat_partner_rows = cursor.fetchall()
        chat_partner_ids = {row["partner_id"] for row in chat_partner_rows if row.get("partner_id")}
    conn.close()

    matched_users = []
    added_ids = set()

    for u in all_users:
        uid = u["id"]
        uid_str = str(uid)
        u["isOnline"] = uid_str in active_sockets

        user_norm = normalize_phone(u.get("phoneNumber") or "")
        in_contacts = user_norm and user_norm in normalized_map
        in_chat_history = uid in chat_partner_ids

        if in_contacts or in_chat_history:
            # If the user saved this contact with a local phonebook name, use that name!
            if in_contacts:
                local_name = normalized_map[user_norm]
                if local_name:
                    u["displayName"] = local_name
            # Otherwise keep their own displayName or username
            elif not u.get("displayName"):
                u["displayName"] = u.get("phoneNumber") or u.get("username") or "Kullanıcı"

            if uid not in added_ids:
                matched_users.append(u)
                added_ids.add(uid)

    return matched_users

@app.get("/api/messages/{user1}/{user2}")
def get_messages(user1: int, user2: int):
    conn = get_db_connection()
    with conn.cursor() as cursor:
        cursor.execute(
            """SELECT id, sender_id AS senderId, receiver_id AS receiverId, content, message_type AS type, 
                      is_delivered AS isDelivered, is_read AS isRead, media_url AS mediaUrl, 
                      is_deleted AS isDeleted, is_edited AS isEdited, original_content AS originalContent,
                      created_at AS timestamp 
               FROM messages 
               WHERE (sender_id = %s AND receiver_id = %s) OR (sender_id = %s AND receiver_id = %s) 
               ORDER BY created_at ASC""",
            (user1, user2, user2, user1)
        )
        messages = cursor.fetchall()
    conn.close()
    return messages

# --- CALL LOGS ENDPOINTS ---
class SaveCallLogRequest(BaseModel):
    callerId: int
    receiverId: int
    callType: str  # 'audio' or 'video'
    callStatus: str  # 'missed', 'accepted', 'rejected', 'ended'
    durationSeconds: Optional[int] = 0

@app.post("/api/calls/logs")
def save_call_log(req: SaveCallLogRequest):
    conn = get_db_connection()
    with conn.cursor() as cursor:
        cursor.execute(
            """INSERT INTO call_logs (caller_id, receiver_id, call_type, call_status, duration_seconds)
               VALUES (%s, %s, %s, %s, %s)""",
            (req.callerId, req.receiverId, req.callType, req.callStatus, req.durationSeconds)
        )
        log_id = cursor.lastrowid
    conn.close()
    return {"status": "success", "callLogId": log_id}

@app.get("/api/calls/logs/{userId}")
def get_call_logs(userId: int):
    conn = get_db_connection()
    with conn.cursor() as cursor:
        cursor.execute(
            """SELECT cl.id, cl.caller_id AS callerId, cl.receiver_id AS receiverId,
                      cl.call_type AS callType, cl.call_status AS callStatus,
                      cl.duration_seconds AS durationSeconds, cl.created_at AS createdAt,
                      u_caller.display_name AS callerName, u_caller.photo_url AS callerPic,
                      u_receiver.display_name AS receiverName, u_receiver.photo_url AS receiverPic
               FROM call_logs cl
               JOIN users u_caller ON cl.caller_id = u_caller.id
               JOIN users u_receiver ON cl.receiver_id = u_receiver.id
               WHERE cl.caller_id = %s OR cl.receiver_id = %s
               ORDER BY cl.created_at DESC""",
            (userId, userId)
        )
        logs = cursor.fetchall()
    conn.close()
    return logs

# --- STORY / DURUM (STATUS) ENDPOINTS ---

class CreateStoryRequest(BaseModel):
    userId: int
    mediaUrl: str
    caption: Optional[str] = ""
    mediaType: Optional[str] = "image"

class StoryViewRequest(BaseModel):
    storyId: int
    viewerId: int

@app.post("/api/stories")
def create_story(req: CreateStoryRequest):
    conn = get_db_connection()
    with conn.cursor() as cursor:
        cursor.execute(
            """INSERT INTO stories (user_id, media_url, caption, media_type, expires_at)
               VALUES (%s, %s, %s, %s, DATE_ADD(NOW(), INTERVAL 24 HOUR))""",
            (req.userId, req.mediaUrl, req.caption, req.mediaType)
        )
        story_id = cursor.lastrowid
        cursor.execute(
            """SELECT s.id, s.user_id AS userId, s.media_url AS mediaUrl, s.caption, s.media_type AS mediaType,
                      s.created_at AS createdAt, s.expires_at AS expiresAt,
                      u.username, u.display_name AS displayName, u.photo_url AS userPhotoUrl
               FROM stories s
               JOIN users u ON s.user_id = u.id
               WHERE s.id = %s""",
            (story_id,)
        )
        story = cursor.fetchone()
    conn.close()
    return {"status": "success", "story": story}

@app.get("/api/stories")
def get_stories(currentUserId: Optional[int] = 0):
    conn = get_db_connection()
    with conn.cursor() as cursor:
        # Get all non-expired stories (within 24 hours)
        cursor.execute(
            """SELECT s.id, s.user_id AS userId, s.media_url AS mediaUrl, s.caption, s.media_type AS mediaType,
                      s.created_at AS createdAt, s.expires_at AS expiresAt,
                      u.username, u.display_name AS displayName, u.photo_url AS userPhotoUrl,
                      (SELECT COUNT(*) FROM story_views sv WHERE sv.story_id = s.id AND sv.viewer_id = %s) > 0 AS isViewed,
                      (SELECT COUNT(*) FROM story_views sv WHERE sv.story_id = s.id) AS viewCount
               FROM stories s
               JOIN users u ON s.user_id = u.id
               WHERE s.created_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
               ORDER BY s.created_at ASC""",
            (currentUserId,)
        )
        stories = cursor.fetchall()

    conn.close()

    # Group stories by user
    grouped = {}
    for st in stories:
        uid = st["userId"]
        if uid not in grouped:
            grouped[uid] = {
                "userId": uid,
                "username": st["username"],
                "displayName": st["displayName"],
                "userPhotoUrl": st["userPhotoUrl"],
                "stories": [],
                "allViewed": True,
                "latestTimestamp": st["createdAt"]
            }
        
        is_viewed = bool(st["isViewed"])
        if not is_viewed and uid != currentUserId:
            grouped[uid]["allViewed"] = False

        grouped[uid]["latestTimestamp"] = st["createdAt"]
        grouped[uid]["stories"].append({
            "id": st["id"],
            "userId": st["userId"],
            "mediaUrl": st["mediaUrl"],
            "caption": st["caption"] or "",
            "mediaType": st["mediaType"],
            "createdAt": str(st["createdAt"]),
            "isViewed": is_viewed,
            "viewCount": st["viewCount"]
        })

    # Sort so currentUser is handled or recent ones are first
    result = list(grouped.values())
    result.sort(key=lambda x: x["latestTimestamp"], reverse=True)
    return result

@app.post("/api/stories/view")
def view_story(req: StoryViewRequest):
    conn = get_db_connection()
    with conn.cursor() as cursor:
        try:
            cursor.execute(
                "INSERT IGNORE INTO story_views (story_id, viewer_id) VALUES (%s, %s)",
                (req.storyId, req.viewerId)
            )
        except Exception as e:
            print(f"[STORY VIEW ERR] {e}")
    conn.close()
    return {"status": "success"}

@app.delete("/api/stories/{storyId}")
def delete_story(storyId: int, userId: int):
    conn = get_db_connection()
    with conn.cursor() as cursor:
        cursor.execute("DELETE FROM stories WHERE id = %s AND user_id = %s", (storyId, userId))
    conn.close()
    return {"status": "success"}

# --- SOCKET.IO REALTIME & WEBRTC SIGNALING ---

@sio.event
async def connect(sid, environ):
    print(f"[SOCKET] Baglanti: {sid}")

@sio.event
async def join(sid, user_id):
    active_sockets[str(user_id)] = sid
    print(f"[USER] Kullanici baglandi: ID {user_id}")

    # Update database
    try:
        conn = get_db_connection()
        with conn.cursor() as cursor:
            cursor.execute("UPDATE users SET is_online = 1 WHERE id = %s", (user_id,))
            # Mark all pending messages to this user as delivered
            cursor.execute("UPDATE messages SET is_delivered = 1 WHERE receiver_id = %s AND is_delivered = 0", (user_id,))
        conn.close()
    except Exception as e:
        print(f"[DB ERR] {e}")

    await sio.emit("user_status_change", {"userId": str(user_id), "isOnline": True})


@sio.event
async def send_message(sid, data):
    print(f"[SOCKET] send_message tetiklendi: {data}")
    sender_id = data.get("senderId")
    receiver_id = data.get("receiverId")
    content = data.get("content") or ""
    msg_type = data.get("type", "text")
    media_url = data.get("mediaUrl")

    receiver_sid = active_sockets.get(str(receiver_id))
    is_delivered = bool(receiver_sid)

    conn = get_db_connection()
    sender_name = "Biri"
    with conn.cursor() as cursor:
        cursor.execute(
            "INSERT INTO messages (sender_id, receiver_id, content, message_type, media_url, is_delivered, is_read) VALUES (%s, %s, %s, %s, %s, %s, 0)",
            (sender_id, receiver_id, content, msg_type, media_url, is_delivered)
        )
        msg_id = cursor.lastrowid
        cursor.execute("SELECT display_name, username FROM users WHERE id = %s", (sender_id,))
        sender_row = cursor.fetchone()
        if sender_row:
            sender_name = sender_row.get("display_name") or sender_row.get("username") or "Biri"
    conn.close()

    client_temp_id = data.get("clientTempId")

    saved_message = {
        "id": msg_id,
        "clientTempId": client_temp_id,
        "senderId": sender_id,
        "senderName": sender_name,
        "receiverId": receiver_id,
        "content": content,
        "type": msg_type,
        "mediaUrl": media_url,
        "isDelivered": is_delivered,
        "isRead": False,
        "timestamp": str(datetime.now())
    }

    if receiver_sid:
        await sio.emit("receive_message", saved_message, to=receiver_sid)
    await sio.emit("message_sent", saved_message, to=sid)

    # Trigger FCM Push Notification
    try:
        target_uid = int(receiver_id)
        print(f"[FCM] send_message push cagriliyor -> Target UID: {target_uid}")
        
        push_body = content
        if msg_type == "image":
            push_body = "📷 Fotoğraf"
        elif msg_type == "video":
            push_body = "🎥 Video"
        elif msg_type == "doc":
            push_body = "📄 Belge / Dosya"
        elif msg_type == "location":
            push_body = "📍 Konum Paylaştı"
        elif content.startswith("ENC::"):
            push_body = "🔒 Yeni bir mesajınız var"

        send_fcm_push(
            user_id=target_uid,
            title=f"{sender_name}",
            body=push_body,
            data_payload={
                "type": "message",
                "messageId": str(msg_id),
                "senderId": str(sender_id),
                "receiverId": str(receiver_id),
                "senderName": sender_name,
                "content": content,
            }
        )
    except Exception as e:
        print(f"[FCM HATA] send_message icinde push hatasi: {e}")


@sio.event
async def message_delivered(sid, data):
    # Receiver reports that messages were delivered
    sender_id = data.get("senderId")
    receiver_id = data.get("receiverId")
    msg_id = data.get("messageId")

    conn = get_db_connection()
    with conn.cursor() as cursor:
        if msg_id:
            cursor.execute("UPDATE messages SET is_delivered = 1 WHERE id = %s", (msg_id,))
        elif sender_id and receiver_id:
            cursor.execute("UPDATE messages SET is_delivered = 1 WHERE sender_id = %s AND receiver_id = %s", (sender_id, receiver_id))
    conn.close()

    sender_sid = active_sockets.get(str(sender_id))
    if sender_sid:
        await sio.emit("messages_delivered", {"senderId": str(sender_id), "receiverId": str(receiver_id), "messageId": msg_id}, to=sender_sid)


@sio.event
async def message_read(sid, data):
    # Receiver opened the chat / read the message
    sender_id = data.get("senderId")
    receiver_id = data.get("receiverId")
    msg_id = data.get("messageId")

    conn = get_db_connection()
    with conn.cursor() as cursor:
        if msg_id:
            cursor.execute("UPDATE messages SET is_delivered = 1, is_read = 1 WHERE id = %s", (msg_id,))
        elif sender_id and receiver_id:
            cursor.execute("UPDATE messages SET is_delivered = 1, is_read = 1 WHERE sender_id = %s AND receiver_id = %s", (sender_id, receiver_id))
    conn.close()

    sender_sid = active_sockets.get(str(sender_id))
    if sender_sid:
        await sio.emit("messages_read", {"senderId": str(sender_id), "receiverId": str(receiver_id), "messageId": msg_id}, to=sender_sid)


@sio.event
async def delete_message(sid, data):
    msg_id = data.get("messageId")
    sender_id = data.get("senderId")
    receiver_id = data.get("receiverId")
    print(f"[SOCKET] delete_message: #{msg_id} (Gonderen #{sender_id} -> Alici #{receiver_id})")

    if not msg_id:
        return

    try:
        conn = get_db_connection()
        with conn.cursor() as cursor:
            # Soft delete: mark is_deleted = 1, KEEP row in database for admin/forensics!
            cursor.execute("UPDATE messages SET is_deleted = 1 WHERE id = %s", (msg_id,))
        conn.close()
    except Exception as e:
        print(f"[DB ERR delete_message] {e}")

    # Broadcast to receiver and sender so it live updates both screens
    payload = {"messageId": str(msg_id), "senderId": str(sender_id), "receiverId": str(receiver_id)}
    receiver_sid = active_sockets.get(str(receiver_id))
    if receiver_sid:
        await sio.emit("message_deleted", payload, to=receiver_sid)
    await sio.emit("message_deleted", payload, to=sid)


@sio.event
async def edit_message(sid, data):
    msg_id = data.get("messageId")
    sender_id = data.get("senderId")
    receiver_id = data.get("receiverId")
    new_content = data.get("newContent") or ""
    print(f"[SOCKET] edit_message: #{msg_id}")

    if not msg_id or not new_content:
        return

    try:
        conn = get_db_connection()
        with conn.cursor() as cursor:
            # Preserve original content on first edit for forensic audit
            cursor.execute("SELECT content, original_content FROM messages WHERE id = %s", (msg_id,))
            row = cursor.fetchone()
            if row:
                old_content = row["content"]
                orig_content = row.get("original_content") or old_content
                cursor.execute(
                    "UPDATE messages SET content = %s, original_content = %s, is_edited = 1 WHERE id = %s",
                    (new_content, orig_content, msg_id),
                )
        conn.close()
    except Exception as e:
        print(f"[DB ERR edit_message] {e}")

    payload = {
        "messageId": str(msg_id),
        "senderId": str(sender_id),
        "receiverId": str(receiver_id),
        "content": new_content,
    }
    receiver_sid = active_sockets.get(str(receiver_id))
    if receiver_sid:
        await sio.emit("message_edited", payload, to=receiver_sid)
    await sio.emit("message_edited", payload, to=sid)


@sio.event
async def live_location_update(sid, data):
    receiver_id = data.get("receiverId")
    sender_id = data.get("senderId")
    if receiver_id:
        receiver_sid = active_sockets.get(str(receiver_id))
        if receiver_sid:
            await sio.emit("live_location_received", data, to=receiver_sid)


@sio.event
async def stop_live_location(sid, data):
    receiver_id = data.get("receiverId")
    sender_id = data.get("senderId")
    if receiver_id:
        receiver_sid = active_sockets.get(str(receiver_id))
        if receiver_sid:
            await sio.emit("live_location_stopped", data, to=receiver_sid)


@sio.event
async def call_user(sid, data):
    print(f"[SOCKET] call_user tetiklendi: {data.get('callType')} -> Receiver: {data.get('receiverId')}")
    receiver_id = data.get("receiverId")
    caller_data = data.get("caller", {})
    caller_name = caller_data.get("displayName") or caller_data.get("username") or "Biri"
    call_type_str = data.get("callType", "video")

    # Store pending call in memory so killed/background app can retrieve it on launch
    active_pending_calls[str(receiver_id)] = data

    receiver_sid = active_sockets.get(str(receiver_id))
    if receiver_sid:
        await sio.emit("incoming_call", data, to=receiver_sid)

    # Always trigger high-priority FCM wake-up call notification
    try:
        target_uid = int(receiver_id)
        print(f"[FCM] call_user push cagriliyor -> Target UID: {target_uid}")
        send_fcm_push(
            user_id=target_uid,
            title=f"Gelen { 'Görüntülü' if call_type_str == 'video' else 'Sesli' } Arama",
            body=f"{caller_name} sizi arıyor...",
            data_payload={
                "type": "call",
                "callerName": caller_name,
                "callType": call_type_str,
                "callerId": caller_data.get("uid", ""),
            }
        )
    except Exception as e:
        print(f"[FCM HATA] call_user icinde push hatasi: {e}")


@sio.event
async def answer_call(sid, data):
    caller_id = data.get("callerId")
    # Remove from pending
    for r_id, c_data in list(active_pending_calls.items()):
        if str(c_data.get("caller", {}).get("uid")) == str(caller_id):
            active_pending_calls.pop(r_id, None)

    caller_sid = active_sockets.get(str(caller_id))
    if caller_sid:
        await sio.emit("call_answered", data, to=caller_sid)

@sio.event
async def ice_candidate(sid, data):
    target_user_id = data.get("targetUserId")
    target_sid = active_sockets.get(str(target_user_id))
    if target_sid:
        await sio.emit("ice_candidate", data, to=target_sid)

@sio.event
async def end_call(sid, data):
    target_user_id = data.get("targetUserId") if isinstance(data, dict) else None
    
    # Remove from pending calls
    for r_id in list(active_pending_calls.keys()):
        active_pending_calls.pop(r_id, None)

    if target_user_id:
        target_sid = active_sockets.get(str(target_user_id))
        if target_sid:
            print(f"[CALL] Arama sonlandirildi -> Hedef: {target_user_id}")
            await sio.emit("call_ended", {}, to=target_sid)
    else:
        # Broadcast to others if specific target is not given
        for uid, s in list(active_sockets.items()):
            if s != sid:
                await sio.emit("call_ended", {}, to=s)

@sio.event
async def disconnect(sid):
    for uid, s in list(active_sockets.items()):
        if s == sid:
            del active_sockets[uid]
            print(f"[USER] Kullanici ayrildi: ID {uid}")
            try:
                conn = get_db_connection()
                with conn.cursor() as cursor:
                    cursor.execute("UPDATE users SET is_online = 0, last_seen = NOW() WHERE id = %s", (uid,))
                conn.close()
            except Exception as e:
                print(f"[DB ERR] {e}")

            await sio.emit("user_status_change", {"userId": str(uid), "isOnline": False})
            break


if __name__ == "__main__":
    uvicorn.run("main:socket_app", host="0.0.0.0", port=3000, reload=True)
