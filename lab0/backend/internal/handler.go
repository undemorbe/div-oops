package main

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"gorm.io/gorm"
)

type Handler struct {
	db *gorm.DB
}

func NewHandler(db *gorm.DB) *Handler {
	return &Handler{db: db}
}

func (h *Handler) PostTask(c *gin.Context) {

	var req PostTaskRequest

	err := c.BindJSON(&req)
	if err != nil {
		Log.Warn("Некорректнеый запрос: ", err)
		c.Status(http.StatusBadRequest)
		return
	}

	if req.Task.Title == "" {
		Log.Warn("Отсутствует Title")
		c.Status(http.StatusBadRequest)
		return
	}

	task := Task{Title: req.Task.Title}

	err = h.db.Save(&task).Error
	if err != nil {
		Log.Error("Ошибка при сохранении задачи в БД: ", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	c.Status(http.StatusNoContent)
}

func (h *Handler) GetTasks(c *gin.Context) {

	var tasks []Task

	err := h.db.Find(&tasks).Error
	if err != nil {
		Log.Error("Ошибка при поиске задач в БД: ", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	taskModels := make([]TaskModel, 0, len(tasks))

	for _, task := range tasks {
		taskModels = append(taskModels, TaskModel{
			Title: task.Title,
		})
	}

	response := GetTasksResponse{Tasks: taskModels}

	c.JSON(http.StatusOK, response)
}

func (h *Handler) DeleteTasks(c *gin.Context) {

	err := h.db.
		Where("title != ?", "").
		Delete(&Task{}).
		Error

	if err != nil {
		Log.Error("Ошибка при удалении задач в БД: ", err)
		c.Status(http.StatusInternalServerError)
		return
	}

	c.Status(http.StatusNoContent)
}
