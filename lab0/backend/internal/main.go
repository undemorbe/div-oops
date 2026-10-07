package main

import (
	"net/http"
	"os"

	"github.com/gin-gonic/gin"
	"github.com/joho/godotenv"
)

var Port string

func main() {
	r := gin.Default()

	InitLogger()

	if err := godotenv.Load(); err != nil {
		Log.Fatal("Ошибка при загрузке .env файла")
	}

	db, err := NewPostgresConnection()
	if err != nil {
		Log.Fatal("Ошибка подключения к БД: ", err)
	}
	Log.Info("Успешно осуществлено подключение к БД")

	err = RunMigrations(db)
	if err != nil {
		Log.Fatal("Ошибка применения миграций: ", err)
	}
	Log.Info("Миграции успешно применены")

	handler := NewHandler(db)

	api := r.Group("/api")
	{
		api.GET("/tasks", handler.GetTasks)
		api.POST("/task", handler.PostTask)
		api.DELETE("/tasks", handler.DeleteTasks)

		r.GET("/health", func(c *gin.Context) {
			c.Status(http.StatusOK)
		})
	}

	Port = os.Getenv("PORT")
	Log.Info("Сервер запущен на порту :" + Port)

	if err := r.Run(":" + Port); err != nil {
		Log.Error(err)
	}
}
