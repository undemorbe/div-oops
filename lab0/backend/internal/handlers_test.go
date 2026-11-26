package main

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"regexp"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"github.com/gin-gonic/gin"
	"github.com/sirupsen/logrus"
	"gorm.io/driver/postgres"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func setupTestHandler(t *testing.T) (*Handler, sqlmock.Sqlmock) {
	t.Helper()

	Log = logrus.New()
	Log.SetLevel(logrus.PanicLevel)

	sqlDB, mock, err := sqlmock.New()
	if err != nil {
		t.Fatalf("не удалось создать sqlmock: %v", err)
	}

	db, err := gorm.Open(postgres.New(postgres.Config{
		Conn: sqlDB,
	}), &gorm.Config{
		Logger: logger.Default.LogMode(logger.Info),
	})
	if err != nil {
		sqlDB.Close()
		t.Fatalf("не удалось создать GORM DB: %v", err)
	}

	t.Cleanup(func() {
		_ = sqlDB.Close()
	})

	return NewHandler(db), mock
}

func setupRouter(handler *Handler) *gin.Engine {
	gin.SetMode(gin.TestMode)

	router := gin.New()
	router.GET("/tasks", handler.GetTasks)
	router.POST("/tasks", handler.PostTask)

	return router
}

func TestGetTasks(t *testing.T) {
	handler, mock := setupTestHandler(t)

	mock.ExpectQuery(regexp.QuoteMeta(`SELECT * FROM "tasks"`)).
		WillReturnRows(
			sqlmock.NewRows([]string{"id", "title"}).
				AddRow("550e8400-e29b-41d4-a716-446655440000", "First task").
				AddRow("550e8400-e29b-41d4-a716-446655440001", "Second task"),
		)

	router := setupRouter(handler)

	req := httptest.NewRequest(http.MethodGet, "/tasks", nil)
	rec := httptest.NewRecorder()

	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusOK {
		t.Fatalf("ожидался статус 200, получен %d: %s",
			rec.Code, rec.Body.String())
	}

	var response GetTasksResponse
	if err := json.Unmarshal(rec.Body.Bytes(), &response); err != nil {
		t.Fatalf("ошибка разбора JSON: %v", err)
	}

	if len(response.Tasks) != 2 {
		t.Fatalf("ожидалось 2 задачи, получено %d", len(response.Tasks))
	}

	if response.Tasks[0].Title != "First task" {
		t.Errorf("ожидался заголовок First task, получен %q",
			response.Tasks[0].Title)
	}

	if response.Tasks[1].Title != "Second task" {
		t.Errorf("ожидался заголовок Second task, получен %q",
			response.Tasks[1].Title)
	}

	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("SQL-ожидания не выполнены: %v", err)
	}
}

func TestPostTaskSuccess(t *testing.T) {
	handler, mock := setupTestHandler(t)

	mock.ExpectBegin()

	mock.ExpectExec(regexp.QuoteMeta(
		`INSERT INTO "tasks" ("id","title") VALUES ($1,$2)`,
	)).
		WithArgs(sqlmock.AnyArg(), "Test task").
		WillReturnResult(sqlmock.NewResult(0, 1))

	mock.ExpectCommit()

	router := setupRouter(handler)

	body := `{"task":{"title":"Test task"}}`
	req := httptest.NewRequest(
		http.MethodPost,
		"/tasks",
		bytes.NewBufferString(body),
	)
	req.Header.Set("Content-Type", "application/json")

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusNoContent {
		t.Fatalf(
			"ожидался статус 204, получен %d: %s",
			rec.Code,
			rec.Body.String(),
		)
	}

	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("SQL-ожидания не выполнены: %v", err)
	}
}

func TestPostTaskBadRequest(t *testing.T) {
	handler, mock := setupTestHandler(t)
	router := setupRouter(handler)

	body := `{"task":{"title":""}}`
	req := httptest.NewRequest(
		http.MethodPost,
		"/tasks",
		bytes.NewBufferString(body),
	)
	req.Header.Set("Content-Type", "application/json")

	rec := httptest.NewRecorder()
	router.ServeHTTP(rec, req)

	if rec.Code != http.StatusBadRequest {
		t.Fatalf("ожидался статус 400, получен %d: %s",
			rec.Code, rec.Body.String())
	}

	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("SQL-ожидания не выполнены: %v", err)
	}
}
