package main

import (
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"github.com/gin-gonic/gin"
	_ "github.com/go-sql-driver/mysql"
	"github.com/golang-jwt/jwt/v5"
	"github.com/gorilla/websocket"
	"golang.org/x/crypto/bcrypt"
	"google.golang.org/api/option"
)

// Environment & Config
var (
	dbHost     = getEnv("DB_HOST", "localhost")
	dbUser     = getEnv("DB_USER", "root")
	dbPassword = getEnv("DB_PASSWORD", "")
	dbName     = getEnv("DB_NAME", "chat_app_db")
	dbPort     = getEnv("DB_PORT", "3306")
	jwtSecret  = []byte(getEnv("JWT_SECRET", "super_secret_jwt_key_talknex_2026"))
	serverPort = getEnv("PORT", "3001")

	db        *sql.DB
	fcmClient *messaging.Client

	// Active Gorilla WebSocket Clients: userID (string) -> *WSClient
	wsClients sync.Map
	// Pending calls: receiverID (string) -> callData (map[string]interface{})
	activePendingCalls sync.Map

	uploadDir string

	wsUpgrader = websocket.Upgrader{
		CheckOrigin: func(r *http.Request) bool {
			return true
		},
		ReadBufferSize:  1024 * 64,
		WriteBufferSize: 1024 * 64,
	}
)

type WSClient struct {
	conn   *websocket.Conn
	userID string
	mu     sync.Mutex
}

func (c *WSClient) Send(event string, data interface{}) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.conn.WriteJSON(gin.H{
		"event": event,
		"data":  data,
	})
}

func getEnv(key, fallback string) string {
	if val := os.Getenv(key); val != "" {
		return val
	}
	return fallback
}

func initDB() {
	// 1. Ensure Database Exists
	rootDSN := fmt.Sprintf("%s:%s@tcp(%s:%s)/?charset=utf8mb4&parseTime=True&loc=Local", dbUser, dbPassword, dbHost, dbPort)
	rootDB, err := sql.Open("mysql", rootDSN)
	if err == nil {
		_, _ = rootDB.Exec(fmt.Sprintf("CREATE DATABASE IF NOT EXISTS %s CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci", dbName))
		rootDB.Close()
	}

	// 2. Connect to Database
	dsn := fmt.Sprintf("%s:%s@tcp(%s:%s)/%s?charset=utf8mb4&parseTime=True&loc=Local", dbUser, dbPassword, dbHost, dbPort, dbName)
	var dbErr error
	db, dbErr = sql.Open("mysql", dsn)
	if dbErr != nil {
		log.Fatalf("[DB HATA] Veritabani baglantisi acilamadi: %v", dbErr)
	}

	db.SetMaxOpenConns(1000)
	db.SetMaxIdleConns(100)
	db.SetConnMaxLifetime(time.Hour)

	if pingErr := db.Ping(); pingErr != nil {
		log.Printf("[UYARI] MariaDB baglanti denemesi uyarisi: %v", pingErr)
	} else {
		log.Println("[OK] MariaDB Go yuksek performansli baglantisi hazir!")
		_, _ = db.Exec("ALTER TABLE messages ADD COLUMN IF NOT EXISTS deleted_by_users TEXT NULL AFTER is_deleted")
		_, _ = db.Exec(`CREATE TABLE IF NOT EXISTS groups (
			id INT AUTO_INCREMENT PRIMARY KEY,
			name VARCHAR(150) NOT NULL,
			photo_url TEXT NULL,
			description TEXT NULL,
			created_by INT NOT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
			INDEX (created_by)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`)
		_, _ = db.Exec(`CREATE TABLE IF NOT EXISTS group_members (
			id INT AUTO_INCREMENT PRIMARY KEY,
			group_id INT NOT NULL,
			user_id INT NOT NULL,
			role VARCHAR(20) DEFAULT 'member',
			joined_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			UNIQUE KEY unique_group_user (group_id, user_id),
			INDEX (group_id),
			INDEX (user_id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`)
		_, _ = db.Exec(`CREATE TABLE IF NOT EXISTS group_messages (
			id INT AUTO_INCREMENT PRIMARY KEY,
			group_id INT NOT NULL,
			sender_id INT NOT NULL,
			content TEXT NOT NULL,
			message_type VARCHAR(50) DEFAULT 'text',
			media_url TEXT NULL,
			is_deleted TINYINT(1) DEFAULT 0,
			deleted_by_users TEXT NULL,
			is_edited TINYINT(1) DEFAULT 0,
			original_content TEXT NULL,
			created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
			INDEX (group_id),
			INDEX (sender_id)
		) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COLLATE=utf8mb4_unicode_ci`)
	}
}

func initFirebase() {
	keyFiles, _ := filepath.Glob("safechet-bildirim-firebase-adminsdk*.json")
	if len(keyFiles) == 0 {
		keyFiles, _ = filepath.Glob("../server_python/safechet-bildirim-firebase-adminsdk*.json")
	}

	if len(keyFiles) > 0 {
		opt := option.WithCredentialsFile(keyFiles[0])
		app, err := firebase.NewApp(context.Background(), nil, opt)
		if err == nil {
			fcmClient, err = app.Messaging(context.Background())
			if err == nil {
				log.Printf("[OK] Firebase Admin SDK yuklendi (Go): %s", keyFiles[0])
				return
			}
		}
		log.Printf("[UYARI] Firebase baslatilamadi: %v", err)
	} else {
		log.Println("[UYARI] Firebase JSON sertifika dosyasi bulunamadi!")
	}
}

func sendFCMPush(userID int, title, body string, payload map[string]string) {
	if fcmClient == nil {
		return
	}

	var fcmToken sql.NullString
	err := db.QueryRow("SELECT fcm_token FROM users WHERE id = ?", userID).Scan(&fcmToken)
	if err != nil || !fcmToken.Valid || fcmToken.String == "" {
		return
	}

	msgData := make(map[string]string)
	for k, v := range payload {
		msgData[k] = v
	}
	msgData["title"] = title
	msgData["body"] = body

	msg := &messaging.Message{
		Token: fcmToken.String,
		Data:  msgData,
		Android: &messaging.AndroidConfig{
			Priority: "high",
		},
	}

	res, err := fcmClient.Send(context.Background(), msg)
	if err != nil {
		log.Printf("[FCM HATA] Push gonderilemedi (#%d): %v", userID, err)
	} else {
		log.Printf("[FCM] Push iletildi (#%d): %s", userID, res)
	}
}

func normalizePhone(phone string) string {
	var digits strings.Builder
	for _, r := range phone {
		if r >= '0' && r <= '9' {
			digits.WriteRune(r)
		}
	}
	str := digits.String()
	if len(str) >= 10 {
		return str[len(str)-10:]
	}
	return str
}

func hashPassword(password string) string {
	bytes, _ := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	return string(bytes)
}

