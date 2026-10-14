package main

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/minio/minio-go/v7"
	"github.com/minio/minio-go/v7/pkg/credentials"
)

var (
	s3Client    *minio.Client
	isS3Active  bool
	s3Bucket    string
	s3PublicURL string
)

func initS3Storage() {
	endpoint := getEnv("S3_ENDPOINT", "")
	accessKey := getEnv("S3_ACCESS_KEY", "")
	secretKey := getEnv("S3_SECRET_KEY", "")
	bucket := getEnv("S3_BUCKET", "")
	region := getEnv("S3_REGION", "auto")
	s3PublicURL = strings.TrimSuffix(getEnv("S3_PUBLIC_URL", ""), "/")
	useSSL := getEnv("S3_USE_SSL", "true") == "true"

	if endpoint == "" || accessKey == "" || secretKey == "" || bucket == "" {
		log.Printf("[STORAGE] S3/R2 yapılandırması belirtilmedi. Yerel disk (/uploads) modunda çalışılıyor.")
		isS3Active = false
		return
	}

	// Clean endpoint scheme if passed with https:// or http://
	cleanedEndpoint := endpoint
	if strings.HasPrefix(cleanedEndpoint, "https://") {
		cleanedEndpoint = strings.TrimPrefix(cleanedEndpoint, "https://")
		useSSL = true
	} else if strings.HasPrefix(cleanedEndpoint, "http://") {
		cleanedEndpoint = strings.TrimPrefix(cleanedEndpoint, "http://")
		useSSL = false
	}

	client, err := minio.New(cleanedEndpoint, &minio.Options{
		Creds:  credentials.NewStaticV4(accessKey, secretKey, ""),
		Secure: useSSL,
		Region: region,
	})
	if err != nil {
		log.Printf("[STORAGE UYARI] S3 istemcisi başlatılamadı: %v. Yerel disk modunda devam ediliyor.", err)
		isS3Active = false
		return
	}

	s3Client = client
	s3Bucket = bucket

	// Test bucket reachability
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	exists, err := s3Client.BucketExists(ctx, s3Bucket)
	if err != nil {
		log.Printf("[STORAGE UYARI] S3 Bucket kontrolü uyarısı: %v. (Devam ediliyor)", err)
	} else if !exists {
		// Attempt to create bucket
		err = s3Client.MakeBucket(ctx, s3Bucket, minio.MakeBucketOptions{Region: region})
		if err != nil {
			log.Printf("[STORAGE UYARI] S3 Bucket oluşturulamadı: %v", err)
		} else {
			log.Printf("[STORAGE] S3 Bucket oluşturuldu: %s", s3Bucket)
		}
	}

	isS3Active = true
	if s3PublicURL == "" {
		proto := "https://"
		if !useSSL {
			proto = "http://"
		}
		s3PublicURL = fmt.Sprintf("%s%s/%s", proto, endpoint, s3Bucket)
	}

	log.Printf("[STORAGE BAŞARILI] S3 / Cloudflare R2 Nesne Depolama aktif! (Bucket: %s, Public: %s)", s3Bucket, s3PublicURL)
}

// uploadFileStream saves the file to S3/R2 if active, or falls back to local disk
func uploadFileStream(file io.Reader, originalFilename string, size int64, contentType string, serverBaseURL string) (string, error) {
	ext := filepath.Ext(originalFilename)
	if ext == "" {
		ext = ".jpg"
	}
	randBytes := make([]byte, 16)
	_, _ = rand.Read(randBytes)
	filename := hex.EncodeToString(randBytes) + ext

	if isS3Active {
		ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()

		if contentType == "" {
			contentType = "application/octet-stream"
		}

		_, err := s3Client.PutObject(ctx, s3Bucket, filename, file, size, minio.PutObjectOptions{
			ContentType: contentType,
		})
		if err != nil {
			return "", fmt.Errorf("S3 yukleme hatasi: %w", err)
		}

		publicURL := fmt.Sprintf("%s/%s", s3PublicURL, filename)
		return publicURL, nil
	}

	// Fallback: Local Disk Storage
	dstPath := filepath.Join(uploadDir, filename)
	out, err := os.Create(dstPath)
	if err != nil {
		return "", fmt.Errorf("Yerel dosya olusturulamadi: %w", err)
	}
	defer out.Close()

	if _, err := io.Copy(out, file); err != nil {
		return "", fmt.Errorf("Dosya yazilamadi: %w", err)
	}

	localURL := fmt.Sprintf("%s/uploads/%s", strings.TrimSuffix(serverBaseURL, "/"), filename)
	return localURL, nil
}

// generatePresignedUploadURL creates a direct client-to-S3 upload URL
func generatePresignedUploadURL(ext string, contentType string, expiry time.Duration) (uploadURL string, downloadURL string, err error) {
	if !isS3Active {
		return "", "", fmt.Errorf("S3 depolama aktif degil")
	}

	if ext == "" {
		ext = ".jpg"
	}
	if !strings.HasPrefix(ext, ".") {
		ext = "." + ext
	}

	randBytes := make([]byte, 16)
	_, _ = rand.Read(randBytes)
	filename := hex.EncodeToString(randBytes) + ext

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	u, err := s3Client.PresignedPutObject(ctx, s3Bucket, filename, expiry)
	if err != nil {
		return "", "", err
	}

	uploadURL = u.String()
	downloadURL = fmt.Sprintf("%s/%s", s3PublicURL, filename)
	return uploadURL, downloadURL, nil
}
