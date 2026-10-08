package main

import (
	// "net/http"
	"os"

	"github.com/gin-gonic/gin"
	// "github.com/joho/godotenv"
)

var Port string

func main() {
	r := gin.Default()

	Log.Info("")

	InitLogger()

	// if err := godotenv.Load(); err != nil {
	// 	Log.Fatal("Ошибка при загрузке .env файла")
	// }

	// db, err := NewPostgresConnection()
	// if err != nil {
	// 	Log.Fatal("Ошибка подключения к БД: ", err)
	// }
	// Log.Info("Успешно осуществлено подключение к БД")

	// err = RunMigrations(db)
	// if err != nil {
	// 	Log.Fatal("Ошибка применения миграций: ", err)
	// }
	Log.Info("Миграции успешно применены")

	// handler := NewHandler(db)

	port := os.Getenv("PORT")

	// Идентификатор инстанса — чтобы за балансировщиком было видно, кто ответил.
	instanceID := os.Getenv("INSTANCE_ID")
	if instanceID == "" {
		instanceID = "backend:" + port
	}
	r.Use(func(c *gin.Context) {
		c.Header("X-Instance-Id", instanceID)
		c.Next()
	})

	// api := r.Group("/api")
	// {
	// 	api.GET("/whoami", func(c *gin.Context) {
	// 		c.JSON(http.StatusOK, gin.H{"instance": instanceID, "port": port})
	// 	})
	// 	api.GET("/tasks", handler.GetTasks)
	// 	api.POST("/task", handler.PostTask)
	// 	api.DELETE("/tasks", handler.DeleteTasks)
	// }

	Log.Info("Сервер запущен на порту :" + port)

	if err := r.Run(":" + Port); err != nil {
		Log.Error(err)
	}
}
