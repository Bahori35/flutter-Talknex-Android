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
	"strconv"
	"strings"
	"sync"
	"time"

	firebase "firebase.google.com/go/v4"
	"firebase.google.com/go/v4/messaging"
	"github.com/gin-gonic/gin"
	_ "github.com/go-sql-driver/mysql"
	"github.com/golang-jwt/jwt/v5"
	socketio "github.com/googollee/go-socket.io"
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

	// Active Sockets: userID (string) -> socket connection
	activeSockets sync.Map
	// Pending calls: receiverID (string) -> callData (map[string]interface{})
	activePendingCalls sync.Map

	uploadDir string
)

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

	db.SetMaxOpenConns(500)
	db.SetMaxIdleConns(50)
	db.SetConnMaxLifetime(time.Hour)

	if pingErr := db.Ping(); pingErr != nil {
		log.Printf("[UYARI] MariaDB baglanti denemesi uyarisi: %v", pingErr)
	} else {
		log.Println("[OK] MariaDB Go yuksek performansli baglantisi hazir!")
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

	// Ensure uploads directory exists
	exeDir, _ := filepath.Abs(filepath.Dir(os.Args[0]))
	uploadDir = filepath.Join(exeDir, "uploads")
	_ = os.MkdirAll(uploadDir, os.ModePerm)

	// --- SETUP SOCKET.IO SERVER ---
	server := socketio.NewServer(nil)

	server.OnConnect("/", func(s socketio.Conn) error {
		s.SetContext("")
		return nil
	})

	server.OnEvent("/", "join", func(s socketio.Conn, userID interface{}) {
		uidStr := fmt.Sprintf("%v", userID)
		s.SetContext(uidStr)
		activeSockets.Store(uidStr, s)
		log.Printf("[USER] Kullanici baglandi: ID %s", uidStr)

		// DB Update: is_online = 1
		_, _ = db.Exec("UPDATE users SET is_online = 1 WHERE id = ?", uidStr)
		_, _ = db.Exec("UPDATE messages SET is_delivered = 1 WHERE receiver_id = ? AND is_delivered = 0", uidStr)

		server.BroadcastToNamespace("/", "user_status_change", map[string]interface{}{
			"userId":   uidStr,
			"isOnline": true,
		})
	})

	server.OnEvent("/", "send_message", func(s socketio.Conn, data map[string]interface{}) {
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

		receiverVal, isReceiverOnline := activeSockets.Load(strconv.Itoa(receiverID))
		isDelivered := isReceiverOnline

		// Insert Message
		res, err := db.Exec(
			"INSERT INTO messages (sender_id, receiver_id, content, message_type, media_url, is_delivered, is_read) VALUES (?, ?, ?, ?, ?, ?, 0)",
			senderID, receiverID, content, msgType, mediaURL, isDelivered,
		)
		if err != nil {
			log.Printf("[DB ERR send_message]: %v", err)
			return
		}

		msgID, _ := res.LastInsertId()

		// Sender Display Name
		var senderName string
		_ = db.QueryRow("SELECT COALESCE(NULLIF(display_name, ''), username) FROM users WHERE id = ?", senderID).Scan(&senderName)
		if senderName == "" {
			senderName = "Biri"
		}

		savedMessage := map[string]interface{}{
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
			if rConn, ok := receiverVal.(socketio.Conn); ok {
				rConn.Emit("receive_message", savedMessage)
			}
		}
		s.Emit("message_sent", savedMessage)

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
	})

	server.OnEvent("/", "edit_message", func(s socketio.Conn, data map[string]interface{}) {
		msgID, _ := strconv.Atoi(fmt.Sprintf("%v", data["messageId"]))
		senderID, _ := strconv.Atoi(fmt.Sprintf("%v", data["senderId"]))
		receiverID, _ := strconv.Atoi(fmt.Sprintf("%v", data["receiverId"]))
		newContent := fmt.Sprintf("%v", data["newContent"])

		if msgID == 0 || newContent == "" {
			return
		}

		// Save original content for forensics on first edit
		var oldContent, origContent sql.NullString
		_ = db.QueryRow("SELECT content, original_content FROM messages WHERE id = ?", msgID).Scan(&oldContent, &origContent)
		firstContent := oldContent.String
		if origContent.Valid && origContent.String != "" {
			firstContent = origContent.String
		}

		_, _ = db.Exec("UPDATE messages SET content = ?, original_content = ?, is_edited = 1 WHERE id = ?", newContent, firstContent, msgID)

		payload := map[string]interface{}{
			"messageId":  msgID,
			"senderId":   senderID,
			"receiverId": receiverID,
			"newContent": newContent,
			"isEdited":   true,
		}

		if rVal, ok := activeSockets.Load(strconv.Itoa(receiverID)); ok {
			if rConn, ok := rVal.(socketio.Conn); ok {
				rConn.Emit("message_edited", payload)
			}
		}
		s.Emit("message_edited", payload)
	})

	server.OnEvent("/", "delete_message", func(s socketio.Conn, data map[string]interface{}) {
		msgID, _ := strconv.Atoi(fmt.Sprintf("%v", data["messageId"]))
		senderID, _ := strconv.Atoi(fmt.Sprintf("%v", data["senderId"]))
		receiverID, _ := strconv.Atoi(fmt.Sprintf("%v", data["receiverId"]))

		if msgID == 0 {
			return
		}

		// Soft Delete: Keep row for audit
		_, _ = db.Exec("UPDATE messages SET is_deleted = 1 WHERE id = ?", msgID)

		payload := map[string]interface{}{
			"messageId":  strconv.Itoa(msgID),
			"senderId":   strconv.Itoa(senderID),
			"receiverId": strconv.Itoa(receiverID),
		}

		if rVal, ok := activeSockets.Load(strconv.Itoa(receiverID)); ok {
			if rConn, ok := rVal.(socketio.Conn); ok {
				rConn.Emit("message_deleted", payload)
			}
		}
		s.Emit("message_deleted", payload)
	})

	server.OnEvent("/", "call_user", func(s socketio.Conn, data map[string]interface{}) {
		receiverID := fmt.Sprintf("%v", data["receiverId"])
		activePendingCalls.Store(receiverID, data)

		if rVal, ok := activeSockets.Load(receiverID); ok {
			if rConn, ok := rVal.(socketio.Conn); ok {
				rConn.Emit("incoming_call", data)
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
	})

	server.OnEvent("/", "answer_call", func(s socketio.Conn, data map[string]interface{}) {
		callerID := fmt.Sprintf("%v", data["callerId"])
		activePendingCalls.Range(func(key, value interface{}) bool {
			activePendingCalls.Delete(key)
			return true
		})

		if cVal, ok := activeSockets.Load(callerID); ok {
			if cConn, ok := cVal.(socketio.Conn); ok {
				cConn.Emit("call_answered", data)
			}
		}
	})

	server.OnEvent("/", "ice_candidate", func(s socketio.Conn, data map[string]interface{}) {
		targetUserID := fmt.Sprintf("%v", data["targetUserId"])
		if tVal, ok := activeSockets.Load(targetUserID); ok {
			if tConn, ok := tVal.(socketio.Conn); ok {
				tConn.Emit("ice_candidate", data)
			}
		}
	})

	server.OnEvent("/", "end_call", func(s socketio.Conn, data map[string]interface{}) {
		activePendingCalls.Range(func(key, value interface{}) bool {
			activePendingCalls.Delete(key)
			return true
		})

		targetUserID := ""
		if data != nil {
			targetUserID = fmt.Sprintf("%v", data["targetUserId"])
		}

		if targetUserID != "" {
			if tVal, ok := activeSockets.Load(targetUserID); ok {
				if tConn, ok := tVal.(socketio.Conn); ok {
					tConn.Emit("call_ended", map[string]interface{}{})
				}
			}
		} else {
			activeSockets.Range(func(key, val interface{}) bool {
				if sConn, ok := val.(socketio.Conn); ok && sConn.ID() != s.ID() {
					sConn.Emit("call_ended", map[string]interface{}{})
				}
				return true
			})
		}
	})

	server.OnDisconnect("/", func(s socketio.Conn, reason string) {
		uidStr := s.Context()
		if uid, ok := uidStr.(string); ok && uid != "" {
			activeSockets.Delete(uid)
			log.Printf("[USER] Kullanici ayrildi: ID %s", uid)
			_, _ = db.Exec("UPDATE users SET is_online = 0, last_seen = NOW() WHERE id = ?", uid)
			server.BroadcastToNamespace("/", "user_status_change", map[string]interface{}{
				"userId":   uid,
				"isOnline": false,
			})
		}
	})

	go func() {
		if err := server.Serve(); err != nil {
			log.Fatalf("[SOCKET HATA]: %v", err)
		}
	}()
	defer server.Close()

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

	// Socket.IO Mount
	router.GET("/socket.io/*any", gin.WrapH(server))
	router.POST("/socket.io/*any", gin.WrapH(server))

	// REST API Routes
	api := router.Group("/api")
	{
		api.POST("/register", func(c *gin.Context) {
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

			hash := hashPassword(req.Password)
			res, err := db.Exec(
				"INSERT INTO users (username, display_name, password_hash, phone_number) VALUES (?, ?, ?, ?)",
				req.Username, req.DisplayName, hash, req.PhoneNumber,
			)
			if err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Kullanici adi zaten alinmis"})
				return
			}
			id, _ := res.LastInsertId()
			token := generateJWT(int(id), req.Username)
			c.JSON(http.StatusOK, gin.H{
				"status": "success",
				"token":  token,
				"user": gin.H{
					"id":          id,
					"username":    req.Username,
					"displayName": req.DisplayName,
					"phoneNumber": req.PhoneNumber,
				},
			})
		})

		api.POST("/login", func(c *gin.Context) {
			var req struct {
				Username string `json:"username"`
				Password string `json:"password"`
			}
			if err := c.ShouldBindJSON(&req); err != nil {
				c.JSON(http.StatusBadRequest, gin.H{"error": "Gecersiz istek"})
				return
			}

			var id int
			var pwdHash, displayName, photoURL, phone, status string
			err := db.QueryRow("SELECT id, password_hash, display_name, photo_url, phone_number, status FROM users WHERE username = ?", req.Username).
				Scan(&id, &pwdHash, &displayName, &photoURL, &phone, &status)
			if err != nil || !checkPassword(req.Password, pwdHash) {
				c.JSON(http.StatusUnauthorized, gin.H{"error": "Kullanici adi veya sifre hatali"})
				return
			}

			token := generateJWT(id, req.Username)
			c.JSON(http.StatusOK, gin.H{
				"status": "success",
				"token":  token,
				"user": gin.H{
					"id":          id,
					"username":    req.Username,
					"displayName": displayName,
					"photoUrl":    photoURL,
					"phoneNumber": phone,
					"status":      status,
				},
			})
		})

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

		api.GET("/calls/pending/:userId", func(c *gin.Context) {
			uID := c.Param("userId")
			if val, ok := activePendingCalls.Load(uID); ok {
				c.JSON(http.StatusOK, gin.H{"hasPendingCall": true, "callData": val})
				return
			}
			c.JSON(http.StatusOK, gin.H{"hasPendingCall": false, "callData": nil})
		})
	}

	log.Printf("[*] Talknex Go Ultra-Fast Backend calisiyor (Port: %s)...", serverPort)
	if err := router.Run(":" + serverPort); err != nil {
		log.Fatalf("[HATA] Go sunucusu baslatilamadi: %v", err)
	}
}
