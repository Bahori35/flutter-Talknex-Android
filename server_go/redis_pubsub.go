package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

var (
	rdb              *redis.Client
	isRedisActive    bool
	serverInstanceID string
	redisCtx         = context.Background()
)

// RedisPubSubMessage encapsulates an event broadcast or unicast across servers
type RedisPubSubMessage struct {
	OriginServer string      `json:"originServer"`
	ChannelType  string      `json:"channelType"` // "user", "broadcast", "group"
	TargetID     string      `json:"targetId"`     // userID or groupID
	Event        string      `json:"event"`
	Data         interface{} `json:"data"`
}

func initRedis() {
	serverInstanceID = "srv-" + uuid.New().String()[:8]
	redisHost := getEnv("REDIS_HOST", "")
	redisPort := getEnv("REDIS_PORT", "6379")
	redisPassword := getEnv("REDIS_PASSWORD", "")
	redisDB := 0

	// Check if Redis is enabled
	redisEnabled := strings.ToLower(getEnv("REDIS_ENABLED", "auto"))
	if redisEnabled == "false" || (redisEnabled == "auto" && redisHost == "") {
		log.Printf("[REDIS] Redis yapılandırması belirtilmedi. Tek sunucu (In-Memory) modunda çalışılıyor.")
		isRedisActive = false
		return
	}

	if redisHost == "" {
		redisHost = "localhost"
	}

	addr := fmt.Sprintf("%s:%s", redisHost, redisPort)
	log.Printf("[REDIS] Bağlantı kuruluyor: %s (Sunucu ID: %s)...", addr, serverInstanceID)

	rdb = redis.NewClient(&redis.Options{
		Addr:         addr,
		Password:     redisPassword,
		DB:           redisDB,
		DialTimeout:  3 * time.Second,
		ReadTimeout:  3 * time.Second,
		WriteTimeout: 3 * time.Second,
	})

	ctx, cancel := context.WithTimeout(redisCtx, 3*time.Second)
	defer cancel()

	if err := rdb.Ping(ctx).Err(); err != nil {
		log.Printf("[REDIS UYARI] Redis sunucusuna bağlanılamadı: %v. Sunucu yerel bellek modunda devam ediyor.", err)
		isRedisActive = false
		return
	}

	isRedisActive = true
	log.Printf("[REDIS BAŞARILI] Redis Pub/Sub kümesine bağlandı! 500k Çoklu Sunucu (Cluster) modu aktif.")

	// Start subscriber loop in background
	go startRedisSubscriber()
}

func startRedisSubscriber() {
	pubsub := rdb.PSubscribe(redisCtx, "talknex:events:*")
	defer pubsub.Close()

	ch := pubsub.Channel()
	for msg := range ch {
		var pkt RedisPubSubMessage
		if err := json.Unmarshal([]byte(msg.Payload), &pkt); err != nil {
			continue
		}

		// Don't echo message if this server instance originated it
		if pkt.OriginServer == serverInstanceID {
			continue
		}

		handleIncomingClusterMessage(pkt)
	}
}

func handleIncomingClusterMessage(pkt RedisPubSubMessage) {
	switch pkt.ChannelType {
	case "user":
		// Check if target user is connected to THIS server instance
		if val, ok := wsClients.Load(pkt.TargetID); ok {
			if client, ok := val.(*WSClient); ok {
				_ = client.Send(pkt.Event, pkt.Data)
			}
		}

	case "broadcast":
		// Broadcast to all clients connected to THIS server instance
		wsClients.Range(func(key, value interface{}) bool {
			if client, ok := value.(*WSClient); ok {
				_ = client.Send(pkt.Event, pkt.Data)
			}
			return true
		})

	case "group":
		deliverGroupEventLocally(pkt.TargetID, pkt.Event, pkt.Data)
	}
}

// deliverGroupEventLocally sends the event to all users connected to THIS server who are members of groupID
func deliverGroupEventLocally(groupIDStr string, event string, data interface{}) {
	wsClients.Range(func(key, value interface{}) bool {
		userIDStr, _ := key.(string)
		if client, ok := value.(*WSClient); ok {
			var count int
			_ = db.QueryRow("SELECT COUNT(*) FROM group_members WHERE group_id = ? AND user_id = ?", groupIDStr, userIDStr).Scan(&count)
			if count > 0 {
				_ = client.Send(event, data)
			}
		}
		return true
	})
}

// dispatchUserEvent delivers an event to targetUserID (locally if present, and via Redis across other servers)
func dispatchUserEvent(targetUserID string, event string, data interface{}) {
	// 1. Deliver locally if user is on this node
	if val, ok := wsClients.Load(targetUserID); ok {
		if client, ok := val.(*WSClient); ok {
			_ = client.Send(event, data)
		}
	}

	// 2. Publish to Redis so other server instances can deliver it to targetUserID
	if isRedisActive {
		pkt := RedisPubSubMessage{
			OriginServer: serverInstanceID,
			ChannelType:  "user",
			TargetID:     targetUserID,
			Event:        event,
			Data:         data,
		}
		payloadBytes, err := json.Marshal(pkt)
		if err == nil {
			_ = rdb.Publish(redisCtx, "talknex:events:user:"+targetUserID, string(payloadBytes))
		}
	}
}

// dispatchBroadcastEvent delivers to all users on this node and all other nodes via Redis
func dispatchBroadcastEvent(event string, data interface{}) {
	// 1. Deliver to all local clients
	wsClients.Range(func(key, value interface{}) bool {
		if client, ok := value.(*WSClient); ok {
			_ = client.Send(event, data)
		}
		return true
	})

	// 2. Publish to Redis cluster
	if isRedisActive {
		pkt := RedisPubSubMessage{
			OriginServer: serverInstanceID,
			ChannelType:  "broadcast",
			Event:        event,
			Data:         data,
		}
		payloadBytes, err := json.Marshal(pkt)
		if err == nil {
			_ = rdb.Publish(redisCtx, "talknex:events:broadcast", string(payloadBytes))
		}
	}
}

// dispatchGroupEvent delivers to group members across all cluster nodes
func dispatchGroupEvent(groupIDStr string, event string, data interface{}) {
	// 1. Deliver locally
	deliverGroupEventLocally(groupIDStr, event, data)

	// 2. Publish to Redis
	if isRedisActive {
		pkt := RedisPubSubMessage{
			OriginServer: serverInstanceID,
			ChannelType:  "group",
			TargetID:     groupIDStr,
			Event:        event,
			Data:         data,
		}
		payloadBytes, err := json.Marshal(pkt)
		if err == nil {
			_ = rdb.Publish(redisCtx, "talknex:events:group:"+groupIDStr, string(payloadBytes))
		}
	}
}

// setClusterUserOnline tracks user presence across the cluster
func setClusterUserOnline(userID string, isOnline bool) {
	if !isRedisActive {
		return
	}
	key := "talknex:online:" + userID
	if isOnline {
		_ = rdb.Set(redisCtx, key, "1", 24*time.Hour)
	} else {
		_ = rdb.Del(redisCtx, key)
	}
}

// isUserOnlineInCluster checks if user is online on this server or in Redis cluster
func isUserOnlineInCluster(userID string) bool {
	// Check locally
	if _, ok := wsClients.Load(userID); ok {
		return true
	}
	// Check Redis
	if isRedisActive {
		val, err := rdb.Get(redisCtx, "talknex:online:"+userID).Result()
		if err == nil && val == "1" {
			return true
		}
	}
	return false
}