func checkPassword(password, hash string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

func generateJWT(userID int, username string) string {
	token := jwt.NewWithClaims(jwt.SigningMethodHS256, jwt.MapClaims{
		"id":       userID,
		"username": username,
		"exp":      time.Now().Add(time.Hour * 24 * 30).Unix(),
	})
	tokenString, _ := token.SignedString(jwtSecret)
	return tokenString
}

func main() {
	gin.SetMode(gin.ReleaseMode)
	initDB()
	initFirebase()

	// Ensure uploads directory exists (use C:\talknex_uploads if available to avoid Windows unicode path issues)
	uploadDir = `C:\talknex_uploads`
	if fi, err := os.Stat(uploadDir); err != nil || !fi.IsDir() {
		exeDir, _ := filepath.Abs(filepath.Dir(os.Args[0]))
		uploadDir = filepath.Join(exeDir, "uploads")
		_ = os.MkdirAll(uploadDir, os.ModePerm)
	}

	// --- SETUP GORILLA WEBSOCKET HANDLER ---
	handleWebSocket := func(c *gin.Context) {
		conn, err := wsUpgrader.Upgrade(c.Writer, c.Request, nil)
		if err != nil {
			log.Printf("[WS HATA] Upgrade basarisiz: %v", err)
			return
		}

		client := &WSClient{conn: conn}
		defer func() {
			conn.Close()
			if client.userID != "" {
				wsClients.Delete(client.userID)
				log.Printf("[WS USER] Kullanici ayrildi: ID %s", client.userID)
				_, _ = db.Exec("UPDATE users SET is_online = 0, last_seen = NOW() WHERE id = ?", client.userID)

				// Broadcast offline status
				wsClients.Range(func(key, value interface{}) bool {
					if other, ok := value.(*WSClient); ok && other.userID != client.userID {
						_ = other.Send("user_status_change", gin.H{
							"userId":   client.userID,
							"isOnline": false,
						})
					}
					return true
				})
			}
		}()

		// WebSocket Message Loop
		for {
			var packet struct {
				Event string                 `json:"event"`
				Data  map[string]interface{} `json:"data"`
			}

			if err := conn.ReadJSON(&packet); err != nil {
				if websocket.IsUnexpectedCloseError(err, websocket.CloseGoingAway, websocket.CloseAbnormalClosure) {
					log.Printf("[WS HATA] Baglanti kapandi: %v", err)
				}
				break
			}

			event := packet.Event
			data := packet.Data
			if data == nil {
				data = make(map[string]interface{})
			}

			switch event {
			case "join":
				var uidStr string
				if rawUID, ok := data["userId"]; ok {
					uidStr = fmt.Sprintf("%v", rawUID)
				} else if rawUID, ok := data["uid"]; ok {
					uidStr = fmt.Sprintf("%v", rawUID)
				} else if rawUID, ok := data["id"]; ok {
					uidStr = fmt.Sprintf("%v", rawUID)
				}

				if uidStr != "" {
					client.userID = uidStr
					wsClients.Store(uidStr, client)
					log.Printf("[WS USER] Kullanici baglandi: ID %s", uidStr)

					_, _ = db.Exec("UPDATE users SET is_online = 1 WHERE id = ?", uidStr)
					_, _ = db.Exec("UPDATE messages SET is_delivered = 1 WHERE receiver_id = ? AND is_delivered = 0", uidStr)

					// Broadcast online status
					wsClients.Range(func(key, value interface{}) bool {
						if other, ok := value.(*WSClient); ok && other.userID != client.userID {
							_ = other.Send("user_status_change", gin.H{
								"userId":   uidStr,
								"isOnline": true,
							})
						}
						return true
					})
				}

			case "send_message":
				senderID, _ := strconv.Atoi(fmt.Sprintf("%v", data["senderId"]))
				receiverID, _ := strconv.Atoi(fmt.Sprintf("%v", data["receiverId"]))
				content := fmt.Sprintf("%v", data["content"])
				msgType := "text"
				if t, ok := data["type"].(string); ok && t != "" {
					msgType = t
				}
				mediaURL := ""
				if m, ok := data["mediaUrl"].(string); ok {
					mediaURL = m
				}
				clientTempID := ""
				if c, ok := data["clientTempId"].(string); ok {
					clientTempID = c
				}

				receiverVal, isReceiverOnline := wsClients.Load(strconv.Itoa(receiverID))
				isDelivered := isReceiverOnline

				// Insert Message into MariaDB
				res, err := db.Exec(
					"INSERT INTO messages (sender_id, receiver_id, content, message_type, media_url, is_delivered, is_read) VALUES (?, ?, ?, ?, ?, ?, 0)",
					senderID, receiverID, content, msgType, mediaURL, isDelivered,
				)
				if err != nil {
					log.Printf("[DB ERR send_message]: %v", err)
					continue
				}

				msgID, _ := res.LastInsertId()
				log.Printf("[DB SUCCESS] Mesaj kaydedildi: ID %d (Gonderen: %d -> Alici: %d)", msgID, senderID, receiverID)

				// Sender Display Name
				var senderName string
				_ = db.QueryRow("SELECT COALESCE(NULLIF(display_name, ''), username) FROM users WHERE id = ?", senderID).Scan(&senderName)
				if senderName == "" {
					senderName = "Biri"
				}

				savedMessage := gin.H{
					"id":           msgID,
					"clientTempId": clientTempID,
					"senderId":     senderID,
					"senderName":   senderName,
					"receiverId":   receiverID,
					"content":      content,
					"type":         msgType,
					"mediaUrl":     mediaURL,
					"isDelivered":  isDelivered,
					"isRead":       false,
					"timestamp":    time.Now().Format("2006-01-02 15:04:05"),
				}

				if isReceiverOnline {
					if rClient, ok := receiverVal.(*WSClient); ok {
						_ = rClient.Send("receive_message", savedMessage)
					}
				}
				_ = client.Send("message_sent", savedMessage)

				// FCM Push Notification
				go func() {
					pushBody := content
					switch msgType {
					case "image":
						pushBody = "📷 Fotoğraf"
					case "video":
						pushBody = "🎥 Video"
					case "doc":
						pushBody = "📄 Belge / Dosya"
					case "location":
						pushBody = "📍 Canlı Konum"
					}
					sendFCMPush(receiverID, senderName, pushBody, map[string]string{
						"type":        "chat",
						"senderId":    strconv.Itoa(senderID),
						"senderName":  senderName,
						"messageId":   strconv.FormatInt(msgID, 10),
						"messageType": msgType,
					})
				}()

			case "edit_message":
				msgID, _ := strconv.Atoi(fmt.Sprintf("%v", data["messageId"]))
				senderID, _ := strconv.Atoi(fmt.Sprintf("%v", data["senderId"]))
				receiverID, _ := strconv.Atoi(fmt.Sprintf("%v", data["receiverId"]))
				newContent := fmt.Sprintf("%v", data["newContent"])

				if msgID == 0 || newContent == "" {
					continue
				}

				var oldContent, origContent sql.NullString
				var createdAt time.Time
				err := db.QueryRow("SELECT content, original_content, created_at FROM messages WHERE id = ?", msgID).Scan(&oldContent, &origContent, &createdAt)
				if err != nil {
					continue
				}

				// 15 Dakika Düzenleme Süresi Kontrolü
				if time.Since(createdAt) > 15*time.Minute {
					log.Printf("[UYARI] Mesaj #%d düzenleme süresi (15 dk) dolduğu için reddedildi.", msgID)
					_ = client.Send("error", gin.H{"message": "Mesajlar gönderildikten sonra yalnızca 15 dakika içinde düzenlenebilir."})
					continue
				}

				firstContent := oldContent.String
				if origContent.Valid && origContent.String != "" {
					firstContent = origContent.String
				}

				_, _ = db.Exec("UPDATE messages SET content = ?, original_content = ?, is_edited = 1 WHERE id = ?", newContent, firstContent, msgID)

				payload := gin.H{
					"messageId":  msgID,
					"senderId":   senderID,
					"receiverId": receiverID,
					"content":    newContent,
					"newContent": newContent,
					"isEdited":   true,
				}

				if rVal, ok := wsClients.Load(strconv.Itoa(receiverID)); ok {
					if rClient, ok := rVal.(*WSClient); ok {
						_ = rClient.Send("message_edited", payload)
					}
				}
				_ = client.Send("message_edited", payload)

			case "delete_message":
				msgID, _ := strconv.Atoi(fmt.Sprintf("%v", data["messageId"]))
				senderID, _ := strconv.Atoi(fmt.Sprintf("%v", data["senderId"]))
				receiverID, _ := strconv.Atoi(fmt.Sprintf("%v", data["receiverId"]))
				deleteMode := fmt.Sprintf("%v", data["mode"]) // "everyone" or "me"
				if deleteMode == "" || deleteMode == "<nil>" {
					deleteMode = "everyone"
				}

				if msgID == 0 {
					continue
				}

				var msgSenderID int
				var createdAt time.Time
				var deletedBy sql.NullString
				err := db.QueryRow("SELECT sender_id, created_at, deleted_by_users FROM messages WHERE id = ?", msgID).Scan(&msgSenderID, &createdAt, &deletedBy)
				if err != nil {
					continue
				}

				currentUidStr := client.userID
				if currentUidStr == "" {
					currentUidStr = strconv.Itoa(senderID)
				}

				if deleteMode == "everyone" {
					// 15 Dakika Herkesten Silme Kontrolü
					if time.Since(createdAt) > 15*time.Minute {
						log.Printf("[UYARI] Mesaj #%d herkesten silme suresi (15 dk) doldugu icin reddedildi.", msgID)
						_ = client.Send("error", gin.H{"message": "Mesajlar gönderildikten sonra yalnızca 15 dakika içinde herkesten silinebilir."})
						continue
					}

					_, _ = db.Exec("UPDATE messages SET is_deleted = 1 WHERE id = ?", msgID)

					payload := gin.H{
						"messageId":  strconv.Itoa(msgID),
						"senderId":   strconv.Itoa(senderID),
						"receiverId": strconv.Itoa(receiverID),
						"mode":       "everyone",
					}

					if rVal, ok := wsClients.Load(strconv.Itoa(receiverID)); ok {
						if rClient, ok := rVal.(*WSClient); ok {
							_ = rClient.Send("message_deleted", payload)
						}
					}
					_ = client.Send("message_deleted", payload)
				} else {
					// Benden Sil (Delete for me)
					existingList := strings.Split(deletedBy.String, ",")
					alreadyInList := false
					for _, u := range existingList {
						if strings.TrimSpace(u) == currentUidStr {
							alreadyInList = true
							break
						}
					}

					newList := deletedBy.String
					if !alreadyInList {
						if newList == "" {
							newList = currentUidStr
						} else {
							newList = newList + "," + currentUidStr
						}
						_, _ = db.Exec("UPDATE messages SET deleted_by_users = ? WHERE id = ?", newList, msgID)
					}

					payload := gin.H{
						"messageId":  strconv.Itoa(msgID),
						"senderId":   strconv.Itoa(senderID),
						"receiverId": strconv.Itoa(receiverID),
						"mode":       "me",
						"deletedBy":  currentUidStr,
					}
					_ = client.Send("message_deleted", payload)
				}

			case "message_delivered":
				senderID, _ := strconv.Atoi(fmt.Sprintf("%v", data["senderId"]))
				receiverID, _ := strconv.Atoi(fmt.Sprintf("%v", data["receiverId"]))
				msgID, _ := strconv.Atoi(fmt.Sprintf("%v", data["messageId"]))

				if msgID > 0 {
					_, _ = db.Exec("UPDATE messages SET is_delivered = 1 WHERE id = ?", msgID)
				} else if senderID > 0 && receiverID > 0 {
					_, _ = db.Exec("UPDATE messages SET is_delivered = 1 WHERE sender_id = ? AND receiver_id = ?", senderID, receiverID)
				}

				if sVal, ok := wsClients.Load(strconv.Itoa(senderID)); ok {
					if sClient, ok := sVal.(*WSClient); ok {
						_ = sClient.Send("messages_delivered", gin.H{
							"senderId":   strconv.Itoa(senderID),
							"receiverId": strconv.Itoa(receiverID),
							"messageId":  msgID,
						})
					}
				}

			case "message_read":
				senderID, _ := strconv.Atoi(fmt.Sprintf("%v", data["senderId"]))
				receiverID, _ := strconv.Atoi(fmt.Sprintf("%v", data["receiverId"]))
				msgID, _ := strconv.Atoi(fmt.Sprintf("%v", data["messageId"]))

				if msgID > 0 {
					_, _ = db.Exec("UPDATE messages SET is_delivered = 1, is_read = 1 WHERE id = ?", msgID)
				} else if senderID > 0 && receiverID > 0 {
					_, _ = db.Exec("UPDATE messages SET is_delivered = 1, is_read = 1 WHERE sender_id = ? AND receiver_id = ?", senderID, receiverID)
				}

				if sVal, ok := wsClients.Load(strconv.Itoa(senderID)); ok {
					if sClient, ok := sVal.(*WSClient); ok {
						_ = sClient.Send("messages_read", gin.H{
							"senderId":   strconv.Itoa(senderID),
							"receiverId": strconv.Itoa(receiverID),
							"messageId":  msgID,
						})
					}
				}

			case "live_location_update":
				receiverID := fmt.Sprintf("%v", data["receiverId"])
				if rVal, ok := wsClients.Load(receiverID); ok {
					if rClient, ok := rVal.(*WSClient); ok {
						_ = rClient.Send("live_location_received", data)
					}
				}

			case "stop_live_location":
				receiverID := fmt.Sprintf("%v", data["receiverId"])
				if rVal, ok := wsClients.Load(receiverID); ok {
					if rClient, ok := rVal.(*WSClient); ok {
						_ = rClient.Send("live_location_stopped", data)
					}
				}

			case "call_user":
				receiverID := fmt.Sprintf("%v", data["receiverId"])
				activePendingCalls.Store(receiverID, data)

				if rVal, ok := wsClients.Load(receiverID); ok {
					if rClient, ok := rVal.(*WSClient); ok {
						_ = rClient.Send("incoming_call", data)
					}
				}

				go func() {
					callerData, _ := data["caller"].(map[string]interface{})
					callerName := "Biri"
					if callerData != nil {
						if d, ok := callerData["displayName"].(string); ok && d != "" {
							callerName = d
						}
					}
					callType := fmt.Sprintf("%v", data["callType"])
					rIDInt, _ := strconv.Atoi(receiverID)
					title := "Gelen Sesli Arama"
					if callType == "video" {
						title = "Gelen Görüntülü Arama"
					}
					sendFCMPush(rIDInt, title, fmt.Sprintf("%s sizi arıyor...", callerName), map[string]string{
						"type":       "call",
						"callerName": callerName,
						"callType":   callType,
						"callerId":   fmt.Sprintf("%v", callerData["uid"]),
					})
				}()

			case "answer_call":
				callerID := fmt.Sprintf("%v", data["callerId"])
				activePendingCalls.Range(func(key, value interface{}) bool {
					activePendingCalls.Delete(key)
					return true
				})

				if cVal, ok := wsClients.Load(callerID); ok {
					if cClient, ok := cVal.(*WSClient); ok {
						_ = cClient.Send("call_answered", data)
					}
				}

			case "ice_candidate":
				targetUserID := fmt.Sprintf("%v", data["targetUserId"])
				if tVal, ok := wsClients.Load(targetUserID); ok {
					if tClient, ok := tVal.(*WSClient); ok {
						_ = tClient.Send("ice_candidate", data)
					}
				}

			case "end_call":
				activePendingCalls.Range(func(key, value interface{}) bool {
					activePendingCalls.Delete(key)
					return true
				})

				targetUserID := ""
				if data != nil {
					targetUserID = fmt.Sprintf("%v", data["targetUserId"])
				}

				if targetUserID != "" {
					if tVal, ok := wsClients.Load(targetUserID); ok {
						if tClient, ok := tVal.(*WSClient); ok {
							_ = tClient.Send("call_ended", gin.H{})
						}
					}
				} else {
					wsClients.Range(func(key, val interface{}) bool {
						if other, ok := val.(*WSClient); ok && other.userID != client.userID {
							_ = other.Send("call_ended", gin.H{})
						}
						return true
					})
				}

			case "send_group_message":
				groupID, _ := strconv.Atoi(fmt.Sprintf("%v", data["groupId"]))
				senderID, _ := strconv.Atoi(fmt.Sprintf("%v", data["senderId"]))
				content := fmt.Sprintf("%v", data["content"])
				msgType := fmt.Sprintf("%v", data["type"])
				if msgType == "" || msgType == "<nil>" {
					msgType = "text"
				}
				mediaURL := ""
				if m, ok := data["mediaUrl"].(string); ok {
					mediaURL = m
				}
				clientTempID := ""
				if c, ok := data["clientTempId"].(string); ok {
					clientTempID = c
				}

				if groupID == 0 || senderID == 0 || content == "" {
					continue
				}

				// Check membership
				var isMember int
				_ = db.QueryRow("SELECT COUNT(*) FROM group_members WHERE group_id = ? AND user_id = ?", groupID, senderID).Scan(&isMember)
				if isMember == 0 {
					_ = client.Send("error", gin.H{"message": "Bu gruba mesaj gönderme yetkiniz yok."})
					continue
				}

				res, err := db.Exec(
					"INSERT INTO group_messages (group_id, sender_id, content, message_type, media_url) VALUES (?, ?, ?, ?, ?)",
					groupID, senderID, content, msgType, mediaURL,
				)
				if err != nil {
					log.Printf("[DB ERR send_group_message]: %v", err)
					continue
				}

				msgID, _ := res.LastInsertId()

				var senderName, senderPhoto string
				_ = db.QueryRow("SELECT COALESCE(NULLIF(display_name, ''), username), COALESCE(photo_url, '') FROM users WHERE id = ?", senderID).Scan(&senderName, &senderPhoto)
				if senderName == "" {
					senderName = "Grup Üyesi"
				}

				var groupName string
				_ = db.QueryRow("SELECT name FROM groups WHERE id = ?", groupID).Scan(&groupName)

				savedGroupMsg := gin.H{
					"id":           msgID,
					"groupId":      groupID,
					"clientTempId": clientTempID,
					"senderId":     senderID,
					"senderName":   senderName,
					"senderPhoto":  senderPhoto,
					"content":      content,
					"type":         msgType,
					"mediaUrl":     mediaURL,
					"isDeleted":    false,
					"isEdited":     false,
					"timestamp":    time.Now().Format("2006-01-02 15:04:05"),
				}

				// Broadcast to all active group members
				mRows, mErr := db.Query("SELECT user_id FROM group_members WHERE group_id = ?", groupID)
				if mErr == nil {
					for mRows.Next() {
						var mUID int
						_ = mRows.Scan(&mUID)
						uidStr := strconv.Itoa(mUID)
						if memVal, ok := wsClients.Load(uidStr); ok {
							if memClient, ok := memVal.(*WSClient); ok {
								_ = memClient.Send("receive_group_message", savedGroupMsg)
							}
						} else if mUID != senderID {
							// Push notification to offline member
							go func(targetID int) {
								pushText := senderName + ": " + content
								if msgType == "image" {
									pushText = senderName + ": 📷 Fotoğraf"
								} else if msgType == "video" {
									pushText = senderName + ": 🎥 Video"
								} else if msgType == "doc" {
									pushText = senderName + ": 📄 Belge"
								}
								sendFCMPush(targetID, groupName, pushText, map[string]string{
									"type":      "group_chat",
									"groupId":   strconv.Itoa(groupID),
									"groupName": groupName,
									"messageId": strconv.FormatInt(msgID, 10),
								})
							}(mUID)
						}
					}
					mRows.Close()
				}
				_ = client.Send("group_message_sent", savedGroupMsg)

			case "delete_group_message":
				msgID, _ := strconv.Atoi(fmt.Sprintf("%v", data["messageId"]))
				groupID, _ := strconv.Atoi(fmt.Sprintf("%v", data["groupId"]))
				deleteMode := fmt.Sprintf("%v", data["mode"]) // "everyone" or "me"
				if deleteMode == "" || deleteMode == "<nil>" {
					deleteMode = "everyone"
				}

				if msgID == 0 || groupID == 0 {
					continue
				}

				currentUidStr := client.userID
				currentUID, _ := strconv.Atoi(currentUidStr)

				var msgSenderID int
				var createdAt time.Time
				var deletedBy sql.NullString
				err := db.QueryRow("SELECT sender_id, created_at, deleted_by_users FROM group_messages WHERE id = ? AND group_id = ?", msgID, groupID).Scan(&msgSenderID, &createdAt, &deletedBy)
				if err != nil {
					continue
				}

				// Check role of requester in group
				var userRole string
				_ = db.QueryRow("SELECT role FROM group_members WHERE group_id = ? AND user_id = ?", groupID, currentUID).Scan(&userRole)
				isAdmin := userRole == "admin"
				isSender := msgSenderID == currentUID

				if deleteMode == "everyone" {
					// Either admin can delete anyone's message anytime, OR sender can delete within 15 minutes!
					canDelete := isAdmin || (isSender && time.Since(createdAt) <= 15*time.Minute)
					if !canDelete {
						_ = client.Send("error", gin.H{"message": "Mesajı herkesten silme yetkiniz yok (Yönetici olmalı veya kendi mesajınızı 15 dk içinde silmelisiniz)."})
						continue
					}

					_, _ = db.Exec("UPDATE group_messages SET is_deleted = 1 WHERE id = ?", msgID)

					payload := gin.H{
						"messageId": strconv.Itoa(msgID),
						"groupId":   strconv.Itoa(groupID),
						"mode":      "everyone",
					}

					mRows, mErr := db.Query("SELECT user_id FROM group_members WHERE group_id = ?", groupID)
					if mErr == nil {
						for mRows.Next() {
							var mUID int
							_ = mRows.Scan(&mUID)
							if memVal, ok := wsClients.Load(strconv.Itoa(mUID)); ok {
								if memClient, ok := memVal.(*WSClient); ok {
									_ = memClient.Send("group_message_deleted", payload)
								}
							}
						}
						mRows.Close()
					}
				} else {
					// Delete for me
					existingList := strings.Split(deletedBy.String, ",")
					alreadyInList := false
					for _, u := range existingList {
						if strings.TrimSpace(u) == currentUidStr {
							alreadyInList = true
							break
						}
					}
					newList := deletedBy.String
					if !alreadyInList {
						if newList == "" {
							newList = currentUidStr
						} else {
							newList = newList + "," + currentUidStr
						}
						_, _ = db.Exec("UPDATE group_messages SET deleted_by_users = ? WHERE id = ?", newList, msgID)
					}
					_ = client.Send("group_message_deleted", gin.H{
						"messageId": strconv.Itoa(msgID),
						"groupId":   strconv.Itoa(groupID),
						"mode":      "me",
						"deletedBy": currentUidStr,
					})
				}
			}
		}
	}

	// --- SETUP GIN ROUTER ---
	router := gin.Default()

	// CORS Middleware
	router.Use(func(c *gin.Context) {
		c.Writer.Header().Set("Access-Control-Allow-Origin", "*")
		c.Writer.Header().Set("Access-Control-Allow-Credentials", "true")
		c.Writer.Header().Set("Access-Control-Allow-Headers", "Content-Type, Content-Length, Accept-Encoding, X-CSRF-Token, Authorization, accept, origin, Cache-Control, X-Requested-With")
		c.Writer.Header().Set("Access-Control-Allow-Methods", "POST, OPTIONS, GET, PUT, DELETE")
		if c.Request.Method == "OPTIONS" {
			c.AbortWithStatus(204)
			return
		}
		c.Next()
	})

	// Static uploads directory
	router.Static("/uploads", uploadDir)

	// Gorilla WebSocket Mount (Direct /ws & fallback /socket.io/)
	router.GET("/ws", handleWebSocket)
	router.GET("/socket.io/*any", handleWebSocket)

	// REST API Routes
	api := router.Group("/api")
	{
		// 1. Auth Register
		handleRegister := func(c *gin.Context) {
			var req struct {
				Username    string `json:"username"`
				Password    string `json:"password"`
				DisplayName string `json:"displayName"`
				PhoneNumber string `json:"phoneNumber"`
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz istek"})
				return
			}

			cleanUsername := strings.ToLower(strings.TrimSpace(req.Username))
			displayName := strings.TrimSpace(req.DisplayName)
			if displayName == "" {
				displayName = cleanUsername
			}
			photoURL := fmt.Sprintf("https://ui-avatars.com/api/?name=%s&background=075E54&color=fff", displayName)
			phone := strings.TrimSpace(req.PhoneNumber)

			hash := hashPassword(req.Password)
			res, err := db.Exec(
				"INSERT INTO users (username, display_name, password_hash, photo_url, phone_number, is_online) VALUES (?, ?, ?, ?, ?, 1)",
				cleanUsername, displayName, hash, photoURL, phone,
			)
			if err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Bu kullanıcı adı zaten alınmış."})
				return
			}
			id, _ := res.LastInsertId()
			token := generateJWT(int(id), cleanUsername)
			c.JSON(http.StatusOK, gin.H{
				"message": "Kayıt başarılı.",
				"token":   token,
				"user": gin.H{
					"id":          id,
					"username":    cleanUsername,
					"displayName": displayName,
					"photoUrl":    photoURL,
					"phoneNumber": phone,
					"isOnline":    true,
				},
			})
		}
		api.POST("/register", handleRegister)
		api.POST("/auth/register", handleRegister)

		// 2. Auth Login
		handleLogin := func(c *gin.Context) {
			var req struct {
				Username string `json:"username"`
				Password string `json:"password"`
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz istek"})
				return
			}

			cleanUsername := strings.ToLower(strings.TrimSpace(req.Username))
			var id int
			var pwdHash, displayName, photoURL, phone, status string
			err := db.QueryRow("SELECT id, password_hash, display_name, photo_url, phone_number, status FROM users WHERE username = ?", cleanUsername).
				Scan(&id, &pwdHash, &displayName, &photoURL, &phone, &status)
			if err != nil || !checkPassword(req.Password, pwdHash) {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Kullanıcı adı veya şifre hatalı."})
				return
			}

			_, _ = db.Exec("UPDATE users SET is_online = 1 WHERE id = ?", id)
			token := generateJWT(id, cleanUsername)
			c.JSON(http.StatusOK, gin.H{
				"message": "Giriş başarılı.",
				"token":   token,
				"user": gin.H{
					"id":          id,
					"username":    cleanUsername,
					"displayName": displayName,
					"photoUrl":    photoURL,
					"phoneNumber": phone,
					"status":      status,
					"isOnline":    true,
				},
			})
		}
		api.POST("/login", handleLogin)
		api.POST("/auth/login", handleLogin)

		// 3. User Profile Update
		api.POST("/users/profile", func(c *gin.Context) {
			var req struct {
				UserId      int    `json:"userId"`
				DisplayName string `json:"displayName"`
				PhotoUrl    string `json:"photoUrl"`
				Status      string `json:"status"`
				PhoneNumber string `json:"phoneNumber"`
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz istek"})
				return
			}
			_, _ = db.Exec("UPDATE users SET display_name = ?, photo_url = ?, status = ?, phone_number = ? WHERE id = ?",
				req.DisplayName, req.PhotoUrl, req.Status, req.PhoneNumber, req.UserId)

			var u struct {
				ID          int    `json:"id"`
				Username    string `json:"username"`
				DisplayName string `json:"displayName"`
				PhotoUrl    string `json:"photoUrl"`
				PhoneNumber string `json:"phoneNumber"`
				Status      string `json:"status"`
			}
			_ = db.QueryRow("SELECT id, username, display_name, photo_url, phone_number, status FROM users WHERE id = ?", req.UserId).
				Scan(&u.ID, &u.Username, &u.DisplayName, &u.PhotoUrl, &u.PhoneNumber, &u.Status)

			c.JSON(http.StatusOK, gin.H{"status": "success", "user": u})
		})

		// 4. File Upload (Photos, Encrypted Videos, Docs)
		api.POST("/upload", func(c *gin.Context) {
			file, header, err := c.Request.FormFile("file")
			if err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Dosya yuklenemedi"})
				return
			}
			defer file.Close()

			ext := filepath.Ext(header.Filename)
			if ext == "" {
				ext = ".jpg"
			}
			randBytes := make([]byte, 16)
			_, _ = rand.Read(randBytes)
			filename := hex.EncodeToString(randBytes) + ext
			dstPath := filepath.Join(uploadDir, filename)

			out, err := os.Create(dstPath)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Dosya kaydedilemedi"})
				return
			}
			defer out.Close()
			_, _ = io.Copy(out, file)

			c.JSON(http.StatusOK, gin.H{
				"status": "success",
				"url":    fmt.Sprintf("http://46.197.188.20:3000/uploads/%s", filename),
			})
		})

		// 5. FCM Token Registration
		api.POST("/users/fcm-token", func(c *gin.Context) {
			var req struct {
				UserId   int    `json:"userId"`
				FcmToken string `json:"fcmToken"`
			}
			if err := c.ShouldBindJSON(&req); err == nil {
				_, _ = db.Exec("UPDATE users SET fcm_token = ? WHERE id = ?", req.FcmToken, req.UserId)
			}
			c.JSON(http.StatusOK, gin.H{"status": "success"})
		})

		// 6. Contact Syncing + Previously Messaged Partners
		api.POST("/users/sync-contacts", func(c *gin.Context) {
			var req struct {
				UserId   int `json:"userId"`
				Contacts []struct {
					Phone string `json:"phone"`
					Name  string `json:"name"`
				} `json:"contacts"`
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz istek"})
				return
			}

			normalizedMap := make(map[string]string)
			for _, entry := range req.Contacts {
				norm := normalizePhone(entry.Phone)
				if norm != "" {
					normalizedMap[norm] = strings.TrimSpace(entry.Name)
				}
			}

			// Find previous chat partners
			chatPartners := make(map[int]bool)
			pRows, pErr := db.Query(
				"SELECT DISTINCT CASE WHEN sender_id = ? THEN receiver_id ELSE sender_id END AS partner_id FROM messages WHERE sender_id = ? OR receiver_id = ?",
				req.UserId, req.UserId, req.UserId,
			)
			if pErr == nil {
				for pRows.Next() {
					var pid int
					if err := pRows.Scan(&pid); err == nil && pid > 0 {
						chatPartners[pid] = true
					}
				}
				pRows.Close()
			}

			// Query all other users with their last message to/from req.UserId
			uRows, err := db.Query(
				`SELECT u.id, u.username, u.display_name, u.photo_url, u.phone_number, u.status, u.is_online, u.last_seen,
				        COALESCE((SELECT content FROM messages WHERE ((sender_id = u.id AND receiver_id = ?) OR (sender_id = ? AND receiver_id = u.id)) AND is_deleted = 0 ORDER BY id DESC LIMIT 1), '') AS last_msg,
				        COALESCE((SELECT created_at FROM messages WHERE ((sender_id = u.id AND receiver_id = ?) OR (sender_id = ? AND receiver_id = u.id)) AND is_deleted = 0 ORDER BY id DESC LIMIT 1), u.created_at) AS last_time
				 FROM users u 
				 WHERE u.id != ?`,
				req.UserId, req.UserId, req.UserId, req.UserId, req.UserId,
			)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Kullanicilar yuklenemedi"})
				return
			}
			defer uRows.Close()

			type UserItem struct {
				ID          int    `json:"id"`
				Username    string `json:"username"`
				DisplayName string `json:"displayName"`
				PhotoUrl    string `json:"photoUrl"`
				PhoneNumber string `json:"phoneNumber"`
				Status      string `json:"status"`
				IsOnline    bool   `json:"isOnline"`
				LastSeen    string `json:"lastSeen"`
				LastMessage string `json:"lastMessage"`
				LastTime    string `json:"lastTime"`
			}

			var matched []UserItem
			added := make(map[int]bool)

			for uRows.Next() {
				var u UserItem
				var dName, pUrl, pNum, st, lSeen, lMsg sql.NullString
				var isOnline int
				var lTime time.Time
				_ = uRows.Scan(&u.ID, &u.Username, &dName, &pUrl, &pNum, &st, &isOnline, &lSeen, &lMsg, &lTime)
				u.DisplayName = dName.String
				u.PhotoUrl = pUrl.String
				u.PhoneNumber = pNum.String
				u.Status = st.String
				u.LastSeen = lSeen.String
				u.LastMessage = lMsg.String
				if !lTime.IsZero() {
					u.LastTime = lTime.Format("2006-01-02 15:04:05")
				}

				// Check online in memory
				_, u.IsOnline = wsClients.Load(strconv.Itoa(u.ID))

				userNorm := normalizePhone(u.PhoneNumber)
				localName, inContacts := normalizedMap[userNorm]
				inHistory := chatPartners[u.ID]

				if inContacts || inHistory {
					if inContacts && localName != "" {
						u.DisplayName = localName
					} else if u.DisplayName == "" {
						if u.PhoneNumber != "" {
							u.DisplayName = u.PhoneNumber
						} else {
							u.DisplayName = u.Username
						}
					}
					if !added[u.ID] {
						matched = append(matched, u)
						added[u.ID] = true
					}
				}
			}

			c.JSON(http.StatusOK, matched)
		})

		// 7. Get Messages Between Two Users
		api.GET("/messages/:user1/:user2", func(c *gin.Context) {
			user1 := c.Param("user1")
			user2 := c.Param("user2")

			rows, err := db.Query(
				`SELECT id, sender_id, receiver_id, content, message_type, is_delivered, is_read, 
				        media_url, is_deleted, deleted_by_users, is_edited, original_content, created_at 
				 FROM messages 
				 WHERE (sender_id = ? AND receiver_id = ?) OR (sender_id = ? AND receiver_id = ?) 
				 ORDER BY created_at ASC`,
				user1, user2, user2, user1,
			)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Mesajlar yuklenemedi"})
				return
			}
			defer rows.Close()

			var messages []map[string]interface{}
			for rows.Next() {
				var id, sID, rID, isDeliv, isRead, isDel, isEd int
				var content, mType string
				var mURL, origContent, delByUsers sql.NullString
				var cAt time.Time

				_ = rows.Scan(&id, &sID, &rID, &content, &mType, &isDeliv, &isRead, &mURL, &isDel, &delByUsers, &isEd, &origContent, &cAt)

				// Kullanıcı kendinden silmişse bu mesajı ona gönderme
				if delByUsers.Valid && delByUsers.String != "" {
					isDeletedForUser1 := false
					for _, u := range strings.Split(delByUsers.String, ",") {
						if strings.TrimSpace(u) == user1 {
							isDeletedForUser1 = true
							break
						}
					}
					if isDeletedForUser1 {
						continue
					}
				}

				messages = append(messages, map[string]interface{}{
					"id":              id,
					"senderId":        sID,
					"receiverId":      rID,
					"content":         content,
					"type":            mType,
					"isDelivered":     isDeliv == 1,
					"isRead":          isRead == 1,
					"mediaUrl":        mURL.String,
					"isDeleted":       isDel == 1,
					"isEdited":        isEd == 1,
					"originalContent": origContent.String,
					"timestamp":       cAt.Format("2006-01-02 15:04:05"),
				})
			}
			c.JSON(http.StatusOK, messages)
		})

		// 8. Story (Durum) Endpoints
		api.POST("/stories", func(c *gin.Context) {
			var req struct {
				UserId    int    `json:"userId"`
				MediaUrl  string `json:"mediaUrl"`
				Caption   string `json:"caption"`
				MediaType string `json:"mediaType"`
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz istek"})
				return
			}
			mType := req.MediaType
			if mType == "" {
				mType = "image"
			}
			res, err := db.Exec(
				"INSERT INTO stories (user_id, media_url, caption, media_type, expires_at) VALUES (?, ?, ?, ?, DATE_ADD(NOW(), INTERVAL 24 HOUR))",
				req.UserId, req.MediaUrl, req.Caption, mType,
			)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Hikaye paylasilamadi"})
				return
			}
			sid, _ := res.LastInsertId()
			c.JSON(http.StatusOK, gin.H{"status": "success", "storyId": sid})
		})

		api.GET("/stories", func(c *gin.Context) {
			currUID, _ := strconv.Atoi(c.DefaultQuery("currentUserId", "0"))

			rows, err := db.Query(
				`SELECT s.id, s.user_id, s.media_url, s.caption, s.media_type, s.created_at, s.expires_at,
				        u.username, u.display_name, u.photo_url,
				        (SELECT COUNT(*) FROM story_views sv WHERE sv.story_id = s.id AND sv.viewer_id = ?) > 0 AS isViewed,
				        (SELECT COUNT(*) FROM story_views sv WHERE sv.story_id = s.id) AS viewCount
				 FROM stories s
				 JOIN users u ON s.user_id = u.id
				 WHERE s.created_at >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
				 ORDER BY s.created_at ASC`,
				currUID,
			)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Hikayeler alinamadi"})
				return
			}
			defer rows.Close()

			type StoryItem struct {
				ID        int    `json:"id"`
				UserId    int    `json:"userId"`
				MediaUrl  string `json:"mediaUrl"`
				Caption   string `json:"caption"`
				MediaType string `json:"mediaType"`
				CreatedAt string `json:"createdAt"`
				IsViewed  bool   `json:"isViewed"`
				ViewCount int    `json:"viewCount"`
			}
			type StoryGroup struct {
				UserId          int         `json:"userId"`
				Username        string      `json:"username"`
				DisplayName     string      `json:"displayName"`
				UserPhotoUrl    string      `json:"userPhotoUrl"`
				Stories         []StoryItem `json:"stories"`
				AllViewed       bool        `json:"allViewed"`
				LatestTimestamp time.Time   `json:"-"`
			}

			grouped := make(map[int]*StoryGroup)

			for rows.Next() {
				var id, uID, isViewedInt, vCount int
				var mURL, mType, uName string
				var cap, expAt, dName, pURL sql.NullString
				var cAt time.Time

				_ = rows.Scan(&id, &uID, &mURL, &cap, &mType, &cAt, &expAt, &uName, &dName, &pURL, &isViewedInt, &vCount)

				if _, exists := grouped[uID]; !exists {
					grouped[uID] = &StoryGroup{
						UserId:          uID,
						Username:        uName,
						DisplayName:     dName.String,
						UserPhotoUrl:    pURL.String,
						Stories:         []StoryItem{},
						AllViewed:       true,
						LatestTimestamp: cAt,
					}
				}

				isV := isViewedInt > 0
				if !isV && uID != currUID {
					grouped[uID].AllViewed = false
				}
				grouped[uID].LatestTimestamp = cAt
				grouped[uID].Stories = append(grouped[uID].Stories, StoryItem{
					ID:        id,
					UserId:    uID,
					MediaUrl:  mURL,
					Caption:   cap.String,
					MediaType: mType,
					CreatedAt: cAt.Format("2006-01-02 15:04:05"),
					IsViewed:  isV,
					ViewCount: vCount,
				})
			}

			var resList []*StoryGroup
			for _, g := range grouped {
				resList = append(resList, g)
			}
			sort.Slice(resList, func(i, j int) bool {
				return resList[i].LatestTimestamp.After(resList[j].LatestTimestamp)
			})

			c.JSON(http.StatusOK, resList)
		})

		api.POST("/stories/view", func(c *gin.Context) {
			var req struct {
				StoryId  int `json:"storyId"`
				ViewerId int `json:"viewerId"`
			}
			if err := c.ShouldBindJSON(&req); err == nil {
				_, _ = db.Exec("INSERT IGNORE INTO story_views (story_id, viewer_id) VALUES (?, ?)", req.StoryId, req.ViewerId)
			}
			c.JSON(http.StatusOK, gin.H{"status": "success"})
		})

		api.DELETE("/stories/:storyId", func(c *gin.Context) {
			sID := c.Param("storyId")
			uID := c.Query("userId")
			_, _ = db.Exec("DELETE FROM stories WHERE id = ? AND user_id = ?", sID, uID)
			c.JSON(http.StatusOK, gin.H{"status": "success"})
		})

		// 9. Call Logs Endpoints
		api.POST("/calls/logs", func(c *gin.Context) {
			var req struct {
				CallerId        int    `json:"callerId"`
				ReceiverId      int    `json:"receiverId"`
				CallType        string `json:"callType"`
				CallStatus      string `json:"callStatus"`
				DurationSeconds int    `json:"durationSeconds"`
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz istek"})
				return
			}
			res, _ := db.Exec(
				"INSERT INTO call_logs (caller_id, receiver_id, call_type, call_status, duration_seconds) VALUES (?, ?, ?, ?, ?)",
				req.CallerId, req.ReceiverId, req.CallType, req.CallStatus, req.DurationSeconds,
			)
			lid, _ := res.LastInsertId()
			c.JSON(http.StatusOK, gin.H{"status": "success", "callLogId": lid})
		})

		api.GET("/calls/logs/:userId", func(c *gin.Context) {
			uID := c.Param("userId")
			rows, err := db.Query(
				`SELECT cl.id, cl.caller_id, cl.receiver_id, cl.call_type, cl.call_status,
				        cl.duration_seconds, cl.created_at,
				        u_c.display_name, u_c.photo_url,
				        u_r.display_name, u_r.photo_url
				 FROM call_logs cl
				 JOIN users u_c ON cl.caller_id = u_c.id
				 JOIN users u_r ON cl.receiver_id = u_r.id
				 WHERE cl.caller_id = ? OR cl.receiver_id = ?
				 ORDER BY cl.created_at DESC`,
				uID, uID,
			)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Arama kayitlari alinamadi"})
				return
			}
			defer rows.Close()

			var logs []map[string]interface{}
			for rows.Next() {
				var id, cID, rID, dur int
				var cType, cStat string
				var cName, cPic, rName, rPic sql.NullString
				var cAt time.Time

				_ = rows.Scan(&id, &cID, &rID, &cType, &cStat, &dur, &cAt, &cName, &cPic, &rName, &rPic)
				logs = append(logs, map[string]interface{}{
					"id":              id,
					"callerId":        cID,
					"receiverId":      rID,
					"callType":        cType,
					"callStatus":      cStat,
					"durationSeconds": dur,
					"createdAt":       cAt.Format("2006-01-02 15:04:05"),
					"callerName":      cName.String,
					"callerPic":       cPic.String,
					"receiverName":    rName.String,
					"receiverPic":     rPic.String,
				})
			}
			c.JSON(http.StatusOK, logs)
		})

		// 10. Pending Calls Check
		api.GET("/calls/pending/:userId", func(c *gin.Context) {
			uID := c.Param("userId")
			if val, ok := activePendingCalls.Load(uID); ok {
				c.JSON(http.StatusOK, gin.H{"hasPendingCall": true, "callData": val})
				return
			}
			c.JSON(http.StatusOK, gin.H{"hasPendingCall": false, "callData": nil})
		})

		// 11. GROUPS APIS
		// A. Create Group (Creator is automatically admin, max 200 members check)
		api.POST("/groups", func(c *gin.Context) {
			var req struct {
				Name        string `json:"name"`
				PhotoUrl    string `json:"photoUrl"`
				Description string `json:"description"`
				CreatedBy   int    `json:"createdBy"`
				MemberIds   []int  `json:"memberIds"` // Initial member IDs
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz grup bilgisi"})
				return
			}
			if strings.TrimSpace(req.Name) == "" {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Grup ismi bos olamaz"})
				return
			}

			// Ensure unique member list including creator
			uniqueMembers := make(map[int]bool)
			uniqueMembers[req.CreatedBy] = true
			for _, m := range req.MemberIds {
				if m > 0 {
					uniqueMembers[m] = true
				}
			}

			if len(uniqueMembers) > 200 {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Bir grupta en fazla 200 kisi olabilir!"})
				return
			}

			res, err := db.Exec(
				"INSERT INTO groups (name, photo_url, description, created_by) VALUES (?, ?, ?, ?)",
				req.Name, req.PhotoUrl, req.Description, req.CreatedBy,
			)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Grup olusturulamadi"})
				return
			}
			gID, _ := res.LastInsertId()

			// Add creator as admin
			_, _ = db.Exec("INSERT INTO group_members (group_id, user_id, role) VALUES (?, ?, 'admin')", gID, req.CreatedBy)

			// Add other members
			for mUID := range uniqueMembers {
				if mUID != req.CreatedBy {
					_, _ = db.Exec("INSERT IGNORE INTO group_members (group_id, user_id, role) VALUES (?, ?, 'member')", gID, mUID)
				}
			}

			c.JSON(http.StatusOK, gin.H{
				"status":      "success",
				"groupId":     gID,
				"name":        req.Name,
				"memberCount": len(uniqueMembers),
			})
		})

		// B. List Groups for a User
		api.GET("/groups/my/:userId", func(c *gin.Context) {
			uID := c.Param("userId")
			rows, err := db.Query(
				`SELECT g.id, g.name, COALESCE(g.photo_url, ''), COALESCE(g.description, ''), g.created_by, gm.role,
				        (SELECT COUNT(*) FROM group_members WHERE group_id = g.id) AS member_count,
				        COALESCE((SELECT content FROM group_messages WHERE group_id = g.id AND is_deleted = 0 ORDER BY id DESC LIMIT 1), '') AS last_msg,
				        COALESCE((SELECT sender_id FROM group_messages WHERE group_id = g.id AND is_deleted = 0 ORDER BY id DESC LIMIT 1), 0) AS last_sender_id,
				        COALESCE((SELECT created_at FROM group_messages WHERE group_id = g.id AND is_deleted = 0 ORDER BY id DESC LIMIT 1), g.created_at) AS last_time
				 FROM groups g
				 JOIN group_members gm ON g.id = gm.group_id
				 WHERE gm.user_id = ?
				 ORDER BY last_time DESC`,
				uID,
			)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Gruplar alinamadi"})
				return
			}
			defer rows.Close()

			var list []map[string]interface{}
			for rows.Next() {
				var gID, createdBy, memCount, lastSenderID int
				var gName, photoURL, desc, myRole, lastMsg string
				var lastTime time.Time
				_ = rows.Scan(&gID, &gName, &photoURL, &desc, &createdBy, &myRole, &memCount, &lastMsg, &lastSenderID, &lastTime)

				list = append(list, map[string]interface{}{
					"id":           gID,
					"name":         gName,
					"photoUrl":     photoURL,
					"description":  desc,
					"createdBy":    createdBy,
					"myRole":       myRole,
					"memberCount":  memCount,
					"lastMessage":  lastMsg,
					"lastSenderId": strconv.Itoa(lastSenderID),
					"lastTime":     lastTime.Format("2006-01-02 15:04:05"),
				})
			}
			c.JSON(http.StatusOK, list)
		})

		// C. Get Group Details & Members
		api.GET("/groups/:groupId", func(c *gin.Context) {
			gID := c.Param("groupId")
			var id, createdBy int
			var name, photoURL, desc string
			var createdAt time.Time

			err := db.QueryRow("SELECT id, name, COALESCE(photo_url, ''), COALESCE(description, ''), created_by, created_at FROM groups WHERE id = ?", gID).
				Scan(&id, &name, &photoURL, &desc, &createdBy, &createdAt)
			if err != nil {
				c.JSON(http.StatusNotFound, gin.H{"error": "Grup bulunamadi"})
				return
			}

			// Members
			mRows, mErr := db.Query(
				`SELECT u.id, u.username, COALESCE(NULLIF(u.display_name, ''), u.username) AS display_name,
				        COALESCE(u.photo_url, ''), COALESCE(u.phone_number, ''), gm.role, gm.joined_at
				 FROM group_members gm
				 JOIN users u ON gm.user_id = u.id
				 WHERE gm.group_id = ?
				 ORDER BY CASE WHEN gm.role = 'admin' THEN 0 ELSE 1 END, u.display_name ASC`,
				gID,
			)
			var members []map[string]interface{}
			if mErr == nil {
				for mRows.Next() {
					var uID int
					var uname, dname, uPic, phone, role string
					var jAt time.Time
					_ = mRows.Scan(&uID, &uname, &dname, &uPic, &phone, &role, &jAt)
					members = append(members, map[string]interface{}{
						"userId":      uID,
						"username":    uname,
						"displayName": dname,
						"photoUrl":    uPic,
						"phoneNumber": phone,
						"role":        role,
						"joinedAt":    jAt.Format("2006-01-02 15:04:05"),
					})
				}
				mRows.Close()
			}

			c.JSON(http.StatusOK, gin.H{
				"id":          id,
				"name":        name,
				"photoUrl":    photoURL,
				"description": desc,
				"createdBy":   createdBy,
				"createdAt":   createdAt.Format("2006-01-02 15:04:05"),
				"members":     members,
				"memberCount": len(members),
			})
		})

		// D. Update Group Info / Photo (Only admin allowed)
		api.PUT("/groups/:groupId", func(c *gin.Context) {
			gID := c.Param("groupId")
			var req struct {
				UserId      int     `json:"userId"` // Requester user ID
				Name        *string `json:"name"`
				PhotoUrl    *string `json:"photoUrl"`
				Description *string `json:"description"`
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz istek"})
				return
			}

			var role string
			err := db.QueryRow("SELECT role FROM group_members WHERE group_id = ? AND user_id = ?", gID, req.UserId).Scan(&role)
			if err != nil || role != "admin" {
				c.JSON(http.StatusForbidden, gin.H{"error": "Bu islemi sadece grup yoneticisi yapabilir!"})
				return
			}

			if req.Name != nil && strings.TrimSpace(*req.Name) != "" {
				_, _ = db.Exec("UPDATE groups SET name = ? WHERE id = ?", strings.TrimSpace(*req.Name), gID)
			}
			if req.PhotoUrl != nil {
				_, _ = db.Exec("UPDATE groups SET photo_url = ? WHERE id = ?", *req.PhotoUrl, gID)
			}
			if req.Description != nil {
				_, _ = db.Exec("UPDATE groups SET description = ? WHERE id = ?", *req.Description, gID)
			}

			c.JSON(http.StatusOK, gin.H{"status": "success", "message": "Grup bilgileri güncellendi"})
		})

		// E. Add Member(s) to Group (Only admin allowed, max 200 limit enforced)
		api.POST("/groups/:groupId/members", func(c *gin.Context) {
			gID := c.Param("groupId")
			var req struct {
				AdminUserId int   `json:"adminUserId"`
				UserIds     []int `json:"userIds"`
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz istek"})
				return
			}

			var role string
			err := db.QueryRow("SELECT role FROM group_members WHERE group_id = ? AND user_id = ?", gID, req.AdminUserId).Scan(&role)
			if err != nil || role != "admin" {
				c.JSON(http.StatusForbidden, gin.H{"error": "Sadece grup yoneticisi uye ekleyebilir!"})
				return
			}

			var currentCount int
			_ = db.QueryRow("SELECT COUNT(*) FROM group_members WHERE group_id = ?", gID).Scan(&currentCount)

			addedCount := 0
			for _, newUID := range req.UserIds {
				if currentCount+addedCount >= 200 {
					break
				}
				res, insErr := db.Exec("INSERT IGNORE INTO group_members (group_id, user_id, role) VALUES (?, ?, 'member')", gID, newUID)
				if insErr == nil {
					aff, _ := res.RowsAffected()
					if aff > 0 {
						addedCount++
					}
				}
			}

			if currentCount+addedCount >= 200 && len(req.UserIds) > addedCount {
				c.JSON(http.StatusOK, gin.H{
					"status":  "partial",
					"message": "Grup limiti (en fazla 200 kişi) dolduğu için kalan üyeler eklenemedi.",
					"added":   addedCount,
				})
				return
			}

			c.JSON(http.StatusOK, gin.H{"status": "success", "added": addedCount})
		})

		// F. Update Member Role (Promote to Admin or Demote to Member, only admin allowed)
		api.PUT("/groups/:groupId/members/role", func(c *gin.Context) {
			gID := c.Param("groupId")
			var req struct {
				AdminUserId  int    `json:"adminUserId"`
				TargetUserId int    `json:"targetUserId"`
				NewRole      string `json:"newRole"` // 'admin' or 'member'
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz istek"})
				return
			}

			var role string
			err := db.QueryRow("SELECT role FROM group_members WHERE group_id = ? AND user_id = ?", gID, req.AdminUserId).Scan(&role)
			if err != nil || role != "admin" {
				c.JSON(http.StatusForbidden, gin.H{"error": "Sadece yonetici uye rollerini degistirebilir!"})
				return
			}

			if req.NewRole != "admin" && req.NewRole != "member" {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz rol (admin veya member olmali)"})
				return
			}

			_, _ = db.Exec("UPDATE group_members SET role = ? WHERE group_id = ? AND user_id = ?", req.NewRole, gID, req.TargetUserId)
			c.JSON(http.StatusOK, gin.H{"status": "success", "newRole": req.NewRole})
		})

		// G. Remove Member or Leave Group
		api.DELETE("/groups/:groupId/members/:userId", func(c *gin.Context) {
			gID := c.Param("groupId")
			targetUID := c.Param("userId")
			reqUID := c.DefaultQuery("requesterId", targetUID)

			// If removing someone else, requester must be admin
			if reqUID != targetUID {
				var role string
				err := db.QueryRow("SELECT role FROM group_members WHERE group_id = ? AND user_id = ?", gID, reqUID).Scan(&role)
				if err != nil || role != "admin" {
					c.JSON(http.StatusForbidden, gin.H{"error": "Baska bir uyeyi yalnizca yonetici gruptan cikarabilir!"})
					return
				}
			}

			_, _ = db.Exec("DELETE FROM group_members WHERE group_id = ? AND user_id = ?", gID, targetUID)
			c.JSON(http.StatusOK, gin.H{"status": "success", "message": "Uye gruptan ayrildi"})
		})

		// H. Get Group Messages (Filtered by deleted_by_users)
		api.GET("/groups/:groupId/messages", func(c *gin.Context) {
			gID := c.Param("groupId")
			currUID := c.DefaultQuery("userId", "0")

			rows, err := db.Query(
				`SELECT gm.id, gm.group_id, gm.sender_id, gm.content, gm.message_type, gm.media_url,
				        gm.is_deleted, gm.deleted_by_users, gm.is_edited, gm.created_at,
				        COALESCE(NULLIF(u.display_name, ''), u.username) AS sender_name,
				        COALESCE(u.photo_url, '') AS sender_photo
				 FROM group_messages gm
				 JOIN users u ON gm.sender_id = u.id
				 WHERE gm.group_id = ?
				 ORDER BY gm.created_at ASC`,
				gID,
			)
			if err != nil {
				c.JSON(http.StatusInternalServerError, gin.H{"error": "Grup mesajlari alinamadi"})
				return
			}
			defer rows.Close()

			var msgs []map[string]interface{}
			for rows.Next() {
				var id, gIDVal, sID, isDel, isEd int
				var content, mType, sName, sPic string
				var mURL, delByUsers sql.NullString
				var cAt time.Time

				_ = rows.Scan(&id, &gIDVal, &sID, &content, &mType, &mURL, &isDel, &delByUsers, &isEd, &cAt, &sName, &sPic)

				if delByUsers.Valid && delByUsers.String != "" {
					hiddenForMe := false
					for _, u := range strings.Split(delByUsers.String, ",") {
						if strings.TrimSpace(u) == currUID {
							hiddenForMe = true
							break
						}
					}
					if hiddenForMe {
						continue
					}
				}

				msgs = append(msgs, map[string]interface{}{
					"id":          id,
					"groupId":     gIDVal,
					"senderId":    sID,
					"senderName":  sName,
					"senderPhoto": sPic,
					"content":     content,
					"type":        mType,
					"mediaUrl":    mURL.String,
					"isDeleted":   isDel == 1,
					"isEdited":    isEd == 1,
					"timestamp":   cAt.Format("2006-01-02 15:04:05"),
				})
			}
			c.JSON(http.StatusOK, msgs)
		})
	}

	log.Printf("[*] Talknex Go Ultra-Fast Backend calisiyor (Port: %s)...", serverPort)
	if err := router.Run(":" + serverPort); err != nil {
		log.Fatalf("[HATA] Go sunucusu baslatilamadi: %v", err)
	}
}
